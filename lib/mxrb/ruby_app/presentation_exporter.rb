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
        @project.modules.each do |mod|
          declarations = menus(mod) + snippets(mod) + layouts(mod) + images(mod)
          next if declarations.empty?

          filename = @exporter.send(:underscore, mod.name)
          @exporter.send(:write, "app/presentation/#{filename}.rb",
                         "# frozen_string_literal: true\n\n#{declarations.join("\n\n")}\n")
        end
      end

      def project_widgets(document) = PresentationProjection.new(@exporter).call(document)

      private

      def layouts(mod)
        mod.presentation_documents.filter_map do |entry|
          next unless entry[:type] == 'Forms$Layout'

          name = "#{mod.name}.#{entry[:name]}"
          widgets = project_widgets(entry.fetch(:doc))
          "Mxrb::RubyApp::Presentation.layout #{name.inspect} do\n" \
            "#{widget_source(name, entry.fetch(:doc), widgets)}\nend"
        end
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
        parameters = array(document['Parameters']).map { _1.fetch('Name') }
        "Mxrb::RubyApp::Presentation.snippet #{name.inspect}, parameters: #{parameters.inspect} do\n" \
          "#{widget_source(name, document, widgets)}\nend"
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
        arguments = [item.fetch(:caption).inspect]
        arguments.concat(item.slice(:page, :microflow, :icon).map { |key, value| "#{key}: #{value.inspect}" })
        translations = item.fetch(:caption_translations, {}).to_a
        arguments << "translations: #{translations.inspect}" unless translations.empty?
        "#{' ' * indent}item #{arguments.join(', ')}"
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
