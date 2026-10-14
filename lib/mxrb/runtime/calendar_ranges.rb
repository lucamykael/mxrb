# frozen_string_literal: true

require 'bigdecimal'
require 'date'
require_relative 'decimal_values'

module Mxrb
  module Runtime
    # Distances between instants and calendar period boundaries, measured as the
    # Mendix 11.12.1 Runtime does (docs/evidence/calendar-functions-2026-10-14.json).
    class CalendarRanges
      BETWEEN = /\A(milliseconds|seconds|minutes|hours|days|weeks)between\z/
      CALENDAR_BETWEEN = /\Acalendar(months|years)between\z/
      BOUNDS = /\A(begin|end)of(day|week|month|year)\z/
      UNIT_MILLISECONDS = {
        'milliseconds' => 1, 'seconds' => 1000, 'minutes' => 60_000, 'hours' => 3_600_000,
        'days' => 86_400_000, 'weeks' => 604_800_000
      }.freeze

      def initialize(calendar) = @calendar = calendar

      def supported?(name) = [BETWEEN, CALENDAR_BETWEEN, BOUNDS].any? { _1.match?(name) }

      def invoke(name, arguments)
        times = arguments.map { @calendar.instant(_1) }
        bounds = BOUNDS.match(name)
        return bound(*single(times), bounds[2], bounds[1] == 'end') if bounds

        raise ArgumentError, 'expected 2 date arguments' unless times.length == 2

        first, second = times.sort
        return calendar_between(first, second, name) if CALENDAR_BETWEEN.match?(name)

        milliseconds_between(first, second, BETWEEN.match(name)[1])
      end

      private

      def single(times)
        raise ArgumentError, 'expected 1 date argument' unless times.length == 1

        times
      end

      # The distance regardless of order: milliseconds as a whole number, larger
      # units as a decimal with the Runtime's 38 significant digits.
      def milliseconds_between(first, second, unit)
        milliseconds = ((second.to_r - first.to_r) * 1000).round
        return milliseconds if unit == 'milliseconds'

        DecimalContext.new.divide(BigDecimal(milliseconds), BigDecimal(UNIT_MILLISECONDS.fetch(unit)))
      end

      # Complete months or years in the session time zone.
      def calendar_between(first, second, name)
        zone = @calendar.zone(false)
        months = complete_months(zone.to_local(first), zone.to_local(second))
        name.include?('years') ? months / 12 : months
      end

      def complete_months(start, finish)
        months = ((finish.year - start.year) * 12) + finish.month - start.month
        (position(finish) <=> position(start)).negative? ? months - 1 : months
      end

      def position(time) = [time.day, time.hour, time.min, time.sec, time.subsec]

      def bound(time, unit, ending)
        zone = @calendar.zone(false)
        first = period_start(zone.to_local(time).to_date, unit)
        return midnight(first, zone) unless ending

        midnight(period_after(first, unit), zone) - Rational(1, 1000)
      end

      # Weeks start on Sunday, as for the en_US locale the Runtime uses.
      def period_start(date, unit)
        case unit
        when 'day' then date
        when 'week' then date - date.wday
        when 'month' then Date.new(date.year, date.month, 1)
        else Date.new(date.year, 1, 1)
        end
      end

      def period_after(first, unit)
        { 'day' => first + 1, 'week' => first + 7, 'month' => first >> 1, 'year' => first >> 12 }.fetch(unit)
      end

      def midnight(date, zone) = @calendar.resolve(Time.utc(date.year, date.month, date.day), zone)
    end
  end
end
