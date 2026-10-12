# frozen_string_literal: true

module Mxrb
  module Runtime
    # EXISTS, IN and value subqueries of OQL expressions. Included by OqlPredicate,
    # which supplies the subquery compiler, the token queue and the source text.
    module OqlSubqueryGrammar
      private

      def subquery_ahead? = @tokens.first == '(' && @tokens[1].to_s.casecmp?('SELECT')

      # Consumes "( SELECT ... )" and compiles the text between the parentheses.
      def subquery
        error!('subqueries are not supported here') unless @subquery
        opening = @tokens.shift
        depth = 1
        closing = nil
        until depth.zero?
          closing = @tokens.shift
          error!('unbalanced subquery parentheses') unless closing
          depth += { '(' => 1, ')' => -1 }.fetch(closing.to_s, 0)
        end
        @subquery.call(@text[(opening.offset + 1)...closing.offset], @resolve, @scope)
      end

      def exists_operand
        error!('EXISTS requires a subquery') unless subquery_ahead?
        query = subquery
        OqlPredicate::Operand.new(:boolean, ->(row) { query.rows(row).any? }, false)
      end

      def scalar_subquery
        query = single_column(subquery)
        error!('a value subquery requires one aggregate or LIMIT 1') unless query.single_row?
        type = query.columns.first.type
        reader = lambda do |row|
          rows = query.rows(row)
          error!('a value subquery returned more than one row') if rows.length > 1
          rows.first&.first
        end
        OqlPredicate::Operand.new(OqlPredicate::KINDS.fetch(type), reader, false, type, type == :decimal ? 8 : 0)
      end

      # SQL membership: NULL when the value is NULL, or when nothing matches and a candidate is NULL.
      def within_subquery(left)
        query = single_column(subquery)
        validate_comparison(left, column_operand(query), '=')
        normalize = ->(value) { comparable(left.kind, value) }
        OqlPredicate::Operand.new(:boolean, lambda { |row|
          candidates = query.rows(row).map(&:first)
          OqlMembership.within(left.read, candidates, normalize).call(row)
        }, false)
      end

      def column_operand(query)
        type = query.columns.first.type
        OqlPredicate::Operand.new(OqlPredicate::KINDS.fetch(type), nil, false, type)
      end

      def single_column(query)
        error!('a subquery must select exactly one column') unless query.columns.one?
        type = query.columns.first.type
        error!("unsupported subquery column type #{type}") unless OqlPredicate::KINDS[type]
        query
      end
    end
  end
end
