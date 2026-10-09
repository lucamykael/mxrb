# frozen_string_literal: true

require 'bigdecimal'
require_relative 'decimal_formatting'

module Mxrb
  module Runtime
    # Microflow expression functions measured on Mendix 11.12.1. Regular
    # expressions follow Java: isMatch matches the whole text and replacement
    # text is literal (no $1 groups). pow computes with doubles, sqrt with the
    # 38-digit decimal context, and parseInteger rejects blanks and fractions.
    module ExpressionFunctions
      NAMES = %w[replaceall replacefirst ismatch pow sqrt max min parseinteger formatdecimal].freeze
      LONG = (-(2**63))..((2**63) - 1)

      module_function

      def invoke(name, arguments, decimal)
        return math(name, arguments, decimal) if %w[pow sqrt].include?(name)
        return extreme(name, arguments) if %w[max min].include?(name)

        public_send(name.to_sym, arguments)
      end

      def replaceall(arguments) = text(arguments, 3).then { |value, regex, by| value.gsub(pattern(regex)) { by } }
      def replacefirst(arguments) = text(arguments, 3).then { |value, regex, by| value.sub(pattern(regex)) { by } }
      def ismatch(arguments) = text(arguments, 2).then { |value, regex| /\A(?:#{pattern(regex)})\z/.match?(value) }
      def formatdecimal(arguments) = DecimalFormatting.format(number(arguments, 2).first, arguments[1].to_s)

      def math(name, arguments, decimal)
        if name == 'sqrt'
          return decimal.significant(DecimalValues.parse(number(arguments,
                                                                1).first).sqrt(decimal.precision + 5))
        end

        base, exponent = number(arguments, 2)
        DecimalValues.parse((base.to_f**exponent.to_f).to_s)
      end

      def text(arguments, count)
        unless arguments.length == count && arguments.all?(String)
          raise ArgumentError,
                "expected #{count} text arguments"
        end

        arguments
      end

      def number(arguments, count)
        unless arguments.length == count && arguments.first.is_a?(Numeric)
          raise ArgumentError,
                "expected #{count} numeric arguments"
        end

        arguments
      end

      def pattern(source)
        Regexp.new(source)
      rescue RegexpError => e
        raise ArgumentError, "invalid regular expression: #{e.message}"
      end

      def extreme(name, arguments)
        raise ArgumentError, "#{name} requires numbers" unless arguments.length >= 2 && arguments.all?(Numeric)

        name == 'max' ? arguments.max : arguments.min
      end

      def parseinteger(arguments)
        unless (1..2).cover?(arguments.length)
          raise ArgumentError,
                'parseInteger requires a text and an optional default'
        end

        value = arguments.first
        result = Integer(value, 10) if value.is_a?(String) && value.match?(/\A[+-]?\d+\z/)
        return result if result && LONG.cover?(result)
        return arguments[1] if arguments.length == 2

        raise ArgumentError, "cannot parse #{value.inspect} as an integer"
      end
    end
  end
end
