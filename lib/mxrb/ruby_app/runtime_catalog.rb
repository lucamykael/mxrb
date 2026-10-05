# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Joins source declarations with legacy metadata without mutating the export manifest.
    class RuntimeCatalog
      COLLECTIONS = { page: 'pages', enumeration: 'enumerations' }.freeze

      def initialize(modules)
        @modules = Marshal.load(Marshal.dump(modules))
      end

      def modules
        %i[record page service enumeration].each do |kind|
          Registry.all(kind).each_value { add(kind, _1) }
        end
        @modules
      end

      private

      def add(kind, implementation)
        mod = module_for(implementation.mendix_name.split('.').first)
        entries = (mod[collection(kind, implementation)] ||= [])
        index = entries.index { same_document?(_1, implementation) }
        definition = (index ? entries.fetch(index) : {}).merge(identity(implementation))
        definition.merge!(details(kind, implementation, mod))
        index ? entries[index] = definition : entries << definition
      end

      def identity(implementation)
        { 'name' => implementation.mendix_name, 'id' => implementation.mendix_id }
      end

      def module_for(name)
        existing = @modules.find { _1['name'] == name }
        return existing if existing

        { 'name' => name }.tap { @modules << _1 }
      end

      def same_document?(entry, implementation)
        entry['name'] == implementation.mendix_name &&
          (entry['id'].nil? || entry['id'] == implementation.mendix_id)
      end

      def collection(kind, implementation)
        return implementation.persistable ? 'models' : 'dtos' if kind == :record
        return implementation.native_kind == :nanoflow ? 'nanoflows' : 'services' if kind == :service

        COLLECTIONS.fetch(kind)
      end

      def details(kind, implementation, mod)
        case kind
        when :record then record_details(implementation, mod)
        when :page
          { 'title' => implementation.title, 'widgets' => implementation.widgets,
            'allowed_module_roles' => implementation.allowed_module_roles }
        when :service then { 'kind' => implementation.native_kind.to_s }
        else {}
        end
      end

      def record_details(record, mod)
        associations = record.associations.map { association_details(record.mendix_name, _1) }
        mod['associations'] = Array(mod['associations']).reject do |entry|
          entry['from_entity'] == record.mendix_name
        end + associations
        { 'persistable' => record.persistable, 'dto' => !record.persistable, 'associations' => associations }
      end

      def association_details(name, association)
        association.transform_keys(&:to_s).merge(
          'type' => association.fetch(:type).to_s,
          'from_entity' => name, 'to_entity' => association.fetch(:target)
        )
      end
    end
  end
end
