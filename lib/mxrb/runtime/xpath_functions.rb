# frozen_string_literal: true

require 'date'
require 'tzinfo'

module Mxrb
  module Runtime
    # XPath functions operate on authorized attribute sets, including association paths.
    class XPathFunctions
      DATE_PARTS = {
        'year' => :year, 'month' => :month, 'day' => :day, 'hours' => :hour,
        'minutes' => :min, 'seconds' => :sec, 'day-of-year' => :yday,
        'quarter' => ->(time) { ((time.month - 1) / 3) + 1 },
        'week' => ->(time) { time.to_date.cweek }, 'weekday' => ->(time) { time.wday + 1 }
      }.freeze
      STRINGS = { 'contains' => :include?, 'starts-with' => :start_with?, 'ends-with' => :end_with? }.freeze

      def initialize(context = nil)
        attributes = context.respond_to?(:attributes) ? context.attributes : {}
        @zone = attributes.fetch('time_zone', 'UTC')
      end

      def supported?(name)
        %w[length string-length].include?(name) || STRINGS.key?(name) || date_part(name)
      end

      def invoke(name, arguments)
        validate_arity(name, arguments.length)
        values = arguments.first.is_a?(Array) ? arguments.first : [arguments.first]
        rest = arguments.drop(1).map { scalar(_1) }
        values.map { apply(name, _1, rest) }
      end

      private

      def scalar(value)
        return value unless value.is_a?(Array)
        raise ArgumentError, 'XPath function requires a single value' unless value.one?

        value.first
      end

      def date_part(name)
        DATE_PARTS[name.delete_suffix('-from-datetime')] if name.end_with?('-from-datetime')
      end

      def validate_arity(name, count)
        allowed = if STRINGS.key?(name)
                    [2]
                  elsif date_part(name)
                    [1, 2]
                  else
                    [1]
                  end
        raise ArgumentError, "invalid XPath arguments for #{name}" unless allowed.include?(count)
      end

      def apply(name, value, rest)
        return nil if value.nil?
        return extract_date(name, value, rest.first || @zone) if date_part(name)

        raise ArgumentError, 'XPath string function requires a string attribute' unless value.is_a?(String)
        return value.length if %w[length string-length].include?(name)

        argument = rest.first
        raise ArgumentError, 'XPath string comparison requires a string' unless argument.is_a?(String)

        value.public_send(STRINGS.fetch(name), argument)
      end

      def extract_date(name, value, zone)
        raise ArgumentError, 'XPath date function requires a DateTime attribute' unless value.respond_to?(:to_time)

        time = TZInfo::Timezone.get(zone).to_local(value.to_time)
        part = date_part(name)
        part.is_a?(Symbol) ? time.public_send(part) : part.call(time)
      rescue TZInfo::InvalidTimezoneIdentifier
        raise ArgumentError, "invalid XPath time zone #{zone.inspect}"
      end
    end
  end
end
