# frozen_string_literal: true

require 'digest'
require_relative 'oql_predicate'
require_relative 'oql_view_query'

module Mxrb
  module Runtime
    # A view over the attributes of one persistent entity, read straight from its table.
    class OqlProjectionView
      def initialize(store, decoder:)
        @store = store
        @decoder = decoder
      end

      def retrieve(name, entity, text)
        parsed = OqlViewQuery.new(text)
        associations = @store.schema.associations.select { _1.from_entity == name.to_s }
        validate_projections(name, entity, parsed.columns, associations)
        @store.schema.concrete_entities(parsed.source).flat_map do |definition|
          read_definition(name, definition, parsed, associations)
        end
      end

      private

      def read_definition(name, definition, parsed, associations)
        readers = projections(parsed.columns, definition, associations)
        filter = predicate(parsed.filter, parsed.scope, definition)
        read_rows(name, definition, readers, filter)
      end

      def validate_projections(name, entity, columns, associations)
        expected = entity.attributes.map(&:name) + associations.map(&:name)
        return if columns.map(&:last).sort == expected.sort

        raise NativeRuntimeError, "OQL view #{name} projections must match its attributes and associations"
      end

      def read_rows(name, definition, projections, predicate)
        table = definition.table.gsub('"', '""')
        @store.database.execute("SELECT * FROM \"#{table}\" ORDER BY rowid").filter_map do |row|
          next unless predicate.call(row)

          members = projections.to_h { |key, reader| [key, reader.call(row)] }
          id = Digest::SHA256.hexdigest([name, definition.name, row.fetch('id')].join("\0"))
          Native::ObjectValue.new(entity: name.to_s, id: "view:#{id}", members:)
        end
      end

      def predicate(filter, scope, definition)
        return ->(_row) { true } unless filter

        OqlPredicate.new(filter, scope) do |column|
          reader = attribute_reader(column, definition)
          [definition.columns.find { _1.name == column }.type, reader]
        end
      end

      def projections(columns, definition, associations)
        columns.map do |column, output|
          association = associations.find { _1.name == output }
          reader = if association
                     association_reader(column, definition,
                                        association)
                   else
                     attribute_reader(column, definition)
                   end
          [output, reader]
        end
      end

      def association_reader(column, definition, association)
        unless column.casecmp?('ID') && association.type == :Reference &&
               @store.schema.assignable?(definition.name, association.to_entity)
          raise NativeRuntimeError, "Unsupported OQL view association: #{association.name}"
        end

        ->(row) { @store.find(definition.name, row.fetch('id')) }
      end

      def attribute_reader(column, definition)
        attribute = definition.columns.find { _1.name == column }
        raise NativeRuntimeError, "Unknown OQL view source attribute: #{column}" unless attribute

        ->(row) { OqlRelations.value(@decoder.call(row[attribute.sql_name], attribute.type), attribute.type) }
      end
    end
  end
end
