# frozen_string_literal: true

require 'date'
require 'tzinfo'

module Mxrb
  module Runtime
    # Calendar operations keep wall-clock time across changes of UTC offset.
    # Elapsed durations (hours and smaller) operate on instants instead.
    class CalendarFunctions
      DURATIONS = { 'milliseconds' => Rational(1, 1000), 'seconds' => 1, 'minutes' => 60, 'hours' => 3600 }.freeze
      MONTHS = { 'months' => 1, 'quarters' => 3, 'years' => 12 }.freeze
      SHIFT = /\A(add|subtract)(milliseconds|seconds|minutes|hours|days|weeks|months|quarters|years)(utc)?\z/
      TRIM = /\Atrimto(seconds|minutes|hours|days|months|years)(utc)?\z/

      def initialize(time_zone: 'UTC') = @time_zone = time_zone

      def supported?(name)
        SHIFT.match?(name) || TRIM.match?(name) ||
          %w[datetime datetimeutc datetimetoepoch epochtodatetime].include?(name)
      end

      def invoke(name, arguments)
        if (match = SHIFT.match(name))
          shift_arguments(arguments, match)
        elsif (match = TRIM.match(name))
          arity!(arguments, 1)
          trim(instant(arguments[0]), match[1], zone(match[2]))
        else
          create_or_epoch(name, arguments)
        end
      end

      private

      def shift_arguments(arguments, match)
        arity!(arguments, 2)
        count = integer(arguments[1]) * (match[1] == 'add' ? 1 : -1)
        shift(instant(arguments[0]), count, match[2], zone(match[3]))
      end

      def create_or_epoch(name, arguments)
        return create(arguments, zone(name.end_with?('utc'))) if %w[datetime datetimeutc].include?(name)

        arity!(arguments, 1)
        return (instant(arguments[0]).to_r * 1000).floor if name == 'datetimetoepoch'

        Time.at(Rational(integer(arguments[0]), 1000)).utc
      end

      def zone(utc)
        name = @time_zone.respond_to?(:call) ? @time_zone.call : @time_zone
        TZInfo::Timezone.get(utc ? 'UTC' : name)
      rescue TZInfo::InvalidTimezoneIdentifier
        raise ArgumentError, 'invalid expression time zone'
      end

      def arity!(arguments, count)
        raise ArgumentError, "expected #{count} date arguments" unless arguments.length == count
      end

      def integer(value)
        raise ArgumentError, 'date component must be an integer' unless value.is_a?(Integer)

        value
      end

      def instant(value)
        raise ArgumentError, 'expected a date and time' unless value.is_a?(Time) || value.is_a?(DateTime)

        value.to_time.getutc
      end

      def create(arguments, zone)
        raise ArgumentError, 'dateTime requires one to six arguments' unless (1..6).cover?(arguments.length)

        parts = arguments.map { integer(_1) }
        parts += [nil, 1, 1, 0, 0, 0].drop(parts.length)
        validate_parts!(parts)
        resolve(Time.utc(*parts), zone)
      end

      def validate_parts!(parts)
        year, month, day, hour, minute, second = parts
        unless year >= 1800 && Date.valid_date?(year, month, day) && (0..23).cover?(hour) &&
               (0..59).cover?(minute) && (0..59).cover?(second)
          raise ArgumentError, 'invalid dateTime components'
        end
      end

      def shift(time, count, unit, zone)
        return time + DURATIONS.fetch(unit) * count if DURATIONS.key?(unit)
        return shift_days(time, count * (unit == 'weeks' ? 7 : 1), zone) unless MONTHS.key?(unit)

        local = zone.to_local(time)
        date = local.to_date >> (count * MONTHS.fetch(unit))
        wall = wall_time(date, local)
        resolve(wall, zone)
      end

      def wall_time(date, local)
        Time.utc(date.year, date.month, date.day, local.hour, local.min, local.sec + local.subsec)
      end

      def shift_days(time, count, zone)
        local = zone.to_local(time)
        elapsed = time + count * 86_400
        adjusted = elapsed + local.utc_offset - zone.to_local(elapsed).utc_offset
        zone.to_local(adjusted).to_date == local.to_date + count ? adjusted : elapsed
      end

      def trim(time, unit, zone)
        local = zone.to_local(time)
        parts = [local.year, local.month, local.day, local.hour, local.min, local.sec]
        length = %w[years months days hours minutes seconds].index(unit) + 1
        parts[length..] = [nil, 1, 1, 0, 0, 0].drop(length)
        resolve(Time.utc(*parts), zone)
      end

      def resolve(wall, zone)
        periods = zone.periods_for_local(wall)
        return wall - periods.last.observed_utc_offset unless periods.empty?

        # A gap can be thirty minutes or even an entire day. Use the actual
        # transition, never assume all daylight-saving changes last one hour.
        transition = gap_transition(wall, zone)
        raise ArgumentError, 'cannot resolve local date' unless transition

        wall - transition.previous_offset.observed_utc_offset
      end

      def gap_transition(wall, zone)
        zone.transitions_up_to(wall + 172_800, wall - 172_800).find do |item|
          first = item.at.to_time + item.previous_offset.observed_utc_offset
          last = item.at.to_time + item.offset.observed_utc_offset
          wall >= first && wall < last
        end
      end
    end
  end
end
