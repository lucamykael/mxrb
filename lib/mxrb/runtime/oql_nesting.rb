# frozen_string_literal: true

module Mxrb
  module Runtime
    # Parenthesis depth of OQL tokens, so clauses, UNION and aggregates of subqueries
    # are told apart from those of the enclosing query.
    module OqlNesting
      module_function

      def paren(token) = { '(' => 1, ')' => -1 }.fetch(token.text, 0)

      # Indexes of the tokens outside every parenthesis for which the block holds.
      def top_level(tokens)
        depth = 0
        tokens.each_index.select do |index|
          depth += paren(tokens[index])
          depth.zero? && yield(tokens[index])
        end
      end

      # The tokens without any "( SELECT ... )".
      def outside_subqueries(tokens)
        kept = []
        index = 0
        while index < tokens.length
          skip = subquery_start?(tokens, index)
          kept << tokens[index] unless skip
          index = skip ? closing(tokens, index) + 1 : index + 1
        end
        kept
      end

      def subquery_start?(tokens, index)
        tokens[index].text == '(' && tokens.fetch(index + 1, tokens[index]).text.casecmp?('SELECT')
      end

      # Index of the parenthesis that closes the one at start, or the last index when unbalanced.
      def closing(tokens, start)
        depth = 0
        (start...tokens.length).find { |index| (depth += paren(tokens[index])).zero? } || tokens.length
      end
    end
  end
end
