# frozen_string_literal: true

module Mxrb
  module Modeler
    # Read-only, JSON-safe projection used by the React project modeler.
    # rubocop:disable Metrics
    class Catalog
      SETTINGS_PATTERN = /(?:Settings|Configuration)\$|(?:Settings|Configuration)\z/

      def initialize(path)
        @path = File.expand_path(path)
      end

      def to_h
        project = Model::Project.open(@path)
        documents = project_documents(project)
        modules = project.modules.map { module_payload(_1) }
        {
          project: project_payload(project),
          summary: summary(modules),
          modules:,
          navigation: project.navigation.to_h,
          security: security_payload(documents),
          settings: settings_payload(documents)
        }
      ensure
        project&.close
      end

      private

      def project_payload(project)
        {
          name: project.name,
          mendix_version: project.mendix_version,
          format_version: project.format_version
        }
      end

      def summary(modules)
        keys = %i[entities pages microflows nanoflows integrations configurations]
        { modules: modules.size }.merge(
          keys.to_h { |key| [key, modules.sum { Array(_1[key]).size }] }
        )
      end

      def module_payload(mod)
        documents = catalog_documents(mod)
        integration_groups = %w[endpoints integrations mappings]
        {
          id: mod.id,
          name: mod.name,
          marketplace: mod.from_app_store == true,
          marketplace_guid: blank_to_nil(mod.app_store_guid),
          marketplace_version: blank_to_nil(mod.app_store_version),
          entities: mod.entities.map { entity_payload(_1, mod.name) },
          pages: mod.pages.map { page_payload(_1, mod.name) },
          microflows: mod.microflows.map { flow_payload(_1, mod.name, 'microflow') },
          nanoflows: mod.nanoflows.map { flow_payload(_1, mod.name, 'nanoflow') },
          module_roles: mod.module_roles,
          integrations: documents.select { integration_groups.include?(_1[:group]) },
          configurations: documents.reject { integration_groups.include?(_1[:group]) }
        }
      end

      def entity_payload(entity, module_name)
        {
          id: entity.id,
          name: entity.name,
          qualified_name: entity.qualified_name || "#{module_name}.#{entity.name}",
          persistent: entity.persistable == true,
          attributes: entity.attributes.map do |attribute|
            { name: attribute.name, type: attribute.type.to_s, required: attribute.required == true }
          end
        }
      end

      def page_payload(page, module_name)
        widgets = flatten_widgets(page.widgets)
        {
          id: page.id,
          name: page.name,
          qualified_name: "#{module_name}.#{page.name}",
          title: page.title,
          url: page.url,
          layout_id: page.layout_id,
          excluded: page.excluded == true,
          allowed_module_roles: page.allowed_module_roles.map(&:to_s),
          widget_count: widgets.size,
          widget_types: widgets.filter_map { _1[:type]&.to_s }.tally
        }
      end

      def flow_payload(flow, module_name, kind)
        {
          id: flow.id,
          name: flow.name,
          qualified_name: "#{module_name}.#{flow.name}",
          kind:,
          documentation: flow.documentation.to_s,
          allowed_module_roles: flow.allowed_module_roles.map(&:to_s),
          parameter_count: flow.parameters.size,
          object_count: flow.objects.size,
          flow_count: flow.flows.size
        }
      end

      def flatten_widgets(widgets)
        Array(widgets).flat_map do |widget|
          next [] unless widget.is_a?(Hash)

          [widget, *flatten_widgets(widget[:children] || widget['children'])]
        end
      end

      def catalog_documents(mod)
        documents = mod.infrastructure_documents + mod.application_documents + mod.domain_documents
        documents.map do |document|
          {
            id: document[:id],
            name: document[:name].to_s,
            type: document[:type],
            group: document[:route].to_s.split('/').first
          }
        end
      end

      def project_documents(project)
        project.all_units.filter_map do |unit|
          document = project.parse_bson(unit)
          type = document['$Type'].to_s
          next if type.empty?

          { id: unit['UnitID'], type:, document: }
        end
      end

      def security_payload(documents)
        source = documents.find { _1[:type] == 'Security$ProjectSecurity' }&.fetch(:document)
        return { configured: false, level: nil, user_roles: [] } unless source

        roles = array(source['UserRoles']).map do |role|
          {
            name: role['Name'].to_s,
            description: role['Description'].to_s,
            module_roles: array(role['ModuleRoles']).map(&:to_s)
          }
        end
        { configured: true, level: source['SecurityLevel'], user_roles: roles }
      end

      def settings_payload(documents)
        documents.filter { _1[:type].match?(SETTINGS_PATTERN) }.map do |entry|
          document = entry[:document]
          {
            id: entry[:id],
            type: entry[:type],
            name: document['Name'].to_s,
            values: scalar_values(document)
          }
        end
      end

      def scalar_values(document)
        document.each_with_object({}) do |(key, value), result|
          next if key.start_with?('$') || value.is_a?(Hash) || value.is_a?(Array)

          result[key] = value
        end
      end

      def array(value) = IO::BsonCodec.parse_array(value)[:items]

      def blank_to_nil(value) = value.to_s.empty? ? nil : value
    end
    # rubocop:enable Metrics
  end
end
