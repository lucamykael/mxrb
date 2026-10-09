# frozen_string_literal: true

require 'date'
require 'strscan'
require_relative 'date_parse_fields'

module Mxrb
  module Runtime
    # Java SimpleDateFormat parsing (strict, en_US) as Mendix 11.12.1 parses
    # microflow dates. A successfully parsed prefix is accepted; components out
    # of range, a contradicting weekday and an unknown name reject the text.
    # Numeric fields skip leading blanks; a field followed by another numeric
    # field reads exactly its pattern width. Missing fields default to
    # 1970-01-01 00:00 in the time zone of the call.
    module DateParsing
      LETTERS = 'GyMLdDEuahHkKmsSzZXw'
      # Java switches to the Julian calendar before this date; Ruby times are Gregorian.
      REFORM = Time.utc(1582, 10, 15)

      module_function

      # parseDateTimeUTC(text, pattern[, fallback]), or parseDateTime in zone when given.
      def invoke(arguments, zone: nil, now: Time.now.utc)
        unless (2..3).cover?(arguments.length) && arguments.first(2).all?(String)
          raise ArgumentError, 'parseDateTime requires a date string, pattern and optional date fallback'
        end

        value = parse(arguments[0], tokenize(arguments[1]), zone, now)
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
        raise ArgumentError, "unsupported date pattern: #{field}" unless LETTERS.include?(field[0])

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

      def parse(text, tokens, zone, now)
        values = read(text, tokens) or return
        fields = DateParseFields.new(values, now)
        time = fields.resolve(zone)
        raise ArgumentError, 'dates before the 1582 calendar reform are not supported' if time && time < REFORM

        time
      rescue RangeError
        nil
      end

      # The field values of the longest matching prefix, or nil.
      def read(text, tokens)
        scanner = StringScanner.new(text)
        values = tokens.each_with_index.map do |(kind, value), index|
          next(scanner.scan(Regexp.new(Regexp.escape(value))) ? nil : (return nil)) if kind == :literal

          read_field(scanner, value, tokens[index + 1]) || (return nil)
        end
        scanner.pos.positive? ? values.compact : nil
      end

      def read_field(scanner, field, following)
        matcher = DateParseMatchers.matcher(field, adjacent: numeric_field?(following))
        text = scanner.scan(matcher) or return
        [field, text.strip]
      end

      def numeric_field?(token)
        token&.first == :field && DateParseMatchers.numeric?(token.last)
      end
    end
  end
end
