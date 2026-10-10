# frozen_string_literal: true

require 'mxrb'

# Client oracle for nanoflow expressions: each button runs one nanoflow that logs
# "ORACLE <case>=<value>" in the browser console. Run with script/client_native_oracle.
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Probe do
    enumeration :Kind do
      value :Big, caption: 'Large thing'
      value :Small, caption: 'Small one'
    end
    entity(:Item) { string :Name }
    entity :Row do
      string :Name
      enum :Kind, enumeration: 'Probe.Kind'
      association 'Probe.Item', name: :Row_Item, cardinality: :many_to_one
    end
    microflow :Load do
      create_object 'Probe.Item', as: :item, set: { Name: "'probe'" }, commit: true
      create_object 'Probe.Row', as: :row, commit: true do
        set :Name, to: "'North'"
        set :Kind, to: 'Probe.Kind.Big'
        set_association 'Probe.Row_Item', to: '$item'
      end
      create_object 'Probe.Row', as: :orphan, set: { Name: "'Lone'" }, commit: true
      return_type 'Probe.Item'
      return_value '$item'
    end
    cases = {
      'Trim' => "'[' + trim('  a b  ') + ']|' + toString(length(trim('  x  '))) + '|' + " \
                "toString(length(trim('	x	')))",
      'Casing' => "toLowerCase('ÀBÇ İ') + '|' + toUpperCase('straße ﬁ') + '|' + toUpperCase('i')",
      'Length' => "toString(length('ab😀')) + '|' + toString(length(''))",
      'Substring' => "substring('abcdef', 2) + '|' + substring('abcdef', 1, 3) + '|[' + substring('abc', 3) + " \
                     "']'",
      'SubstringOut' => "substring('abc', 5)",
      'SubstringLong' => "substring('abc', 1, 9)",
      'Find' => "toString(find('abcabc', 'c')) + '|' + toString(find('abcabc', 'c', 3)) + '|' + " \
                "toString(findLast('abcabc', 'c')) + '|' + toString(findLast('abcabc', 'c', 4)) + '|' + " \
                "toString(find('abc', '')) + '|' + toString(find('abc', 'z'))",
      'Replace' => "replaceAll('a.b.c', '.', '-') + '|' + replaceAll('abc', '(b)', '[$1]') + '|' + " \
                   "replaceFirst('aaa', 'a', 'b') + '|' + replaceAll('ab', 'b', '<$&>') + '|' + " \
                   "replaceAll('ab', 'b', '$$') + '|' + replaceAll('ab', 'x*', '-')",
      'ReplaceInline' => "replaceAll('AbAB', '(?i)b', 'x')",
      'Match' => "toString(isMatch('abc', 'b')) + '|' + toString(isMatch('abc', 'a.c')) + '|' + " \
                 "toString(isMatch('abc', 'b|abc')) + '|' + toString(isMatch('', '')) + '|' + " \
                 "toString(isMatch('a\\nb', 'a.b'))",
      'MatchInline' => "toString(isMatch('ABC', '(?i)abc'))",
      'Contains' => "toString(contains('Hello', 'ell')) + '|' + toString(contains('Hello', 'ELL')) + '|' + " \
                    "toString(startsWith('Hello', 'He')) + '|' + toString(endsWith('Hello', 'LO'))",
      'Url' => "urlEncode('a b&c/ç~*') + '|' + urlDecode('a+b%20c%C3%A7')",
      'Caption' => "getCaption($row/Kind) + '|' + getKey($row/Kind) + '|' + getCaption(Probe.Kind.Small) + " \
                   "'|' + toString($row/Kind)",
      'CaptionEmpty' => "'[' + getCaption($orphan/Kind) + ']'",
      'Tokens' => "toString([%CurrentDateTime%] > dateTime(2020)) + '|' + " \
                  "toString([%BeginOfCurrentDay%] <= [%CurrentDateTime%]) + '|' + " \
                  "toString([%EndOfCurrentDay%] > [%CurrentDateTime%]) + '|' + " \
                  'toString([%BeginOfCurrentDayUTC%] <= [%CurrentDateTime%])',
      'Path' => "$row/Probe.Row_Item/Probe.Item/Name + '|' + toString($row/Probe.Row_Item = $item) + " \
                "'|' + toString($row/Probe.Row_Item != empty) + '|' + " \
                'toString($orphan/Probe.Row_Item = empty)',
      'PathEmpty' => "'[' + $orphan/Probe.Row_Item/Probe.Item/Name + ']'",
      'PathObject' => "toString($row/Probe.Row_Item/Probe.Item = $item) + '|' + " \
                      'toString($orphan/Probe.Row_Item/Probe.Item = empty)',
      'TrimEmpty' => "'[' + trim($orphan/Probe.Row_Item/Probe.Item/Name) + ']'",
      'LowerEmpty' => "'[' + toLowerCase($orphan/Probe.Row_Item/Probe.Item/Name) + ']'",
      'LengthEmpty' => 'toString(length($orphan/Probe.Row_Item/Probe.Item/Name))',
      'ContainsEmpty' => "toString(contains($orphan/Probe.Row_Item/Probe.Item/Name, 'a'))",
      'FindEmpty' => "toString(find($orphan/Probe.Row_Item/Probe.Item/Name, 'a'))",
      'ConcatMixed' => "'a' + 1 + '|' + 'b' + 1.5 + '|' + toString(1 + 2) + 'c'",
      'TokenDay' => "toString([%BeginOfCurrentDay%] = trimToDays([%CurrentDateTime%])) + '|' + " \
                    'toString([%EndOfCurrentDay%] = addMilliseconds(addDays([%BeginOfCurrentDay%], 1), -1)) + ' \
                    "'|' + toString([%EndOfCurrentDay%] = addDays([%BeginOfCurrentDay%], 1)) + '|' + " \
                    'toString([%BeginOfCurrentDayUTC%] = trimToDaysUTC([%CurrentDateTime%]))',
      'TokenUnits' => "toString([%BeginOfCurrentHour%] = trimToHours([%CurrentDateTime%])) + '|' + " \
                      "toString([%BeginOfCurrentMinute%] = trimToMinutes([%CurrentDateTime%])) + '|' + " \
                      "toString([%BeginOfCurrentMonth%] = trimToMonths([%CurrentDateTime%])) + '|' + " \
                      "toString([%BeginOfCurrentYear%] = trimToYears([%CurrentDateTime%])) + '|' + " \
                      'toString([%EndOfCurrentHour%] = addMilliseconds(addHours([%BeginOfCurrentHour%], 1), -1)) + ' \
                      "'|' + " \
                      'toString([%EndOfCurrentMonth%] = addMilliseconds(addMonths([%BeginOfCurrentMonth%], 1), -1))'
    }
    cases.each do |name, expression|
      nanoflow("Case#{name}") do
        retrieve_objects 'Probe.Item', as: :item, single: true
        retrieve_objects 'Probe.Row', as: :row, single: true, xpath: "[Name = 'North']"
        retrieve_objects 'Probe.Row', as: :orphan, single: true, xpath: "[Name = 'Lone']"
        log_message "ORACLE #{name}={1}", parameters: [expression]
      end
    end
    page :Home do
      title 'Nanoflow expression oracle'
      data_source microflow: 'Probe.Load'
      text_box :Name, attribute: 'Probe.Item.Name', caption: 'Name'
      cases.each_key { |name| button(name, caption: name) { on_click nanoflow: "Probe.Case#{name}" } }
    end
  end
  navigation { profile :Responsive, home_page: 'Probe.Home' }
end
# rubocop:enable Metrics/BlockLength
