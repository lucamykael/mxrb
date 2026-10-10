# frozen_string_literal: true

require_relative 'oql_nesting'

module Mxrb
  module Runtime
    # Splits a query at top-level UNION [ALL]; words in strings and subqueries stay put.
    module OqlUnion
      module_function

      # [[text, all], ...]; all tells whether the part joins with UNION ALL.
      def parts(text)
        tokens = Oql::Translator.tokens(text.to_s.strip)
        cuts = OqlNesting.top_level(tokens) { union?(_1) }
        [-1, *cuts].each_with_index.map do |cut, position|
          start, all = part_start(tokens, cut)
          [tokens[start...cuts.fetch(position, tokens.length)].map(&:text).join.strip, all]
        end
      end

      def union?(token) = token.type == :word && token.text.casecmp?('UNION')

      # Where the part after a UNION begins, skipping a following ALL.
      def part_start(tokens, cut)
        word = ((cut + 1)...tokens.length).find { tokens[_1].type != :space }
        all = cut >= 0 && !word.nil? && tokens[word].text.casecmp?('ALL')
        [all ? word + 1 : cut + 1, all]
      end
    end
  end
end
