# frozen_string_literal: true

require 'date'

module Mxrb
  module Runtime
    # Java SimpleDateFormat patterns for the en_US locale, as Mendix 11.12.1
    # formats microflow dates. Weeks follow the US rules: they start on Sunday
    # and week 1 holds January 1st. The default forms are the JDK 21 CLDR short
    # formats, which put a narrow no-break space before AM or PM.
    module DateFormatting
      MONTHS = %w[January February March April May June July August September October November December].freeze
      DAYS = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze
      NARROW_SPACE = ' '
      DATE = 'M/d/yy'
      TIME = "h:mm'#{NARROW_SPACE}'a".freeze
      ZONE_NAMES = { 'UTC' => ['UTC', 'Coordinated Universal Time'] }.freeze
      # Integers are zero-padded to the pattern width; strings are used as they are.
      FIELDS = {
        'G' => ->(time, _) { time.year.positive? ? 'AD' : 'BC' },
        'y' => ->(time, count) { year(time.year, count) },
        'Y' => ->(time, count) { year(week_year(time.to_date), count) },
        'M' => ->(time, count) { month(time.month, count) },
        'L' => ->(time, count) { month(time.month, count) },
        'E' => ->(time, count) { count >= 4 ? DAYS[time.wday] : DAYS[time.wday][0, 3] },
        'a' => ->(time, _) { time.hour < 12 ? 'AM' : 'PM' },
        'd' => ->(time, _) { time.day },
        'D' => ->(time, _) { time.yday },
        'u' => ->(time, _) { time.wday.zero? ? 7 : time.wday },
        'w' => ->(time, _) { week_of_year(time.to_date) },
        'W' => ->(time, _) { ((time.day + Date.new(time.year, time.month, 1).wday - 1) / 7) + 1 },
        'F' => ->(time, _) { ((time.day - 1) / 7) + 1 },
        'H' => ->(time, _) { time.hour },
        'k' => ->(time, _) { time.hour.zero? ? 24 : time.hour },
        'K' => ->(time, _) { time.hour % 12 },
        'h' => ->(time, _) { (time.hour % 12).zero? ? 12 : time.hour % 12 },
        'm' => ->(time, _) { time.min },
        's' => ->(time, _) { time.sec },
        'S' => ->(time, _) { time.usec / 1000 }
      }.freeze

      module_function

      # zone is the TZInfo identifier the time is shown in.
      def format(time, pattern, zone: 'UTC')
        tokens(pattern).map { |letter, count| letter ? field(time, letter, count, zone) : count }.join
      end

      # name is a lowercase Mendix function; patterns are accepted only by formatDateTime[UTC].
      def invoke(name, time, rest, zone)
        pattern = rest.first if rest.length == 1 && name.start_with?('formatdatetime')
        raise ArgumentError, "#{name} accepts a date and an optional pattern" unless rest.length == (pattern ? 1 : 0)
        return format(time, pattern.to_s, zone:) if pattern

        public_send({ 'formatdate' => :date, 'formattime' => :time }.fetch(name, :date_time), time, zone:)
      end

      def date(time, zone:) = format(time, DATE, zone:)
      def time(time, zone:) = format(time, TIME, zone:)
      def date_time(time, zone:) = "#{date(time, zone:)}, #{time(time, zone:)}"

      # [letter, count] for pattern fields, [nil, text] for literal text.
      def tokens(pattern)
        pattern.to_enum(:scan, /'(?:[^']|'')*'|([A-Za-z])\1*|[^A-Za-z']+/).map do
          text = Regexp.last_match(0)
          next [nil, quoted(text)] if text.start_with?("'")

          Regexp.last_match(1) ? [text[0], text.length] : [nil, text]
        end
      end

      def quoted(text) = text == "''" ? "'" : text[1...-1].gsub("''", "'")

      def field(time, letter, count, zone)
        return zone_name(zone, count) if letter == 'z'
        return offset(time.utc_offset, letter, count) if %w[Z X].include?(letter)

        rule = FIELDS.fetch(letter) { raise ArgumentError, "unsupported date pattern letter #{letter}" }
        value = rule.call(time, count)
        value.is_a?(Integer) ? value.to_s.rjust(count, '0') : value
      end

      def year(value, count) = count == 2 ? (value % 100).to_s.rjust(2, '0') : value.to_s.rjust(count, '0')

      def month(value, count)
        return MONTHS[value - 1] if count >= 4
        return MONTHS[value - 1][0, 3] if count == 3

        value.to_s.rjust(count, '0')
      end

      def week_start(date) = date - date.wday

      def week_of_year(date)
        start = week_start(date)
        return 1 if start + 6 >= Date.new(date.year + 1, 1, 1)

        ((start - week_start(Date.new(date.year, 1, 1))).to_i / 7) + 1
      end

      def week_year(date) = week_start(date) + 6 >= Date.new(date.year + 1, 1, 1) ? date.year + 1 : date.year

      def zone_name(zone, count)
        names = ZONE_NAMES.fetch(zone) { raise ArgumentError, "time zone names are verified only for UTC, not #{zone}" }
        count >= 4 ? names.last : names.first
      end

      def offset(seconds, letter, count)
        return 'Z' if letter == 'X' && seconds.zero?

        sign = seconds.negative? ? '-' : '+'
        hours, minutes = (seconds.abs / 60).divmod(60).map { _1.to_s.rjust(2, '0') }
        return "#{sign}#{hours}#{minutes}" unless letter == 'X'

        [sign, hours, (':' if count >= 3), (minutes if count >= 2)].join
      end
    end
  end
end
