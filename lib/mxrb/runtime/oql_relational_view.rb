# frozen_string_literal: true

require 'json'
require_relative 'oql_relational_query'
require_relative 'oql_relations'

module Mxrb
  module Runtime
    # Binds view projections before reading rows, then groups and aggregates typed values.
    class OqlRelationalView
      NUMBERS = %i[integer long autonumber decimal].freeze
      ORDERED = [*NUMBERS, :string, :datetime].freeze

      def initialize(text, store, decoder:, decimal:)
        @query = OqlRelationalQuery.new(text)
        @store = store
        @decimal = decimal
        @relations = OqlRelations.new(@query, store, decoder:)
        @groups = @query.groups.map { @relations.column(_1) }
        @columns = @query.projections.map { bind_projection(_1) }
        @filter = @query.filter && @relations.predicate(@query.filter)
      end

      def retrieve(name, entity)
        associations = @store.schema.associations.select { _1.from_entity == name }
        validate_outputs(entity, associations)
        rows = @relations.rows
        rows.select! { @filter.call(_1) } if @filter
        partitions(rows).map do |identity, group|
          members = project_members(group, associations)
          id = Digest::SHA256.hexdigest(JSON.generate([name, identity]))
          Native::ObjectValue.new(entity: name, id: "view:#{id}", members:)
        end
      end

      private

      def project_members(group, associations)
        @columns.to_h do |projection, column|
          value = project(projection, column, group)
          association = associations.find { _1.name == projection.name }
          value = @store.find(association.to_entity, value) if association && value
          [projection.name, value]
        end
      end

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

      def validate_outputs(entity, associations)
        expected = entity.attributes.map(&:name) + associations.map(&:name)
        actual = @columns.map { _1.first.name }
        invalid!('projections must match view attributes and associations') unless actual.sort == expected.sort
        validate_references(associations)
      end

      def validate_references(associations)
        @columns.each do |projection, column|
          association = associations.find { _1.name == projection.name }
          validate_reference(projection, column, association) if association
        end
      end

      def validate_reference(projection, column, association)
        unless !projection.aggregate && column.type == :identifier && association.type == :Reference &&
               @store.schema.assignable?(column.entity, association.to_entity)
          invalid!("unsupported view association #{association.name}")
        end
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
