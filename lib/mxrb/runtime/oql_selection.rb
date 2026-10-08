# frozen_string_literal: true

module Mxrb
  module Runtime
    # Typed projection and aggregation shared by views and tabular OQL queries.
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
      end

      def columns
        @columns.to_h do |projection, column|
          type = case projection.aggregate
                 when 'COUNT' then :integer
                 when 'AVG' then :decimal
                 else column.type
                 end
          [projection.name, type]
        end
      end

      def each
        return enum_for(:each) unless block_given?

        rows = @relations.rows
        rows.select! { @filter.call(_1) } if @filter
        partitions(rows).each do |identity, group|
          yield identity, @columns.to_h { |projection, column| [projection.name, project(projection, column, group)] }
        end
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

      def partitions(rows)
        if @query.grouped?
          return { [] => rows } if @groups.empty?

          return rows.group_by { |row| @groups.map { _1.read(row) } }
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

        aggregate(projection.aggregate, values)
      end

      def aggregate(function, values)
        return @decimal.persist(@decimal.divide(values.sum, values.length)) if function == 'AVG'

        values.public_send(function.downcase)
      end

      def invalid!(message)
        raise NativeRuntimeError, "Unsupported relational OQL view: #{message}"
      end
    end
  end
end
