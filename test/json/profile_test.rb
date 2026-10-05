# frozen_string_literal: true

# Minitest for JSON::Profile — the explicit JSON generation profile.
#
# Run with:
#   ruby -Ilib test/json/profile_test.rb

require 'json'
require 'minitest/autorun'

class JSONProfileTest < Minitest::Test
  def setup
    @to_json_calls = 0
    @hook_calls = 0
  end

  # --- native types -------------------------------------------------------

  def test_nil_outputs_null
    profile = JSON::Profile.new
    assert_equal 'null', profile.generate(nil)
  end

  def test_native_scalars
    profile = JSON::Profile.new
    assert_equal 'true', profile.generate(true)
    assert_equal 'false', profile.generate(false)
    assert_equal '42', profile.generate(42)
    assert_equal '3.14', profile.generate(3.14)
    assert_equal '"hello"', profile.generate('hello')
  end

  def test_native_arrays_and_hashes_keep_structure
    profile = JSON::Profile.new
    assert_equal '[1,2,3]', profile.generate([1, 2, 3])
    assert_equal '{"a":1,"b":"x"}', profile.generate(a: 1, b: 'x')
    assert_equal '{"a":[1,{"b":2}]}', profile.generate(a: [1, { b: 2 }])
  end

  # --- unknown objects ----------------------------------------------------

  def test_unknown_object_raises
    profile = JSON::Profile.new
    obj = Object.new
    error = assert_raises(JSON::GeneratorError) { profile.generate(obj) }
    assert_match(/not allowed in JSON/, error.message)
  end

  def test_unauthorized_to_json_is_never_called
    klass = Class.new do
      def to_json(*)
        $to_json_calls += 1
        '"unauthorized"'
      end
    end
    $to_json_calls = 0
    profile = JSON::Profile.new # no whitelist
    assert_raises(JSON::GeneratorError) { profile.generate(klass.new) }
    assert_equal 0, $to_json_calls
  end

  # --- whitelist ----------------------------------------------------------

  def test_whitelisted_to_json_is_called
    klass = Class.new do
      def to_json(*)
        '"authorized"'
      end
    end
    profile = JSON::Profile.new(allowed: klass)
    assert_equal '"authorized"', profile.generate(klass.new)
  end

  def test_whitelist_accepts_an_array_of_classes
    klass_a = Class.new { def to_json(*); '"a"'; end }
    klass_b = Class.new { def to_json(*); '"b"'; end }
    profile = JSON::Profile.new(allowed: [klass_a, klass_b])
    assert_equal '["a","b"]', profile.generate([klass_a.new, klass_b.new])
  end

  # --- hook ---------------------------------------------------------------

  def test_legal_hook_is_called_once_per_object
    obj = Object.new
    calls = 0
    profile = JSON::Profile.new do |object|
      calls += 1
      '"hooked"'
    end
    # The same object appears twice (DAG, not a cycle): hook must run once.
    assert_equal '["hooked","hooked"]', profile.generate([obj, obj])
    assert_equal 1, calls
  end

  def test_hook_returning_two_root_values_is_rejected
    profile = JSON::Profile.new { |_obj| '1,2' }
    error = assert_raises(JSON::GeneratorError) { profile.generate(Object.new) }
    assert_match(/invalid JSON value/, error.message)
  end

  def test_hook_returning_a_fragment
    profile = JSON::Profile.new { |_obj| JSON::Fragment.new('[1,2,3]') }
    assert_equal '[1,2,3]', profile.generate(Object.new)
  end

  def test_hook_returning_non_json_type_is_rejected
    profile = JSON::Profile.new { |_obj| Object.new }
    assert_raises(JSON::GeneratorError) { profile.generate(Object.new) }
  end

  # --- cycles -------------------------------------------------------------

  def test_self_loop_reports_position
    profile = JSON::Profile.new
    a = []
    a << a
    error = assert_raises(JSON::GeneratorError) do
      profile.generate(foo: { bar: a })
    end
    assert_match(/circular reference detected/, error.message)
    assert_match(/\$\.foo\.bar\[0\]/, error.message)
  end

  def test_mutual_cycle_reports_position
    profile = JSON::Profile.new
    a = []
    b = [a]
    a << b
    error = assert_raises(JSON::GeneratorError) { profile.generate(a) }
    assert_match(/circular reference detected/, error.message)
    assert_match(/\$\[0\]\[0\]/, error.message)
  end

  # --- atomicity ----------------------------------------------------------

  def test_failure_does_not_write_half_a_result
    profile = JSON::Profile.new
    obj = Object.new
    assert_raises(JSON::GeneratorError) { profile.generate(obj) }
    # The profile is still usable after a failure.
    assert_equal 'null', profile.generate(nil)
  end

  # --- three-object example -----------------------------------------------

  def test_three_object_example
    # Three objects: one whitelisted (to_json called), one hooked (hook
    # called), and one native (passed through). The profile serializes all
    # three into a single JSON document.
    whitelisted = Class.new do
      def to_json(*)
        '"whitelisted"'
      end
    end

    hooked = Object.new
    calls = 0

    profile = JSON::Profile.new(allowed: [whitelisted]) do |object|
      calls += 1
      case object
      when hooked then '"hooked"'
      else raise "unexpected object"
      end
    end

    document = profile.generate([whitelisted.new, hooked, { native: true }])
    assert_equal '["whitelisted","hooked",{"native":true}]', document
    assert_equal 1, calls
  end

  # --- JSON.generate integration ------------------------------------------

  def test_generate_with_profile_option
    profile = JSON::Profile.new
    assert_equal '[1,2,3]', JSON.generate([1, 2, 3], profile: profile)
  end

  def test_json_profile_factory
    klass = Class.new
    profile = JSON.profile { |_obj| '"ok"' }
    assert_equal '"ok"', profile.generate(klass.new)
  end

  # --- formatting options --------------------------------------------------

  def test_formatting_options_are_passed_through
    profile = JSON::Profile.new(indent: '  ', space: ' ', object_nl: "\n")
    expected = "{\n  \"a\": 1\n}"
    assert_equal expected, profile.generate(a: 1)
  end
end
