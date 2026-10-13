# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Page metadata remains ordinary Ruby while the browser receives its JSON
    # projection from the integrated backend.
    class Page
      extend PageDataSources

      # Builds the runtime-facing widget projection without making the page an
      # authoritative native document. This keeps exported pages lossless via
      # the MPR sidecar while presenting their structure as editable Ruby.
      class WidgetTree
        include Dsl::WidgetComposite
        include Dsl::WidgetEvents
        include NativeFragmentAccess
        include PageDataSources

        OPTION_UNSET = Object.new.freeze
        STRUCTURED_METHODS = %i[data_view layout_grid native_widget tab_control table].freeze
        WIDGET_METHODS = %i[
          button check_box container data_grid data_view date_picker drop_down gallery
          file_manager image_uploader image_viewer native_widget layout_grid menu_bar
          navigation_list navigation_tree number_input page_title
          pluggable_widget radio_button_group reference_selector reference_set_selector
          scroll_container sidebar_toggle snippet static_image tab_control table text text_area
          text_box layout placeholder
        ].freeze

        attr_reader :widgets

        def initialize(event_owner: false, property_owner: nil)
          @widgets = []
          @events = []
          @event_owner = event_owner
          @property_owner = property_owner
          initialize_widget_composite(
            key_transform: :to_s.to_proc,
            path_normalizer: method(:normalize),
            child_factory: -> { self.class.new }
          )
        end

        def widget(type, name = '', options: {}, events: OPTION_UNSET, caption: OPTION_UNSET, &block)
          options = normalize(options)
          value = { 'type' => type.to_s, 'name' => name.to_s }
          value['options'] = options unless options.empty?
          caption = options['caption'] if caption.equal?(OPTION_UNSET) && options.key?('caption')
          value['caption'] = caption unless caption.equal?(OPTION_UNSET) || caption.to_s.empty?
          explicit_events = !events.equal?(OPTION_UNSET)
          normalized_events = explicit_events ? normalize(events) : []
          value['events'] = normalized_events unless normalized_events.empty?

          if block
            property_owner = if type.to_s == 'pluggable_widget'
                               { name: name.to_s, widget_id: options['widget_id'], legacy: options.key?('properties') }
                             end
            content = self.class.new(event_owner: true, property_owner:)
            block.arity.zero? ? content.instance_eval(&block) : block.call(content)
            if explicit_events && content.send(:widget_event_collection).any?
              raise ArgumentError, 'widget accepts either events: or typed event declarations'
            end

            content.send(:append_to, value)
          end

          @widgets << value
          value
        end

        def properties(&block)
          raise ArgumentError, 'properties must belong to a pluggable widget' unless @property_owner
          raise ArgumentError, 'properties requires a block' unless block
          if @property_owner.fetch(:legacy)
            raise ArgumentError, 'widget accepts either properties: or a properties block'
          end

          raise ArgumentError, 'widget accepts only one properties block' if @pluggable_properties

          bridge = PluggableProperties.for_widget(
            @property_owner.fetch(:name), widget_id: @property_owner.fetch(:widget_id)
          )
          @pluggable_properties = bridge.evaluate(&block).to_projection
        end

        (WIDGET_METHODS - STRUCTURED_METHODS).each do |type|
          define_method(type) do |name = '', caption: OPTION_UNSET, events: OPTION_UNSET, **options, &block|
            options[:class] = options.delete(:class_name) if options.key?(:class_name)
            options[:caption] = caption unless caption.equal?(OPTION_UNSET)
            widget(type, name, options:, events:, &block)
          end
        end

        # A data grid declared with a block (header, typed columns and events) is
        # built as in pages; other declarations keep the generic widget form.
        def data_grid(name = '', events: OPTION_UNSET, caption: OPTION_UNSET, **options, &block)
          options[:class] = options.delete(:class_name) if options.key?(:class_name)
          return widget(:data_grid, name, options:, events:, caption:, &block) unless
            block && events.equal?(OPTION_UNSET) && caption.equal?(OPTION_UNSET)

          builder = Dsl::WidgetBuilder.new(:data_grid, name, **options)
          builder.instance_eval(&block)
          append_structured(builder, declared_fields: false)
        end

        def table(name = '', width_unit: :weight, tab_index: 0, class_name: nil, style: nil,
                  dynamic_class: nil, visible: nil, &block)
          builder = Dsl::TableBuilder.new(
            name, width_unit:, tab_index:, class_name:, style:, dynamic_class:, visible:
          )
          builder.instance_eval(&block) if block
          append_structured(builder)
        end

        def layout_grid(name = '', width: :full, tab_index: 0, class_name: nil, style: nil,
                        dynamic_class: nil, visible: nil, &block)
          builder = Dsl::LayoutGridBuilder.new(
            name, width:, tab_index:, class_name:, style:, dynamic_class:, visible:
          )
          builder.instance_eval(&block) if block
          append_structured(builder)
        end

        def data_view(name = '', from:, editable: Dsl::UNSET, read_only_style: Dsl::UNSET,
                      label_width: Dsl::UNSET, show_footer: Dsl::UNSET,
                      no_entity_message: Dsl::UNSET, tab_index: Dsl::UNSET,
                      class_name: Dsl::UNSET, style: Dsl::UNSET,
                      dynamic_class: Dsl::UNSET, &block)
          builder = Dsl::DataViewBuilder.new(
            name, from:, editable:, read_only_style:, label_width:, show_footer:,
                  no_entity_message:, tab_index:, class_name:, style:, dynamic_class:
          )
          builder.instance_eval(&block) if block
          append_structured(builder, declared_fields: false)
        end

        def tab_control(name = '', **options, &block)
          builder = Dsl::WidgetBuilder.new(:tab_control, name, **options)
          builder.instance_eval(&block) if block
          append_structured(builder, declared_fields: false)
        end

        def native_widget(name = '', type:, deep_structure:)
          raise ArgumentError, 'deep_structure requires a Hash' unless deep_structure.is_a?(Hash)

          value = {
            type: :native_widget, name: name.to_s,
            options: { native_type: type.to_s, deep_structure: }, events: []
          }
          append_structured(value, declared_fields: false)
        end

        def form_widget(node)
          document = Forms::MprCodec.new.encode(node)
          page = Model::Page.allocate
          page.decode('Widgets' => [2, document])
          page.widgets.each { append_structured(_1, declared_fields: false) }
        end

        def grid_column(name, attribute: nil, caption: nil, filter: nil, sortable: nil)
          builder = Dsl::WidgetBuilder.new(:data_grid, '')
          normalize(builder.column(name, attribute:, caption:, filter:, sortable:).last)
        end

        def sort_by(attribute, direction: 'Ascending')
          { 'attribute' => attribute.to_s, 'direction' => direction.to_s }
        end

        private

        def append_to(value)
          (value['options'] ||= {})['properties'] = @pluggable_properties if @pluggable_properties
          value['events'] = normalize(@events) unless @events.empty?
          append_widget_composite(value, children: @widgets)
        end

        def widget_event_collection
          raise ArgumentError, 'event declarations must belong to a widget' unless @event_owner

          @events
        end

        def append_structured(builder, declared_fields: true)
          value = normalize(builder.to_h)
          value.delete('events') if Array(value['events']).empty?
          value.delete('declared_fields') unless declared_fields
          @widgets << value
          value
        end

        def normalize(value)
          case value
          when Hash then value.to_h { |key, child| [key.to_s, normalize(child)] }
          when Array then value.map { normalize(_1) }
          when Symbol then value.to_s
          else value
          end
        end
      end

      class << self
        attr_reader :mendix_id, :title, :widgets, :appearance_class,
                    :appearance_style, :data_source, :native_definition,
                    :navigation_definition, :allowed_module_roles, :presentation_contract

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :page, @mendix_name, id:)
          Registry.register(:page, @mendix_name, self)
        end

        # An excluded page stays in the project but does not exist at runtime,
        # as Studio Pro excludes it from the app.
        def excluded = (@excluded = true)
        def excluded? = @excluded == true

        def configure(title:, widgets: nil, appearance_class: '', appearance_style: '', data_source: nil,
                      allowed_roles: nil, presentation: {},
                      &block)
          raise ArgumentError, 'configure accepts either widgets: or a widget block, not both' \
            if widgets && block

          title = title.to_s
          appearance_class = appearance_class.to_s
          appearance_style = appearance_style.to_s
          widgets = if block
                      tree = WidgetTree.new
                      PluggableProperties.with_page(mendix_id) do
                        block.arity.zero? ? tree.instance_eval(&block) : block.call(tree)
                      end
                      tree.widgets.freeze
                    else
                      Array(widgets).freeze
                    end
          widgets = PageDesignIdentity.configure(self, widgets).freeze
          @title = title
          @widgets = widgets
          @appearance_class = appearance_class
          @appearance_style = appearance_style
          @data_source = data_source
          @allowed_module_roles = allowed_roles&.map(&:to_s)
          @presentation_contract = presentation
        end

        # Declares an editable native Mendix page with the typed page/widget
        # DSL. Existing exported pages may keep using #configure and remain
        # untouched; only pages with #native are synchronized back to the MPR.
        def native(&block)
          qualified = require_qualified_mendix_name!
          builder = Dsl::PageBuilder.new(qualified.split('.', 2).last)
          builder.instance_eval(&block) if block
          definition = builder.to_h.merge(unit_id: native_unit_id)
          @native_definition = definition
          @presentation_contract = PresentationContracts.declared(definition)
          @title = definition.fetch(:title).to_s
          @widgets = definition.fetch(:widgets).freeze
          @data_source = definition[:data_source]
          @appearance_class ||= ''
          @appearance_style ||= ''
          definition
        end

        # Adds or updates one navigation item without replacing unrelated
        # native menu entries. Set home: true only when this page must become
        # the profile's home page.
        def navigation(caption:, profile: 'Responsive', icon: nil, home: false)
          qualified = require_qualified_mendix_name!
          @navigation_definition = {
            page: qualified, caption:, profile: profile.to_s, icon:, home: home == true
          }
        end

        private

        def require_qualified_mendix_name!
          value = @mendix_name.to_s
          return value if value.match?(/\A[A-Za-z_]\w*\.[A-Za-z_]\w*\z/)

          raise ArgumentError, 'call mendix_name with Module.Document before native'
        end

        def native_unit_id
          return @mendix_id unless @mendix_id.to_s.empty?

          hex = Digest::SHA1.hexdigest("mxrb:ruby:page:#{@mendix_name}")
          "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
        end
      end

      Dsl::WidgetDesign.wrap(Page::WidgetTree, Page::WidgetTree::WIDGET_METHODS + %i[widget], list: :widgets)
      Page::WidgetTree.include(Dsl::WidgetDesign::Helpers)
    end
    # rubocop:enable Metrics
  end
end
