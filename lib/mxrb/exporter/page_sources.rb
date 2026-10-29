# frozen_string_literal: true

module Mxrb
  class Exporter
    # Writes pages, native fragments, menus and their widget trees.
    module PageSources
      INLINE_NATIVE_MAX_BYTES = 96 * 1024

      INLINE_NATIVE_MAX_LINE_BYTES = 1_600

      PAGE_TYPED_KEYS = %w[$ID Name name].freeze

      OVERLAY_WIDGET_TYPES = {
        table: 'Forms$Table', layout_grid: 'Forms$LayoutGrid', data_view: 'Forms$DataView'
      }.freeze

      DATA_GRID_OPTIONS = %i[page_size server_side sort presentation columns_resizable columns_draggable
                             columns_hidable xpath on_click_trigger filter_attributes source].freeze

      COLUMN_OPTIONS = %i[association_path dynamic_text parameters filter sortable hidable width size
                          alignment].freeze

      private

      def page_source(page, metadata = nil, module_unit_id: nil)
        if (forms_model = @typed_pages&.fetch(page.id, nil))
          return typed_page_source(page, forms_model, metadata)
        end

        body = []
        body << "  layout #{ruby(page.layout_id)}" if page.layout_id
        body << "  title #{ruby(page.title)}"
        body << '  popup!' if page.popup_width.to_i.positive? || page.popup_height.to_i.positive?
        unless page.allowed_module_roles.empty?
          body << "  allowed_roles #{page.allowed_module_roles.map do
            symbol(_1)
          end.join(', ')}"
        end
        widgets = metadata ? metadata.fetch(:widgets, []) : page.widgets
        source = metadata&.dig(:data_source) || page.data_source
        if source && %i[microflow nanoflow].include?(source.fetch(:kind).to_sym)
          body << "  data_source #{source.fetch(:kind)}: #{reference(source.fetch(:name))}"
        end
        raw_document = page.raw_document if page.respond_to?(:raw_document)
        if raw_document.is_a?(Hash) && semantic_page_baseline?(widgets)
          baseline = Writer::PageOverlay.metadata(
            widgets, page_unit_id: page.id, module_unit_id:
          )
          baseline['apply_fields'] = page_overlay_exportable?(page, widgets)
          baseline['baseline_digest'] = Writer::PageOverlay.baseline_digest(
            raw_document, baseline
          )
          body << "  baseline_overlay page_id: #{ruby(page.id)}, " \
                  "module_id: #{ruby(module_unit_id)}, " \
                  "baseline_digest: #{ruby(baseline.fetch('baseline_digest'))}, " \
                  "version: #{baseline.fetch('version')}, " \
                  "apply_fields: #{baseline.fetch('apply_fields')}"
          baseline.fetch('widgets').each do |widget|
            body << "  baseline_widget #{symbol(widget.fetch('type'))}, " \
                    "#{ruby(widget.fetch('name'))}, fingerprint: #{ruby(widget.fetch('fingerprint'))}"
          end
        elsif (deep = page_deep_structure(page))
          body << "  form_structure(#{native_fragment_ruby(presentation_value_spec(deep))})"
        end
        metadata&.fetch(:events, [])&.each do |event|
          args = []
          args << "target: #{symbol(event[:target])}" if event[:target]
          args << "#{event.fetch(:kind)}: #{symbol(event.fetch(:handler))}"
          args << "pass: #{native_ruby(event.fetch(:arguments), 2)}" unless event.fetch(:arguments, {}).empty?
          body << "  #{event.fetch(:event)} #{args.join(', ')}"
        end
        widgets.each do |widget|
          rendered = render_widget(widget, 2)
          body.concat(rendered)
        end
        declaration = [symbol(page.name), "unit_id: #{ruby(page.id)}"]
        declaration << 'public: true' if metadata&.fetch(:public, false)
        <<~RUBY
            # frozen_string_literal: true

            page #{declaration.join(', ')} do
          #{body.join("\n")}
            end
        RUBY
      end

      def typed_page_source(page, forms_model, metadata)
        form = Forms::SourceEmitter.new.emit_as(forms_model, 'form')
        body = form.lines(chomp: true).map { "  #{_1}" }.join("\n")
        # A document name is the stable public identity. The writer resolves the
        # existing unit by module, type and name, so exposing its storage UUID in
        # editable Ruby is unnecessary transport noise.
        declaration = [symbol(page.name)]
        declaration << 'public: true' if metadata&.fetch(:public, false)
        [
          '# frozen_string_literal: true', '',
          "page #{declaration.join(', ')} do", body, 'end', ''
        ].join("\n")
      end

      def page_deep_structure(page)
        raw = page.raw_document
        return nil unless raw.is_a?(Hash)

        raw.reject { |key, _| PAGE_TYPED_KEYS.include?(key.to_s) }
      end

      def page_overlay_exportable?(page, widgets)
        slots = page_root_widget_slots(page.raw_document)
        return false unless slots.one?

        native_roots = slots.first
        candidates = Array(widgets).filter_map do |widget|
          type = OVERLAY_WIDGET_TYPES[widget.fetch(:type).to_sym]
          [widget, type] if type
        end
        return false if candidates.empty?

        candidates.all? do |widget, type|
          native_roots.one? do |native|
            native.is_a?(Hash) && native['$Type'] == type &&
              native['Name'].to_s == widget.fetch(:name).to_s
          end
        end
      end

      def semantic_page_baseline?(widgets)
        safe = true
        each_page_widget(widgets) do |widget|
          safe = false if widget.fetch(:type).to_sym == :native_widget
        end
        safe
      end

      def page_root_widget_slots(document)
        return [] unless document.is_a?(Hash)

        slots = []
        slots << bson_items(document['Widgets']) if document.key?('Widgets')
        form_call = document['FormCall']
        return slots unless form_call.is_a?(Hash)

        bson_items(form_call['Arguments']).each do |argument|
          next unless argument.is_a?(Hash)

          slots << bson_items(argument['Widgets']) if argument.key?('Widgets')
          slots << [argument['Widget']].compact if argument.key?('Widget')
        end
        slots
      end

      def native_ruby(value, indent = 0)
        case value
        when BSON::Binary
          encoded = Base64.strict_encode64(value.data)
          "bson_binary(#{ruby(encoded)}, subtype: #{value.type.inspect})"
        when Time
          "Time.at(#{value.to_i}, #{value.nsec}, :nanosecond).utc"
        when Hash
          return '{}' if value.empty?

          pad = ' ' * indent
          child_pad = ' ' * (indent + 2)
          entries = value.map do |key, item|
            "#{child_pad}#{ruby(key)} => #{native_ruby(item, indent + 2)}"
          end
          "{\n#{entries.join(",\n")}\n#{pad}}"
        when Array
          return '[]' if value.empty?

          pad = ' ' * indent
          child_pad = ' ' * (indent + 2)
          entries = value.map { "#{child_pad}#{native_ruby(_1, indent + 2)}" }
          "[\n#{entries.join(",\n")}\n#{pad}]"
        else
          ruby(value)
        end
      end

      def native_fragment_ruby(document)
        return native_ruby(document) unless instance_variable_defined?(:@native_fragment_store)

        raise ValidationError, 'native fragment store is not initialized' unless @native_fragment_store

        inline = native_ruby(document)
        return inline if inline_native_fragment?(document, inline)

        digest = @native_fragment_store.put(document)
        types = native_fragment_types(document)
        hints = native_fragment_hints(document)
        overrides = native_fragment_overrides(document)
        arguments = [ruby(digest)]
        arguments << "types: #{ruby(types)}" unless types.empty?
        arguments << "hints: #{ruby(hints)}" unless hints.empty?
        arguments << "overrides: #{ruby(overrides)}" unless overrides.empty?
        "native_fragment(#{arguments.join(', ')})"
      end

      def inline_native_fragment?(document, source)
        return false if source.bytesize > INLINE_NATIVE_MAX_BYTES
        return false if source.each_line.any? { _1.bytesize > INLINE_NATIVE_MAX_LINE_BYTES }

        native_fragment_readable?(document)
      end

      def native_fragment_readable?(value)
        case value
        when BSON::Binary
          false
        when Hash
          value.all? { native_fragment_readable?(_1) && native_fragment_readable?(_2) }
        when Array
          value.all? { native_fragment_readable?(_1) }
        else
          true
        end
      end

      def native_fragment_types(value, found = [])
        case value
        when Hash
          found << value['$Type'].to_s unless value['$Type'].to_s.empty?
          value.each_value { native_fragment_types(_1, found) }
        when Array
          value.each { native_fragment_types(_1, found) }
        end
        found.uniq.sort
      end

      def native_fragment_hints(value, found = [])
        case value
        when Hash
          value.each do |key, child|
            found << child.to_s if key.to_s.match?(/(?:url|uri|endpoint|host)\z/i) &&
                                   child.is_a?(String) && child.bytesize.between?(1, 512)
            native_fragment_hints(child, found)
          end
        when Array
          value.each { native_fragment_hints(_1, found) }
        end
        found.uniq.sort.first(16)
      end

      def native_fragment_overrides(document)
        document.each_with_object({}) do |(key, value), overrides|
          next if %w[$ID $Type Name].include?(key.to_s)
          next unless native_fragment_override_value?(value)

          overrides[key.to_s] = value
        end
      end

      def native_fragment_override_value?(value)
        return value.bytesize <= 512 if value.is_a?(String)

        value.nil? || value.is_a?(Numeric) || value == true || value == false
      end

      def menu_source(menu)
        return opaque_menu_source(menu) unless menu.semantic?

        body = menu.items.flat_map { menu_item_source(_1, 2) }
        body.unshift("  baseline_menu unit_id: #{ruby(menu.id)}") if menu.raw_document.is_a?(Hash)
        body.unshift("  export_level #{symbol(menu.export_level)}") unless menu.export_level.empty?
        body.unshift('  excluded') if menu.excluded?
        body.unshift("  documentation #{ruby(menu.documentation)}") unless menu.documentation.empty?
        <<~RUBY
          # frozen_string_literal: true

          menu #{symbol(menu.name)} do
          #{body.join("\n")}
          end
        RUBY
      end

      def menu_item_source(item, indent)
        pad = ' ' * indent
        translations = item.fetch(:caption_translations, {})
        primary_locale = item[:caption_locale]
        args = if !translations.empty? && primary_locale != 'en_US'
                 [ruby(translations)]
               else
                 values = translations.reject { |locale, _text| locale.to_s == 'en_US' }
                 [ruby(item.fetch(:caption))].tap do |entries|
                   entries << "translations: #{ruby(values)}" unless values.empty?
                 end
               end
        args << "page: #{ruby(item[:page])}" if item[:page]
        args << "microflow: #{ruby(item[:microflow])}" if item[:microflow]
        args << "icon: #{ruby(item[:icon])}" if item[:icon]
        children = Array(item[:items])
        return ["#{pad}item #{args.join(', ')}"] if children.empty?

        lines = ["#{pad}item #{args.join(', ')} do"]
        lines.concat(children.flat_map { menu_item_source(_1, indent + 2) })
        lines << "#{pad}end"
      end

      def opaque_menu_source(menu)
        <<~RUBY
          # frozen_string_literal: true

          menu #{symbol(menu.name)} do
            deep_structure #{native_fragment_ruby(menu.raw_document)}
          end
        RUBY
      end

      def render_widget(widget, indent)
        pad       = ' ' * indent
        child_pad = ' ' * (indent + 2)
        # Architecture metadata is serialized through JSON inside generated MPRs,
        # so a second export can surface widget type values as strings.
        type      = widget.fetch(:type).to_sym
        options   = widget.fetch(:options, {})

        # Snippet: snippet :name, from: "..."
        if type == :snippet
          snippet_ref = options[:snippet].to_s
          args = [ruby(widget.fetch(:name))]
          args << "from: #{ruby(snippet_ref)}" unless snippet_ref == widget.fetch(:name).to_s
          return ["#{pad}snippet #{args.join(', ')}"]
        end

        if type == :native_widget
          return [
            "#{pad}native_widget #{symbol(widget.fetch(:name))},",
            "#{child_pad}type: #{ruby(options.fetch(:native_type))},",
            "#{child_pad}deep_structure: #{native_fragment_ruby(options.fetch(:deep_structure))}"
          ]
        end

        if type == :pluggable_widget
          args = [symbol(widget.fetch(:name)), "widget_id: #{ruby(options.fetch(:widget_id))}"]
          args << "widget_name: #{ruby(options[:widget_name])}" if options[:widget_name]
          args << "properties: #{native_ruby(options[:properties])}" if options[:properties]
          append_appearance_ruby_args(args, options)
          args << "platform: #{ruby(options[:platform])}" if options[:platform]
          body = Array(widget[:slots]).flat_map { render_pluggable_slot(_1, indent + 2) }
          body.concat(widget.fetch(:events, []).map { render_widget_event(_1, indent + 2) })
          return ["#{pad}pluggable_widget #{args.join(', ')}"] if body.empty?

          return ["#{pad}pluggable_widget #{args.join(', ')} do", *body, "#{pad}end"]
        end

        return render_table_widget(widget, indent) if type == :table
        return render_layout_grid_widget(widget, indent) if type == :layout_grid
        return render_data_view_widget(widget, indent) if type == :data_view
        if %i[
          file_manager image_uploader image_viewer menu_bar navigation_tree
          reference_set_selector navigation_list scroll_container sidebar_toggle
        ].include?(type)
          return render_legacy_semantic_widget(widget, indent)
        end

        if type == :page_title
          args = [symbol(widget.fetch(:name))]
          append_appearance_ruby_args(args, options)
          return ["#{pad}page_title #{args.join(', ')}"]
        end

        if type == :static_image
          args = [symbol(widget.fetch(:name)), "image: #{ruby(options.fetch(:image))}"]
          args << "alternative_text: #{ruby(options[:alternative_text])}" unless options[:alternative_text].to_s.empty?
          args << "width: #{options[:width]}" if options[:width].to_i.positive?
          args << "height: #{options[:height]}" if options[:height].to_i.positive?
          args << "width_unit: #{symbol(options[:width_unit])}" if options[:width_unit]
          args << "height_unit: #{symbol(options[:height_unit])}" if options[:height_unit]
          args << 'responsive: false' if options[:responsive] == false
          append_appearance_ruby_args(args, options)
          events = widget.fetch(:events, []).map { render_widget_event(_1, indent + 2) }
          return ["#{pad}static_image #{args.join(', ')}"] if events.empty?

          return ["#{pad}static_image #{args.join(', ')} do", *events, "#{pad}end"]
        end

        # Container: recurse into children
        if type == :container
          children_lines = Array(widget[:children]).flat_map { render_widget(_1, indent + 2) }
          children_lines.concat(
            widget.fetch(:events, []).map { render_widget_event(_1, indent + 2) }
          )
          args = [symbol(widget.fetch(:name))]
          append_appearance_ruby_args(args, options)
          return ["#{pad}container #{args.join(', ')}"] if children_lines.empty?

          lines = ["#{pad}container #{args.join(', ')} do"]
          lines.concat(children_lines)
          lines << "#{pad}end"
          return lines

        end

        args = [symbol(widget.fetch(:name))]
        args << "attribute: #{symbol(options[:attribute])}" if options[:attribute]
        args << "caption: #{ruby(options[:caption])}" if options.key?(:caption) && !options[:caption].nil?
        args << "entity: #{ruby(options[:entity])}" if options[:entity]
        args << "selection: #{symbol(options[:selection])}" if type == :data_grid && options.key?(:selection)
        if type == :data_grid
          DATA_GRID_OPTIONS.each { args << "#{_1}: #{native_ruby(options[_1])}" if options.key?(_1) }
        end
        if %i[text_box number_input text_area check_box date_picker radio_button_group
              reference_selector drop_down].include?(type)
          append_appearance_ruby_args(args, options)
          Forms::InputPresentation::OPTION_KEYS.each do |key|
            next unless options.key?(key)

            value = if key == :source_variable
                      page_variable_ruby(options.fetch(key))
                    elsif key == :editability && options.fetch(key).keys == [:expression]
                      "input_condition(#{ruby(options.fetch(key).fetch(:expression))})"
                    else
                      native_ruby(options.fetch(key))
                    end
            args << "#{key}: #{value}"
          end
        end
        if %i[button text].include?(type)
          args << "parameters: #{native_ruby(options[:parameters])}" unless Array(options[:parameters]).empty?
          append_appearance_ruby_args(args, options)
          args << "visibility: #{native_ruby(options[:visibility])}" if options[:visibility]
        end
        args << "render_mode: #{ruby(options[:render_mode].to_s)}" if type == :text && options[:render_mode]
        args << "button_style: #{symbol(options[:button_style])}" if type == :button && options[:button_style]
        args << "icon: #{ruby(options[:icon])}" if type == :button && options[:icon]
        args << "render_type: #{ruby(options[:render_type].to_s)}" if type == :button && options[:render_type]
        args << "lines: #{options[:lines]}" if type == :text_area && options[:lines]
        args << 'horizontal: true' if type == :radio_button_group && options[:horizontal]
        if type == :reference_selector && options[:display_attribute]
          args << "display_attribute: #{ruby(options[:display_attribute])}"
        end

        widget_body = []
        if widget.key?(:header)
          widget_body << "#{child_pad}header do"
          widget_body.concat(Array(widget[:header]).flat_map { render_widget(_1, indent + 4) })
          widget_body << "#{child_pad}end"
        end
        Array(options[:columns]).each do |column|
          widget_body.concat(render_column(column, indent + 2))
        end
        Array(options[:tabs]).each do |tab|
          tab_args = [symbol(tab.fetch(:name))]
          tab_args << "caption: #{ruby(tab[:caption])}" if tab.key?(:caption) && !tab[:caption].nil?
          tab_widgets = Array(tab[:widgets])
          if tab_widgets.empty?
            widget_body << "#{child_pad}tab_page #{tab_args.join(', ')}"
          else
            widget_body << "#{child_pad}tab_page #{tab_args.join(', ')} do"
            widget_body.concat(tab_widgets.flat_map { render_widget(_1, indent + 4) })
            widget_body << "#{child_pad}end"
          end
        end

        if (sb = options[:search_bar])
          sb_lines = ["#{child_pad}search_bar do"]
          Array(sb[:fields]).each do |field|
            sf_args = [symbol(field[:attribute])]
            sf_args << "caption: #{ruby(field[:caption])}" if field[:caption]
            sb_lines << "#{child_pad}  search_field #{sf_args.join(', ')}"
          end
          sb_lines << "#{child_pad}end"
          widget_body.concat(sb_lines)
        end

        if (tb = options[:toolbar])
          tb_lines = ["#{child_pad}toolbar do"]
          Array(tb[:buttons]).each do |btn|
            btn_method = case btn[:type].to_sym
                         when :new    then 'new_button'
                         when :delete then 'delete_button'
                         when :search then 'search_button'
                         when :export then 'export_button'
                         end
            next unless btn_method

            tb_arg = btn[:caption] ? "caption: #{ruby(btn[:caption])}" : nil
            tb_lines << "#{child_pad}  #{btn_method}#{tb_arg ? "(#{tb_arg})" : ''}"
          end
          tb_lines << "#{child_pad}end"
          widget_body.concat(tb_lines)
        end

        widget.fetch(:events, []).each do |event|
          widget_body << render_widget_event(event, indent + 2)
        end

        if widget_body.empty?
          ["#{pad}#{type} #{args.join(', ')}"]
        else
          lines = ["#{pad}#{type} #{args.join(', ')} do"]
          lines.concat(widget_body)
          lines << "#{pad}end"
        end
      end

      def render_widget_event(event, indent)
        arguments = event.fetch(:arguments, {})
        handler = if event.fetch(:kind).to_sym == :page
                    symbol(event.fetch(:handler))
                  else
                    reference(event.fetch(:handler))
                  end
        declaration = "#{' ' * indent}#{event.fetch(:event)} " \
                      "#{event.fetch(:kind)}: #{handler}"
        declaration += ", close_page: #{event.fetch(:close_page).inspect}" if event.key?(:close_page)
        if event.key?(:settings)
          settings = JSON.parse(JSON.generate(event.fetch(:settings)))
          declaration += ", settings: #{RubyApp::Exporter.allocate.send(:client_settings_source, settings)}"
        end
        return declaration if arguments.empty?

        "#{declaration}, pass: #{native_ruby(arguments, indent)}"
      end

      def render_legacy_semantic_widget(widget, indent)
        type = widget.fetch(:type).to_sym
        options = widget.fetch(:options, {})
        args = [symbol(widget.fetch(:name))]
        fields = case type
                 when :file_manager
                   %i[allowed_extensions editable max_file_size show_file_in_browser mode tab_index]
                 when :image_viewer
                   %i[entity alternative_text default_image force_full_objects width height width_unit
                      height_unit responsive show_as_thumbnail on_click_enlarge tab_index]
                 when :image_uploader
                   %i[allowed_extensions caption editable max_file_size thumbnail_width
                      thumbnail_height tab_index]
                 when :menu_bar, :navigation_tree
                   %i[menu tab_index navigation_profile]
                 when :sidebar_toggle
                   %i[caption button_style tooltip]
                 when :reference_set_selector
                   %i[selection number_of_rows selectable_xpath control_bar select_first show_empty_rows
                      paging tab_index width_unit association target_entity display_attribute association_path
                      association_steps caption editable]
                 when :navigation_list
                   %i[tab_index]
                 when :scroll_container
                   %i[alignment layout_mode hide_scrollbars scroll_behavior tab_index width width_mode
                      native_layout region_options]
                 end
        symbol_fields = %i[editable mode selection paging width_unit alignment layout_mode
                           scroll_behavior width_mode height_unit]
        fields.each do |field|
          next unless options.key?(field)

          value = if field == :association_path
                    steps = options.fetch(field).map do
                      [ruby(_1.fetch(:association)), ruby(_1.fetch(:entity))].join(', ')
                    end
                    "association_path(#{steps.map { "[#{_1}]" }.join(', ')})"
                  else
                    symbol_fields.include?(field) ? symbol(options[field]) : native_ruby(options[field])
                  end
          args << "#{field}: #{value}"
        end
        append_appearance_ruby_args(args, options)
        events = widget.fetch(:events, []).map { render_widget_event(_1, indent + 2) }
        children = Array(widget[:children]).flat_map { render_widget(_1, indent + 2) }
        body = events + children + render_widget_regions(widget.fetch(:regions, {}), indent + 2)
        return ["#{' ' * indent}#{type} #{args.join(', ')}"] if body.empty?

        ["#{' ' * indent}#{type} #{args.join(', ')} do", *body, "#{' ' * indent}end"]
      end

      def render_column(column, indent)
        pad = ' ' * indent
        args = [symbol(column.fetch(:name))]
        args << "attribute: #{symbol(column[:attribute])}" if column[:attribute]
        args << "caption: #{ruby(column[:caption])}" if column.key?(:caption) && !column[:caption].nil?
        COLUMN_OPTIONS.each { args << "#{_1}: #{native_ruby(column[_1])}" if column.key?(_1) }
        return ["#{pad}column #{args.join(', ')}"] unless column.key?(:content)

        ["#{pad}column #{args.join(', ')} do", *Array(column[:content]).flat_map { render_widget(_1, indent + 2) },
         "#{pad}end"]
      end

      def render_widget_regions(regions, indent)
        regions.flat_map do |name, widgets|
          declaration = "#{' ' * indent}region #{symbol(name)}"
          next [declaration] if Array(widgets).empty?

          ["#{declaration} do", *widgets.flat_map { render_widget(_1, indent + 2) }, "#{' ' * indent}end"]
        end
      end

      def render_pluggable_slot(slot, indent)
        path = Array(slot.fetch(:path))
        widgets = Array(slot[:widgets])
        declaration = pluggable_slot_declaration(path, indent)
        return [declaration] if widgets.empty?

        ["#{declaration} do", *widgets.flat_map { render_widget(_1, indent + 2) },
         "#{' ' * indent}end"]
      end

      def pluggable_slot_declaration(path, indent)
        pad = ' ' * indent
        if path.size == 1
          "#{pad}slot #{symbol(path.first)}"
        elsif path.size == 4 && path[1].to_s == 'objects' && path[2].is_a?(Integer)
          "#{pad}slot #{symbol(path[3])}, within: #{symbol(path[0])}, item: #{path[2]}"
        else
          "#{pad}slot path: #{native_ruby(path, indent)}"
        end
      end

      def render_data_view_widget(widget, indent)
        pad = ' ' * indent
        child_pad = ' ' * (indent + 2)
        options = widget.fetch(:options, {})
        args = [symbol(widget.fetch(:name)), "from: #{data_view_source_ruby(options.fetch(:source))}"]
        args << "editable: #{symbol(options[:editable])}" if options.fetch(:editable, :always).to_sym != :always
        if options.fetch(:read_only_style, :control).to_sym != :control
          args << "read_only_style: #{symbol(options[:read_only_style])}"
        end
        args << "label_width: #{options[:label_width]}" if options[:label_width].to_i != 0
        args << 'show_footer: false' if options[:show_footer] == false
        args << "no_entity_message: #{ruby(options[:no_entity_message])}" unless options[:no_entity_message].to_s.empty?
        args << "tab_index: #{options[:tab_index]}" if options[:tab_index].to_i != 0
        append_appearance_ruby_args(args, options)
        body = Array(widget[:body]).flat_map { render_widget(_1, indent + 4) }
        footer = Array(widget[:footer]).flat_map { render_widget(_1, indent + 4) }
        lines = ["#{pad}data_view #{args.join(', ')} do"]
        unless body.empty?
          lines << "#{child_pad}body do"
          lines.concat(body)
          lines << "#{child_pad}end"
        end
        unless footer.empty?
          lines << "#{child_pad}footer do"
          lines.concat(footer)
          lines << "#{child_pad}end"
        end
        lines.concat(data_view_condition_ruby(:visible_when, options[:visibility], indent + 2))
        lines.concat(data_view_condition_ruby(:editable_when, options[:editability], indent + 2))
        unless Array(options[:design_properties]).empty?
          Array(options[:design_properties]).each do |property|
            if property.is_a?(Hash) && property.key?(:key) && property.key?(:option)
              args = [ruby(property.fetch(:key)), "option: #{ruby(property.fetch(:option))}"]
              args << "id: #{ruby(property[:id])}" if property[:id]
              args << "value_id: #{ruby(property[:value_id])}" if property[:value_id]
              lines << "#{child_pad}design_property #{args.join(', ')}"
            else
              lines << "#{child_pad}design_properties(#{native_ruby(property, indent + 2)})"
            end
          end
        end
        unless options.fetch(:unknown_native, {}).empty?
          lines << "#{child_pad}unknown_native(#{native_ruby(options[:unknown_native], indent + 2)})"
        end
        lines << "#{pad}end"
      end

      def render_table_widget(widget, indent)
        pad = ' ' * indent
        child_pad = ' ' * (indent + 2)
        options = widget.fetch(:options, {})
        args = [symbol(widget.fetch(:name))]
        args << "width_unit: #{symbol(options[:width_unit])}" if
          options[:width_unit] && options[:width_unit].to_sym != :weight
        args << "tab_index: #{options[:tab_index]}" if options[:tab_index].to_i != 0
        append_appearance_ruby_args(args, options)
        lines = ["#{pad}table #{args.join(', ')} do"]
        Array(options[:columns]).each do |column|
          lines << "#{child_pad}column width: #{column.fetch(:width, 0).to_i}"
        end
        Array(options[:rows]).each do |row|
          row_args = []
          append_appearance_ruby_args(row_args, row.fetch(:options, {}))
          lines << "#{child_pad}row#{row_args.empty? ? '' : " #{row_args.join(', ')}"} do"
          cursor = 0
          Array(row[:cells]).each do |cell|
            cell_args = []
            column = cell.fetch(:column, cursor).to_i
            cell_args << "column: #{column}" unless column == cursor
            cell_args << "colspan: #{cell[:colspan]}" if cell[:colspan].to_i > 1
            cell_args << "rowspan: #{cell[:rowspan]}" if cell[:rowspan].to_i > 1
            cell_args << 'header: true' if cell[:header] == true
            append_appearance_ruby_args(cell_args, cell.fetch(:options, {}))
            widgets = Array(cell[:widgets])
            declaration = "#{child_pad}  cell#{cell_args.empty? ? '' : " #{cell_args.join(', ')}"}"
            if widgets.empty?
              lines << declaration
            else
              lines << "#{declaration} do"
              lines.concat(widgets.flat_map { render_widget(_1, indent + 6) })
              lines << "#{child_pad}  end"
            end
            cursor = column + [cell.fetch(:colspan, 1).to_i, 1].max
          end
          lines << "#{child_pad}end"
        end
        lines << "#{pad}end"
      end

      def render_layout_grid_widget(widget, indent)
        pad = ' ' * indent
        options = widget.fetch(:options, {})
        args = [symbol(widget.fetch(:name))]
        args << "width: #{symbol(options[:width])}" if options.fetch(:width, :full).to_sym != :full
        args << "tab_index: #{options[:tab_index]}" if options[:tab_index].to_i != 0
        append_appearance_ruby_args(args, options)
        lines = ["#{pad}layout_grid #{args.join(', ')} do"]
        lines.concat(Array(options[:rows]).flat_map { render_layout_grid_row(_1, indent + 2) })
        lines << "#{pad}end"
      end

      def render_layout_grid_row(row, indent)
        pad = ' ' * indent
        options = row.fetch(:options, {})
        args = []
        args << "horizontal_alignment: #{symbol(options[:horizontal_alignment])}" if
          options.fetch(:horizontal_alignment, :none).to_sym != :none
        args << "vertical_alignment: #{symbol(options[:vertical_alignment])}" if
          options.fetch(:vertical_alignment, :none).to_sym != :none
        args << 'gutters: false' if options[:gutters] == false
        append_appearance_ruby_args(args, options)
        declaration = "#{pad}row#{args.empty? ? '' : " #{args.join(', ')}"}"
        columns = Array(row[:columns])
        return [declaration] if columns.empty?

        ["#{declaration} do", *columns.flat_map { render_layout_grid_column(_1, indent + 2) },
         "#{pad}end"]
      end

      def render_layout_grid_column(column, indent)
        pad = ' ' * indent
        options = column.fetch(:options, {})
        args = %i[desktop tablet phone].filter_map do |viewport|
          value = options.fetch(viewport, :grow)
          next if value.to_s == 'grow'

          rendered = value.to_s == 'auto' ? symbol(value) : Integer(value)
          "#{viewport}: #{rendered}"
        end
        alignment = options.fetch(:vertical_alignment, :none)
        args << "vertical_alignment: #{symbol(alignment)}" if alignment.to_sym != :none
        append_appearance_ruby_args(args, options)
        declaration = "#{pad}column#{args.empty? ? '' : " #{args.join(', ')}"}"
        widgets = Array(column[:widgets])
        return [declaration] if widgets.empty?

        ["#{declaration} do", *widgets.flat_map { render_widget(_1, indent + 2) }, "#{pad}end"]
      end

      def append_appearance_ruby_args(args, options)
        args << "class_name: #{ruby(options[:class])}" unless options[:class].to_s.empty?
        args << "style: #{ruby(options[:style])}" unless options[:style].to_s.empty?
        args << "dynamic_class: #{ruby(options[:dynamic_class])}" unless options[:dynamic_class].to_s.empty?
        args << "visible: #{ruby(options[:visible])}" unless options[:visible].to_s.empty?
      end
    end
  end
end
