# frozen_string_literal: true

module Mxrb
  module Dsl
    # Builds sub-widgets inside a data_grid column sub-items or inside a container.
    class WidgetBuilder
      include WidgetDsl
      include WidgetEvents

      def initialize(type, name, **options)
        @type        = type
        @name        = name.to_s
        @options     = options
        @events      = []
        @columns     = []
        @tabs        = []
        @search_bar  = nil
        @toolbar     = nil
        @children    = []
        @filters     = []
        initialize_widget_composite(
          key_transform: :to_sym.to_proc, path_normalizer: ->(path) { path },
          child_factory: -> { WidgetSlotBuilder.new }
        )
      end

      # A data grid column. Data grid 2 columns may show the attribute over an
      # association path, a dynamic text or the widgets of the block, per row.
      def column(name, attribute: nil, caption: nil, association_path: nil, dynamic_text: nil,
                 parameters: nil, filter: nil, sortable: nil, hidable: nil, width: nil, size: nil,
                 alignment: nil, &block)
        column = {
          name: name.to_s, attribute: attribute&.to_s, caption:,
          association_path: association_path && data_grid_association_path(association_path),
          dynamic_text:, parameters:, filter:, sortable:, hidable:, width: width&.to_s, size:,
          alignment: alignment&.to_s
        }.compact
        column[:content] = widget_composite_content(&block) if block
        @columns << column
      end

      # Widgets shown above a Data grid 2 (its filtersPlaceholder).
      def header(&block)
        @header = widget_composite_content(&block)
      end

      def filter(widget) = @filters << widget

      def tab_page(name, caption: nil, &block)
        tab = TabPageBuilder.new(name, caption: caption)
        tab.instance_eval(&block) if block
        @tabs << tab.to_h
      end

      def search_bar(&block)
        sb = SearchBarBuilder.new
        sb.instance_eval(&block) if block
        @search_bar = sb.to_h
      end

      def toolbar(&block)
        tb = ToolbarBuilder.new
        tb.instance_eval(&block) if block
        @toolbar = tb.to_h
      end

      def to_h
        options = @options.dup
        options[:columns]    = @columns    unless @columns.empty?
        options[:tabs]       = @tabs       unless @tabs.empty?
        options[:search_bar] = @search_bar if @search_bar
        options[:toolbar]    = @toolbar    if @toolbar
        options[:filters]    = @filters    unless @filters.empty?
        value = { type: @type, name: @name, options: options, events: @events }
        value[:header] = @header if @header
        append_widget_composite(value, children: @children)
      end

      private

      def data_grid_association_path(steps)
        Array(steps).map do |step|
          next { association: step.fetch(0).to_s, entity: step.fetch(1).to_s } if step.is_a?(Array)

          step.to_h.transform_keys(&:to_sym).transform_values(&:to_s)
        end
      end

      def _widget_list = @children
    end

    # Composite shared by native and runtime page trees. Includers supply the
    # child builder and key/path normalization while this module owns the
    # region and slot lifecycle.
    module WidgetComposite
      def body(&block) = set_widget_region(:body, &block)
      def footer(&block) = set_widget_region(:footer, &block)
      def region(name, &block) = set_widget_region(name, &block)

      def slot(path:, role: UNSET, &block)
        append_widget_slot(path:, role:, &block)
      end

      private

      def initialize_widget_composite(key_transform:, path_normalizer:, child_factory:)
        @widget_composite_key_transform = key_transform
        @widget_composite_path_normalizer = path_normalizer
        @widget_composite_child_factory = child_factory
        @widget_regions = {}
        @widget_slots = []
      end

      def set_widget_region(name, &block)
        key = widget_composite_key(name)
        raise ArgumentError, "duplicate widget region #{name}" if @widget_regions.key?(key)

        @widget_regions[key] = widget_composite_content(&block)
      end

      def append_widget_slot(path:, role: UNSET, &block)
        value = {
          widget_composite_key(:path) => @widget_composite_path_normalizer.call(Array(path)),
          widget_composite_key(:widgets) => widget_composite_content(&block)
        }
        value[widget_composite_key(:role)] = role&.to_s unless role.equal?(UNSET)
        @widget_slots << value
      end

      def append_widget_composite(value, children:)
        value[widget_composite_key(:children)] = children unless children.empty?
        %i[body footer].each do |name|
          key = widget_composite_key(name)
          value[key] = @widget_regions.fetch(key) if @widget_regions.key?(key)
        end
        reserved = %i[body footer].map { widget_composite_key(_1) }
        regions = @widget_regions.reject { |name, _widgets| reserved.include?(name) }
        value[widget_composite_key(:regions)] = regions unless regions.empty?
        value[widget_composite_key(:slots)] = @widget_slots unless @widget_slots.empty?
        value
      end

      def widget_composite_content(&block)
        builder = @widget_composite_child_factory.call
        builder.instance_eval(&block) if block
        builder.widgets
      end

      def widget_composite_key(name) = @widget_composite_key_transform.call(name)
    end

    class WidgetBuilder
      include WidgetComposite
    end

    class GenericWidgetBuilder
      include WidgetDsl
      include WidgetEvents
      include WidgetComposite

      def initialize(type, name, options:, events:)
        raise ArgumentError, 'generic widget options must be a Hash' unless options.is_a?(Hash)
        raise ArgumentError, 'generic widget events must be an Array' unless events.is_a?(Array)
        raise ArgumentError, 'generic widget events must contain only Hash values' unless
          events.all? { _1.is_a?(Hash) }

        @type = type.to_sym
        @name = name.to_s
        @options = options
        @events = events
        @children = []
        initialize_widget_composite(
          key_transform: :to_sym.to_proc,
          path_normalizer: ->(path) { path },
          child_factory: -> { WidgetSlotBuilder.new }
        )
      end

      def to_h
        value = { type: @type, name: @name, options: @options, events: @events }
        append_widget_composite(value, children: @children)
      end

      private

      def _widget_list = @children
    end

    class PluggableWidgetBuilder < GenericWidgetBuilder
      def initialize(name, options:, properties_declared: options.key?(:properties))
        super(:pluggable_widget, name, options:, events: [])
        @properties_declared = properties_declared
      end

      def properties(&block)
        raise ArgumentError, 'properties requires a block' unless block
        raise ArgumentError, 'widget accepts either properties: or a properties block' if @properties_declared
        raise ArgumentError, 'widget accepts only one properties block' if @properties_block

        bridge = RubyApp::PluggableProperties.for_widget(@name, widget_id: @options.fetch(:widget_id))
        projection = bridge.evaluate(&block).to_projection
        @options = @options.merge(properties: projection)
        @properties_block = true
      end

      def slot(name = nil, within: nil, item: nil, path: nil, role: UNSET, &block)
        resolved_path = pluggable_slot_path(name, within:, item:, path:)
        append_widget_slot(path: resolved_path, role:, &block)
      end

      private

      def pluggable_slot_path(name, within:, item:, path:)
        return Array(path) if path
        return [name] unless within

        raise ArgumentError, 'slot within: requires item:' if item.nil?

        [within, :objects, Integer(item), name]
      end
    end

    class WidgetSlotBuilder
      include WidgetDsl

      attr_reader :widgets

      def initialize = (@widgets = [])

      private

      def _widget_list = @widgets
    end

    class TabPageBuilder
      include WidgetDsl

      def initialize(name, caption: nil)
        @name = name.to_s
        @caption = caption || name.to_s
        @widgets = []
      end

      def to_h = { name: @name, caption: @caption, widgets: @widgets }

      private

      def _widget_list = @widgets
    end
  end
end
