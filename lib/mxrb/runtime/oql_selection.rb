# frozen_string_literal: true

module Mxrb
  module Runtime
    # Typed projection and aggregation shared by views and tabular OQL queries.
    # Group keys, DISTINCT and string MIN/MAX ignore case; the first stored row represents its group.
    class OqlSelection
      NUMBERS = %i[integer long autonumber decimal].freeze
      ORDERED = [*NUMBERS, :string, :datetime].freeze
      attr_reader :projections

      def initialize(query, relations, decimal:)
        @query = query
        @relations = relations
        @decimal = decimal
        @groups = query.groups.map { @relations.column(_1) }
        @columns = query.projections.map { bind_projection(_1) }
        @projections = @columns
        @filter = query.filter && @relations.predicate(query.filter)
        @having = query.having && having_predicate(query.having)
      end

      def columns
        @columns.to_h do |projection, column|
          [projection.name, projection.aggregate ? aggregate_type(projection.aggregate, column) : column.type]
        end
      end

      def each(&)
        return enum_for(:each) unless block_given?

        results.each(&)
      end

      private

      def bind_projection(projection)
        column = @relations.column(projection.reference) unless projection.reference == '*'
        if @query.grouped? && !projection.aggregate && !@groups.include?(column)
          invalid!('non-aggregate projections must occur in GROUP BY')
        end
        validate_aggregate(projection.aggregate, column)
        [projection, column]
      end

      def validate_aggregate(function, column)
        return unless function && function != 'COUNT'

        types = %w[SUM AVG].include?(function) ? NUMBERS : ORDERED
        invalid!("#{function} does not support #{column.type}") unless types.include?(column.type)
      end

      def results
        rows = @relations.rows
        rows.select! { @filter.call(_1) } if @filter
        groups = partitions(rows)
        groups = groups.select { |_identity, group| @having.call(group) } if @having
        projected = groups.map { |identity, group| [identity, values(group)] }
        @query.distinct? ? distinct(projected) : projected
      end

      def values(group) = @columns.to_h { |projection, column| [projection.name, project(projection, column, group)] }

      def having_predicate(text)
        OqlPredicate.new(text, @relations.scopes, aggregate: method(:having_aggregate)) { having_column(_1) }
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

      def aggregate_type(function, column)
        case function
        when 'COUNT' then :integer
        when 'AVG' then :decimal
        else column.type
        end
      end

      def distinct(results)
        results.group_by { |_identity, values| values.values.map { _1.is_a?(String) ? _1.downcase : _1 } }
               .map { |key, group| [[:distinct, key], group.first.last] }
      end

      def group_key(column, value) = value.is_a?(String) && column.type == :string ? value.downcase : value

      def partitions(rows)
        if @query.grouped?
          return { [] => rows } if @groups.empty?

          return rows.group_by { |row| @groups.map { group_key(_1, _1.read(row)) } }
        end
        rows.map do |row|
          identity = @query.sources.map do |source|
            [source.scope, row.dig(source.scope, '__entity'), row.dig(source.scope, 'ID')]
          end
          [identity, [row]]
        end
      end

      def project(projection, column, rows)
        return column.read(rows.first) unless projection.aggregate
        return rows.length if projection.reference == '*'

        values = rows.map { column.read(_1) }.compact
        return values.length if projection.aggregate == 'COUNT'
        return nil if values.empty?

        aggregate(projection.aggregate, values, column)
      end

      def aggregate(function, values, column)
        return @decimal.persist(@decimal.divide(values.sum, values.length)) if function == 'AVG'
        return values.public_send(:"#{function.downcase}_by", &:downcase) if column.type == :string

        values.public_send(function.downcase)
      end

      def invalid!(message)
        raise NativeRuntimeError, "Unsupported relational OQL view: #{message}"
      end
    end
  end
end
