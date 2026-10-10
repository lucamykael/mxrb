# frozen_string_literal: true

require 'json'
require_relative 'oql_relational_query'
require_relative 'oql_relations'
require_relative 'oql_selection'
require_relative 'oql_subquery'
require_relative 'oql_union'

module Mxrb
  module Runtime
    # Binds view projections before reading rows, then groups and aggregates typed values.
    # UNION parts take the first part's column names; UNION removes duplicates ignoring case.
    class OqlRelationalView
      def initialize(text, store, decoder:, decimal:, sources: nil)
        @store = store
        @parts = OqlUnion.parts(text)
        @selections = @parts.map do |part, _all|
          query = OqlRelationalQuery.new(part)
          subquery = OqlSubquery.factory(store, decoder:, decimal:, depth: 0, sources:)
          OqlSelection.new(query, OqlRelations.new(query, store, decoder:, sources:, subquery:), decimal:)
        end
        @columns = @selections.first.projections
        validate_union
      end

      def retrieve(name, entity)
        associations = @store.schema.associations.select { _1.from_entity == name }
        validate_outputs(entity, associations)
        results.map do |identity, values|
          members = project_members(values, associations)
          id = Digest::SHA256.hexdigest(JSON.generate([name, identity]))
          Native::ObjectValue.new(entity: name, id: "view:#{id}", members:)
        end
      end

      private

      def results
        return @selections.first.each.to_a if @selections.one?

        @selections.each_index.reduce([]) do |rows, index|
          combined = rows + part(index)
          index.zero? || @parts[index].last ? combined : distinct(combined)
        end
      end

      # A part's rows under the first part's column names.
      def part(index)
        names = @columns.map { _1.first.name }
        @selections[index].each.map { |identity, values| [[index, identity], names.zip(values.values).to_h] }
      end

      def distinct(rows)
        rows.group_by { |_identity, values| values.values.map { _1.is_a?(String) ? _1.downcase : _1 } }
            .map { |key, group| [[:union, key], group.first.last] }
      end

      def validate_union
        return if @selections.all? { _1.projections.length == @columns.length }

        invalid!('UNION parts must select the same number of columns')
      end

      def project_members(values, associations)
        values.to_h do |name, value|
          association = associations.find { _1.name == name }
          value = @store.find(association.to_entity, value) if association && value
          [name, value]
        end
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
        unless !projection.aggregate && !projection.expression && column.type == :identifier &&
               association.type == :Reference &&
               @store.schema.assignable?(column.entity, association.to_entity)
          invalid!("unsupported view association #{association.name}")
        end
      end

      def invalid!(message)
        raise NativeRuntimeError, "Unsupported relational OQL view: #{message}"
      end
    end
  end
end
