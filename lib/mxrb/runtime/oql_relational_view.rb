# frozen_string_literal: true

require 'json'
require_relative 'oql_relational_query'
require_relative 'oql_relations'
require_relative 'oql_selection'

module Mxrb
  module Runtime
    # Binds view projections before reading rows, then groups and aggregates typed values.
    class OqlRelationalView
      def initialize(text, store, decoder:, decimal:)
        query = OqlRelationalQuery.new(text)
        @store = store
        relations = OqlRelations.new(query, store, decoder:)
        @selection = OqlSelection.new(query, relations, decimal:)
        @columns = @selection.projections
      end

      def retrieve(name, entity)
        associations = @store.schema.associations.select { _1.from_entity == name }
        validate_outputs(entity, associations)
        @selection.each.map do |identity, values|
          members = project_members(values, associations)
          id = Digest::SHA256.hexdigest(JSON.generate([name, identity]))
          Native::ObjectValue.new(entity: name, id: "view:#{id}", members:)
        end
      end

      private

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
        unless !projection.aggregate && column.type == :identifier && association.type == :Reference &&
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
