# frozen_string_literal: true

require 'json'

module Mxrb
  module RubyApp
    # What a Mendix 11.12.1 Runtime reports through Core.getMetaObjects,
    # Core.getMetaAssociations and its microflow API, for the application's records
    # and services and the Runtime's own System module.
    class Metamodel # rubocop:disable Metrics/ClassLength
      SYSTEM = JSON.parse(File.read(File.join(__dir__, '..', 'runtime', 'system_metamodel_11.12.1.json'))).freeze
      PRIMITIVE_TYPES = {
        string: 'String', integer: 'Integer', long: 'Long', decimal: 'Decimal', boolean: 'Boolean',
        datetime: 'DateTime', date_time: 'DateTime', autonumber: 'AutoNumber', hashstring: 'HashString',
        hash_string: 'HashString', binary: 'Binary', enum: 'Enum', enumeration: 'Enum'
      }.freeze
      # IDataType names and DSL types of each primitive; an Integer reports as Long.
      DATA_TYPES = {
        'String' => 'String', 'Integer' => 'Long', 'Long' => 'Long', 'Decimal' => 'Decimal',
        'Boolean' => 'Boolean', 'DateTime' => 'Datetime', 'AutoNumber' => 'AutoNumber',
        'HashString' => 'HashString', 'Binary' => 'Binary'
      }.freeze
      FLOW_TYPES = DATA_TYPES.merge('Void' => 'Nothing').freeze
      # The values of each System enumeration, as the Runtime's System primitives list them.
      SYSTEM_PRIMITIVES = SYSTEM.fetch('objects').flat_map { _1.fetch('primitives') }.freeze
      SYSTEM_ENUMERATIONS = SYSTEM_PRIMITIVES.each_with_object({}) do |entry, all|
        all[entry.fetch('datatype').fetch('dsl').delete_prefix('#')] = entry.fetch('enum') if entry.key?('enum')
      end.freeze
      SYSTEM_MEMBERS = { created_date: 'createdDate', changed_date: 'changedDate' }.freeze
      SYSTEM_ASSOCIATIONS = { owner: 'System.owner', changed_by: 'System.changedBy' }.freeze

      def initialize(project, language: 'en_US')
        @project = project
        @language = language
        @records = Registry.all(:record).values.uniq.to_h { [_1.mendix_name, _1] }
        @system = SYSTEM.fetch('objects').to_h { [_1.fetch('name'), _1] }
      end

      def objects
        @objects ||= (@system.keys + @records.keys).uniq.sort.map { object(_1) }
      end

      def object(name)
        { 'name' => name, 'module' => name.split('.', 2).first, 'persistable' => persistable?(name),
          'supers' => supers(name).sort, 'subs' => subs(name).sort, 'primitives' => primitives(name) }
      end

      def associations
        @associations ||= begin
          own = @records.values.flat_map { |record| record_associations(record) }
          (SYSTEM.fetch('associations') + own).sort_by { "#{_1.fetch('name')}/#{_1.fetch('parent')}" }
        end
      end

      def microflows
        @microflows ||= begin
          own = @project.modules.flat_map do |mod|
            mod.microflows.map { |flow| microflow("#{mod.name}.#{flow.name}", flow) }
          end
          (SYSTEM.fetch('microflows') + own).sort_by { _1.fetch('name') }
        end
      end

      # A value's caption in a language, falling back to the default language.
      def enum_caption(enumeration, meta_value, language)
        implementation = Registry.fetch(:enumeration, enumeration)
        return meta_value.fetch('caption') unless implementation

        captions = implementation.values.find { _1.fetch(:name) == meta_value.fetch('id') }.fetch(:captions)
        captions.fetch(language) { captions.fetch(@language, meta_value.fetch('caption')) }
      end

      private

      def persistable?(name)
        record = @records[name]
        record ? record.persistable != false : @system.fetch(name).fetch('persistable')
      end

      def parent(name)
        record = @records[name]
        return record.generalization&.fetch(:target) if record

        @system.fetch(name).fetch('supers').max_by { supers(_1).length }
      end

      def supers(name)
        chain = []
        current = parent(name)
        while current
          chain << current
          current = parent(current)
        end
        chain
      end

      def subs(name) = (@system.keys + @records.keys).uniq.select { supers(_1).include?(name) }

      # Inherited primitives come first, from the root down, then the entity's own.
      def primitives(name)
        return @system.fetch(name).fetch('primitives') unless @records.key?(name)

        inherited = parent(name) ? primitives(parent(name)) : []
        record = @records.fetch(name)
        own = Array(record.attributes).map { primitive(_1) }
        root = parent(name).nil? ? system_member_primitives(record) : []
        inherited + own + root
      end

      def primitive(declaration)
        type = PRIMITIVE_TYPES.fetch(declaration.fetch(:type).to_sym)
        entry = { 'name' => declaration.fetch(:mendix_name), 'type' => type, 'length' => length(declaration, type),
                  'virtual' => false }
        return entry.merge('datatype' => data_type(DATA_TYPES.fetch(type))) unless type == 'Enum'

        enumeration = declaration.fetch(:enumeration).to_s
        entry.merge('datatype' => enumeration_type(enumeration), 'enum' => enum_values(enumeration))
      end

      def length(declaration, type)
        return 8 if type == 'Decimal'
        return 200 unless type == 'String'

        declaration[:length].nil? ? 200 : declaration[:length].to_i
      end

      def system_member_primitives(record)
        members = record.runtime_system_members
        SYSTEM_MEMBERS.filter_map do |key, name|
          next unless members[key]

          { 'name' => name, 'type' => 'DateTime', 'length' => 0, 'virtual' => false,
            'datatype' => data_type('Datetime') }
        end
      end

      def enum_values(enumeration)
        implementation = Registry.fetch(:enumeration, enumeration)
        unless implementation
          return SYSTEM_ENUMERATIONS.fetch(enumeration) do
            raise NativeRuntimeError, "unknown enumeration #{enumeration}"
          end
        end

        implementation.values.map do |value|
          { 'id' => value.fetch(:name), 'caption' => value.fetch(:captions)[@language] }
        end
      end

      def record_associations(record) # rubocop:disable Metrics/AbcSize
        own = Array(record.associations).map do |entry|
          name = entry.fetch(:name).to_s
          qualified = name.include?('.') ? name : "#{record.mendix_name.split('.', 2).first}.#{name}"
          association(qualified, record.mendix_name, entry.fetch(:target), entry.fetch(:type), entry.fetch(:owner))
        end
        members = parent(record.mendix_name).nil? ? record.runtime_system_members : {}
        system = SYSTEM_ASSOCIATIONS.filter_map do |key, name|
          association(name, record.mendix_name, 'System.User', :Reference, :Default) if members[key]
        end
        own + system
      end

      def association(name, parent, child, type, owner)
        { 'name' => name, 'parent' => parent, 'child' => child,
          'type' => type.to_s.casecmp?('ReferenceSet') ? 'REFERENCESET' : 'REFERENCE',
          'owner' => owner.to_s.casecmp?('Both') ? 'BOTH' : 'DEFAULT' }
      end

      def microflow(name, flow)
        parameters = Array(flow.parameters).map do |parameter|
          { 'name' => parameter.fetch('Name'), 'datatype' => flow_type(parameter['VariableType']) }
        end
        { 'name' => name, 'parameters' => parameters.sort_by { _1.fetch('name') },
          'return' => flow_type(flow.return_type_document) }
      end

      def flow_type(document)
        kind = document.to_h['$Type'].to_s.delete_prefix('DataTypes$').delete_suffix('Type')
        case kind
        when 'Object' then object_type(document.fetch('Entity'), list: false)
        when 'List' then object_type(document.fetch('Entity'), list: true)
        when 'Enumeration' then enumeration_type(document.fetch('Enumeration'))
        else data_type(FLOW_TYPES.fetch(kind))
        end
      end

      def data_type(name)
        { 'type' => name, 'dsl' => name, 'object' => nil, 'list' => false, 'mendix_object' => false }
      end

      def enumeration_type(enumeration)
        { 'type' => 'Enumeration', 'dsl' => "##{enumeration}", 'object' => nil, 'list' => false,
          'mendix_object' => false }
      end

      def object_type(entity, list:)
        { 'type' => 'Object', 'dsl' => list ? "[#{entity}]" : entity, 'object' => entity, 'list' => list,
          'mendix_object' => true }
      end
    end
  end
end
