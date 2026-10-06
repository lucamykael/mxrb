# frozen_string_literal: true

require_relative 'presentation_projection'

module Mxrb
  module RubyApp
    # Materializes shared content as public Ruby declarations and image files.
    class PresentationExporter # rubocop:disable Metrics/ClassLength
      include Compiler::ModelValues

      def initialize(exporter, project)
        @exporter = exporter
        @project = project
      end

      def export!
        @exporter.send(:with_presentation_fragments) { export_modules }
      end

      def project_widgets(document) = PresentationProjection.new(@exporter).call(document)

      private

      def export_modules
        @project.modules.each do |mod|
          declarations = menus(mod) + snippets(mod) + layouts(mod) + images(mod) + icons(mod)
          next if declarations.empty?

          filename = @exporter.send(:underscore, mod.name)
          @exporter.send(:write, "app/presentation/#{filename}.rb",
                         "# frozen_string_literal: true\n\n#{declarations.join("\n\n")}\n")
        end
      end

      def layouts(mod)
        mod.presentation_documents.filter_map do |entry|
          next unless entry[:type] == 'Forms$Layout'

          name = "#{mod.name}.#{entry[:name]}"
          widgets = project_widgets(entry.fetch(:doc))
          widgets = layout_appearance(widgets, entry.fetch(:doc))
          "Mxrb::RubyApp::Presentation.layout #{name.inspect} do\n" \
            "#{widget_source(name, entry.fetch(:doc), widgets)}\nend"
        end
      end

      def layout_appearance(widgets, document)
        appearance = document.fetch('Appearance', {})
        options = { 'class' => appearance['Class'], 'style' => appearance['Style'] }
                  .reject { |_key, value| value.to_s.empty? }
        return widgets if options.empty?

        [{ 'type' => 'container', 'name' => 'LayoutAppearance', 'options' => options, 'children' => widgets }]
      end

      def menus(mod)
        mod.menus.map do |menu|
          items = menu_items(menu.items, array(menu.raw_document.dig('ItemCollection', 'Items')), mod.name)
          "Mxrb::RubyApp::Presentation.menu #{"#{mod.name}.#{menu.name}".inspect} do\n" \
            "#{menu_source(items, 2)}\nend"
        end
      end

      def menu_items(items, documents, module_name)
        items.zip(documents).map do |item, document|
          children = menu_items(item.fetch(:items, []), array(document && document['Items']), module_name)
          result = item.merge(items: children)
          action = menu_action(document && document['Action'], module_name)
          result[:action] = action if action
          result
        end
      end

      def menu_action(document, module_name)
        action = Model::Page.allocate.send(:parse_action, document)
        return unless action
        return action if action[:kind] == :action

        paths = [%w[MicroflowSettings Microflow], ['Microflow'], %w[NanoflowSettings Nanoflow], ['Nanoflow']]
        handler = paths.filter_map { document.dig(*_1) }.first || action[:handler]
        action.merge(handler: handler.include?('.') ? handler : "#{module_name}.#{handler}")
      end

      def snippets(mod)
        mod.presentation_documents.filter_map do |entry|
          next unless entry[:type] == 'Forms$Snippet'

          snippet_source("#{mod.name}.#{entry[:name]}", entry.fetch(:doc))
        end
      end

      def snippet_source(name, document)
        page = Model::Page.allocate
        page.decode(document)
        widgets = page.widgets.map { @exporter.send(:widget_manifest, _1) }
        parameters = PresentationContracts.parameters(document)
        variables = PresentationContracts.variables(document)
        parameter_source = PresentationContracts.source(parameters, kind: :parameter)
        variable_source = PresentationContracts.source(variables, kind: :variable)
        "Mxrb::RubyApp::Presentation.snippet #{name.inspect}, parameters: #{parameter_source}, " \
          "variables: #{variable_source} do\n#{widget_source(name, document, widgets)}\nend"
      end

      def widget_source(name, document, widgets)
        PluggableContext.current.with_document(name, document) do
          @exporter.send(:presentation_widget_source, widgets)
        end
      end

      def images(mod)
        mod.asset_documents.flat_map do |entry|
          next [] unless entry[:type] == 'Images$ImageCollection'

          array(entry.fetch(:doc)['Images']).map do |image|
            image_source("#{mod.name}.#{entry[:name]}.#{image.fetch('Name')}", image)
          end
        end
      end

      def icons(mod)
        mod.asset_documents.flat_map do |entry|
          next [] unless entry[:type] == 'CustomIcons$CustomIconCollection'

          document = entry.fetch(:doc)
          path = export_icon_font(document.fetch('FontData').data, "#{mod.name}.#{entry[:name]}")
          array(document['Icons']).map { icon_source("#{mod.name}.#{entry[:name]}", _1, path) }
        end
      end

      def icon_source(collection, icon, path)
        name = "#{collection}.#{icon.fetch('Name')}"
        "Mxrb::RubyApp::Presentation.icon #{name.inspect}, path: #{path.inspect}, " \
          "character: #{icon.fetch('CharacterCode').to_i}"
      end

      def export_icon_font(font, name)
        unless name.match?(/\A[A-Za-z_]\w*\.[A-Za-z_]\w*\z/)
          raise SerializationError, 'icon font requires a qualified collection name'
        end

        path = "/assets/fonts/#{name}.woff"
        @exporter.send(:write, "frontend/public#{path}", font)
        path
      end

      def image_source(name, image)
        extension = image_format(image)
        unless %w[png gif jpg jpeg bmp ico webp svg].include?(extension)
          raise SerializationError, "unsupported presentation image format #{extension.inspect}"
        end

        filename = "#{Digest::SHA256.hexdigest(name)[0, 24]}.#{extension}"
        path = "/assets/images/#{filename}"
        @exporter.send(:write, "frontend/public#{path}", image_bytes(image['Image']))
        "Mxrb::RubyApp::Presentation.image #{name.inspect}, path: #{path.inspect}"
      end

      def menu_source(items, indent)
        items.map do |item|
          line = menu_item_source(item, indent)
          body = menu_item_body(item, indent + 2)
          body.empty? ? line : "#{line} do\n#{body.join("\n")}\n#{' ' * indent}end"
        end.join("\n")
      end

      def menu_item_source(item, indent)
        "#{' ' * indent}item #{menu_item_arguments(item).join(', ')}"
      end

      def menu_item_arguments(item)
        arguments = [item.fetch(:caption).inspect]
        arguments.concat(item.slice(:page, :microflow).map { |key, value| "#{key}: #{value.inspect}" })
        arguments << "icon: #{menu_icon_source(item[:icon])}" if item[:icon]
        translations = item.fetch(:caption_translations, {}).to_a
        arguments << "translations: #{translations.inspect}" unless translations.empty?
        arguments
      end

      def menu_icon_source(icon)
        icon.is_a?(Hash) ? "collection_icon(#{icon.fetch(:collection).inspect})" : icon.inspect
      end

      def menu_item_body(item, indent)
        body = []
        if (action = item[:action])
          event = JSON.parse(JSON.generate(action.merge(event: :on_click)))
          body << @exporter.send(:runtime_widget_event_source, { 'events' => [event] }, indent)
        end
        children = item.fetch(:items, [])
        body << menu_source(children, indent) unless children.empty?
        body
      end
    end
  end
end
