# frozen_string_literal: true

require 'mxrb'

# Client oracle for nanoflow date, number and parsing functions: each button runs one
# nanoflow that logs "ORACLE <case>=<value>". Run with script/client_native_oracle under
# TZ=America/New_York so daylight saving transitions are exercised.
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Probe do
    entity :Item do
      string :Name
      datetime :When
    end
    microflow :Load do
      create_object 'Probe.Item', as: :item, set: { Name: "'probe'" }, commit: true
      return_type 'Probe.Item'
      return_value '$item'
    end
    day = 'dateTime(2024, 3, 5, 14, 7, 9)'
    morning = 'dateTime(2024, 3, 5, 9, 4, 0)'
    cases = {
      'FormatPattern' => "formatDateTime(#{day}, 'yyyy-MM-dd HH:mm:ss') + '|' + " \
                         "formatDateTime(#{day}, 'EEE, d MMM yy h:mm a') + '|' + " \
                         "formatDateTime(#{morning}, 'EEEE MMMM d, y hh:mm a')",
      'FormatFields' => "formatDateTime(#{day}, 'D w W E u F') + '|' + formatDateTime(#{day}, 'k K H h') + '|' + " \
                        "formatDateTime(dateTime(2024, 3, 5, 0, 30, 0), 'k K H h a')",
      'FormatMillis' => "formatDateTime(addMilliseconds(#{day}, 45), 'ss.SSS S SS')",
      'FormatQuoted' => "formatDateTime(#{day}, '''at'' HH ''o''''clock''')",
      'FormatShort' => "formatDateTime(#{day}, 'M/d/yy L LL LLL')",
      'FormatZone' => "formatDateTime(#{day}, 'z|Z|X|XXX') + '|' + formatDateTime(dateTime(2024, 7, 5), 'z|Z')",
      'FormatEra' => "formatDateTime(#{day}, 'G yyyy YYYY')",
      'FormatDefault' => "formatDateTime(#{day})",
      'FormatUtc' => "formatDateTimeUTC(#{day}, 'yyyy-MM-dd HH:mm z') + '|' + formatDateTimeUTC(#{day})",
      'FormatDate' => "formatDate(#{day}) + '|' + formatTime(#{day})",
      'FormatEmpty' => "'[' + formatDateTime($item/When, 'yyyy') + ']'",
      'ToStringDate' => "toString(#{day})",
      'ParsePattern' => "formatDateTimeUTC(parseDateTime('2024-03-05 14:07', 'yyyy-MM-dd HH:mm'), " \
                        "'yyyy-MM-dd HH:mm:ss')",
      'ParseDst' => "formatDateTimeUTC(parseDateTime('2024-03-10 02:30', 'yyyy-MM-dd HH:mm'), 'yyyy-MM-dd HH:mm')",
      'ParseNames' => "formatDateTimeUTC(parseDateTime('Tue, 5 Mar 2024 2:07 PM', 'EEE, d MMM yyyy h:mm a'), " \
                      "'yyyy-MM-dd HH:mm')",
      'ParseDefault' => "formatDateTimeUTC(parseDateTime('bad', 'yyyy', dateTime(2000)), 'yyyy-MM-dd HH:mm')",
      'ParseInvalid' => "formatDateTimeUTC(parseDateTime('bad', 'yyyy'), 'yyyy')",
      'ParseLenient' => "formatDateTimeUTC(parseDateTime('2024-02-30', 'yyyy-MM-dd'), 'yyyy-MM-dd')",
      'ParseInteger' => "toString(parseInteger('42')) + '|' + toString(parseInteger('-7')) + '|' + " \
                        "toString(parseInteger('x', 5))",
      'ParseIntegerBad' => "toString(parseInteger('4.5'))",
      'Math' => "toString(max(1, 5, 3)) + '|' + toString(min(4, 2.5)) + '|' + toString(pow(2, 10)) + '|' + " \
                "toString(sqrt(2)) + '|' + toString(abs(-3)) + '|' + toString(round(2.5)) + '|' + " \
                "toString(round(-2.5)) + '|' + toString(floor(-1.5)) + '|' + toString(ceil(1.2))",
      'Random' => 'toString(random() >= 0 and random() < 1)',
      'Between' => "toString(daysBetween(#{morning}, #{day})) + '|' + toString(hoursBetween(#{morning}, #{day})) + " \
                   "'|' + toString(minutesBetween(#{morning}, #{day})) + '|' + " \
                   "toString(secondsBetween(#{morning}, #{day})) + '|' + " \
                   "toString(millisecondsBetween(#{morning}, #{day})) + '|' + " \
                   "toString(weeksBetween(dateTime(2024, 1, 1), #{day}))",
      'BetweenDst' => "toString(daysBetween(dateTime(2024, 3, 9), dateTime(2024, 3, 11))) + '|' + " \
                      'toString(hoursBetween(dateTime(2024, 3, 9), dateTime(2024, 3, 11)))',
      'CalendarBetween' => "toString(calendarMonthsBetween(dateTime(2024, 1, 31), #{day})) + '|' + " \
                           "toString(calendarYearsBetween(dateTime(2020, 6, 1), #{day}))",
      'WeekToken' => "formatDateTime([%BeginOfCurrentWeek%], 'EEE HH:mm:ss.SSS') + '|' + " \
                     "formatDateTime([%EndOfCurrentWeek%], 'EEE HH:mm:ss.SSS') + '|' + " \
                     "formatDateTimeUTC([%BeginOfCurrentWeekUTC%], 'EEE HH:mm:ss.SSS')",
      'WeekYear' => "formatDateTime(dateTime(2023, 1, 1, 12), 'w ww Y YY D DDD u E EEEEE') + '|' + " \
                    "formatDateTime(dateTime(2024, 12, 30), 'w Y yy yyy y') + '|' + " \
                    "formatDateTime(dateTime(2021, 1, 2), 'w YYYY u')",
      'Hours' => "formatDateTime(dateTime(2024, 3, 5, 12, 5, 3), 'h hh K KK k kk H HH a aa') + '|' + " \
                 "formatDateTime(dateTime(2024, 3, 5, 0, 5, 3), 'h hh K KK k kk H HH m mm s ss')",
      'Widths' => "formatDateTime(addMilliseconds(#{day}, 5), 'S SS SSS SSSS') + '|' + " \
                  "formatDateTime(#{day}, 'MMMMM M MM d dd ddd EEEEEE')",
      'Letters' => "formatDateTime(#{day}, 'Q|QQQ|q|c|e|A|n|B|b|g|j|O|v|V|x|r|t|T|U|N|o|p|R|i|I|f|l')",
      'Literals' => "formatDateTime(#{day}, 'yyyy/MM/dd - [x] # ''') + '|' + formatDateTime(#{day}, '''abc') + " \
                    "'|' + formatDateTime(#{day}, '')",
      'ParseLoose' => "formatDateTimeUTC(parseDateTime('2024-3-5', 'yyyy-MM-dd'), 'yyyy-MM-dd HH:mm') + '|' + " \
                      "formatDateTimeUTC(parseDateTime('tue, 5 MAR 2024 2:07 pm', 'EEE, d MMM yyyy h:mm a'), " \
                      "'yyyy-MM-dd HH:mm') + '|' + " \
                      "formatDateTimeUTC(parseDateTime('24', 'yy'), 'yyyy') + '|' + " \
                      "formatDateTimeUTC(parseDateTime('99', 'yy'), 'yyyy') + '|' + " \
                      "formatDateTimeUTC(parseDateTime('2024-11-03 01:30', 'yyyy-MM-dd HH:mm'), 'HH:mm') + '|' + " \
                      "formatDateTimeUTC(parseDateTime('05.123', 'ss.SSS'), 'ss.SSS')",
      'ParseYears' => "formatDateTimeUTC(parseDateTimeUTC('1799-01-01', 'yyyy-MM-dd', dateTimeUTC(2000)), " \
                      "'yyyy') + '|' + formatDateTimeUTC(parseDateTimeUTC('10000-01-01', 'yyyy-MM-dd', " \
                      "dateTimeUTC(2000)), 'yyyy') + '|' + formatDateTimeUTC(parseDateTimeUTC('0099-01-01', " \
                      "'yyyy-MM-dd', dateTimeUTC(2000)), 'yyyy')",
      'DayTokens' => "toString([%BeginOfYesterday%] = addDays([%BeginOfCurrentDay%], -1)) + '|' + " \
                     "toString([%EndOfTomorrow%] = addMilliseconds(addDays([%BeginOfCurrentDay%], 2), -1)) + '|' + " \
                     'toString([%BeginOfTomorrowUTC%] = addDays([%BeginOfCurrentDayUTC%], 1))',
      'ParseTrailing' => "formatDateTimeUTC(parseDateTime('2024-03-05x', 'yyyy-MM-dd'), 'yyyy-MM-dd')",
      'ParseWeekday' => "formatDateTimeUTC(parseDateTime('Mon, 5 Mar 2024', 'EEE, d MMM yyyy'), 'yyyy-MM-dd')",
      'ParseHourOverflow' => "formatDateTimeUTC(parseDateTime('2024-03-05 25:00', 'yyyy-MM-dd HH:mm'), " \
                             "'yyyy-MM-dd HH')",
      'ParseIntegerEdge' => "toString(parseInteger(' 42', 1)) + '|' + toString(parseInteger('+5', 1)) + '|' + " \
                            "toString(parseInteger('0x1A', 1)) + '|' + toString(parseInteger('1e3', 1)) + '|' + " \
                            "toString(parseInteger('9999999999', 1)) + '|' + toString(parseInteger('', 1)) + '|' + " \
                            "toString(parseInteger('-0', 1)) + '|' + toString(parseInteger('007', 1))",
      'BetweenReverse' => "toString(daysBetween(#{day}, #{morning})) + '|' + " \
                          "toString(calendarMonthsBetween(#{day}, dateTime(2024, 1, 31))) + '|' + " \
                          "toString(calendarYearsBetween(dateTime(2024, 12, 31), dateTime(2025, 1, 1))) + '|' + " \
                          "toString(millisecondsBetween(#{day}, addMilliseconds(#{day}, 7)))",
      'MathEdge' => "toString(max(1, 2.5)) + '|' + toString(pow(2, 0.5)) + '|' + toString(pow(2, -1)) + '|' + " \
                    "toString(round(2.345, 2)) + '|' + toString(round(1.005, 2)) + '|' + toString(abs(-2.5)) + " \
                    "'|' + toString(floor(2.5)) + '|' + toString(min(3, 3.0)) + '|' + toString(pow(10, 30)) + " \
                    "'|' + toString(sqrt(16)) + '|' + toString(round(1234.5, -2))",
      'SqrtNegative' => 'toString(sqrt(-1))',
      'ToStringNumbers' => "toString(1.50) + '|' + toString(10 : 4) + '|' + toString(1 : 3) + '|' + " \
                           'toString(2 * 0.1) + toString(-0.0)'
    }
    cases.each do |name, expression|
      nanoflow("Case#{name}") do
        retrieve_objects 'Probe.Item', as: :item, single: true
        log_message "ORACLE #{name}={1}", parameters: [expression]
      end
    end
    page :Home do
      title 'Nanoflow function oracle'
      data_source microflow: 'Probe.Load'
      text_box :Name, attribute: 'Probe.Item.Name', caption: 'Name'
      cases.each_key { |name| button(name, caption: name) { on_click nanoflow: "Probe.Case#{name}" } }
    end
  end
  navigation { profile :Responsive, home_page: 'Probe.Home' }
end
# rubocop:enable Metrics/BlockLength
