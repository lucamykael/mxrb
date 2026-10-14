# frozen_string_literal: true

require 'bigdecimal'

module Mxrb
  module Runtime
    # parseDecimal(text, pattern): Java DecimalFormat.parse (en_US, BigDecimal
    # results) as Mendix 11.12.1 applies it. The longest matching prefix decides
    # the sign, digits may carry ',' anywhere when the pattern groups, an 'E'
    # exponent is always read, the suffix must match, '%' and '‰' divide the
    # value, and text after the suffix is ignored. Returns nil when nothing parses.
    module DecimalParsing
      Subpattern = Data.define(:prefix, :number, :suffix, :multiplier) do
        def grouping? = number.include?(',')
      end
      SPECIAL = { '%' => ['%', 100], '‰' => ['‰', 1000], '¤' => ['$', 1] }.freeze
      NUMBER_CHARACTERS = '#0,.'
      GROUPED = /\A(?<whole>[0-9,]*)(?:\.(?<fraction>[0-9]*))?/
      UNGROUPED = /\A(?<whole>[0-9]*)(?:\.(?<fraction>[0-9]*))?/

      module_function

      def parse(text, pattern)
        text = text.to_s
        positive, negative = subpatterns(pattern.to_s)
        signs = matching(text, positive, negative)
        return nil if signs.empty?

        number, position = digits(text, signs.values.first.prefix.length, positive.grouping?)
        signed(number, sign(signs, text[position..]), positive.multiplier) if number
      end

      def signed(number, positive_sign, multiplier)
        return nil if positive_sign.nil?

        (positive_sign ? number : -number) / multiplier
      end

      def matching(text, positive, negative)
        longest({ true => positive, false => negative }.select { text.start_with?(_2.prefix) }, :prefix)
      end

      # true or false when exactly one of the candidate suffixes decides the sign.
      def sign(signs, rest)
        signs = longest(signs.select { rest.start_with?(_2.suffix) }, :suffix)
        signs.keys.first if signs.size == 1
      end

      def longest(signs, part)
        lengths = signs.transform_values { _1.public_send(part).length }
        signs.select { |sign, _| lengths[sign] == lengths.values.max }
      end

      def subpatterns(pattern)
        positive_text, negative_text = split(pattern)
        positive = subpattern(positive_text)
        negative = if negative_text
                     subpattern(negative_text).with(multiplier: positive.multiplier)
                   else
                     positive.with(prefix: "-#{positive.prefix}")
                   end
        [positive, negative]
      end

      def split(pattern)
        quoted = false
        pattern.each_char.with_index do |character, index|
          quoted = !quoted if character == "'"
          return [pattern[0...index], pattern[(index + 1)..]] if character == ';' && !quoted
        end
        [pattern, nil]
      end

      # Prefix literals, the number part ('#', '0', ',', '.', 'E0') and suffix literals.
      def subpattern(text)
        tokens = literals(text)
        start, finish = number_span(tokens)
        (prefix, prefix_factor), (suffix, suffix_factor) = [tokens[0...start], tokens[finish..]].map { affix(_1) }
        Subpattern.new(prefix:, number: tokens[start...finish].map(&:first).join, suffix:,
                       multiplier: [prefix_factor, suffix_factor].max)
      end

      def number_span(tokens)
        start = tokens.index { |character, quoted| !quoted && NUMBER_CHARACTERS.include?(character) } || tokens.size
        length = tokens[start..].index { |character, quoted| quoted || !"#{NUMBER_CHARACTERS}E".include?(character) }
        [start, start + (length || (tokens.size - start))]
      end

      def affix(tokens)
        symbols = tokens.map { |character, quoted| quoted ? [character, 1] : SPECIAL.fetch(character, [character, 1]) }
        [symbols.map(&:first).join, symbols.map(&:last).max || 1]
      end

      # [character, quoted] pairs; 'quoted text' is literal and '' is a quote.
      def literals(text)
        text.scan(/'(?:[^']|'')*'|./m).flat_map do |token|
          next [["'", true]] if token == "''"
          next [[token, false]] unless token.start_with?("'")

          token[1...-1].gsub("''", "'").chars.map { [_1, true] }
        end
      end

      # The digits from position: a BigDecimal and the position after them, or nil.
      def digits(text, position, grouping)
        match = (grouping ? GROUPED : UNGROUPED).match(text[position..])
        whole = match[:whole].delete(',')
        fraction = match[:fraction].to_s
        return nil if whole.empty? && fraction.empty?

        exponent, finish = exponent(text, position + match[0].length)
        [decimal(whole, fraction, exponent), trailing_separator(match, position) || finish]
      end

      def decimal(whole, fraction, exponent)
        BigDecimal("#{whole.empty? ? '0' : whole}.#{fraction.empty? ? '0' : fraction}") * (BigDecimal(10)**exponent)
      end

      # Trailing grouping separators are not consumed, as in DecimalFormat.
      def trailing_separator(match, position)
        return unless match[:fraction].to_s.empty? && match[:whole].end_with?(',')

        position + match[:whole].rindex(',')
      end

      def exponent(text, position)
        match = /\AE(-?)([0-9]+)/.match(text[position..])
        return [0, position] unless match

        [match[2].to_i * (match[1].empty? ? 1 : -1), position + match[0].length]
      end
    end
  end
end
