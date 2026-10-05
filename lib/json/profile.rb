# frozen_string_literal: true

require 'json'

module JSON
  # = JSON::Profile -- explicit JSON generation profile
  #
  # JSON::Profile is an opt-in, allow-list based JSON generator.
  # Unlike JSON.generate, which falls back to calling +to_s+
  # (via Object#to_json) on any unknown object, a profile only emits
  # JSON for:
  #
  # - JSON scalars: +nil+, +true+, +false+, Integer, Float, String, Symbol
  #   (+nil+ is still emitted as +null+),
  # - plain Array and Hash structures (kept as-is, recursively),
  # - instances of classes explicitly declared via +:allow+
  #   (their zero-argument +to_json+ is invoked and its result is
  #   validated as a single JSON value),
  # - instances of classes with an explicitly registered +:hook+
  #   (the hook is called at most once per object per #generate call
  #   and must return a String containing exactly one valid JSON value).
  #
  # Any other object raises JSON::Profile::UnallowedClassError:
  # its +to_json+ is *never* called and no hook runs for it.
  #
  # Additional guarantees:
  #
  # - Circular Array/Hash structures raise JSON::Profile::CircularError
  #   whose +path+ pinpoints where the cycle was detected
  #   (e.g. <tt>$[0]</tt>, <tt>$.items[2]["self"]</tt>).
  # - Generation is atomic: the document is built in an internal buffer
  #   and only returned (or written to the optional IO) once the whole
  #   document succeeded. A failure never emits half a document.
  # - JSON.generate keeps its default, fully compatible behavior;
  #   profiles are a separate, explicit API.
  #
  # == Three-object example
  #
  #   require 'json/profile'
  #
  #   class Point
  #     def initialize(x, y); @x, @y = x, y; end
  #     def to_json(*) = %({"x":#{@x},"y":#{@y}})
  #   end
  #
  #   class User
  #     attr_reader :id
  #     def initialize(id); @id = id; end
  #   end
  #
  #   profile = JSON::Profile.new(
  #     allow: [Point],
  #     hooks: { User => ->(user) { %({"id":#{user.id}}) } }
  #   )
  #
  #   profile.generate([Point.new(1, 2), User.new(7), nil])
  #   # => '[{"x":1,"y":2},{"id":7},null]'
  #
  class Profile
    # Backslash character, built without a literal so the source stays
    # free of escape sequences.
    BACKSLASH = 92.chr

    # Base class for all profile generation errors.
    class Error < JSON::GeneratorError
      # JSONPath-like location of the offending value, e.g. <tt>$[0]["a"]</tt>.
      attr_reader :path

      def initialize(message, path)
        @path = path
        super("#{message} at #{path}")
      end
    end

    # Raised when an object is neither a JSON scalar, a plain Array/Hash,
    # an instance of an allowed class, nor covered by a hook.
    # Its +to_json+ is never invoked and no hook is run for it.
    class UnallowedClassError < Error
      attr_reader :klass

      def initialize(klass, path)
        @klass = klass
        super("class #{klass} is not allowed by this profile", path)
      end
    end

    # Raised when a circular Array/Hash reference is detected.
    # +path+ is the position at which the cycle closes.
    class CircularError < Error
      def initialize(path)
        super('circular reference detected', path)
      end
    end

    # Raised when a hook itself fails.
    class HookError < Error; end

    # Raised when a hook (or an allowed +to_json+) does not return
    # exactly one valid JSON value encoded as a String.
    class HookResultError < Error; end

    # Raised for other invalid values (e.g. non-finite Float,
    # invalid string encoding, unsupported Hash key).
    class ValueError < Error; end

    ESCAPES = {
      '"'        => BACKSLASH + '"',
      BACKSLASH  => BACKSLASH + BACKSLASH,
      8.chr      => BACKSLASH + 'b',
      12.chr     => BACKSLASH + 'f',
      10.chr     => BACKSLASH + 'n',
      13.chr     => BACKSLASH + 'r',
      9.chr      => BACKSLASH + 't',
    }.freeze

    NON_SIMPLE_KEY_CHAR = /[^A-Za-z0-9_]/.freeze
    SIMPLE_KEY_START = /[A-Za-z_]/.freeze

    # +allow+: Array of classes/modules whose instances' zero-argument
    #          +to_json+ may be called.
    # +hooks+: Hash mapping class/module => callable. The callable
    #          receives the object and must return a String containing
    #          exactly one valid JSON value. It is invoked at most once
    #          per object per #generate call.
    def initialize(allow: [], hooks: {})
      @allow = allow.freeze
      @hooks = hooks.freeze
      @hook_cache = {} # object_id => validated JSON fragment (per generate call)
    end

    # Generates a JSON document for +object+ according to this profile.
    # Returns the document as a String. If +io+ is given, the complete
    # document is written to it in a single write, only after the whole
    # document was generated successfully; on failure nothing is written.
    def generate(object, io = nil)
      @hook_cache.clear
      begin
        result = generate_value(object, [])
      ensure
        @hook_cache.clear
      end
      io&.write(result)
      result
    end

    private

    def generate_value(object, segments)
      case object
      when nil        then 'null'
      when true       then 'true'
      when false      then 'false'
      when Integer    then object.to_s
      when Float      then generate_float(object, segments)
      when String     then escape_string(object, segments)
      when Symbol     then escape_string(object.to_s, segments)
      when Array      then generate_array(object, segments)
      when Hash       then generate_hash(object, segments)
      else
        generate_object(object, segments)
      end
    end

    def generate_float(float, segments)
      unless float.finite?
        raise ValueError.new("non-finite Float #{float.inspect} is not a valid JSON value", path(segments))
      end
      float.to_s
    end

    def escape_string(string, segments)
      utf8 =
        begin
          string.encode(Encoding::UTF_8)
        rescue EncodingError => e
          raise ValueError.new("invalid string encoding: #{e.message}", path(segments))
        end
      out = +'"'
      utf8.each_char do |char|
        escaped = ESCAPES[char]
        if escaped
          out << escaped
        elsif char.ord < 0x20
          out << BACKSLASH << 'u' << format('%04x', char.ord)
        else
          out << char
        end
      end
      out << '"'
    end

    def generate_array(array, segments)
      check_circular!(array, segments)
      segments << nil
      begin
        parts = array.each_with_index.map do |element, index|
          segments[-1] = index
          generate_value(element, segments)
        end
      ensure
        segments.pop
        unmark(array)
      end
      "[#{parts.join(',')}]"
    end

    def generate_hash(hash, segments)
      check_circular!(hash, segments)
      segments << nil
      begin
        parts = hash.map do |key, value|
          key_string = hash_key(key, segments)
          segments[-1] = key_string
          "#{escape_string(key_string, segments)}:#{generate_value(value, segments)}"
        end
      ensure
        segments.pop
        unmark(hash)
      end
      "{#{parts.join(',')}}"
    end

    def hash_key(key, segments)
      case key
      when String  then key
      when Symbol  then key.to_s
      when Integer then key.to_s
      else
        raise UnallowedClassError.new(key.class, path(segments))
      end
    end

    def generate_object(object, segments)
      hook = find_hook(object)
      if hook
        return run_hook(hook, object, segments)
      end
      if @allow.any? { |klass| object.is_a?(klass) }
        fragment =
          begin
            object.to_json
          rescue Error
            raise
          rescue => e
            raise Error.new("to_json of #{object.class} failed: #{e.message}", path(segments))
          end
        return validate_fragment(fragment, segments, "to_json of #{object.class}")
      end
      # Unknown object: never call to_json, never run a hook.
      raise UnallowedClassError.new(object.class, path(segments))
    end

    def find_hook(object)
      @hooks.each do |klass, callable|
        return callable if object.is_a?(klass)
      end
      nil
    end

    # Each object is passed through its hook at most once per #generate
    # call; the validated fragment is memoized by object identity.
    def run_hook(hook, object, segments)
      id = object.__id__
      return @hook_cache[id] if @hook_cache.key?(id)

      fragment =
        begin
          hook.call(object)
        rescue Error
          raise
        rescue => e
          raise HookError.new("hook for #{object.class} raised #{e.class}: #{e.message}", path(segments))
        end
      @hook_cache[id] = validate_fragment(fragment, segments, "hook for #{object.class}")
    end

    # A hook (or allowed to_json) must return a String containing exactly
    # one valid JSON value -- nothing more, nothing less.
    def validate_fragment(fragment, segments, source)
      unless fragment.is_a?(String)
        raise HookResultError.new(
          "#{source} must return a String containing a single JSON value, got #{fragment.class}",
          path(segments))
      end
      begin
        JSON.parse(fragment)
      rescue JSON::ParserError => e
        raise HookResultError.new(
          "#{source} did not return exactly one valid JSON value: #{e.message}",
          path(segments))
      end
      fragment
    end

    # --- circular reference tracking ---------------------------------

    def check_circular!(container, segments)
      @ancestors ||= {}.compare_by_identity
      if @ancestors.key?(container)
        raise CircularError.new(path(segments))
      end
      @ancestors[container] = true
    end

    def unmark(container)
      @ancestors.delete(container)
    end

    # --- JSONPath-like position rendering -----------------------------

    def simple_key?(key)
      return false if key.empty?
      return false unless SIMPLE_KEY_START.match?(key[0])
      !NON_SIMPLE_KEY_CHAR.match?(key)
    end

    def path(segments)
      segments.each_with_object(+'$') do |segment, out|
        case segment
        when Integer
          out << "[#{segment}]"
        when String
          if simple_key?(segment)
            out << ".#{segment}"
          else
            out << "[#{segment.inspect}]"
          end
        end
      end
    end
  end
end
