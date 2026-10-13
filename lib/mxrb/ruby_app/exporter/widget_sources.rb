# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Writes pages and their widgets in the runtime widget DSL.
      module WidgetSources
        STRUCTURED_OPTION_KEYS = {
          table: %w[width_unit tab_index class style dynamic_class visible columns rows],
          layout_grid: %w[width tab_index class style dynamic_class visible rows design]
        }.freeze

        DSL_SINK_REQUIRED_OPTIONS = {
          button: %w[caption], pluggable_widget: %w[widget_id widget_name properties],
          image_viewer: %w[entity], menu_bar: %w[menu], navigation_tree: %w[menu],
          radio_button_group: %w[horizontal],
          snippet: %w[snippet],
          placeholder: %w[parameter],
          static_image: %w[image alternative_text width height width_unit height_unit responsive],
          text: %w[caption], text_area: %w[lines]
        }.freeze

        WIDGET_EVENT_METHODS = %w[on_change on_click on_enter on_leave].freeze

        WIDGET_EVENT_HANDLERS = %w[microflow nanoflow page action].freeze

        private

        def page_source(namespace, class_name, qualified, id, title, widgets,
                        appearance_class:, appearance_style:, data_source:, allowed_roles: [], presentation: {},
                        excluded: false)
          widget_source = PluggableProperties.with_page(id) { runtime_widget_dsl_source(widgets, 6) }
          data_source_expression = PageDataSources.configuration_expression(data_source) || data_source.inspect
          <<~RUBY
            # frozen_string_literal: true

            module #{namespace}
              class #{class_name} < Mxrb::RubyApp::Page
                mendix_name #{qualified.inspect}#{"\n    excluded" if excluded}
                configure(
                  title: #{title.inspect},
                  allowed_roles: #{allowed_roles.map(&:to_s).inspect},
                  appearance_class: #{appearance_class.inspect},
                  appearance_style: #{appearance_style.inspect},
                  data_source: #{data_source_expression},
                  presentation: #{PresentationContracts.source(presentation)}
                ) do
            #{widget_source}
                end
              end
            end
          RUBY
        end

        def runtime_widget_dsl_source(widgets, indentation, generic_sink: false)
          Array(widgets).map do |widget|
            runtime_widget_call_source(widget, indentation, generic_sink:)
          end.join("\n")
        end

        def runtime_widget_call_source(widget, indentation, generic_sink: false)
          padding = ' ' * indentation
          type = widget.fetch('type').to_sym
          options = widget.fetch('options', {})
          if type == :data_view && runtime_data_view_supported?(options, widget)
            return runtime_data_view_source(widget, indentation)
          end
          if type == :native_widget && runtime_native_widget_supported?(options, widget)
            return runtime_native_widget_source(widget, indentation)
          end
          if type == :tab_control && runtime_tab_control_supported?(options, widget)
            return runtime_tab_control_source(widget, indentation)
          end

          if runtime_structured_widget?(type, options, widget)
            return runtime_table_source(widget, indentation) if type == :table

            return runtime_layout_grid_source(widget, indentation)
          end
          return runtime_data_grid_source(widget, indentation) if runtime_data_grid_supported?(type, options, widget)

          typed = if generic_sink
                    runtime_dsl_sink_typed?(type, options, widget)
                  else
                    Page::WidgetTree::WIDGET_METHODS.include?(type) &&
                      !Page::WidgetTree::STRUCTURED_METHODS.include?(type) &&
                      runtime_keywords_safe?(options)
                  end
          method_name = typed ? type.to_s : 'widget'
          property_source = runtime_pluggable_properties_source(widget, indentation + 2) if
            typed && type == :pluggable_widget
          arguments = []
          arguments << type.inspect unless typed
          arguments << widget.fetch('name', '').inspect
          if typed
            options.each do |key, value|
              next if key.to_s == 'properties' && property_source

              keyword = runtime_widget_keyword(type, key, generic_sink:)
              expression = if key.to_s == 'source'
                             PageDataSources.source_expression(value)
                           elsif key.to_s == 'source_variable'
                             PageDataSources.variable_reference_expression(value)
                           elsif key.to_s == 'association_path'
                             steps = value.map { [_1['association'], _1['entity']].inspect }
                             "association_path(#{steps.join(', ')})"
                           elsif key.to_s == 'region_options'
                             entries = value.map do |region, settings|
                               args = settings.map { |name, setting| "#{name}: #{setting.inspect}" }.join(', ')
                               "#{region}: scroll_region(#{args})"
                             end
                             "scroll_regions(#{entries.join(', ')})"
                           elsif type == :snippet && key.to_s == 'arguments'
                             pairs = value.map do |name, argument|
                               source = PageDataSources.variable_reference_expression(argument) || argument.inspect
                               "[#{name.inspect}, #{source}]"
                             end
                             "snippet_arguments(#{pairs.join(', ')})"
                           elsif type == :data_grid && key.to_s == 'columns'
                             runtime_grid_columns_expression(value)
                           elsif type == :gallery && key.to_s == 'sort'
                             runtime_gallery_sort_expression(value)
                           elsif %w[editability visibility].include?(key.to_s)
                             runtime_input_condition_source(value)
                           elsif key.to_s == 'design'
                             runtime_design_expression(value)
                           end
              arguments << "#{keyword}: #{expression || pretty_ruby_value(value, indentation + 2)}"
            end
          elsif widget.key?('options')
            arguments << "options: #{pretty_ruby_value(options, indentation + 2)}"
          end
          typed_events = (typed || !generic_sink) && runtime_widget_events_supported?(widget)
          event_source = if typed_events
                           runtime_widget_event_source(widget, indentation + 2, preserve_empty: !generic_sink)
                         else
                           ''
                         end
          emit_events = widget.key?('events') && !typed_events
          arguments << "events: #{pretty_ruby_value(widget.fetch('events'), indentation + 2)}" if emit_events
          children = Array(widget['children'])
          region_source = runtime_widget_regions_source(widget, indentation + 2, generic_sink:)
          block = property_source || !event_source.empty? || !children.empty? || !region_source.empty?
          declaration = runtime_widget_declaration(method_name, arguments, indentation, block)
          return declaration unless block

          nested = runtime_widget_dsl_source(children, indentation + 2, generic_sink:)
          body = [property_source, event_source, nested, region_source].compact.reject(&:empty?).join("\n")
          "#{declaration}\n#{body}\n#{padding}end"
        end

        def runtime_pluggable_properties_source(widget, indentation)
          options = widget.fetch('options', {})
          return unless options.key?('properties')

          bridge = PluggableProperties.try_supported_subset_for_widget(
            widget.fetch('name', ''), widget_id: options['widget_id'], properties: options.fetch('properties')
          )
          return unless bridge

          lines = bridge.to_projection.map do |key, value|
            expression = bridge.source_expression(key, indentation: indentation + 4) ||
                         pretty_ruby_value(value, indentation + 2)
            runtime_widget_declaration('set', [key.inspect, expression],
                                       indentation + 2, false)
          end
          ["#{' ' * indentation}properties do", *lines, "#{' ' * indentation}end"].join("\n")
        end

        def runtime_native_widget_supported?(options, widget)
          return false unless runtime_keys?(widget, %w[type name options events])
          return false unless widget['name'].is_a?(String) && widget.key?('options')
          return false unless options.keys.map(&:to_s).sort == %w[native_fragment native_type]
          return false unless options['native_type'].is_a?(String) && !options['native_type'].empty?
          return false unless Array(widget['events']).empty?

          fragment = options['native_fragment']
          runtime_keys?(fragment, %w[digest]) && fragment.keys.map(&:to_s) == %w[digest] &&
            fragment['digest'].to_s.match?(NativeFragmentStore::DIGEST_PATTERN)
        end

        def runtime_native_widget_source(widget, indentation)
          return presentation_form_widget_source(widget, indentation) if @presentation_source

          options = widget.fetch('options')
          fragment = options.fetch('native_fragment')
          arguments = [
            widget.fetch('name').inspect,
            "type: #{options.fetch('native_type').inspect}",
            "deep_structure: native_fragment(#{fragment.fetch('digest').inspect})"
          ]
          runtime_widget_declaration('native_widget', arguments, indentation, false)
        end

        def presentation_widget_source(widgets)
          @presentation_source = true
          runtime_widget_dsl_source(widgets, 2)
        ensure
          @presentation_source = false
        end

        def presentation_form_widget_source(widget, indentation)
          options = widget.fetch('options')
          document = @native_fragment_store.fetch(options.fetch('native_fragment').fetch('digest'))
          document = document.merge('$Type' => options.fetch('native_type'), 'Name' => widget.fetch('name'))
          node = Forms::MprCodec.new.decode(document)
          source = Forms::SourceEmitter.new.emit(node).lines.map { "#{' ' * (indentation + 2)}#{_1}" }.join
          "#{' ' * indentation}form_widget(\n#{source}#{' ' * indentation})"
        end

        def runtime_tab_control_supported?(options, widget)
          return false unless runtime_keys?(widget, %w[type name options events])
          return false unless widget['name'].is_a?(String) && widget.key?('options')
          return false unless (options.keys.map(&:to_s) - %w[design]) == %w[tabs]
          return false unless Array(widget['events']).empty?
          return false unless options.fetch('tabs').is_a?(Array) && options.fetch('tabs').any?

          options.fetch('tabs').all? do |tab|
            runtime_keys?(tab, %w[name caption widgets]) &&
              tab['name'].is_a?(String) && tab['caption'].is_a?(String) &&
              tab['widgets'].is_a?(Array) && runtime_widget_collection_supported?(tab['widgets'])
          end
        end

        def runtime_tab_control_source(widget, indentation)
          padding = ' ' * indentation
          arguments = [widget.fetch('name', '').inspect]
          design = widget.fetch('options', {})['design']
          arguments << "design: #{runtime_design_expression(design)}" if design
          lines = [runtime_widget_declaration('tab_control', arguments, indentation, true)]
          widget.fetch('options', {}).fetch('tabs', []).each do |tab|
            arguments = [tab.fetch('name').inspect, "caption: #{tab.fetch('caption').inspect}"]
            widgets = tab.fetch('widgets')
            lines << runtime_widget_declaration('tab_page', arguments, indentation + 2, widgets.any?)
            next if widgets.empty?

            lines << runtime_widget_dsl_source(widgets, indentation + 4, generic_sink: true)
            lines << "#{' ' * (indentation + 2)}end"
          end
          lines << "#{padding}end"
          lines.join("\n")
        end

        def runtime_dsl_sink_typed?(type, options, widget)
          allowed = DSL_SINK_OPTIONS[type]
          if %i[text_box text_area number_input check_box date_picker drop_down
                radio_button_group reference_selector].include?(type)
            allowed += Forms::InputPresentation::OPTION_KEYS.map(&:to_s)
          end
          return false unless allowed && (options.keys.map(&:to_s) - allowed - %w[design]).empty?
          return false unless (DSL_SINK_REQUIRED_OPTIONS.fetch(type, []) - options.keys.map(&:to_s)).empty?
          return false if !DSL_SINK_BLOCK_METHODS.include?(type) && widget_block?(widget)
          return false unless runtime_dsl_sink_regions_supported?(type, widget)

          runtime_widget_events_supported?(widget)
        end

        def runtime_dsl_sink_regions_supported?(type, widget)
          return !widget.key?('slots') && !widget.key?('body') && !widget.key?('footer') if type == :scroll_container

          named_regions = %w[body footer regions].any? { widget.key?(_1) }
          return false if named_regions
          return true unless widget.key?('slots')

          type == :pluggable_widget && Array(widget['slots']).all? { !_1.key?('role') }
        end

        def widget_block?(widget)
          Array(widget['events']).any? || Array(widget['children']).any?
        end

        def runtime_widget_events_supported?(widget)
          return false if widget.key?('events') && !widget['events'].is_a?(Array)

          Array(widget['events']).all? do |event|
            runtime_keys?(event, %w[event kind handler arguments close_page settings]) &&
              WIDGET_EVENT_METHODS.include?(event['event'].to_s) &&
              WIDGET_EVENT_HANDLERS.include?(event['kind'].to_s) &&
              %w[event kind handler].all? { event[_1].is_a?(String) && !event[_1].empty? } &&
              (!event.key?('arguments') ||
                (event['arguments'].is_a?(Hash) && event['arguments'].keys.all? { _1.is_a?(String) && !_1.empty? }))
          end
        end

        def client_settings_source(settings)
          fields = settings.map do |key, value|
            expression = case key.to_s
                         when 'source' then PageDataSources.variable_reference_expression(value)
                         when 'outputs'
                           entries = value.map do |mapping|
                             arguments = mapping.map do |name, item|
                               source = if name.to_s == 'source'
                                          PageDataSources.variable_reference_expression(item)
                                        else
                                          item.inspect
                                        end
                               "#{name}: #{source}"
                             end
                             "action_output(#{arguments.join(', ')})"
                           end
                           "[#{entries.join(', ')}]"
                         when 'confirmation', 'link', 'create'
                           arguments = value.map { |name, item| "#{name}: #{item.inspect}" }.join(', ')
                           "action_#{key}(#{arguments})"
                         else value.inspect
                         end
            "#{key}: #{expression}"
          end
          "client_settings(#{fields.join(', ')})"
        end

        def runtime_widget_event_source(widget, indentation, preserve_empty: false)
          Array(widget['events']).map do |event|
            arguments = ["#{event.fetch('kind')}: #{event.fetch('handler').inspect}"]
            arguments << "close_page: #{event.fetch('close_page').inspect}" if event.key?('close_page')
            arguments << "settings: #{client_settings_source(event.fetch('settings'))}" if event.key?('settings')
            # Existing native-widget sinks compacted empty mappings. Preserve
            # that runtime projection while migrating literal events (which did
            # retain empty mappings) using an explicitly empty argument block.
            present = event.key?('arguments') && (preserve_empty || !event.fetch('arguments').empty?)
            declaration = runtime_widget_declaration(event.fetch('event'), arguments, indentation, present)
            next declaration unless present

            lines = event.fetch('arguments').map do |name, value|
              expression = PageDataSources.variable_reference_expression(value) ||
                           pretty_ruby_value(value, indentation + 4)
              runtime_widget_declaration('argument', [name.inspect, expression], indentation + 2, false)
            end
            [declaration, *lines, "#{' ' * indentation}end"].join("\n")
          end.join("\n")
        end

        def runtime_widget_regions_source(widget, indentation, generic_sink:)
          sources = %w[body footer].filter_map do |name|
            next unless widget.key?(name)

            runtime_named_widget_region_source(name, widget.fetch(name), indentation, generic_sink:)
          end
          widget.fetch('regions', {}).each do |name, widgets|
            sources << runtime_named_widget_region_source(
              'region', widgets, indentation, generic_sink:, name:
            )
          end
          Array(widget['slots']).each do |slot|
            sources << runtime_widget_slot_source(slot, indentation, generic_sink:)
          end
          sources.join("\n")
        end

        def runtime_named_widget_region_source(method_name, widgets, indentation, generic_sink:, name: nil)
          arguments = name.nil? ? [] : [name.inspect]
          declaration = runtime_widget_declaration(method_name, arguments, indentation, Array(widgets).any?)
          return declaration if Array(widgets).empty?

          padding = ' ' * indentation
          nested = runtime_widget_dsl_source(widgets, indentation + 2, generic_sink:)
          "#{declaration}\n#{nested}\n#{padding}end"
        end

        def runtime_widget_slot_source(slot, indentation, generic_sink:)
          arguments = ["path: #{pretty_ruby_value(slot.fetch('path'), indentation + 2)}"]
          arguments << "role: #{slot.fetch('role').inspect}" if slot.key?('role')
          widgets = Array(slot['widgets'])
          declaration = runtime_widget_declaration('slot', arguments, indentation, widgets.any?)
          return declaration if widgets.empty?

          padding = ' ' * indentation
          nested = runtime_widget_dsl_source(widgets, indentation + 2, generic_sink:)
          "#{declaration}\n#{nested}\n#{padding}end"
        end

        def runtime_widget_keyword(type, key, generic_sink:)
          return 'from' if generic_sink && type == :snippet && key.to_s == 'snippet'
          return 'class_name' if key.to_s == 'class'

          key.to_s
        end

        def runtime_structured_widget?(type, options, widget)
          allowed = STRUCTURED_OPTION_KEYS[type]
          return false unless allowed && (options.keys.map(&:to_s) - allowed).empty?
          return false unless Array(widget['events']).empty? && Array(widget['children']).empty?

          type == :table ? runtime_table_supported?(options) : runtime_layout_grid_supported?(options)
        end

        def runtime_table_supported?(options)
          return false unless %w[weight percentage pixels].include?(options.fetch('width_unit', 'weight').to_s)

          columns = Array(options['columns'])
          rows = Array(options['rows'])
          return false if columns.empty? || columns.any? { !runtime_keys?(_1, %w[width]) || _1['width'].to_i <= 0 }
          return false unless rows.all? { runtime_table_row_supported?(_1) }

          runtime_table_geometry_supported?(columns.size, rows)
        end

        def runtime_table_row_supported?(row)
          return false unless runtime_keys?(row, %w[options cells])
          return false unless runtime_keys?(row.fetch('options', {}), %w[class style dynamic_class visible])

          Array(row['cells']).all? do |cell|
            runtime_keys?(cell, %w[column colspan rowspan header options widgets]) &&
              runtime_keys?(cell.fetch('options', {}), %w[class style dynamic_class]) &&
              cell.fetch('colspan', 1).to_i.positive? && cell.fetch('rowspan', 1).to_i.positive? &&
              (!cell.key?('column') || cell['column'].to_i >= 0) &&
              Array(cell['widgets']).all? { runtime_nested_widget_supported?(_1) }
          end
        end

        def runtime_table_geometry_supported?(column_count, rows)
          occupied = {}
          rows.each_with_index do |row, row_index|
            cursor = 0
            Array(row['cells']).each do |cell|
              cursor += 1 while occupied[[row_index, cursor]]
              column = cell.fetch('column', cursor).to_i
              right = column + cell.fetch('colspan', 1).to_i
              bottom = row_index + cell.fetch('rowspan', 1).to_i
              return false if right > column_count || bottom > rows.size

              coordinates = (row_index...bottom).to_a.product((column...right).to_a)
              return false if coordinates.any? { occupied[_1] }

              coordinates.each { occupied[_1] = true }
              cursor = right
            end
          end
          true
        end

        def runtime_layout_grid_supported?(options)
          return false unless %w[full fixed].include?(options.fetch('width', 'full').to_s)

          Array(options['rows']).all? do |row|
            runtime_keys?(row, %w[options columns]) && runtime_layout_grid_row_supported?(row)
          end
        end

        def runtime_layout_grid_row_supported?(row)
          options = row.fetch('options', {})
          return false unless runtime_keys?(
            options,
            %w[horizontal_alignment vertical_alignment gutters class style dynamic_class visible design]
          )
          return false unless %w[horizontal_alignment vertical_alignment].all? do |name|
            runtime_alignment?(options.fetch(name, 'none'))
          end

          Array(row['columns']).all? do |column|
            runtime_keys?(column, %w[options widgets]) &&
              runtime_layout_grid_column_supported?(column)
          end
        end

        def runtime_layout_grid_column_supported?(column)
          options = column.fetch('options', {})
          return false unless runtime_keys?(
            options, %w[desktop tablet phone vertical_alignment class style dynamic_class design]
          )
          return false unless runtime_alignment?(options.fetch('vertical_alignment', 'none'))
          return false unless %w[desktop tablet phone].all? { runtime_grid_weight?(options.fetch(_1, 'grow')) }

          Array(column['widgets']).all? { runtime_nested_widget_supported?(_1) }
        end

        def runtime_nested_widget_supported?(widget)
          return false unless runtime_keys?(
            widget, %w[type name caption options events children body footer header regions slots]
          )
          return false unless widget.key?('type') && widget.key?('name')
          return false if widget.key?('caption')
          return false unless widget.key?('options') && widget['options'].is_a?(Hash)
          return false if widget.key?('events') && !widget['events'].is_a?(Array)
          return false unless %w[children body footer header].all? do |name|
            !widget.key?(name) || runtime_widget_collection_supported?(widget[name])
          end
          return false unless widget.fetch('regions', {}).is_a?(Hash)
          return false unless widget.fetch('regions', {}).values.all? do |widgets|
            runtime_widget_collection_supported?(widgets)
          end

          Array(widget['slots']).all? do |slot|
            runtime_keys?(slot, %w[path role widgets]) && slot.key?('path') && slot.key?('widgets') &&
              slot['path'].is_a?(Array) && slot['path'].all? { _1.is_a?(String) || _1.is_a?(Integer) } &&
              (!slot.key?('role') || slot['role'].is_a?(String)) &&
              runtime_widget_collection_supported?(slot.fetch('widgets'))
          end
        end

        def runtime_widget_collection_supported?(widgets)
          widgets.is_a?(Array) && widgets.all? { runtime_nested_widget_supported?(_1) }
        end
      end
      # rubocop:enable Metrics
    end
  end
end
