# frozen_string_literal: true

require 'digest'
require_relative 'oql_predicate'
require_relative 'oql_view_query'
require_relative 'oql_relational_view'

module Mxrb
  module Runtime
    # Read-only projections over durable rows. OQL text is parsed into a small
    # supported grammar; it is never passed to SQLite as executable SQL.
    class OqlViews
      def initialize(project, store, decoder:)
        @store = store
        @decoder = decoder
        @decimal = DecimalContext.new(**DecimalContext.settings(project).transform_keys(&:to_sym))
        @definitions = project.modules.flat_map do |mod|
          mod.entities.filter_map do |entity|
            next unless entity.respond_to?(:oql_view?) && entity.oql_view?

            ["#{mod.name}.#{entity.name}", [entity, mod]]
          end
        end.to_h
      end

      def include?(name) = @definitions.key?(name.to_s)

      def reject_writes!(values)
        Array(values).compact.each do |value|
          raise NativeRuntimeError, "OQL view #{value.entity} is read-only" if include?(value.entity)
        end
      end

      def retrieve(name)
        entity, mod = @definitions.fetch(name.to_s)
        text = query(entity, mod)
        if OqlRelationalQuery.relational?(text)
          return OqlRelationalView.new(text, @store, decoder: @decoder, decimal: @decimal).retrieve(name.to_s, entity)
        end

        retrieve_projection(name, entity, text)
      end

      def associated(definition, start)
        unless start.entity == definition.from_entity
          raise NativeRuntimeError, 'OQL view associations are navigable only from the view'
        end

        Array(start.members[definition.name]).compact
      end

      private

      def retrieve_projection(name, entity, text)
        parsed = OqlViewQuery.new(text)
        associations = @store.schema.associations.select { _1.from_entity == name.to_s }
        validate_projections(name, entity, parsed.columns, associations)
        @store.schema.concrete_entities(parsed.source).flat_map do |definition|
          read_definition(name, definition, parsed, associations)
        end
      end

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

      def query(entity, mod)
        return entity.oql_query unless entity.oql_query.to_s.empty?
        return '' unless entity.respond_to?(:oql_source_document) && mod.respond_to?(:oql_view_documents)

        name = entity.oql_source_document.to_s.split('.').last
        document = mod.oql_view_documents.find { _1.fetch(:name) == name }
        document&.dig(:doc, 'Oql').to_s
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

        ->(row) { @decoder.call(row[attribute.sql_name], attribute.type) }
      end
    end
  end
end
