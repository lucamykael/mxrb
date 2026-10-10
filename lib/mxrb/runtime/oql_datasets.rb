# frozen_string_literal: true

require_relative 'oql_table'

module Mxrb
  module Runtime
    # Executes declared datasets or explicit OQL against this store only.
    # Result objects follow the native query actions: instantiate, copy matching
    # attributes, ignore unknown columns, and leave the objects uncommitted.
    class OqlDatasets
      TYPE = 'DataSets$DataSet'
      Definition = Data.define(:name, :query, :parameters, :excluded)

      def self.definitions(project)
        return project.oql_datasets if project.respond_to?(:oql_datasets)

        project.modules.flat_map { module_definitions(_1) }
      end

      def self.module_definitions(mod)
        return [] unless mod.respond_to?(:application_documents)

        mod.application_documents.filter_map do |document|
          build_definition(mod.name, document) if document[:type] == TYPE
        end
      end

      def self.build_definition(module_name, document)
        value = document.fetch(:doc)
        parameters = IO::BsonCodec.parse_array(value['Parameters'])[:items].map { _1.fetch('Name') }
        Definition.new("#{module_name}.#{document[:name]}", value.dig('Source', 'Query'),
                       parameters, value['Excluded'] == true)
      end

      def initialize(project, store, decoder:, decimal:)
        @store = store
        @decoder = decoder
        @decimal = decimal
        @datasets = self.class.definitions(project).to_h { [_1.name, _1] }
        @entities = project.modules.flat_map { |mod| mod.entities.map { ["#{mod.name}.#{_1.name}", _1] } }.to_h
      end

      def query(text)
        OqlTable.new(text, @store, decoder: @decoder, decimal: @decimal)
      end

      def dataset_query(name)
        definition = @datasets[name.to_s]
        invalid!("unknown dataset #{name}") unless definition
        invalid!("excluded dataset #{name}") if definition.excluded
        invalid!('dataset parameters are not supported') unless definition.parameters.empty?
        invalid!('dataset has no OQL source') unless definition.query.is_a?(String)
        definition.query
      end

      def objects(text, entity_name)
        entity = @entities[entity_name.to_s]
        invalid!("unknown result entity #{entity_name}") unless entity
        table = query(text)
        validate_columns(table, entity)
        attributes = entity.attributes.map(&:name)
        table.rows.map do |row|
          @store.create(entity_name).tap { _1.members.merge!(row.slice(*attributes)) }
        end
      end

      private

      def validate_columns(table, entity)
        table.definition.columns.each do |column|
          attribute = entity.attributes.find { _1.name == column.name }
          next unless attribute
          next if attribute.type == column.type || integer_types?(attribute.type, column.type)

          invalid!("result column #{column.name} does not match #{attribute.type}")
        end
      end

      def integer_types?(first, second)
        [first, second].all? { %i[integer long autonumber].include?(_1) }
      end

      def invalid!(message)
        raise NativeRuntimeError, "Unsupported OQL dataset: #{message}"
      end
    end
  end
end
