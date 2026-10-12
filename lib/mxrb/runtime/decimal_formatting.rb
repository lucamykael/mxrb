# frozen_string_literal: true

require 'bigdecimal'

module Mxrb
  module Runtime
    # Java DecimalFormat patterns (en_US) as Mendix 11.12.1 formatDecimal applies
    # them, rounding half up: literal prefixes and suffixes, '0' and '#' digits,
    # ',' grouping (the size of the last group), '.', '%' and 'E0' exponents. The
    # integer part shows at least one digit.
    module DecimalFormatting
      PATTERN = /\A(?<prefix>[^#0,.%E]*)(?<integer>[#0,]+)(?:\.(?<fraction>[#0]*))?(?:E(?<exponent>0+))?(?<suffix>.*)\z/

      module_function

      def format(value, pattern)
        parts = PATTERN.match(pattern) or raise ArgumentError, "unsupported decimal format #{pattern.inspect}"
        body = digits(BigDecimal(value.to_s) * (parts[:suffix].include?('%') ? 100 : 1), parts)
        "#{'-' if body.start_with?('-')}#{parts[:prefix]}#{body.delete_prefix('-')}#{parts[:suffix]}"
      end

      def digits(number, parts)
        fraction = parts[:fraction].to_s
        return plain(number, parts[:integer], fraction) unless parts[:exponent]

        scientific(number, parts[:integer], fraction, parts[:exponent])
      end

      def plain(number, integer, fraction)
        rounded = number.round(fraction.length, :half_up)
        whole, digits = rounded.abs.to_s('F').split('.')
        digits = fraction_digits(digits.to_s, fraction)
        "#{'-' if rounded.negative?}#{group(whole.rjust([integer.count('0'), 1].max, '0'), integer)}" \
          "#{".#{digits}" unless digits.empty?}"
      end

      # Required '0' places are kept; optional '#' places drop trailing zeros.
      def fraction_digits(digits, fraction)
        digits.ljust(fraction.length, '0')[0, fraction.length].sub(/0{0,#{fraction.count('#')}}\z/, '')
      end

      def group(whole, integer)
        return whole unless integer.include?(',')

        size = integer.split(',').last.length
        whole.reverse.scan(/.{1,#{size}}/).join(',').reverse
      end

      def scientific(number, integer, fraction, exponent_pattern)
        exponent = number.zero? ? 0 : number.abs.exponent - integer.delete(',').length
        mantissa = plain(number / (BigDecimal(10)**exponent), '0', fraction)
        "#{mantissa}E#{'-' if exponent.negative?}#{exponent.abs.to_s.rjust(exponent_pattern.length, '0')}"
      end
    end
  end
end
