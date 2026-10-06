# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Editable presentation resources shared by pages. These declarations are
    # evaluated with the rest of app/, not retrieved from the original model.
    module Presentation
      # Recursive menu actions written with ordinary Ruby blocks.
      class Menu
        include Dsl::WidgetEvents
        include PageDataSources
        attr_reader :items, :events

        def initialize
          @items = []
          @events = []
        end

        def collection_icon(name) = { collection: name.to_s }

        def item(caption, page: nil, microflow: nil, icon: nil, translations: [], &block)
          children = self.class.new
          children.instance_eval(&block) if block
          item = { caption: caption.to_s, page:, microflow:, icon:, items: children.items }.compact
          item[:caption_translations] = translations.to_h unless translations.empty?
          item[:action] = children.events.first unless children.events.empty?
          @items << item
        end
      end

      def self.menu(name, &block)
        menu = Menu.new
        menu.instance_eval(&block) if block
        Registry.register(:presentation, name.to_s, { kind: 'menu', items: menu.items })
      end

      def self.snippet(name, parameters: [], variables: [], &block)
        tree = Page::WidgetTree.new
        PluggableProperties.with_page(name) { tree.instance_eval(&block) } if block
        resource = { kind: 'snippet', widgets: tree.widgets }
        resource[:parameters] = parameters unless parameters.empty?
        resource[:variables] = variables unless variables.empty?
        Registry.register(:presentation, name.to_s, resource)
      end

      def self.image(name, path:)
        unless path.to_s.match?(%r{\A/assets/[A-Za-z0-9_./-]+\z}) && !path.split('/').include?('..')
          raise ArgumentError, 'presentation images must use a local /assets/ path'
        end

        Registry.register(:presentation, name.to_s, { kind: 'image', path: })
      end

      def self.icon(name, path:, character:)
        unless path.to_s.match?(%r{\A/assets/fonts/(?:[a-f0-9]{64}|[A-Za-z_]\w*\.[A-Za-z_]\w*)\.woff\z}) &&
               character.is_a?(Integer) && character.between?(0, 0x10ffff)
          raise ArgumentError, 'presentation icons require a local font and Unicode character'
        end

        Registry.register(:presentation, name.to_s, { kind: 'icon', path:, character: })
      end

      def self.layout(name, &block)
        tree = Page::WidgetTree.new
        PluggableProperties.with_page(name) { tree.instance_eval(&block) } if block
        Registry.register(:presentation, name.to_s, { kind: 'layout', widgets: tree.widgets })
      end

      # Native Ruby pages bind their content to the same Main layout slot as
      # the MPR writer. Exported pages already contain explicit layout calls.
      def self.page(implementation)
        widgets = Array(implementation.widgets)
        name = implementation.native_definition&.dig(:layout)
        if name && Registry.fetch(:presentation, name)&.fetch(:kind) == 'layout'
          widgets = [{ 'type' => 'layout', 'options' => { 'layout' => name },
                       'regions' => { 'Main' => widgets } }]
        else
          name = widgets.find { _1['type'] == 'layout' }&.dig('options', 'layout')
        end
        { layout: name, widgets: compose(widgets) }
      end

      # Resolve reusable layout slots at request time so edits to shared Ruby
      # resources affect every page, including after a restart without an MPR.
      def self.compose(value, slots: {}, stack: [])
        case value
        when Array then compose_array(value, slots, stack)
        when Hash then compose_node(value, slots, stack)
        else value
        end
      end

      def self.compose_array(value, slots, stack)
        value.flat_map do |child|
          result = compose(child, slots:, stack:)
          expansion = child.is_a?(Hash) && %w[layout placeholder].include?((child['type'] || child[:type]).to_s)
          expansion ? result : [result]
        end
      end

      def self.compose_node(value, slots, stack)
        node = value.transform_keys(&:to_s)
        case node['type'].to_s
        when 'layout' then compose_layout(node, slots, stack)
        when 'placeholder'
          name = node.fetch('options', {}).transform_keys(&:to_s).fetch('parameter', node['name']).to_s.split('.').last
          slots.fetch(name, [])
        else value.transform_values { compose(_1, slots:, stack:) }
        end
      end

      def self.compose_layout(node, slots, stack)
        name = node.fetch('options').transform_keys(&:to_s).fetch('layout')
        raise ArgumentError, "recursive layout #{name}" if stack.include?(name) || stack.length >= 32

        layout = Registry.fetch(:presentation, name)
        raise ArgumentError, "missing layout #{name}" unless layout && layout[:kind] == 'layout'

        arguments = compose(node.fetch('regions', {}), slots:, stack:)
        compose(layout.fetch(:widgets), slots: arguments, stack: [*stack, name])
      end

      private_class_method :compose_array, :compose_node, :compose_layout
    end
  end
end
