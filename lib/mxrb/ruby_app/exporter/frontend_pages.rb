# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Exports pages and their typed TypeScript page definitions.
      module FrontendPages
        TYPESCRIPT_WIDGET_KEYS = %w[
          type name caption options events children body footer regions slots header
        ].freeze

        private

        def export_page(page, mod, namespace, root)
          class_name = ruby_constant(page.name, suffix: 'Page')
          relative = embedded_identity_path(:page, page.id) ||
                     File.join('app', 'pages', root, "#{underscore(page.name)}_page.rb")
          qualified = "#{mod.name}.#{page.name}"
          widgets = PresentationExporter.new(self, @project).project_widgets(page.raw_document, name: qualified)
          layouts = @project.modules.flat_map do |owner|
            owner.presentation_documents.map { ["#{owner.name}.#{_1[:name]}", _1[:doc]] }
          end.to_h
          contract = PresentationContracts.page(page.raw_document, layouts:)
          write(
            relative,
            page_source(namespace, class_name, qualified, page.id, page.title, widgets,
                        appearance_class: page.appearance_class,
                        appearance_style: page.appearance_style,
                        allowed_roles: page.allowed_module_roles,
                        data_source: page.data_source, presentation: contract,
                        excluded: page.raw_document['Excluded'] == true)
          )
          add_coverage(page.id, qualified, 'page', relative, 'native_projection_source_preserved')
          manifest = {
            'name' => qualified, 'id' => page.id, 'title' => page.title,
            'ruby_class' => embedded_identity_class(:page, page.id, "#{namespace}::#{class_name}"), 'path' => relative,
            'appearance_class' => page.appearance_class,
            'appearance_style' => page.appearance_style,
            'data_source' => page.data_source,
            'allowed_module_roles' => page.allowed_module_roles.map(&:to_s),
            'widgets' => widgets
          }.merge(contract.transform_keys(&:to_s))
          export_frontend_page(manifest, root, page.name)
          manifest
        end

        def export_frontend_page(manifest, root, page_name)
          relative = File.join(
            'frontend', 'src', 'generated', 'pages', root, "#{underscore(page_name)}.tsx"
          )
          component = "#{typescript_identifier(manifest.fetch('name'))}Page"
          definition = manifest.slice('name', 'title', 'appearance_class', 'appearance_style', 'widgets',
                                      'parameters', 'variables', 'popup', 'autofocus')
          declarations = []
          compiled_widgets = definition.fetch('widgets').each_with_index.map do |widget, index|
            frontend_widget_jsx(widget, [index], declarations, 6)
          end
          widget_tree = compiled_widgets.map(&:first).join("\n")
          definition_source = frontend_page_definition_source(definition, compiled_widgets.map(&:last))
          contracts = %w[WidgetDefinition ExtensionWidgetDefinition].select do |contract|
            declarations.any? { _1.end_with?(" satisfies #{contract};") }
          end
          write(relative, <<~TS)
            import type { #{(contracts + %w[PageComponentProps PageDefinition]).sort.join(', ')} } from '../../types';

            #{declarations.join("\n\n")}

            export const definition = #{definition_source} satisfies PageDefinition;

            export default function #{component}({ busy, Widget: PageWidget }: PageComponentProps) {
              return <main className="mxrb-page region-content mx-scrollcontainer-wrapper"
                aria-busy={busy} data-page={definition.name}>
            #{widget_tree}
              </main>;
            }
          TS
          @page_entries << {
            'name' => manifest.fetch('name'), 'path' => relative,
            'import_name' => component
          }
        end

        def typescript_widget_contract?(widget)
          return false unless widget.is_a?(Hash) && TYPESCRIPT_WIDGET_TYPES.include?(widget['type'])
          return false unless (widget.keys - TYPESCRIPT_WIDGET_KEYS).empty?
          return false unless (widget.fetch('options', {}).keys - TYPESCRIPT_WIDGET_OPTIONS.keys).empty?

          typescript_nested_widgets(widget).all? { typescript_widget_contract?(_1) }
        end

        def typescript_nested_widgets(widget)
          %w[children body footer header].flat_map { Array(widget[_1]) } +
            widget.fetch('regions', {}).values.flatten + Array(widget['slots']).flat_map { Array(_1['widgets']) } +
            Array(widget.dig('options', 'tabs')).flat_map { Array(_1['widgets']) }
        end

        def frontend_widget_jsx(widget, path, declarations, indent)
          identifier = "widget#{path.join('_')}"
          children = Array(widget['children'])
          compiled = widget.reject { |key, _value| key == 'children' }
          nested_widgets = children.each_with_index.map do |child, index|
            frontend_widget_jsx(child, path + [index], declarations, indent + 2)
          end
          source = JSON.pretty_generate(compiled)
          unless nested_widgets.empty?
            source = source.sub(/\n}\z/, ",\n  \"children\": [#{nested_widgets.map(&:last).join(', ')}]\n}")
          end
          contract = typescript_widget_contract?(widget) ? 'WidgetDefinition' : 'ExtensionWidgetDefinition'
          declarations << "const #{identifier} = #{source} satisfies #{contract};"
          padding = ' ' * indent
          return ["#{padding}<PageWidget widget={#{identifier}} index={#{path.last}} />", identifier] if children.empty?

          nested = nested_widgets.map(&:first).join("\n")
          jsx = <<~TS.chomp
            #{padding}<PageWidget widget={#{identifier}} index={#{path.last}}>
            #{nested}
            #{padding}</PageWidget>
          TS
          [jsx, identifier]
        end

        def frontend_page_definition_source(definition, widget_identifiers)
          source = JSON.pretty_generate(definition.reject { |key, _value| key == 'widgets' })
          source.sub(/\n}\z/, ",\n  \"widgets\": [#{widget_identifiers.join(', ')}]\n}")
        end

        def attribute_manifest(attribute)
          value = {
            'name' => attribute.name, 'ruby_name' => ruby_method_name(attribute.name),
            'type' => attribute.type.to_s, 'required' => attribute.required == true,
            'unique' => optional_attribute_value(attribute, :unique) == true,
            'default' => attribute.default_value,
            'documentation' => optional_attribute_value(attribute, :documentation).to_s,
            'length' => optional_attribute_value(attribute, :length),
            'id' => attribute.id
          }
          localize_date = optional_attribute_value(attribute, :localize_date)
          value['localize_date'] = localize_date unless localize_date.nil?
          enumeration = native_identifier(attribute.respond_to?(:enumeration) ? attribute.enumeration : nil)
          value['enumeration'] = enumeration unless enumeration.empty?
          value
        end

        def optional_attribute_value(attribute, name)
          attribute.public_send(name) if attribute.respond_to?(name)
        end
      end
      # rubocop:enable Metrics
    end
  end
end
