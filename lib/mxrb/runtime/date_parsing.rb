# frozen_string_literal: true

require 'date'
require 'strscan'

module Mxrb
  module Runtime
    # Numeric UTC patterns verified against Mendix 11.12.1. Its microflow parser
    # rejects invalid components but accepts a successfully parsed input prefix.
    module DateParsing
      FIELDS = { 'y' => 0, 'M' => 1, 'd' => 2, 'H' => 3, 'm' => 4, 's' => 5, 'S' => 6 }.freeze
      PATTERNS = %w[yyyy M MM d dd H HH m mm s ss S SS SSS X XX XXX Z].freeze
      ZONES = { 'X' => 'Z|[+-]\\d{2}', 'XX' => 'Z|[+-]\\d{4}',
                'XXX' => 'Z|[+-]\\d{2}:\\d{2}', 'Z' => '[+-]\\d{4}' }.freeze

      module_function

      def invoke(arguments)
        unless (2..3).cover?(arguments.length) && arguments.first(2).all?(String)
          raise ArgumentError, 'parseDateTimeUTC requires a date string, pattern and optional date fallback'
        end

        tokens = tokenize(arguments[1])
        value = parse(arguments[0], tokens)
        return value if value
        return fallback(arguments[2]) if arguments.length == 3

        raise ArgumentError, 'cannot parse date and time'
      end

      def fallback(value)
        return value if value.nil? || value.is_a?(Time) || value.is_a?(DateTime)

        raise ArgumentError, 'expected a date fallback'
      end

      def tokenize(pattern)
        scanner = StringScanner.new(pattern)
        tokens = []
        tokens << token(scanner) until scanner.eos?
        tokens
      end

      def token(scanner)
        return [:literal, "'"] if scanner.scan(/''/)
        return [:literal, quoted(scanner)] if scanner.scan(/'/)

        field = scanner.scan(/([A-Za-z])\1*/)
        return [:literal, scanner.getch] unless field

        raise ArgumentError, "unsupported date pattern: #{field}" unless PATTERNS.include?(field)

        [:field, field]
      end

      def quoted(scanner)
        literal = +''
        until scanner.eos?
          return literal if scanner.scan(/'(?!')/)

          literal << (scanner.scan(/''/) ? "'" : scanner.getch)
        end
        raise ArgumentError, 'unterminated date pattern literal'
      end

      def parse(text, tokens)
        match = compiled_pattern(tokens).match(text)
        return unless match&.end(0).to_i.positive?

        fields = tokens.filter_map { |kind, value| value if kind == :field }
        normalize(*components(fields, match.captures))
      rescue RangeError
        nil
      end

      def compiled_pattern(tokens)
        source = tokens.each_with_index.map { |entry, index| token_pattern(entry, tokens[index + 1]) }.join
        Regexp.new("\\A#{source}")
      end

      def token_pattern(entry, following)
        kind, value = entry
        return Regexp.escape(value) if kind == :literal
        return "(#{ZONES.fetch(value)})" if ZONES.key?(value)

        adjacent = following&.first == :field && FIELDS.key?(following.last[0])
        "[ \\t]*(-?\\d#{adjacent ? "{#{value.length}}" : '+'})"
      end

      def components(fields, values)
        parts = [1970, 1, 1, 0, 0, 0, 0]
        offset = 0
        fields.zip(values).each do |field, value|
          if ZONES.key?(field)
            offset = zone_offset(value)
          else
            parts[FIELDS.fetch(field[0])] = Integer(value, 10)
          end
        end
        [parts, offset]
      end

      def zone_offset(text)
        return 0 if text == 'Z'

        digits = text.delete(':')
        hours = digits[1, 2].to_i
        minutes = digits[3, 2].to_i
        raise RangeError, 'invalid date offset' unless hours <= 23 && minutes <= 59

        (digits.start_with?('-') ? -1 : 1) * (hours * 3600 + minutes * 60)
      end

      def normalize(parts, offset)
        validate_parts!(parts)
        Time.utc(*parts.first(6)) + Rational(parts[6], 1000) - offset
      end

      def validate_parts!(parts)
        year, month, day, hour, minute, second, milliseconds = parts
        ranges = [[hour, 23], [minute, 59], [second, 59], [milliseconds, 999]]
        unless (1800..9999).cover?(year) && (1..12).cover?(month) && day.positive? &&
               Date.valid_date?(year, month, day) &&
               ranges.all? { |value, maximum| (0..maximum).cover?(value) }
          raise RangeError, 'invalid parsed date components'
        end

        parts
      end
    end
  end
end
