# frozen_string_literal: true

module Mxrb
  module Runtime
    # Binds HAVING conditions and computed projections of an OqlSelection to group readers.
    module OqlSelectionTerms
      private

      def having_predicate(text)
        aggregate = method(:having_aggregate)
        OqlPredicate.new(text, @relations.scopes, aggregate:, **@relations.expression_options) do
          @relations.outer?(_1) ? @relations.term(_1) : having_column(_1)
        end
      end

      def having_aggregate(function, reference)
        column = @relations.column(reference) unless reference == '*'
        validate_aggregate(function, column)
        projection = OqlRelationalQuery::Projection.new(reference, nil, function)
        [aggregate_type(function, column), ->(group) { project(projection, column, group) }]
      end

      def having_column(reference)
        column = @relations.column(reference)
        invalid!('HAVING columns must occur in GROUP BY') unless @groups.include?(column)
        [column.type, ->(group) { column.read(group.first) }]
      end

      # A computed projection reads its group; ungrouped rows form one-row groups.
      def computed_term(text)
        aggregate = @query.grouped? ? method(:having_aggregate) : nil
        OqlPredicate.value(text, @relations.scopes, aggregate:, **@relations.expression_options) do |reference|
          next @relations.term(reference) if @relations.outer?(reference)

          column = @relations.column(reference)
          invalid!('non-aggregate projections must occur in GROUP BY') if @query.grouped? && !@groups.include?(column)
          [column.type, ->(group) { column.read(group.first) }]
        end
      end

      def aggregate_type(function, column)
        case function
        when 'COUNT' then :integer
        when 'AVG' then :decimal
        else column.type
        end
      end
    end
  end
end
