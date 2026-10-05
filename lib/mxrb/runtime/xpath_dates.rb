# frozen_string_literal: true

require 'date'
require 'tzinfo'

module Mxrb
  module Runtime
    # Calendar boundaries use the session zone; durations retain calendar months/years.
    class XPathDates
      SECONDS = { 'Second' => 1, 'Minute' => 60, 'Hour' => 3600, 'Day' => 86_400, 'Week' => 604_800 }.freeze
      BOUNDARY = /\A(Begin|End)Of(CurrentMinute|CurrentHour|CurrentDay|Yesterday|Tomorrow|
                                CurrentWeek|CurrentMonth|CurrentYear)(UTC)?\z/x
      SHIFT = /\s*([+-])\s*(?:(\d+)\s*\*\s*)?\[%([A-Za-z]+)Length%\]/

      def initialize(context)
        attributes = context.respond_to?(:attributes) ? context.attributes : {}
        @zone = TZInfo::Timezone.get(attributes.fetch('time_zone', 'UTC'))
      rescue TZInfo::InvalidTimezoneIdentifier
        raise ArgumentError, 'invalid XPath session time zone'
      end

      def resolve(source)
        scanner = StringScanner.new(source)
        name = scanner.scan(/\[%([A-Za-z]+)%\]/) && scanner[1]
        raise ArgumentError, 'invalid XPath date token' unless name

        result = token(name)
        result = shift(result, scanner[1], scanner[2], scanner[3]) while scanner.scan(SHIFT)
        raise ArgumentError, 'invalid XPath date arithmetic' unless scanner.rest.strip.empty?

        result
      end

      private

      def token(name)
        return Time.now if name == 'CurrentDateTime'

        match = BOUNDARY.match(name)
        raise ArgumentError, "unknown XPath date token #{name}" unless match

        zone = match[3] ? TZInfo::Timezone.get('UTC') : @zone
        boundary(zone, match[2], match[1] == 'Begin')
      end

      def boundary(zone, period, beginning)
        local = zone.to_local(Time.now)
        first, last = bounds(local, period)
        utc = zone.local_to_utc(beginning ? first : last, local.dst?)
        beginning ? utc : utc - Rational(1, 1000)
      end

      def bounds(time, period)
        date = time.to_date
        case period
        when 'CurrentMinute' then clock_bounds(time, time.min, 60)
        when 'CurrentHour' then clock_bounds(time, 0, 3600)
        else
          first, last = date_bounds(date, period)
          [Time.utc(first.year, first.month, first.day), Time.utc(last.year, last.month, last.day)]
        end
      end

      def clock_bounds(time, minute, length)
        start = Time.utc(time.year, time.month, time.day, time.hour, minute)
        [start, start + length]
      end

      def date_bounds(date, period)
        case period
        when 'CurrentDay' then [date, date + 1]
        when 'Yesterday' then [date - 1, date]
        when 'Tomorrow' then [date + 1, date + 2]
        when 'CurrentWeek' then week_bounds(date)
        when 'CurrentMonth' then month_bounds(date)
        else [Date.new(date.year), Date.new(date.year + 1)] # CurrentYear, validated by BOUNDARY
        end
      end

      def week_bounds(date)
        monday = date - (date.cwday - 1)
        [monday, monday + 7]
      end

      def month_bounds(date)
        first = Date.new(date.year, date.month, 1)
        [first, first >> 1]
      end

      def shift(time, operator, quantity, period)
        count = (quantity || '1').to_i * (operator == '-' ? -1 : 1)
        return time + SECONDS.fetch(period) * count if SECONDS.key?(period)
        raise ArgumentError, "unknown XPath duration #{period}" unless %w[Month Year].include?(period)

        shifted = time.to_datetime >> (period == 'Year' ? count * 12 : count)
        shifted.to_time
      end
    end
  end
end
