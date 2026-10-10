# frozen_string_literal: true

module Mxrb
  module Runtime
    # Decides whether a view query needs the relational evaluator: joins, grouping,
    # DISTINCT, aggregates, subqueries, UNION or computed projections such as LOWER(x) or a + 1.
    module OqlQueryShape
      AGGREGATES = %w[COUNT SUM AVG MIN MAX].freeze
      COMPUTED = %w[( + - * : % CASE].freeze

      module_function

      def relational?(text)
        tokens = Oql::Translator.tokens(text).reject { _1.type == :space }
        nested_select?(tokens) || computed_selection?(tokens) || tokens.each_with_index.any? do |token, index|
          token.type == :word && relational_word?(token.text.upcase, tokens[index + 1]&.text)
        end
      end

      def nested_select?(tokens) = tokens.count { _1.type == :word && _1.text.casecmp?('SELECT') } > 1

      # String literals keep their quotes, so quoted keywords never match.
      def computed_selection?(tokens)
        words = tokens.map { _1.text.upcase }
        selection = words.drop((words.index('SELECT') || words.length) + 1).take_while { _1 != 'FROM' }
        selection != ['*'] && selection.intersect?(COMPUTED)
      end

      def relational_word?(word, following)
        %w[JOIN GROUP DISTINCT UNION EXISTS].include?(word) || (AGGREGATES.include?(word) && following == '(')
      end
    end
  end
end
