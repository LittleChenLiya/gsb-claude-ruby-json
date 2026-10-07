# frozen_string_literal: true
require 'test_helper'

class DupPolicyWidget
  @create_calls = 0

  class << self
    attr_accessor :create_calls
  end

  def self.json_create(hash)
    self.create_calls += 1
    new(hash)
  end

  attr_reader :attributes

  def initialize(attributes)
    @attributes = attributes
  end
end

class JSONDuplicateKeyPolicyTest < Test::Unit::TestCase
  def setup
    DupPolicyWidget.create_calls = 0
  end

  def test_reject_is_the_default_strategy
    error = assert_raise(JSON::ParserError) { JSON.parse('{"a": 1, "a": 2}') }
    assert_include error.message, 'duplicate key "a"'
  end

  def test_reject_error_contains_key_and_nested_path
    error = assert_raise(JSON::ParserError) do
      JSON.parse('{"outer": {"json_class": "DupPolicyWidget", "a": 1, "a": 2}}', duplicate_key: :reject)
    end
    assert_include error.message, 'duplicate key "a"'
    assert_equal '$.outer.a', error.json_path
  end

  def test_reject_error_path_through_arrays
    error = assert_raise(JSON::ParserError) do
      JSON.parse('{"arr": [{"x": {"b": 1, "b": 2}}]}', duplicate_key: :reject)
    end
    assert_include error.message, 'duplicate key "b"'
    assert_equal '$.arr[0].x.b', error.json_path
  end

  def test_last_strategy_keeps_last_value
    assert_equal({ "a" => 2 }, JSON.parse('{"a": 1, "a": 2}', duplicate_key: :last))
    assert_equal({ "x" => { "a" => 3 } }, JSON.parse('{"x": {"a": 1, "a": 3}}', duplicate_key: :last))
  end

  def test_strategy_takes_precedence_over_allow_duplicate_key
    assert_equal({ "a" => 2 }, JSON.parse('{"a": 1, "a": 2}', allow_duplicate_key: false, duplicate_key: :last))
    assert_raise(JSON::ParserError) do
      JSON.parse('{"a": 1, "a": 2}', allow_duplicate_key: true, duplicate_key: :reject)
    end
  end

  def test_invalid_strategy_raises_argument_error
    error = assert_raise(ArgumentError) { JSON.parse('{}', duplicate_key: :first) }
    assert_include error.message, ':reject'
    assert_include error.message, ':last'
  end

  def test_allow_duplicate_key_option_still_supported
    assert_equal({ "a" => 2 }, JSON.parse('{"a": 1, "a": 2}', allow_duplicate_key: true))
    assert_raise(JSON::ParserError) { JSON.parse('{"a": 1, "a": 2}', allow_duplicate_key: false) }
  end

  def test_create_additions_creates_object_normally
    widget = JSON.parse('{"json_class": "DupPolicyWidget", "size": 3}', create_additions: true)
    assert_instance_of DupPolicyWidget, widget
    assert_equal 3, widget.attributes["size"]
    assert_equal 1, DupPolicyWidget.create_calls
  end

  def test_create_additions_creates_nested_objects
    json = '{"json_class": "DupPolicyWidget", "child": {"json_class": "DupPolicyWidget", "size": 1}}'
    widget = JSON.parse(json, create_additions: true)
    assert_instance_of DupPolicyWidget, widget
    assert_instance_of DupPolicyWidget, widget.attributes["child"]
    assert_equal 2, DupPolicyWidget.create_calls
  end

  def test_create_additions_runs_after_duplicate_validation
    error = assert_raise(JSON::ParserError) do
      JSON.parse('{"outer": {"json_class": "DupPolicyWidget", "a": 1, "a": 2}}',
                 create_additions: true, duplicate_key: :reject)
    end
    assert_include error.message, 'duplicate key "a"'
    assert_equal '$.outer.a', error.json_path
    assert_equal 0, DupPolicyWidget.create_calls
  end

  def test_create_additions_hook_not_called_with_default_strategy_either
    assert_raise(JSON::ParserError) do
      JSON.parse('{"json_class": "DupPolicyWidget", "a": 1, "a": 2}', create_additions: true)
    end
    assert_equal 0, DupPolicyWidget.create_calls
  end

  def test_create_additions_disabled_by_default
    result = JSON.parse('{"json_class": "DupPolicyWidget", "size": 3}')
    assert_equal({ "json_class" => "DupPolicyWidget", "size" => 3 }, result)
    assert_equal 0, DupPolicyWidget.create_calls
  end

  def test_create_additions_unknown_class_left_as_hash
    result = JSON.parse('{"json_class": "NoSuchClassAnywhere", "a": 1}', create_additions: true)
    assert_equal({ "json_class" => "NoSuchClassAnywhere", "a" => 1 }, result)
  end

  def test_create_additions_custom_create_id
    widget = JSON.parse('{"kind": "DupPolicyWidget", "size": 5}', create_additions: true, create_id: "kind")
    assert_instance_of DupPolicyWidget, widget
    assert_equal 5, widget.attributes["size"]
  end

  def test_load_supports_create_additions_and_duplicate_key
    widget = JSON.load('{"json_class": "DupPolicyWidget", "size": 1}', nil, create_additions: true)
    assert_instance_of DupPolicyWidget, widget

    assert_equal({ "a" => 2 }, JSON.load('{"a": 1, "a": 2}', nil, duplicate_key: :last))
    assert_raise(JSON::ParserError) { JSON.load('{"a": 1, "a": 2}') }
  end

  def test_coder_supports_duplicate_key_strategy
    coder = JSON::Coder.new(duplicate_key: :last)
    assert_equal({ "a" => 2 }, coder.load('{"a": 1, "a": 2}'))

    strict_coder = JSON::Coder.new(duplicate_key: :reject)
    assert_raise(JSON::ParserError) { strict_coder.load('{"a": 1, "a": 2}') }
  end

  def test_coder_supports_create_additions
    coder = JSON::Coder.new(create_additions: true)
    widget = coder.load('{"json_class": "DupPolicyWidget", "size": 2}')
    assert_instance_of DupPolicyWidget, widget
  end

  def test_original_interface_unchanged_without_new_options
    assert_equal({ "a" => 1 }, JSON.parse('{"a": 1}'))
    assert_equal [1, [2, 3]], JSON.parse('[1, [2, 3]]')
    assert_equal({ "a" => 1 }, JSON::Parser.new('{"a": 1}').parse)
    error = assert_raise(ArgumentError) { JSON.parse('{"a": 1}', bogus_option: true) }
    assert_include error.message, 'bogus_option'
  end
end
