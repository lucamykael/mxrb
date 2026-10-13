# frozen_string_literal: true

module Mxrb
  module Dsl
    module OverlayFields
      private

      def declared_fields(**values)
        values.filter_map { |field, value| field unless value.equal?(UNSET) }
      end

      def default_value(value, default) = value.equal?(UNSET) ? default : value
    end

    # Shared widget-building methods for PageBuilder and ContainerBuilder.
    # Includers must implement private `_widget_list` returning the target array.
    module WidgetDsl
      include NativeFragmentAccess

      def text_box(name, attribute: nil, caption: nil, class_name: nil, style: nil,
                   dynamic_class: nil, visible: nil, **input_options, &block)
        _add_widget(
          :text_box, name, attribute:, caption:, class: class_name, style:, dynamic_class:,
                           visible:, **Forms::InputPresentation.options(input_options), &block
        )
      end

      def number_input(name, attribute: nil, caption: nil, class_name: nil, style: nil,
                       dynamic_class: nil, visible: nil, **input_options, &block)
        _add_widget(
          :number_input, name,
          attribute:, caption:, class: class_name, style:, dynamic_class:, visible:,
          **Forms::InputPresentation.options(input_options), &block
        )
      end

      def text_area(name, attribute: nil, caption: nil, lines: 5, class_name: nil, style: nil,
                    dynamic_class: nil, visible: nil, **input_options, &block)
        _add_widget(
          :text_area, name, attribute:, caption:, lines:, class: class_name, style:,
                            dynamic_class:, visible:, **Forms::InputPresentation.options(input_options), &block
        )
      end

      def check_box(name, attribute: nil, caption: nil, class_name: nil, style: nil,
                    dynamic_class: nil, visible: nil, **input_options, &block)
        _add_widget(
          :check_box, name, attribute:, caption:, class: class_name, style:, dynamic_class:,
                            visible:, **Forms::InputPresentation.options(input_options), &block
        )
      end

      def date_picker(name, attribute: nil, caption: nil, class_name: nil, style: nil,
                      dynamic_class: nil, visible: nil, **input_options, &block)
        _add_widget(
          :date_picker, name, attribute:, caption:, class: class_name, style:, dynamic_class:,
                              visible:, **Forms::InputPresentation.options(input_options), &block
        )
      end

      def radio_button_group(name, attribute: nil, caption: nil, horizontal: false,
                             class_name: nil, style: nil, dynamic_class: nil, visible: nil, **input_options, &block)
        _add_widget(
          :radio_button_group, name, attribute:, caption:, horizontal: horizontal == true,
                                     class: class_name, style:, dynamic_class:, visible:,
                                     **Forms::InputPresentation.options(input_options), &block
        )
      end

      def reference_selector(name, attribute: nil, caption: nil, display_attribute: nil,
                             class_name: nil, style: nil, dynamic_class: nil, visible: nil, **input_options, &block)
        _add_widget(
          :reference_selector, name, attribute:, caption:, display_attribute:,
                                     class: class_name, style:, dynamic_class:, visible:,
                                     **Forms::InputPresentation.options(input_options), &block
        )
      end

      # visibility: shows the text for the values of an attribute, as input_condition.
      # render_mode: h1..h6 or paragraph renders the text as that element.
      def text(name, caption: nil, parameters: [], class_name: nil, style: nil,
               dynamic_class: nil, visible: nil, visibility: nil, render_mode: nil, &block)
        options = {
          caption: caption || name.to_s, parameters: Array(parameters).map(&:to_s),
          class: class_name, style:, dynamic_class:, visible:, visibility:, render_mode: render_mode&.to_s
        }.compact
        options.delete(:parameters) if options[:parameters].empty?
        _add_widget(:text, name, **options, &block)
      end

      def page_title(name, class_name: nil, style: nil, dynamic_class: nil, visible: nil, &block)
        _add_widget(
          :page_title, name, class: class_name, style:, dynamic_class:, visible:, &block
        )
      end

      def placeholder(name, parameter:)
        _add_widget(:placeholder, name, parameter:)
      end

      def sidebar_toggle(name, caption: 'Menu', button_style: :default, tooltip: '', icon: nil,
                         class_name: nil, style: nil, dynamic_class: nil, visible: nil, &block)
        _add_widget(:sidebar_toggle, name, caption:, button_style:, tooltip:, icon:,
                                           class: class_name, style:, dynamic_class:, visible:, &block)
      end

      def static_image(name, image:, alternative_text: '', width: 0, height: 0,
                       width_unit: :pixels, height_unit: :pixels, responsive: true,
                       class_name: nil, style: nil, dynamic_class: nil, visible: nil, &block)
        _add_widget(
          :static_image, name, image: image.to_s, alternative_text: alternative_text.to_s,
                               width: width.to_i, height: height.to_i,
                               width_unit: width_unit.to_sym, height_unit: height_unit.to_sym,
                               responsive: responsive == true, class: class_name, style:,
                               dynamic_class:, visible:, &block
        )
      end

      def file_manager(name, allowed_extensions: '', editable: :always, max_file_size: 5,
                       show_file_in_browser: false, mode: :both, tab_index: 0,
                       class_name: nil, style: nil, dynamic_class: nil, visible: nil, &block)
        _add_widget(
          :file_manager, name, allowed_extensions: allowed_extensions.to_s, editable:,
                               max_file_size: max_file_size.to_i,
                               show_file_in_browser: show_file_in_browser == true, mode:,
                               tab_index: tab_index.to_i, class: class_name, style:,
                               dynamic_class:, visible:, &block
        )
      end

      def reference_set_selector(name, selection: :multi, number_of_rows: 20, selectable_xpath: '',
                                 control_bar: true, select_first: false, show_empty_rows: false,
                                 paging: :yes_with_total_count, tab_index: 0,
                                 width_unit: :weight, class_name: nil, style: nil,
                                 dynamic_class: nil, visible: nil, association: nil, target_entity: nil,
                                 display_attribute: nil, association_steps: 1, association_path: nil,
                                 caption: nil, editable: :always, &block)
        _add_widget(
          :reference_set_selector, name, selection:, number_of_rows: number_of_rows.to_i,
                                         association:, target_entity:, display_attribute:, association_steps:,
                                         caption:, editable:, association_path:,
                                         selectable_xpath: selectable_xpath.to_s,
                                         control_bar: control_bar == true,
                                         select_first: select_first == true,
                                         show_empty_rows: show_empty_rows == true, paging:,
                                         tab_index: tab_index.to_i, width_unit:,
                                         class: class_name, style:, dynamic_class:, visible:, &block
        )
      end

      def navigation_list(name, tab_index: 0, class_name: nil, style: nil,
                          dynamic_class: nil, visible: nil, &block)
        _add_widget(
          :navigation_list, name, tab_index: tab_index.to_i, class: class_name,
                                  style:, dynamic_class:, visible:, &block
        )
      end

      def scroll_container(name, alignment: :center, layout_mode: :headline,
                           hide_scrollbars: false, scroll_behavior: :per_region,
                           tab_index: 0, width: 0, width_mode: :auto,
                           class_name: nil, style: nil, dynamic_class: nil,
                           visible: nil, region_options: nil, native_layout: nil, &block)
        _add_widget(
          :scroll_container, name, alignment:, layout_mode:, region_options:, native_layout:,
                                   hide_scrollbars: hide_scrollbars == true,
                                   scroll_behavior:, tab_index: tab_index.to_i,
                                   width: width.to_i, width_mode:, class: class_name,
                                   style:, dynamic_class:, visible:, &block
        )
      end

      def image_viewer(name, entity: nil, source: nil, alternative_text: '', default_image: '',
                       force_full_objects: false, width: 100, height: 100,
                       width_unit: :auto, height_unit: :auto, responsive: true,
                       show_as_thumbnail: false, on_click_enlarge: false, tab_index: 0,
                       class_name: nil, style: nil, dynamic_class: nil, visible: nil, &block)
        _add_widget(
          :image_viewer, name, entity: entity.to_s, source:, alternative_text: alternative_text.to_s,
                               default_image: default_image.to_s,
                               force_full_objects: force_full_objects == true,
                               width: width.to_i, height: height.to_i,
                               width_unit:, height_unit:, responsive: responsive == true,
                               show_as_thumbnail: show_as_thumbnail == true,
                               on_click_enlarge: on_click_enlarge == true,
                               tab_index: tab_index.to_i, class: class_name, style:,
                               dynamic_class:, visible:, &block
        )
      end

      def image_uploader(name, allowed_extensions: '', caption: '', editable: :always,
                         max_file_size: 5, thumbnail_width: 100, thumbnail_height: 75,
                         tab_index: 0, class_name: nil, style: nil, dynamic_class: nil,
                         visible: nil, &block)
        _add_widget(
          :image_uploader, name, allowed_extensions: allowed_extensions.to_s,
                                 caption: caption.to_s, editable:,
                                 max_file_size: max_file_size.to_i,
                                 thumbnail_width: thumbnail_width.to_i,
                                 thumbnail_height: thumbnail_height.to_i,
                                 tab_index: tab_index.to_i, class: class_name, style:,
                                 dynamic_class:, visible:, &block
        )
      end

      def menu_bar(name, menu:, tab_index: 0, class_name: nil, style: nil,
                   dynamic_class: nil, visible: nil, navigation_profile: nil, &block)
        navigation_menu_widget(
          :menu_bar, name, menu:, tab_index:, class_name:, style:, dynamic_class:, visible:, navigation_profile:, &block
        )
      end

      def navigation_tree(name, menu:, tab_index: 0, class_name: nil, style: nil,
                          dynamic_class: nil, visible: nil, navigation_profile: nil, &block)
        navigation_menu_widget(
          :navigation_tree, name, menu:, tab_index:, class_name:, style:, dynamic_class:,
                                  visible:, navigation_profile:, &block
        )
      end

      def data_grid(name, entity: nil, selection: nil, **runtime_options, &block)
        allowed = %i[page_size pageSize server_side sort toolbar presentation
                     columns_resizable columns_draggable columns_hidable xpath on_click_trigger]
        unknown = runtime_options.keys - allowed
        raise ArgumentError, "unknown data grid options: #{unknown.join(', ')}" unless unknown.empty?

        options = { entity:, selection:, **runtime_options }.compact
        _add_widget(:data_grid, name, **options, &block)
      end

      # Gallery projections remain present beside an authoritative page
      # deep_structure in exported projects. Accept the concise projection at
      # every widget nesting level so arbitrary native pages can be evaluated
      # and reconstructed from their lossless payload.
      def gallery(name, entity: nil, xpath: nil, association: nil, context_variable: nil,
                  sort: [], class_name: nil, style: nil, dynamic_class: nil, visible: nil, &block)
        options = {
          entity:, xpath:, association:, context_variable:, sort:,
          class: class_name, style:, dynamic_class:, visible:
        }.compact
        options.delete(:sort) if options[:sort].empty?
        _add_widget(:gallery, name, **options, &block)
      end

      def sort_by(attribute, direction: 'Ascending')
        { attribute: attribute.to_s, direction: direction.to_s }
      end

      # A data grid column filter: text, number, date, drop_down, boolean or enum,
      # optionally with its default operator (contains, equals, gt, between, ...).
      def grid_filter(type, operator: nil)
        { type: type.to_s, operator: operator&.to_s }.compact
      end

      def tab_control(name, &block)
        _add_widget(:tab_control, name, &block)
      end

      def table(name, width_unit: UNSET, tab_index: UNSET, class_name: UNSET, style: UNSET,
                dynamic_class: UNSET, visible: UNSET, &block)
        builder = TableBuilder.new(
          name, width_unit:, tab_index:, class_name:, style:, dynamic_class:, visible:
        )
        builder.instance_eval(&block) if block
        _widget_list << builder.to_h
      end

      def layout_grid(name, width: UNSET, tab_index: UNSET, class_name: UNSET, style: UNSET,
                      dynamic_class: UNSET, visible: UNSET, &block)
        builder = LayoutGridBuilder.new(
          name, width:, tab_index:, class_name:, style:, dynamic_class:, visible:
        )
        builder.instance_eval(&block) if block
        _widget_list << builder.to_h
      end

      def data_view(name, from:, editable: UNSET, read_only_style: UNSET,
                    label_width: UNSET, show_footer: UNSET, no_entity_message: UNSET,
                    tab_index: UNSET, class_name: UNSET, style: UNSET,
                    dynamic_class: UNSET, visible: UNSET, &block)
        builder = DataViewBuilder.new(
          name, from:, editable:, read_only_style:, label_width:, show_footer:,
                no_entity_message:, tab_index:, class_name:, style:, dynamic_class:
        )
        builder.visible_when(visible) unless visible.equal?(UNSET)
        builder.instance_eval(&block) if block
        _widget_list << builder.to_h
      end

      def context(name = nil, entity:, kind: :page_parameter, sub_key: nil,
                  use_all_pages: false, force_full_objects: false, native: nil)
        variable = (name || kind.to_sym == :current) && page_variable(
          name, kind:, sub_key:, use_all_pages:
        )
        compact_data_view_source(
          kind: :context, entity: entity.to_s, variable:,
          force_full_objects: force_full_objects == true, unknown_native: native
        )
      end

      def association(name, entity:, from: nil, force_full_objects: false, native: nil)
        steps = Array(name).map do |step|
          if step.is_a?(Hash)
            step.transform_keys(&:to_sym)
          elsif step.is_a?(Array)
            { association: step.fetch(0).to_s, entity: step.fetch(1).to_s }
          else
            { association: step.to_s, entity: entity.to_s }
          end
        end
        compact_data_view_source(
          kind: :association, entity: entity.to_s, steps:,
          variable: from, force_full_objects: force_full_objects == true,
          unknown_native: native
        )
      end

      def microflow_source(name, pass: {}, force_full_objects: false, use_all_pages: UNSET, native: nil)
        flow_data_view_source(
          :microflow, name, pass, force_full_objects, native, use_all_pages:
        )
      end

      def nanoflow_source(name, pass: {}, force_full_objects: false, native: nil)
        flow_data_view_source(:nanoflow, name, pass, force_full_objects, native)
      end

      def listen_to(widget, force_full_objects: false, native: nil)
        compact_data_view_source(
          kind: :listen, target: widget.to_s, force_full_objects: force_full_objects == true,
          unknown_native: native
        )
      end

      def view_source(kind, **options)
        compact_data_view_source(kind: kind.to_sym, **options)
      end

      def association_path(*steps)
        steps.map { |name, entity| { association: name, entity: } }
      end

      def scroll_regions(**regions) = regions
      def scroll_region(**options) = options
      def snippet_arguments(*pairs) = pairs.to_h

      def page_variable(name, kind: :page_parameter, sub_key: nil, use_all_pages: false,
                        native: nil)
        allowed = %i[page_parameter snippet_parameter local_variable widget current]
        kind = kind.to_sym
        raise ArgumentError, "unsupported page variable kind #{kind.inspect}" unless allowed.include?(kind)

        compact_data_view_source(
          kind:, name: name&.to_s, sub_key: sub_key&.to_s,
          use_all_pages: use_all_pages == true, unknown_native: native
        )
      end

      # icon: an icon collection image, such as "Atlas_Core.Atlas_Filled.pencil".
      # render_type: "link" renders the button as a link, as Studio Pro's Link render type.
      def button(name, caption: nil, parameters: [], class_name: nil, style: nil, dynamic_class: nil,
                 visible: nil, visibility: nil, button_style: nil, icon: nil, render_type: nil, &block)
        options = {
          caption: caption || name.to_s, parameters: Array(parameters).map(&:to_s),
          class: class_name, style:, dynamic_class:, visible:, visibility:, button_style:, icon:,
          render_type: render_type&.to_s
        }.compact
        options.delete(:parameters) if options[:parameters].empty?
        _add_widget(:button, name, **options, &block)
      end

      def drop_down(name, attribute: nil, caption: nil, class_name: nil, style: nil,
                    dynamic_class: nil, visible: nil, **input_options, &block)
        _add_widget(
          :drop_down, name, attribute: attribute&.to_s, caption:, class: class_name,
                            style:, dynamic_class:, visible:, **Forms::InputPresentation.options(input_options), &block
        )
      end

      # Conditional editability of an input: an expression, or the values of an
      # attribute of the source object (pairs of value and whether it matches).
      # roles: the module roles the widget is also restricted to.
      def input_condition(expression = nil, attribute: nil, conditions: nil, source: nil, roles: nil,
                          ignore_security: nil)
        return { expression: expression.to_s } if [attribute, conditions, source, roles, ignore_security].all?(&:nil?)

        compact_data_view_source(
          expression: expression&.to_s, attribute: attribute&.to_s,
          conditions: Dsl.attribute_conditions(conditions), source_variable: source,
          roles: Array(roles).map(&:to_s), ignore_security: ignore_security == true
        )
      end

      def snippet(name, from: nil, arguments: {}, **appearance)
        _widget_list << {
          type: :snippet, name: name.to_s,
          options: { snippet: (from || name).to_s, arguments:, **appearance },
          events: []
        }
      end

      def container(name, class_name: nil, style: nil, dynamic_class: nil, visible: nil, &block)
        cb = ContainerBuilder.new(
          name, class_name:, style:, dynamic_class:, visible:
        )
        cb.instance_eval(&block) if block
        _widget_list << cb.to_h
      end

      def pluggable_widget(name, widget_id:, widget_name: nil, properties: UNSET, class_name: nil,
                           style: nil, dynamic_class: nil, visible: nil, platform: nil, &block)
        properties_declared = !properties.equal?(UNSET)
        properties = {} unless properties_declared
        options = {
          widget_id: widget_id.to_s, widget_name: (widget_name || name).to_s,
          properties:, class: class_name, style:, dynamic_class:, visible:, platform:
        }.compact
        builder = PluggableWidgetBuilder.new(name, options:, properties_declared:)
        builder.instance_eval(&block) if block
        _widget_list << builder.to_h
      end

      def form_widget(node)
        document = Forms::MprCodec.new.encode(node)
        page = Model::Page.allocate
        page.decode('Widgets' => [2, document])
        _widget_list.concat(page.widgets)
      end

      def native_widget(name, type:, deep_structure:)
        raise ArgumentError, 'deep_structure requires a Hash' unless deep_structure.is_a?(Hash)

        _widget_list << {
          type: :native_widget, name: name.to_s,
          options: { native_type: type.to_s, deep_structure: deep_structure }, events: []
        }
      end

      # Lossless sink used by projections whose surrounding semantic builder
      # cannot assume a narrower widget signature. Known widgets should keep
      # using the named methods above; this preserves future contracts without
      # teaching every container a second, incompatible vocabulary.
      def widget(type, name = '', options: {}, events: [], &block)
        builder = GenericWidgetBuilder.new(type, name, options:, events:)
        builder.instance_eval(&block) if block
        _widget_list << builder.to_h
      end

      # Exported native widget payloads can contain BSON identifiers at any
      # nesting level. Keep the reconstruction helper on the shared widget DSL
      # so pages, containers, and tab pages all evaluate the same export.
      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype.to_sym)
      end

      private

      def navigation_menu_widget(type, name, menu:, tab_index:, class_name:, style:,
                                 dynamic_class:, visible:, navigation_profile: nil, &block)
        _add_widget(
          type, name, navigation_profile:, menu: menu.to_s, tab_index: tab_index.to_i, class: class_name,
                      style:, dynamic_class:, visible:, &block
        )
      end

      def _add_widget(type, name, **options, &block)
        builder = WidgetBuilder.new(type, name, **options.compact)
        builder.instance_eval(&block) if block
        _widget_list << builder.to_h
      end

      def flow_data_view_source(kind, name, pass, force_full_objects, native, use_all_pages: UNSET)
        mappings = pass.map do |parameter, value|
          if value.is_a?(Hash) && value[:kind]
            { parameter: parameter.to_s, variable: value }
          else
            { parameter: parameter.to_s, expression: value.to_s }
          end
        end
        settings = { 'UseAllPages' => use_all_pages == true } unless use_all_pages.equal?(UNSET)
        compact_data_view_source(
          kind:, name: name.to_s, mappings:,
          force_full_objects: force_full_objects == true, unknown_native: native,
          settings_native: settings
        )
      end

      def compact_data_view_source(**values)
        values.reject do |_key, value|
          value.nil? || value == false || (value.respond_to?(:empty?) && value.empty?)
        end
      end
    end

    module WidgetEvents
      def client_settings(disabled_during_execution: nil, close_count: nil, source: nil,
                          confirmation: nil, progress: nil, progress_message: nil,
                          asynchronous: nil, title: nil, link: nil, create: nil, outputs: nil)
        { disabled_during_execution:, close_count:, source:, confirmation:, progress:,
          progress_message:, asynchronous:, title:, link:, create:, outputs: }.compact
      end

      def action_confirmation(question:, proceed: 'Proceed', cancel: 'Cancel')
        { question:, proceed:, cancel: }
      end

      def action_output(source:, expression: '', attribute: nil, source_attribute: nil)
        { source:, expression:, attribute:, source_attribute: }.compact
      end

      def action_create(entity:, page: nil, association: nil)
        { entity:, page:, association: }.compact
      end

      def action_link(type: 'Web', value: '', attribute: nil)
        { type:, value:, attribute: }.compact
      end

      %i[on_change on_click on_enter on_leave].each do |event|
        define_method(event) do |microflow: nil, nanoflow: nil, page: nil, action: nil, pass: UNSET,
                                 close_page: UNSET, settings: UNSET, &block|
          raise ArgumentError, "#{event} accepts either pass: or an argument block" if block && !pass.equal?(UNSET)

          choices = { microflow:, nanoflow:, page:, action: }.compact
          raise ArgumentError, "#{event} requires exactly one handler" unless choices.one?

          pass = {} if pass.equal?(UNSET)
          raise ArgumentError, "#{event} pass: must be a Hash" unless pass.is_a?(Hash)

          declaration = {
            event:, kind: choices.keys.first, handler: choices.values.first.to_s
          }
          declaration[:settings] = settings unless settings.equal?(UNSET)
          declaration[:close_page] = close_page == true unless close_page.equal?(UNSET)
          if block
            declaration[:arguments] = WidgetEventArguments.new.evaluate(&block).arguments
            declaration = WidgetEventArguments.snapshot(declaration)
          else
            declaration[:arguments] = pass unless pass.empty?
          end
          widget_event_collection << declaration
        end
      end

      private

      def widget_event_collection = @events
    end
  end
end
