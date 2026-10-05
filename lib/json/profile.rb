# frozen_string_literal: true

module JSON
  # JSON::Profile is an explicit JSON generation profile.
  #
  # Unlike JSON.generate, which silently converts unknown objects to strings
  # via #to_s, a Profile only serializes:
  # - native JSON types (Hash, Array, String, Integer, Float, true, false, nil),
  # - objects whose class is explicitly whitelisted (via #to_json),
  # - and objects handled by an optional hook proc.
  #
  # Unknown objects raise a JSON::GeneratorError. Cycles are reported with
  # their JSON path. The hook is called at most once per object, and its
  # return value must be a single valid JSON value (raw JSON text).
  #
  #   profile = JSON::Profile.new(allowed: [Time]) do |object|
  #     object.iso8601.to_json
  #   end
  #   profile.generate(Time.now) # => "\"2025-...\""
  #
  class Profile
    # call-seq:
    #   JSON::Profile.new(allowed: nil, **options, &hook)
    #
    # Creates an explicit generation profile.
    #
    # +allowed+ is a Class or an Array of Classes whose #to_json method is
    # authorized to be called. Objects of other classes are either passed to
    # the +hook+ proc (if given) or raise a JSON::GeneratorError.
    #
    # The +hook+ proc is called at most once per object, with the object as
    # its single argument. It must return a String containing a single valid
    # JSON value (raw JSON text), or a JSON::Fragment.
    #
    # +options+ are generation options (indent, space, etc.) passed through to
    # the generator.
    def initialize(allowed: nil, **options, &hook)
      @allowed = Array(allowed).freeze
      @hook = hook
      @options = options.reject { |k, _| k == :as_json }.freeze
      freeze
    end

    # call-seq:
    #   profile.generate(obj) -> String
    #   profile.generate(obj, io) -> io
    #
    # Generates a valid JSON document from +obj+ using this profile.
    # Raises JSON::GeneratorError if +obj+ contains unknown objects, cycles,
    # or if the hook returns an invalid JSON value.
    def generate(obj, io = nil)
      transformed = transform(obj)
      json = JSON.generate(transformed, @options)
      if io
        io.write(json)
        io
      else
        json
      end
    end
    alias_method :dump, :generate

    private

    def transform(obj)
      walk(obj, '$', {}, {})
    end

    def walk(obj, path, ancestors, hook_cache)
      if obj.instance_of?(Hash)
        check_cycle!(obj, path, ancestors)
        ancestors[obj.object_id] = true
        result = {}
        obj.each do |key, value|
          result[key] = walk(value, path_for(path, key), ancestors, hook_cache)
        end
        ancestors.delete(obj.object_id)
        result
      elsif obj.instance_of?(Array)
        check_cycle!(obj, path, ancestors)
        ancestors[obj.object_id] = true
        result = []
        obj.each_with_index do |value, index|
          result << walk(value, "#{path}[#{index}]", ancestors, hook_cache)
        end
        ancestors.delete(obj.object_id)
        result
      elsif native_scalar?(obj)
        obj
      else
        if allowed?(obj)
          json = obj.to_json
          validate_json!(json, path)
          Fragment.new(json)
        elsif @hook
          result = hook_cache[obj.object_id]
          unless hook_cache.key?(obj.object_id)
            result = @hook.call(obj)
            hook_cache[obj.object_id] = result
          end
          process_hook_result(result, path)
        else
          raise GeneratorError, "not allowed in JSON: #{obj.class} at #{path}"
        end
      end
    end

    def native_scalar?(obj)
      obj.instance_of?(String) ||
        obj.instance_of?(Integer) ||
        obj.instance_of?(Float) ||
        obj.equal?(true) ||
        obj.equal?(false) ||
        obj.equal?(nil)
    end

    def allowed?(obj)
      @allowed.any? { |klass| obj.is_a?(klass) }
    end

    def check_cycle!(obj, path, ancestors)
      if ancestors.key?(obj.object_id)
        raise GeneratorError, "circular reference detected at #{path}"
      end
    end

    def process_hook_result(result, path)
      case result
      when String
        validate_json!(result, path)
        Fragment.new(result)
      when Fragment
        validate_json!(result.json, path)
        result
      when Integer, Float, TrueClass, FalseClass, NilClass, Hash, Array
        result
      else
        raise GeneratorError, "hook must return a JSON value (String or Fragment), got #{result.class} at #{path}"
      end
    end

    def validate_json!(json, path)
      unless json.is_a?(String)
        raise GeneratorError, "expected to_json to return a JSON String, got #{json.class} at #{path}"
      end
      JSON.parse(json, max_nesting: false)
    rescue ParserError => e
      raise GeneratorError, "invalid JSON value at #{path}: #{e.message}"
    end

    def path_for(path, key)
      case key
      when String, Symbol
        key_str = key.to_s
        if key_str.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/)
          "#{path}.#{key_str}"
        else
          "#{path}[#{key_str.inspect}]"
        end
      else
        "#{path}[#{key.inspect}]"
      end
    end
  end

  class << self
    # call-seq:
    #   JSON.profile(allowed: nil, **options, &hook) -> JSON::Profile
    #
    # Creates an explicit JSON generation profile. See JSON::Profile.
    def profile(allowed: nil, **options, &hook)
      Profile.new(allowed: allowed, **options, &hook)
    end
  end
end
