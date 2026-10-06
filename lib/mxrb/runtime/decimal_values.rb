# frozen_string_literal: true

require 'bigdecimal'

module Mxrb
  module Runtime
    # Decimal strings cross SQLite/JSON without an intermediate binary float.
    module DecimalValues
      TAG = '__mxrb_decimal'
      NUMBER = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/

      module_function

      def parse(value)
        text = value.to_s
        raise ArgumentError, 'expected a finite decimal' unless NUMBER.match?(text)

        BigDecimal(text)
      end

      def text(value)
        number = parse(value)
        return '0' if number.zero?

        number.to_s('F').sub(/\.?0+\z/, '')
      end

      def encode(value) = { TAG => text(value) }
      def tagged?(value) = value.is_a?(Hash) && value.keys == [TAG]
    end

    # Mendix 11.12 uses a 38 digit MathContext and configurable storage scale.
    # Keep rounding local to this operation, never change BigDecimal global mode.
    class DecimalContext
      MODES = { 'HalfUp' => BigDecimal::ROUND_HALF_UP, 'HalfEven' => BigDecimal::ROUND_HALF_EVEN }.freeze
      attr_reader :precision, :scale, :rounding

      def self.settings(project)
        return project.decimal_settings if project.respond_to?(:decimal_settings)
        return {} unless project.respond_to?(:all_units)

        root = project.all_units.map { project.parse_bson(_1) }.find { _1['$Type'] == 'Settings$ProjectSettings' }
        return {} unless root

        parts = IO::BsonCodec.parse_array(root['Settings'])[:items]
        model = parts.find { _1['$Type'] == 'Settings$ModelSettings' } || root
        { 'scale' => model.fetch('DecimalScale', 8), 'rounding' => model.fetch('RoundingMode', 'HalfUp') }
      end

      def initialize(precision: 38, scale: 8, rounding: 'HalfUp')
        @precision = precision
        @scale = scale
        @rounding = rounding
        @mode = MODES.fetch(rounding)
      end

      def divide(left, right)
        first, second = [left, right].map { DecimalValues.parse(_1) }
        raise ArgumentError, 'division by zero' if second.zero?
        return BigDecimal('0') if first.zero?

        # Rational arithmetic avoids double rounding at the final significant digit.
        round_rational(first.to_r / second.to_r, division_places(first, second))
      end

      def round(value, places = 0)
        raise ArgumentError, 'precision must be an integer' unless places.is_a?(Integer)

        result = DecimalValues.parse(value).round(places, @mode)
        places.zero? ? result.to_i : result
      end

      def persist(value)
        result = DecimalValues.parse(value).round(scale, @mode)
        raise ArgumentError, 'decimal value is not within range' if result.abs > 10**20

        result
      end

      private

      def division_places(first, second)
        exponent = first.exponent - second.exponent
        exponent += 1 if (first.to_r / second.to_r).abs >= 10.to_r**exponent
        precision - exponent
      end

      def round_rational(ratio, places)
        factor = 10.to_r**places
        scaled = ratio * factor
        integer, remainder = scaled.abs.numerator.divmod(scaled.denominator)
        comparison = remainder * 2 <=> scaled.denominator
        integer += 1 if increment?(comparison, integer)
        DecimalValues.parse("#{integer * (scaled.negative? ? -1 : 1)}e#{-places}")
      end

      def increment?(comparison, integer)
        comparison.positive? || (comparison.zero? && (rounding == 'HalfUp' || integer.odd?))
      end
    end
  end
end
