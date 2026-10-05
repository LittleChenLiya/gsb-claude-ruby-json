# frozen_string_literal: true

# Tests for the explicit number_class parse strategy (integer and
# decimal/exponent literals are handed to separately registered converters).
#
# Minitest-style assertions; run locally from the repository root with:
#
#   ruby -Ilib -Iext -Itest/json test/json/json_number_strategy_test.rb
#
# (Build the C extension first, e.g. `rake compile`, or:
#  (cd ext/json/ext/parser && ruby extconf.rb && make) &&
#  cp ext/json/ext/parser/parser.so lib/json/ext/)
require 'test_helper'

class JSONNumberStrategyTest < Test::Unit::TestCase
  # 2**53 + 1 is not exactly representable as a Float.
  BIG_INTEGER = 9_007_199_254_740_993

  # Four-number example: a big integer beyond 2**53, a plain decimal,
  # a negative decimal with exponent, and a small integer.
  FOUR_NUMBERS = '[9007199254740993, 1.5, -2.5e-3, 42]'

  def test_default_parsing_is_unchanged
    assert_equal [BIG_INTEGER, 1.5, -0.0025, 42], JSON.parse(FOUR_NUMBERS)
    assert_kind_of Integer, JSON.parse('9007199254740993')
    assert_kind_of Float, JSON.parse('1.5')
    assert_kind_of Float, JSON.parse('1e3')
  end

  def test_four_numbers_example
    seen = { integer: [], float: [] }
    strategy = {
      integer: ->(lexeme) { seen[:integer] << lexeme; Integer(lexeme) },
      float:   ->(lexeme) { seen[:float]   << lexeme; BigDecimal(lexeme) },
    }

    result = JSON.parse(FOUR_NUMBERS, number_class: strategy)

    assert_equal [BIG_INTEGER, BigDecimal('1.5'), BigDecimal('-2.5e-3'), 42], result
    assert_equal ['9007199254740993', '42'], seen[:integer]
    assert_equal ['1.5', '-2.5e-3'], seen[:float]
  end

  def test_integer_beyond_2_to_the_53_stays_exact
    result = JSON.parse('[9007199254740993]', number_class: { integer: Integer })
    assert_equal [BIG_INTEGER], result
    assert_not_equal [2**53], result
  end

  def test_decimal_converter_receives_original_lexeme
    received = []
    JSON.parse('[1.50e2]', number_class: { float: ->(lexeme) { received << lexeme } })
    # The raw lexeme is passed through, not a Float round-trip ("150.0").
    assert_equal ['1.50e2'], received
  end

  def test_converter_is_called_exactly_once_per_number
    calls = Hash.new(0)
    strategy = {
      integer: ->(lexeme) { calls[:integer] += 1; Integer(lexeme) },
      float:   ->(lexeme) { calls[:float]   += 1; BigDecimal(lexeme) },
    }
    JSON.parse('[1, 2.0, 3e4, 5]', number_class: strategy)
    assert_equal({ integer: 2, float: 2 }, calls)
  end

  def test_class_converters_go_through_kernel_method
    result = JSON.parse('[42, 1.5]', number_class: { integer: Integer, float: BigDecimal })
    assert_equal [42, BigDecimal('1.5')], result
    assert_kind_of BigDecimal, result.last
  end

  def test_converter_failure_raises_parser_error_at_literal_position
    error = assert_raise(JSON::ParserError) do
      JSON.parse('[1, 2]', number_class: { integer: ->(_) { raise ArgumentError, 'nope' } })
    end
    assert_include error.message, 'nope'
    assert_include error.message, 'ArgumentError'
    assert_equal 1, error.line
    assert_equal 2, error.column
    assert_kind_of ArgumentError, error.cause
  end

  def test_converter_failure_returns_no_partial_object
    converter = ->(lexeme) { raise 'boom' if lexeme == '2'; Integer(lexeme) }
    error = assert_raise(JSON::ParserError) do
      JSON.parse('{"a": 1, "b": 2, "c": 3}', number_class: { integer: converter })
    end
    assert_include error.message, 'boom'
  end

  def test_overlong_integer_literal_is_rejected_before_conversion
    called = false
    converter = ->(lexeme) { called = true; Integer(lexeme) }
    error = assert_raise(JSON::ParserError) do
      JSON.parse("[#{'1' * 2000}]", number_class: { integer: converter })
    end
    assert_include error.message, 'too long'
    assert_equal false, called
  end

  def test_overlong_float_literal_is_rejected_before_conversion
    called = false
    converter = ->(lexeme) { called = true; BigDecimal(lexeme) }
    assert_raise(JSON::ParserError) do
      JSON.parse("[1.#{'1' * 2000}]", number_class: { float: converter })
    end
    assert_equal false, called
  end

  def test_string_or_symbol_converters_are_rejected
    assert_raise(TypeError) { JSON.parse('1',   number_class: { integer: 'Integer' }) }
    assert_raise(TypeError) { JSON.parse('1.0', number_class: { float: :BigDecimal }) }
  end

  def test_unknown_number_class_keywords_are_rejected
    assert_raise(ArgumentError) { JSON.parse('1', number_class: { decimal: BigDecimal }) }
  end

  def test_strategy_is_sealed_for_the_parse
    strategy = { integer: ->(lexeme) { Integer(lexeme) * 2 } }
    config = JSON::Ext::Parser::Config.new(number_class: strategy)
    assert_equal 4, config.parse('2')

    strategy[:integer] = ->(lexeme) { Integer(lexeme) * 10 }
    assert_equal 4, config.parse('2')
  end

  def test_json_class_key_is_not_instantiated
    document = '{"json_class": "JSONNumberStrategyTest::NotAClass", "n": 1}'
    expected = { 'json_class' => 'JSONNumberStrategyTest::NotAClass', 'n' => 1 }
    assert_equal expected, JSON.parse(document)
    assert_equal expected, JSON.parse(document, number_class: { integer: Integer })
  end

  def test_unregistered_kind_falls_back_to_default_decoding
    assert_equal [1.5], JSON.parse('[1.5]', number_class: { integer: Integer })
    assert_equal [3], JSON.parse('[3]', number_class: { float: BigDecimal })
  end
end
