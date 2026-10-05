# frozen_string_literal: true

# Standalone Minitest suite for JSON::Profile (explicit generation profile).
#
# Run it with:
#
#   ruby -Ilib test/json/json_profile_test.rb
#
$LOAD_PATH.unshift(File.expand_path('../../../lib', __FILE__))

require 'json'
require 'json/profile'
require 'minitest/autorun'
require 'stringio'

class JSONProfileTest < Minitest::Test
  # Allowed class whose zero-argument to_json may be called by the profile.
  class Point
    attr_reader :x, :y, :to_json_calls

    def initialize(x, y)
      @x, @y = x, y
      @to_json_calls = 0
    end

    def to_json
      @to_json_calls += 1
      %({"x":#{@x},"y":#{@y}})
    end
  end

  # Plain class without to_json support, serialized through a hook.
  class User
    attr_reader :id

    def initialize(id)
      @id = id
    end
  end

  # Object whose to_json and to_s must never be called when unauthorized.
  class Spy
    attr_reader :to_json_calls, :to_s_calls

    def initialize
      @to_json_calls = 0
      @to_s_calls = 0
    end

    def to_json
      @to_json_calls += 1
      '"spy"'
    end

    def to_s
      @to_s_calls += 1
      'spy-to-s'
    end
  end

  def profile(**opts)
    JSON::Profile.new(**opts)
  end

  # --- acceptance: unauthorized to_json count stays 0 -----------------

  def test_unauthorized_to_json_is_never_called
    spy = Spy.new
    error = assert_raises(JSON::Profile::UnallowedClassError) do
      profile.generate(['ok', spy])
    end
    assert_equal 0, spy.to_json_calls, 'to_json must not be called for unauthorized objects'
    assert_equal 0, spy.to_s_calls, 'to_s fallback must not be used for unknown objects'
    assert_equal Spy, error.klass
    assert_equal '$[1]', error.path
  end

  def test_unauthorized_object_does_not_fall_back_to_string
    spy = Spy.new
    profile.generate(spy)
    flunk 'expected UnallowedClassError'
  rescue JSON::Profile::UnallowedClassError
    assert_equal 0, spy.to_s_calls
  end

  def test_unknown_object_runs_no_hook
    hook_calls = 0
    p = profile(hooks: { User => ->(_u) { hook_calls += 1; 'null' } })
    assert_raises(JSON::Profile::UnallowedClassError) { p.generate(Spy.new) }
    assert_equal 0, hook_calls
  end

  # --- acceptance: legal hook runs exactly once per object -------------

  def test_hook_is_called_once_per_object
    user = User.new(7)
    calls = 0
    p = profile(hooks: { User => ->(u) { calls += 1; %({"id":#{u.id}}) } })
    result = p.generate([user, { 'again' => user }])
    assert_equal 1, calls, 'hook must run exactly once per object per generate call'
    assert_equal '[{"id":7},{"again":{"id":7}}]', result
  end

  # --- acceptance: hook returning two values is rejected ---------------

  def test_hook_returning_two_values_is_rejected
    p = profile(hooks: { User => ->(_u) { '1 2' } })
    error = assert_raises(JSON::Profile::HookResultError) { p.generate(User.new(1)) }
    assert_equal '$', error.path
  end

  def test_hook_returning_two_documents_is_rejected
    p = profile(hooks: { User => ->(_u) { '[1],[2]' } })
    assert_raises(JSON::Profile::HookResultError) { p.generate(User.new(1)) }
  end

  def test_hook_returning_non_string_is_rejected
    p = profile(hooks: { User => ->(_u) { 42 } })
    assert_raises(JSON::Profile::HookResultError) { p.generate(User.new(1)) }
  end

  def test_hook_returning_single_valid_value_is_accepted
    p = profile(hooks: { User => ->(u) { u.id.to_s } })
    assert_equal '7', p.generate(User.new(7))
  end

  # --- acceptance: circular references report their position ----------

  def test_self_referencing_array_reports_path
    a = []
    a << a
    error = assert_raises(JSON::Profile::CircularError) { profile.generate(a) }
    assert_equal '$[0]', error.path
    assert_includes error.message, '$[0]'
  end

  def test_self_referencing_hash_reports_path
    h = {}
    h['self'] = h
    error = assert_raises(JSON::Profile::CircularError) { profile.generate(h) }
    assert_equal '$.self', error.path
  end

  def test_nested_cycle_reports_full_position
    inner = []
    doc = { 'items' => [{ 'x' => inner }] }
    inner << doc
    error = assert_raises(JSON::Profile::CircularError) { profile.generate(doc) }
    assert_equal '$.items[0].x[0]', error.path
  end

  def test_shared_non_circular_containers_are_fine
    shared = [1, 2]
    assert_equal '[[1,2],[1,2]]', profile.generate([shared, shared])
  end

  # --- acceptance: nil scalar still generates null ---------------------

  def test_nil_scalar_generates_null
    assert_equal 'null', profile.generate(nil)
    assert_equal '[null]', profile.generate([nil])
    assert_equal '{"a":null}', profile.generate('a' => nil)
  end

  # --- acceptance: default JSON.generate stays compatible --------------

  def test_default_generate_is_unaffected
    assert_equal '{"a":[1,null,"x"]}', JSON.generate('a' => [1, nil, 'x'])
    # Default generation still falls back to to_s for arbitrary objects.
    obj = Object.new
    assert_equal obj.to_s.to_json, JSON.generate(obj)
    # ...while the profile rejects the very same object.
    assert_raises(JSON::Profile::UnallowedClassError) { profile.generate(obj) }
  end

  # --- structural guarantees --------------------------------------------

  def test_plain_arrays_and_hashes_keep_structure
    doc = { 'list' => [1, 2.5, 'three', true, false, nil], 'empty' => [], 'h' => { 'k' => 'v' } }
    assert_equal JSON.generate(doc), profile.generate(doc)
  end

  def test_string_escaping_matches_default_generator
    tricky = "quote#{34.chr} backslash#{92.chr} newline#{10.chr} tab#{9.chr} ctrl#{1.chr} unicode:e9"
    assert_equal JSON.generate(tricky), profile.generate(tricky)
  end

  def test_allowed_class_to_json_is_used_and_validated
    point = Point.new(1, 2)
    assert_equal '[{"x":1,"y":2}]', profile(allow: [Point]).generate([point])
    assert_equal 1, point.to_json_calls

    bad = Class.new(Point) do
      def to_json
        '1 2' # two values: not a single legal JSON value
      end
    end
    assert_raises(JSON::Profile::HookResultError) do
      profile(allow: [bad]).generate(bad.new(0, 0))
    end
  end

  def test_failure_never_writes_partial_results
    spy = Spy.new
    io = StringIO.new
    assert_raises(JSON::Profile::UnallowedClassError) do
      profile.generate(['ok', 1, spy], io)
    end
    assert_equal '', io.string, 'a failed generation must not write half a document'

    ok = StringIO.new
    profile.generate(['ok', 1], ok)
    assert_equal '["ok",1]', ok.string
  end

  # --- three-object example ----------------------------------------------
  #
  #   profile.generate([Point.new(1, 2), User.new(7), nil])
  #   # => '[{"x":1,"y":2},{"id":7},null]'
  #
  # One object serialized via declared to_json (Point), one via a hook
  # (User), one scalar (nil -> null).
  def test_three_object_example
    p = profile(
      allow: [Point],
      hooks: { User => ->(u) { %({"id":#{u.id}}) } },
    )
    assert_equal '[{"x":1,"y":2},{"id":7},null]',
                 p.generate([Point.new(1, 2), User.new(7), nil])
  end
end
