# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Runtime model assembled from the application's loaded Ruby definitions.
    # No MPR is opened or generated. Writer is used only as an in-memory flow
    # graph builder, keeping the existing pure-Ruby interpreter's semantics.
    class RuntimeProject
      Attribute = Data.define(:name, :type, :default_value)
      Association = Data.define(:name, :association_type, :from_entity_id, :to_entity_id)
      Document = Data.define(:name, :allowed_module_roles)
      ModuleView = Data.define(:name, :entities, :associations, :microflows, :nanoflows, :pages, :scheduled_events)

      # Interpreter-facing view of an editable Ruby record.
      class Entity
        attr_reader :implementation

        def initialize(implementation) = (@implementation = implementation)
        def name = implementation.mendix_name.split('.').last
        def id = implementation.mendix_id
        def qualified_name = implementation.mendix_name
        def persistable = implementation.persistable
        def access_rules = Array(implementation.access_rules)
        def lifecycle = Array(implementation.native_lifecycle_definitions)
        def oql_view? = !implementation.oql_view_definition.nil?
        def oql_query = implementation.oql_view_definition&.fetch(:query, nil)

        def attributes
          implementation.runtime_attributes.map do |entry|
            Attribute.new(entry.fetch(:mendix_name), entry.fetch(:type), entry[:default])
          end
        end
      end

      attr_reader :modules, :name, :mendix_version

      def initialize(manifest)
        @manifest = manifest
        @name = manifest.data.fetch('project').fetch('name')
        @mendix_version = manifest.data.fetch('project').fetch('mendix_version')
        @writer = Writer.new(File.join(manifest.root, 'runtime-model'), version: mendix_version, modules: [])
        @modules = module_names.map { build_module(_1) }
        @security = build_security
      end

      def decimal_settings = @manifest.data.fetch('decimal', {})
      def oql_datasets = Registry.all(:dataset).values.map(&:definition)

      def close; end
      def all_units = @security ? [@security] : []
      def parse_bson(value) = value
      def java_action_parameter_names(name) = @manifest.data.fetch('java_action_parameters', {}).fetch(name, {})

      private

      def build_security
        security = Registry.all(:project_security).values.first
        return unless security

        # This model supplies authorization metadata. Runtime login credentials
        # belong to SessionManager; redacted MPR demo passwords are not needed.
        definition = security.native_definition.merge(demo_users: [])
        @writer.send(:ruby_project_security_doc, definition, {})
      end

      def module_names
        declared = %i[record service page].flat_map do |kind|
          Registry.all(kind).values.map { _1.mendix_name.split('.').first }
        end
        @manifest.modules.map { _1.fetch('name') } | declared
      end

      def registered(kind, module_name)
        Registry.all(kind).values.select { _1.mendix_name.start_with?("#{module_name}.") }
      end

      def build_module(module_name)
        records = registered(:record, module_name)
        ModuleView.new(module_name, records.map { Entity.new(_1) }, associations(records),
                       flows(module_name, nanoflow: false), flows(module_name, nanoflow: true),
                       pages(module_name), registered(:scheduled_event, module_name).map(&:native_definition))
      end

      def flows(module_name, nanoflow:)
        registered(:service, module_name).filter_map do |service|
          build_flow(service, module_name) if (service.native_kind == :nanoflow) == nanoflow
        end
      end

      def pages(module_name)
        registered(:page, module_name).map do |page|
          Document.new(page.mendix_name.split('.').last, page_roles(page, module_name))
        end
      end

      def page_roles(page, module_name)
        roles = page.native_definition&.fetch(:allowed_roles, nil) || page.allowed_module_roles
        return roles if roles

        prior = @manifest.modules.find { _1.fetch('name') == module_name }.to_h
        Array(prior['pages']).find { _1['name'] == page.mendix_name }.to_h.fetch('allowed_module_roles', [])
      end

      def associations(records)
        records.flat_map do |record|
          record.associations.map do |entry|
            Association.new(entry.fetch(:name).split('.').last, entry.fetch(:type),
                            record.mendix_id, entry.fetch(:target))
          end
        end
      end

      def build_flow(service, module_name)
        definition = service.native_definition
        return unless definition

        kind = { nanoflow: :nanoflow_doc, rule: :rule_doc }.fetch(service.native_kind, :microflow_doc)
        document = @writer.send(kind, definition, module_name)
        model = Model::Microflow.allocate
        model.decode(document)
        model
      end
    end
  end
end
