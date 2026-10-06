# frozen_string_literal: true

# Tests for the explicit numeric conversion strategy of JSON.parse:
# integer_class / decimal_class converters and the max_number_length limit.
#
# Local command (run from the repository root, Minitest only):
#
#   ruby -Ilib -Itest test/json/json_number_strategy_test.rb
#
# The four-number example document used throughout:
#
#   [9007199254740993, 1.50, -0.25e3, 42]
#
# - 9007199254740993 is 2**53 + 1: an integer Float cannot represent exactly;
# - 1.50 is a decimal whose trailing zero only survives in the raw lexeme;
# - -0.25e3 is a decimal with an exponent (and a sign);
# - 42 is a plain small integer.

$LOAD_PATH.unshift(File.expand_path('../../../lib', __FILE__))

require 'json'
require 'bigdecimal'
require 'minitest/autorun'

class JSONNumberStrategyTest < Minitest::Test
  FOUR_NUMBERS = '[9007199254740993, 1.50, -0.25e3, 42]'.freeze

  # Records every lexeme it is called with, then converts it like Kernel#Integer
  # or Kernel#BigDecimal would. `hook` runs on the first call only.
  class LexemeRecorder
    attr_reader :lexemes
    attr_accessor :hook

    def initialize(&convert)
      @lexemes = []
      @convert = convert
      @hook = nil
    end

    def try_convert(lexeme)
      hook, @hook = @hook, nil
      hook&.call
      @lexemes << lexeme
      @convert.call(lexeme)
    end
  end

  def parse_four(**options)
    JSON.parse(FOUR_NUMBERS, **options)
  end

  def test_default_parse_is_unchanged
    assert_equal [9007199254740993, 1.5, -250.0, 42], parse_four
    assert_equal [Integer, Float, Float, Integer], parse_four.map(&:class)
    # No limit by default: a 1024-digit literal still parses to an exact Integer.
    big = '1' * 1024
    assert_equal big.to_i, JSON.parse(big)
  end

  def test_integer_above_2_to_the_53_stays_exact
    integers = LexemeRecorder.new { |lexeme| Integer(lexeme) }
    result = parse_four(integer_class: integers)

    assert_equal 2**53 + 1, result[0]
    assert_equal 9007199254740993, result[0]
    assert_instance_of Integer, result[0]
    # Only the two integer literals went to the integer converter.
    assert_equal %w[9007199254740993 42], integers.lexemes
  end

  def test_decimal_converter_receives_the_original_lexeme
    decimals = LexemeRecorder.new { |lexeme| BigDecimal(lexeme) }
    result = parse_four(decimal_class: decimals)

    # The raw lexemes are passed through, not a pre-parsed Float:
    # the trailing zero of 1.50 and the exponent form of -0.25e3 survive.
    assert_equal ['1.50', '-0.25e3'], decimals.lexemes
    assert_equal BigDecimal('1.50'), result[1]
    assert_equal BigDecimal('-0.25e3'), result[2]
  end

  def test_integer_and_decimal_lexemes_are_dispatched_separately
    integers = LexemeRecorder.new { |lexeme| Integer(lexeme) }
    decimals = LexemeRecorder.new { |lexeme| BigDecimal(lexeme) }

    result = parse_four(integer_class: integers, decimal_class: decimals)

    assert_equal [9007199254740993, BigDecimal('1.50'), BigDecimal('-0.25e3'), 42], result
    assert_equal %w[9007199254740993 42], integers.lexemes
    assert_equal ['1.50', '-0.25e3'], decimals.lexemes
  end

  def test_converter_is_called_exactly_once_per_number
    integers = LexemeRecorder.new { |lexeme| Integer(lexeme) }
    decimals = LexemeRecorder.new { |lexeme| BigDecimal(lexeme) }

    parse_four(integer_class: integers, decimal_class: decimals)

    # Four numbers in the document, four converter calls in total.
    assert_equal 4, integers.lexemes.size + decimals.lexemes.size
    assert_equal 2, integers.lexemes.size
    assert_equal 2, decimals.lexemes.size

    single = LexemeRecorder.new { |lexeme| Integer(lexeme) }
    assert_equal 7, JSON.parse('7', integer_class: single)
    assert_equal ['7'], single.lexemes
  end

  def test_converter_failure_preserves_position_and_returns_no_half_object
    failing = Class.new do
      def self.new(lexeme)
        raise ArgumentError, "cannot convert #{lexeme}"
      end
    end

    error = assert_raises(JSON::ParserError) do
      JSON.parse("[1, 2,\n  3.5, 4]", decimal_class: failing)
    end

    # The error points at the offending literal, not at the cursor position
    # reached after it, and the converter's own exception is the cause.
    assert_equal 2, error.line
    assert_equal 3, error.column
    assert_includes error.message, '3.5'
    assert_instance_of ArgumentError, error.cause
    assert_equal 'cannot convert 3.5', error.cause.message
  end

  def test_overlong_literal_is_rejected_before_conversion
    integers = LexemeRecorder.new { |lexeme| Integer(lexeme) }

    error = assert_raises(JSON::ParserError) do
      JSON.parse('[12345, 1]', integer_class: integers, max_number_length: 4)
    end

    # Rejected up front: the converter was never invoked for the long literal.
    assert_empty integers.lexemes
    assert_includes error.message, 'max_number_length'
    assert_equal 1, error.line
    assert_equal 2, error.column

    # A literal exactly at the limit is fine.
    assert_equal [1234, 1], JSON.parse('[1234, 1]', integer_class: integers, max_number_length: 4)
    assert_equal %w[1234 1], integers.lexemes

    # The sign counts towards the length; the limit also covers decimals.
    assert_raises(JSON::ParserError) { JSON.parse('-1234', max_number_length: 4) }
    assert_raises(JSON::ParserError) { JSON.parse('1.5', max_number_length: 2) }
    assert_raises(ArgumentError) { JSON.parse('1', max_number_length: -1) }
  end

  def test_converters_are_never_resolved_from_strings
    # Passing a name must not dynamically load or resolve a class.
    assert_raises(ArgumentError) { JSON.parse('1', integer_class: 'Integer') }
    assert_raises(ArgumentError) { JSON.parse('1.5', decimal_class: 'BigDecimal') }
    assert_raises(ArgumentError) { JSON.parse('1', integer_class: :Integer) }
  end

  def test_json_class_key_is_inert_data_and_triggers_no_dynamic_loading
    const_missing_calls = []
    object_singleton = class << Object; self; end
    object_singleton.send(:alias_method, :__original_const_missing, :const_missing)
    object_singleton.send(:define_method, :const_missing) do |name|
      const_missing_calls << name
      raise "json_class must not dynamically load #{name}"
    end

    begin
      document = '{"json_class": "NoSuchClassAnywhere", "n": 9007199254740993}'
      result = JSON.parse(document, integer_class: Integer)
    ensure
      object_singleton.send(:alias_method, :const_missing, :__original_const_missing)
      object_singleton.send(:remove_method, :__original_const_missing)
    end

    assert_empty const_missing_calls
    assert_equal({ 'json_class' => 'NoSuchClassAnywhere', 'n' => 9007199254740993 }, result)
  end

  def test_strategy_is_sealed_for_the_duration_of_a_parse
    second = LexemeRecorder.new { |lexeme| Integer(lexeme) }
    first = LexemeRecorder.new { |lexeme| Integer(lexeme) }
    config = JSON::Ext::Parser::Config.new(integer_class: first)
    # Mid-parse, the first converter swaps the Config over to the second
    # converter; the ongoing parse must keep the sealed strategy.
    first.hook = -> { config.send(:initialize, integer_class: second) }

    result = config.parse('[10, 20, 30]')

    assert_equal [10, 20, 30], result
    assert_equal %w[10 20 30], first.lexemes
    assert_empty second.lexemes
  end

  def test_coder_and_resumable_parser_accept_the_strategy
    coder = JSON::Coder.new(integer_class: Integer, decimal_class: BigDecimal)
    assert_equal [9007199254740993, BigDecimal('1.50')], coder.load('[9007199254740993, 1.50]')

    parser = JSON::ResumableParser.new(integer_class: Integer)
    parser << '9007199254740993 '
    assert parser.parse
    assert_equal 9007199254740993, parser.value
  end
end
