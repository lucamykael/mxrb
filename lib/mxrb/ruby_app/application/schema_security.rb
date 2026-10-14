# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Application
      # rubocop:disable Metrics
      # Builds the client schema, pages and design data a user is allowed to see.
      module SchemaSecurity
        def schema(context: nil)
          result = {
            mode: 'ruby', environment: environment.name, project: manifest.data.fetch('project'),
            languages: manifest.data.fetch('languages', {}),
            navigation: manifest.data.fetch('navigation', {}),
            presentation: design_classed_presentation,
            modules: runtime_schema_modules, coverage: manifest.coverage,
            constants: Registry.all(:constant).values.select { _1.exposed_to_client && !_1.excluded }
                               .to_h { [_1.mendix_name, _1.client_value] },
            module_roles: context&.module_roles || []
          }
          context ? secure_schema(result, context) : result
        end

        def page(name, context: nil)
          implementation = Registry.fetch(:page, name.to_s)
          return if implementation.nil? || implementation.excluded?

          authorize_document!(:page, name, :read, context)

          {
            name: implementation.mendix_name, id: implementation.mendix_id,
            title: implementation.title,
            appearance_class: implementation.appearance_class,
            appearance_style: implementation.appearance_style,
            data_source: implementation.data_source
          }.merge(Presentation.page(implementation, classes: design_classes.method(:[]),
                                                    definitions: design_definitions))
            .merge(implementation.presentation_contract || {})
        end

        # Theme design property classes per document, recorded by the export.
        def design_classes
          @design_classes ||= begin
            path = root && File.join(root, DesignClasses::PATH)
            path && File.file?(path) ? JSON.parse(File.read(path)) : {}
          end
        end

        # The theme design properties that declared widget designs resolve to.
        def design_definitions
          @design_definitions ||= root ? DesignClasses.definitions(File.join(root, *THEME_PLATFORM)) : {}
        end

        def design_classed_presentation
          Registry.all(:presentation).to_h do |name, resource|
            widgets = design_classes[name.to_s]
            resource = DesignClasses.apply(JSON.parse(JSON.generate(resource)), widgets) if widgets
            [name, DesignDeclarations.resolve(resource, design_definitions)]
          end
        end

        private

        def runtime_schema_modules
          modules = RuntimeCatalog.new(manifest.modules,
                                       authoritative: manifest.data['runtime_model'] == 'ruby').modules.map do |mod|
            enumerations = mod.fetch('enumerations', []).map do |definition|
              implementation = Registry.fetch(:enumeration, definition.fetch('name'))
              next definition unless implementation

              values = implementation.values.map do |value|
                captions = value.fetch(:captions)
                {
                  'name' => value.fetch(:name), 'id' => value.fetch(:id), 'captions' => captions,
                  'caption' => captions['en_US'] || captions.values.first || value.fetch(:name)
                }
              end
              definition.merge('values' => values)
            end
            models = mod.fetch('models', []).map { runtime_model_definition(_1) }
            dtos = mod.fetch('dtos', []).map { runtime_model_definition(_1) }
            mod.except('constants').merge('enumerations' => enumerations, 'models' => models, 'dtos' => dtos)
          end
          return modules if modules.any? { _1['name'] == 'System' }

          modules + [system_schema_module]
        end

        # The Runtime-owned System entities and associations, without the hashed password.
        def system_schema_module
          models = Runtime::SystemDomain::ATTRIBUTES.map do |entity, attributes|
            members = attributes.reject { _2 == :hashstring }.map do |name, type, default, unique|
              { 'name' => name, 'mendix_name' => name, 'type' => type.to_s, 'default' => default, 'unique' => unique }
            end
            { 'name' => entity, 'persistable' => true, 'attributes' => members }
          end
          associations = Runtime::SystemDomain::ASSOCIATIONS.map do |qualified, from, to, type|
            { 'name' => qualified.split('.').last, 'type' => type.to_s, 'from_entity' => from, 'to_entity' => to }
          end
          { 'name' => 'System', 'models' => models, 'dtos' => [], 'associations' => associations,
            'enumerations' => [], 'pages' => [], 'services' => [] }
        end

        def runtime_model_definition(definition)
          implementation = Registry.fetch(:record, definition.fetch('name'))
          return definition unless implementation

          attributes = implementation.runtime_attributes.map do |attribute|
            attribute.transform_keys(&:to_s).merge(
              'name' => attribute.fetch(:mendix_name), 'ruby_name' => attribute.fetch(:name).to_s,
              'type' => attribute.fetch(:type).to_s
            )
          end
          definition.merge('attributes' => attributes)
        end

        def authorize_document!(kind, name, action, context)
          return unless context

          access_control.authorize!(name.to_s, kind:, action:, context:)
        end

        def authorize_entity!(name, action, context, member: nil, record: nil)
          return unless context

          access_control.authorize!(name.to_s, kind: :entity, action:, context:, member:, record:)
        end

        def secure_schema(schema, context)
          secured = Marshal.load(Marshal.dump(schema))
          allowed_pages = []
          allowed_services = []
          secured[:modules].each do |mod|
            mod['services'] = mod.fetch('services', []).select do |service|
              access_control.microflow_allowed?(service.fetch('name'), context:)
            end
            allowed_services.concat(mod['services'].flat_map { [_1['name'], _1['id']] }.compact)
            mod['pages'] = mod.fetch('pages', []).select do |page|
              access_control.page_allowed?(page.fetch('name'), context:)
            end
            allowed_pages.concat(mod['pages'].flat_map { [_1['name'], _1['id']] }.compact)
            %w[models dtos].each do |key|
              mod[key] = mod.fetch(key, []).select do |entity|
                access_control.entity_allowed?(entity.fetch('name'), action: :read, context:)
              end
            end
          end
          secured[:navigation] = secure_navigation(secured[:navigation], allowed_pages, allowed_services)
          secured.fetch(:presentation, {}).each_value do |resource|
            next unless resource[:kind] == 'menu'

            resource[:items] = secure_navigation_items(resource[:items], allowed_pages, allowed_services)
          end
          secured
        end

        def secure_navigation(navigation, pages, services)
          result = navigation.to_h.transform_keys(&:to_sym)
          result[:profiles] = Array(result[:profiles]).map do |profile|
            profile = profile.to_h.transform_keys(&:to_sym)
            profile[:home_page] = nil unless pages.include?(profile[:home_page])
            profile[:sign_in_page] = nil unless pages.include?(profile[:sign_in_page])
            profile[:home_microflow] = nil unless services.include?(profile[:home_microflow])
            profile[:role_homes] = Array(profile[:role_homes]).select do |home|
              page = home[:page] || home['page']
              flow = home[:microflow] || home['microflow']
              (!page || pages.include?(page)) && (!flow || services.include?(flow))
            end
            profile[:items] = secure_navigation_items(profile[:items], pages, services)
            profile
          end
          result
        end

        def secure_navigation_items(items, pages, services)
          Array(items).filter_map do |item|
            item = item.to_h.transform_keys(&:to_sym)
            children = secure_navigation_items(item[:items], pages, services)
            allowed = (!item[:page] || pages.include?(item[:page])) &&
                      (!item[:microflow] || services.include?(item[:microflow]))
            action = item[:action].to_h.transform_keys(&:to_sym)
            allowed &&= pages.include?(action[:handler]) if action[:kind].to_s == 'page'
            allowed &&= services.include?(action[:handler]) if %w[microflow nanoflow].include?(action[:kind].to_s)
            next unless allowed || children.any?

            item = item.reject { %i[page microflow action].include?(_1) } unless allowed
            item.merge(items: children)
          end
        end
      end
      # rubocop:enable Metrics
    end
  end
end
