# frozen_string_literal: true

require 'bigdecimal'
require 'date'
require 'time'

module Mxrb
  module Runtime
    # Scalar OQL operations with the results measured on Mendix 11.12.1 (HSQLDB):
    # division truncates to the larger operand scale, % truncates its operands,
    # ROUND rounds half away from zero, DATEPART and DATEDIFF use UTC, WEEK is the
    # ISO week, WEEKDAY counts from Sunday = 1 and DATEDIFF counts crossed boundaries.
    module OqlScalar
      INTEGER_RANGE = (-(2**31))..((2**31) - 1)
      DATE_PARTS = {
        'YEAR' => :year, 'QUARTER' => ->(time) { ((time.month - 1) / 3) + 1 }, 'MONTH' => :month,
        'DAYOFYEAR' => :yday, 'DAY' => :day, 'WEEK' => ->(time) { time.to_date.cweek },
        'WEEKDAY' => ->(time) { time.wday + 1 }, 'HOUR' => :hour, 'MINUTE' => :min, 'SECOND' => :sec
      }.freeze
      DATE_DIFFERENCES = {
        'YEAR' => :year, 'MONTH' => ->(time) { (time.year * 12) + time.month },
        'DAY' => ->(time) { time.to_date.jd }, 'HOUR' => ->(time) { (time.to_r / 3600).floor },
        'MINUTE' => ->(time) { (time.to_r / 60).floor }
      }.freeze

      module_function

      def decimal(value) = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)

      def divide(left, right, scale, integer:)
        raise NativeRuntimeError, 'OQL division by zero' if right.zero?
        return truncated_quotient(left, right) if integer

        digits = decimal(left).exponent.abs + decimal(right).exponent.abs + scale + 20
        decimal(left).div(decimal(right), digits).truncate(scale)
      end

      def truncated_quotient(left, right)
        quotient = left.abs / right.abs
        left.negative? ^ right.negative? ? -quotient : quotient
      end

      def arithmetic(left, operator, right, integer:, scale:)
        case operator
        when ':' then divide(left, right, scale, integer:)
        when '%' then modulo(left, right, decimal: !integer)
        else integer ? left.public_send(operator, right) : decimal(left).public_send(operator, right)
        end
      end

      def replace(source, from, to)
        return nil if source.nil?
        raise NativeRuntimeError, 'Argument of Replace() must be a string' if from.nil? || to.nil?

        from.empty? ? source : source.gsub(from, to)
      end

      def modulo(left, right, decimal:)
        divisor = right.truncate.to_i
        raise NativeRuntimeError, 'OQL division by zero' if divisor.zero?

        result = left.truncate.to_i.remainder(divisor)
        decimal ? BigDecimal(result) : result
      end

      def round(value, digits) = decimal(value).round(digits, :half_up)

      def date_part(part, value) = callable(DATE_PARTS.fetch(part)).call(value.utc)

      def date_difference(part, first, second)
        measure = callable(DATE_DIFFERENCES.fetch(part))
        measure.call(second.utc) - measure.call(first.utc)
      end

      def callable(value) = value.is_a?(Symbol) ? value.to_proc : value

      def cast(value, source, target, scale)
        case target
        when 'STRING' then text(value, source, scale)
        when 'INTEGER', 'LONG' then integer(value, source, target == 'INTEGER' ? INTEGER_RANGE : nil)
        when 'DECIMAL' then decimal(value)
        when 'BOOLEAN' then boolean(value, source)
        else datetime(value)
        end
      end

      def boolean(value, source) = source == :boolean ? value : !value.zero?

      def text(value, source, scale)
        case source
        when :decimal then fixed(value, scale)
        when :boolean then value ? 'TRUE' : 'FALSE'
        when :datetime then value.utc.strftime('%Y-%m-%d %H:%M:%S.%6N')
        else value.to_s
        end
      end

      def fixed(value, scale)
        whole, fraction = decimal(value).round(scale, :half_up).to_s('F').split('.')
        "#{whole}.#{fraction.ljust(scale, '0')}"
      end

      def integer(value, source, range)
        result = source == :string ? Integer(value.strip, 10) : value.truncate.to_i
        raise NativeRuntimeError, 'OQL numeric value out of range' if range && !range.cover?(result)

        result
      rescue ArgumentError
        raise NativeRuntimeError, "OQL cannot cast #{value.inspect} to a number"
      end

      def datetime(value)
        match = /\A(\d{4})-(\d{2})-(\d{2})(?: (\d{2}):(\d{2}):(\d{2})(\.\d+)?)?\z/.match(value.strip)
        raise NativeRuntimeError, "OQL cannot cast #{value.inspect} to a date" unless match

        year, month, day, hour, minute, second, fraction = match.captures
        Time.utc(year.to_i, month.to_i, day.to_i, hour.to_i, minute.to_i, second.to_i + fraction.to_r)
      end
    end
  end
end
