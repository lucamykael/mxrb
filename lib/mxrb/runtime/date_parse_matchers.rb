# frozen_string_literal: true

require_relative 'date_formatting'

module Mxrb
  module Runtime
    # The text each SimpleDateFormat field accepts when parsing (en_US).
    module DateParseMatchers
      MONTHS = DateFormatting::MONTHS.map(&:downcase).freeze
      DAYS = DateFormatting::DAYS.map(&:downcase).freeze
      ZONES = { 'utc' => 0, 'gmt' => 0, 'coordinated universal time' => 0, 'est' => -18_000 }.freeze
      TEXT = { 'M' => MONTHS, 'L' => MONTHS, 'E' => DAYS }.freeze
      OFFSET = { 'X' => 'Z|[+-]\\d{2}(?::?\\d{2})?', 'Z' => '[+-]\\d{4}' }.freeze
      FIXED = {
        'a' => /AM|PM/i, 'G' => /AD|BC/i,
        'z' => Regexp.new(ZONES.keys.sort_by { -_1.length }.map { Regexp.escape(_1) }.join('|'), 'i')
      }.freeze

      module_function

      def numeric?(field) = !name?(field) && !'aGzZX'.include?(field[0])

      def name?(field) = TEXT.key?(field[0]) && (field.length >= 3 || field[0] == 'E')

      def matcher(field, adjacent:)
        letter = field[0]
        return names(TEXT.fetch(letter)) if name?(field)
        return FIXED.fetch(letter) if FIXED.key?(letter)
        return Regexp.new(OFFSET.fetch(letter)) if OFFSET.key?(letter)

        adjacent ? /[ \t]*-?\d{#{field.length}}/ : /[ \t]*-?\d+/
      end

      def names(list)
        Regexp.new((list + list.map { _1[0, 3] }).uniq.sort_by { -_1.length }.join('|'), 'i')
      end
    end
  end
end
