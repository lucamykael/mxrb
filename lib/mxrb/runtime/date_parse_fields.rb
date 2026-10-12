# frozen_string_literal: true

require 'date'
require 'tzinfo'
require_relative 'date_parse_matchers'

module Mxrb
  module Runtime
    # Resolves parsed SimpleDateFormat fields into a time, strictly: hours,
    # minutes and calendar days must be in range and a weekday must agree with
    # the date. Two-digit years (yy with two digits) fall within 80 years before
    # and 20 years after now, as Java resolves them.
    class DateParseFields
      MONTHS = DateParseMatchers::MONTHS
      DAYS = DateParseMatchers::DAYS
      ZONES = DateParseMatchers::ZONES

      def initialize(values, now)
        @values = values.to_h { |field, text| [field[0], [field, text]] }
        @now = now
      end

      def resolve(zone)
        date = calendar_date or return
        hour = hour_of_day or return
        minute, second, milliseconds = %w[m s S].map { number(_1) }
        return unless minute.between?(0, 59) && second.between?(0, 59) && milliseconds.between?(0, 999)

        wall = [date.year, date.month, date.day, hour, minute, second + Rational(milliseconds, 1000)]
        instant(wall, zone)
      end

      private

      def text(letter) = @values[letter]&.last
      def field(letter) = @values[letter]&.first
      def number(letter, default = 0) = text(letter) ? Integer(text(letter), 10) : default

      def calendar_date
        year = calendar_year or return
        return week_date(year) if text('w')
        return day_of_year(year) if text('D') && !text('d')

        date = month_date(year) or return
        weekday_matches?(date) ? date : nil
      end

      def calendar_year
        year = text('y') ? number('y') : 1970
        return if year < 1

        year = pivot(year) if two_digit_year?
        text('G')&.casecmp?('BC') ? 1 - year : year
      end

      def two_digit_year? = field('y')&.length == 2 && text('y').delete('-').length == 2

      def pivot(value)
        start = @now.year - 80
        year = ((start / 100) * 100) + value
        year += 100 if year < start || (year == start && ([month, number('d', 1)] <=> [@now.month, @now.day]).negative?)
        year
      end

      def month
        value = text('M') || text('L')
        return 1 unless value

        value.match?(/\A\s*-?\d/) ? Integer(value, 10) : (MONTHS.index { _1.start_with?(value.downcase) } + 1)
      end

      def month_date(year)
        return first_weekday(year) if text('E') && !text('d')

        day = number('d', 1)
        valid = month.between?(1, 12) && day.positive? && Date.valid_civil?(year, month, day)
        valid ? Date.new(year, month, day) : nil
      end

      def first_weekday(year)
        first = Date.new(year, month, 1)
        first + ((weekday - first.wday) % 7)
      end

      def weekday = DAYS.index { _1.start_with?(text('E').downcase) }

      def weekday_matches?(date) = !text('E') || date.wday == weekday

      def day_of_year(year)
        day = number('D')
        return unless day.between?(1, Date.leap?(year) ? 366 : 365)

        Date.new(year, 1, 1) + day - 1
      end

      # US weeks: week 1 holds January 1st and weeks start on Sunday.
      def week_date(year)
        first = Date.new(year, 1, 1)
        (first - first.wday) + ((number('w') - 1) * 7) + (text('E') ? weekday : 0)
      end

      def hour_of_day
        return clock_hour if text('a') || text('h') || text('K')
        return (number('k') % 24 if number('k').between?(1, 24)) if text('k')

        number('H').between?(0, 23) ? number('H') : nil
      end

      def clock_hour
        hour = text('h') ? number('h') : number('K')
        valid = text('h') ? hour.between?(1, 12) : hour.between?(0, 11)
        return unless valid

        (hour % 12) + (text('a')&.casecmp?('PM') ? 12 : 0)
      end

      def instant(wall, zone)
        offset = zone_offset
        return Time.utc(*wall) - offset if offset
        return Time.utc(*wall) unless zone

        TZInfo::Timezone.get(zone).local_to_utc(Time.utc(*wall), dst: true)
      end

      def zone_offset
        return ZONES.fetch(text('z').downcase) if text('z')

        value = text('Z') || text('X')
        value && numeric_offset(value)
      end

      def numeric_offset(value)
        return 0 if value == 'Z'

        digits = value.delete(':')
        hours = digits[1, 2].to_i
        minutes = digits[3, 2].to_i
        raise RangeError, 'invalid date offset' unless hours <= 23 && minutes <= 59

        (digits.start_with?('-') ? -1 : 1) * ((hours * 3600) + (minutes * 60))
      end
    end
  end
end
