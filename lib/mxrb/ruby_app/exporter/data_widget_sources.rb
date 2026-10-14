# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Writes data views, data grids, tables, layout grids and design properties in the widget DSL.
      module DataWidgetSources
        DATA_VIEW_OPTION_KEYS = %w[
          source editable read_only_style label_width show_footer no_entity_message tab_index
          class style dynamic_class visibility editability design_properties unknown_native
        ].freeze

        DATA_VIEW_DECLARATION_KEYS = %w[
          editable read_only_style label_width show_footer no_entity_message tab_index
          class style dynamic_class
        ].freeze

        DATA_VIEW_SOURCE_KEYS = {
          'context' => %w[kind entity variable force_full_objects unknown_native entity_ref_native],
          'association' => %w[
            kind entity steps variable force_full_objects unknown_native entity_ref_native
          ],
          'microflow' => %w[kind name mappings force_full_objects unknown_native settings_native],
          'nanoflow' => %w[kind name mappings force_full_objects unknown_native],
          'listen' => %w[kind target force_full_objects unknown_native],
          'native' => %w[kind native_type force_full_objects unknown_native]
        }.freeze

        DATA_VIEW_CONDITION_KEYS = %w[
          expression roles attribute conditions ignore_security source_variable unknown_native
        ].freeze

        PAGE_VARIABLE_KEYS = %w[kind name sub_key use_all_pages unknown_native].freeze

        DATA_GRID_OPTION_KEYS = %w[
          entity selection page_size pageSize server_side sort toolbar presentation columns_resizable
          columns_draggable columns_hidable xpath on_click_trigger filter_attributes source design
        ].freeze

        DATA_GRID_COLUMN_KEYS = %w[
          attribute caption association_path dynamic_text parameters filter sortable hidable width size alignment
        ].freeze

        private

        def runtime_data_view_supported?(options, widget)
          return false unless runtime_keys?(
            widget, %w[type name options events body footer]
          )
          return false unless runtime_keys?(options, DATA_VIEW_OPTION_KEYS)
          return false unless runtime_data_view_options_supported?(options)
          return false unless Array(widget['events']).empty?
          return false if widget.key?('body') && !runtime_data_view_region_supported?(widget['body'])
          return false if widget.key?('footer') && !runtime_data_view_region_supported?(widget['footer'])

          true
        end

        def runtime_data_view_region_supported?(widgets)
          widgets.is_a?(Array) && widgets.all? do |widget|
            widget.is_a?(Hash) && widget.key?('type')
          end
        end

        def runtime_data_view_options_supported?(options)
          source = options['source']
          return false unless runtime_data_view_source_supported?(source)
          return false unless %w[always never conditional conditionally].include?(options['editable'].to_s)
          return false unless %w[control text inherit].include?(options['read_only_style'].to_s)
          return false unless non_negative_integer?(options['label_width'])
          return false unless non_negative_integer?(options['tab_index'])
          return false unless [true, false].include?(options['show_footer'])
          return false unless options['no_entity_message'].is_a?(String)
          return false unless %w[class style dynamic_class].all? do |name|
            !options.key?(name) || options[name].is_a?(String)
          end
          return false if options.key?('visibility') &&
                          !runtime_data_view_condition_supported?(options['visibility'])
          return false if options.key?('editability') &&
                          !runtime_data_view_condition_supported?(options['editability'])
          return false if options.key?('design_properties') && !options['design_properties'].is_a?(Array)
          return false if options.key?('unknown_native') && !options['unknown_native'].is_a?(Hash)

          true
        end

        def runtime_data_view_source_supported?(source)
          return false unless source.is_a?(Hash)

          kind = source['kind'].to_s
          allowed = DATA_VIEW_SOURCE_KEYS[kind]
          return false unless allowed && runtime_keys?(source, allowed)
          return false unless runtime_page_variable_supported?(source['variable'])
          return false if %w[context association].include?(kind) && source['entity'].to_s.empty?
          return false if %w[microflow nanoflow].include?(kind) && source['name'].to_s.empty?
          return false if kind == 'listen' && source['target'].to_s.empty?
          return false unless runtime_data_view_steps_supported?(source['steps'])
          return false unless runtime_data_view_mappings_supported?(source['mappings'])

          true
        end

        def runtime_page_variable_supported?(variable)
          return true if variable.nil?
          return false unless runtime_keys?(variable, PAGE_VARIABLE_KEYS)

          kind = variable.fetch('kind', 'page_parameter').to_s
          return false unless %w[page_parameter snippet_parameter local_variable widget current].include?(kind)

          kind == 'current' || !variable['name'].to_s.empty?
        end

        def runtime_data_view_steps_supported?(steps)
          return true if steps.nil?

          steps.is_a?(Array) && steps.all? do |step|
            runtime_keys?(step, %w[association entity unknown_native]) &&
              !step['association'].to_s.empty? && !step['entity'].to_s.empty?
          end
        end

        def runtime_data_view_mappings_supported?(mappings)
          return true if mappings.nil?

          mappings.is_a?(Array) && mappings.all? do |mapping|
            runtime_keys?(mapping, %w[parameter expression variable unknown_native]) &&
              !mapping['parameter'].to_s.empty? &&
              runtime_page_variable_supported?(mapping['variable'])
          end
        end

        def runtime_data_view_condition_supported?(condition)
          runtime_keys?(condition, DATA_VIEW_CONDITION_KEYS) &&
            runtime_page_variable_supported?(condition['source_variable']) &&
            (!condition.key?('expression') || condition['expression'].is_a?(String)) &&
            (!condition.key?('attribute') || condition['attribute'].is_a?(String)) &&
            (!condition.key?('roles') ||
              Array(condition['roles']).all? { _1.is_a?(String) }) &&
            (!condition.key?('conditions') || condition['conditions'].is_a?(Array)) &&
            (!condition.key?('ignore_security') ||
              [true, false].include?(condition['ignore_security'])) &&
            (!condition.key?('unknown_native') || condition['unknown_native'].is_a?(Hash))
        end

        def runtime_data_view_source(widget, indentation)
          padding = ' ' * indentation
          options = widget.fetch('options')
          arguments = [widget.fetch('name', '').inspect]
          source = options.fetch('source')
          source_expression = PageDataSources.source_expression(source) || pretty_ruby_value(source, indentation + 2)
          arguments << "from: #{source_expression}"
          DATA_VIEW_DECLARATION_KEYS.each do |name|
            next unless options.key?(name)

            keyword = name == 'class' ? 'class_name' : name
            arguments << "#{keyword}: #{pretty_ruby_value(options.fetch(name), indentation + 2)}"
          end
          body = runtime_data_view_body_source(widget, options, indentation + 2)
          declaration = runtime_widget_declaration('data_view', arguments, indentation, !body.empty?)
          return declaration if body.empty?

          "#{declaration}\n#{body.join("\n")}\n#{padding}end"
        end

        def runtime_data_view_body_source(widget, options, indentation)
          lines = %w[body footer].filter_map do |name|
            next unless widget.key?(name)

            runtime_named_widget_region_source(
              name, widget.fetch(name), indentation, generic_sink: true
            )
          end
          %w[visibility editability].each do |name|
            next unless options.key?(name)

            method_name = name == 'visibility' ? 'visible_when' : 'editable_when'
            lines << runtime_data_view_condition_source(
              method_name, options.fetch(name), indentation
            )
          end
          if options.key?('design_properties')
            properties = options.fetch('design_properties')
            if runtime_design_properties_supported?(properties)
              properties.each do |value|
                lines << runtime_design_property_source(value, indentation)
              end
            else
              arguments = properties.map { pretty_ruby_value(_1, indentation + 2) }
              lines << runtime_widget_declaration('design_properties', arguments, indentation, false)
            end
          end
          if options.key?('unknown_native')
            lines << runtime_widget_declaration(
              'unknown_native', [pretty_ruby_value(options.fetch('unknown_native'), indentation + 2)],
              indentation, false
            )
          end
          lines
        end

        def runtime_design_properties_supported?(properties)
          properties.any? && properties.all? do |value|
            runtime_design_property_supported?(value)
          end
        end

        def runtime_design_property_supported?(value)
          return false unless value.is_a?(Hash)
          return false unless value.values_at('id', 'key', 'value_id').all? { _1.is_a?(String) && !_1.empty? }

          if value.key?('option')
            value.keys.sort == %w[id key option value_id] && value.fetch('option').is_a?(String)
          elsif value.key?('toggle')
            value.keys.sort == %w[id key toggle value_id] && value.fetch('toggle') == true
          elsif value.key?('properties')
            value.keys.sort == %w[id key properties value_id] &&
              value.fetch('properties').is_a?(Array) && value.fetch('properties').any? &&
              value.fetch('properties').all? { runtime_design_property_supported?(_1) }
          else
            false
          end
        end

        def runtime_design_property_source(value, indentation)
          arguments = [value.fetch('key').inspect]
          if value.key?('option')
            arguments << "option: #{value.fetch('option').inspect}"
            return runtime_widget_declaration('design_property', arguments, indentation, false)
          end

          if value.key?('toggle')
            arguments << 'toggle: true'
            return runtime_widget_declaration('design_property', arguments, indentation, false)
          end

          declaration = runtime_widget_declaration('design_property', arguments, indentation, true)
          nested = value.fetch('properties').map do |property|
            runtime_design_property_source(property, indentation + 2)
          end
          [declaration, *nested, "#{' ' * indentation}end"].join("\n")
        end

        def runtime_grid_columns_expression(columns)
          return unless columns.is_a?(Array)

          values = columns.map { runtime_grid_column_expression(_1) }
          return if values.any?(&:nil?)

          "[#{values.join(', ')}]"
        end

        def runtime_grid_column_expression(column)
          return unless column.is_a?(Hash) && column['name'].is_a?(String)
          return unless runtime_keys?(column, %w[name attribute caption filter sortable])

          keywords = column.reject { |key, _value| key == 'name' }.transform_keys(&:to_sym)
          actual = Page::WidgetTree.new.grid_column(column.fetch('name'), **keywords)
          return unless actual == column

          arguments = [column.fetch('name').inspect]
          arguments.concat(keywords.map { |key, value| "#{key}: #{value.inspect}" })
          "grid_column(#{arguments.join(', ')})"
        end

        def runtime_gallery_sort_expression(sort)
          return unless sort.is_a?(Array)

          values = sort.map do |item|
            next unless item.is_a?(Hash) && item.keys.sort == %w[attribute direction]
            next unless item.values.all? { _1.is_a?(String) }

            "sort_by(#{item.fetch('attribute').inspect}, direction: #{item.fetch('direction').inspect})"
          end
          "[#{values.join(', ')}]" unless values.any?(&:nil?)
        end

        def runtime_data_view_condition_source(method_name, condition, indentation)
          arguments = []
          arguments << pretty_ruby_value(condition.fetch('expression'), indentation + 2) if
            condition.key?('expression')
          {
            'roles' => 'roles', 'attribute' => 'attribute', 'conditions' => 'conditions',
            'ignore_security' => 'ignore_security', 'source_variable' => 'source',
            'unknown_native' => 'native'
          }.each do |name, keyword|
            next unless condition.key?(name)

            value = condition.fetch(name)
            source = case name
                     when 'conditions' then runtime_attribute_conditions_source(value)
                     when 'source_variable' then PageDataSources.variable_reference_expression(value)
                     end
            arguments << "#{keyword}: #{source || pretty_ruby_value(value, indentation + 2)}"
          end
          runtime_widget_declaration(method_name, arguments, indentation, false)
        end

        # An input's conditional editability: an expression and/or attribute values,
        # optionally read from another widget's object. nil keeps the generic form.
        def runtime_input_condition_source(condition)
          return unless condition.is_a?(Hash) && condition.any? &&
                        (condition.keys - %w[expression attribute conditions source_variable roles
                                             ignore_security]).empty?
          return unless %w[expression attribute].all? { !condition.key?(_1) || condition[_1].is_a?(String) }
          return unless Array(condition['roles']).all?(String) && [nil, true].include?(condition['ignore_security'])

          arguments = []
          arguments << condition.fetch('expression').inspect if condition.key?('expression')
          return "input_condition(#{arguments.first})" if condition.keys == ['expression']

          arguments << "attribute: #{condition.fetch('attribute').inspect}" if condition.key?('attribute')
          if condition.key?('conditions')
            values = runtime_attribute_conditions_source(condition.fetch('conditions'))
            return unless values

            arguments << "conditions: #{values}"
          end
          if condition.key?('source_variable')
            source = PageDataSources.variable_reference_expression(condition.fetch('source_variable'))
            return unless source

            arguments << "source: #{source}"
          end
          arguments << "roles: #{condition.fetch('roles').inspect}" if condition.key?('roles')
          arguments << 'ignore_security: true' if condition['ignore_security'] == true
          "input_condition(#{arguments.join(', ')})"
        end

        # Attribute values as [value, matches] pairs; model identities are not public.
        def runtime_attribute_conditions_source(conditions)
          return unless conditions.is_a?(Array) && conditions.all? do |condition|
            condition.is_a?(Hash) &&
            (condition.keys - %w[$ID $Type]).sort == %w[AttributeValue EditableVisible] &&
            condition.fetch('$Type', 'Enumerations$Condition') == 'Enumerations$Condition' &&
            condition['AttributeValue'].is_a?(String) && [true, false].include?(condition['EditableVisible'])
          end

          pairs = conditions.map { "[#{_1.fetch('AttributeValue').inspect}, #{_1.fetch('EditableVisible')}]" }
          "[#{pairs.join(', ')}]"
        end

        def non_negative_integer?(value)
          Integer(value) >= 0
        rescue ArgumentError, TypeError
          false
        end

        def runtime_data_grid_supported?(type, options, widget)
          return false unless type == :data_grid
          return false unless runtime_keys?(options, %w[columns] + DATA_GRID_OPTION_KEYS)
          return false unless Array(widget['children']).empty?
          return false unless runtime_dsl_sink_regions_supported?(type, widget)
          return false unless runtime_widget_events_supported?(widget)
          return false if widget.key?('header') && !runtime_widget_collection_supported?(widget['header'])

          Array(options['columns']).all? { runtime_data_grid_column_supported?(_1) }
        end

        def runtime_data_grid_column_supported?(column)
          return false unless runtime_keys?(column, %w[name content] + DATA_GRID_COLUMN_KEYS) && column.key?('name')
          return false if column.key?('content') && !runtime_widget_collection_supported?(column['content'])

          path = column.fetch('association_path', [])
          path.is_a?(Array) && path.all? do |step|
            runtime_keys?(step, %w[association entity]) && %w[association entity].all? { step[_1].is_a?(String) }
          end
        end

        def runtime_data_grid_source(widget, indentation)
          padding = ' ' * indentation
          options = widget.fetch('options')
          arguments = [widget.fetch('name', '').inspect]
          DATA_GRID_OPTION_KEYS.each do |name|
            next unless options.key?(name)

            value = options.fetch(name)
            source = runtime_gallery_sort_expression(value) if name == 'sort'
            source = runtime_design_expression(value) if name == 'design'
            source = PageDataSources.source_expression(value) if name == 'source'
            arguments << "#{name}: #{source || pretty_ruby_value(value, indentation + 2)}"
          end
          lines = [runtime_widget_declaration('data_grid', arguments, indentation, true)]
          if widget.key?('header')
            lines << "#{padding}  header do"
            lines << runtime_widget_dsl_source(widget.fetch('header'), indentation + 4, generic_sink: true)
            lines << "#{padding}  end"
          end
          Array(options['columns']).each { lines.concat(runtime_data_grid_column_source(_1, indentation + 2)) }
          events = runtime_widget_event_source(widget, indentation + 2)
          lines << events unless events.empty?
          lines << "#{padding}end"
          lines.join("\n")
        end

        def runtime_data_grid_column_source(column, indentation)
          arguments = [column.fetch('name').inspect]
          DATA_GRID_COLUMN_KEYS.each do |name|
            next unless column.key?(name)

            value = column.fetch(name)
            source = case name
                     when 'association_path'
                       steps = value.map { "[#{_1.fetch('association').inspect}, #{_1.fetch('entity').inspect}]" }
                       "[#{steps.join(', ')}]"
                     when 'filter' then runtime_grid_filter_expression(value)
                     end
            source ||= pretty_ruby_value(value, indentation + 2)
            arguments << "#{name}: #{source}"
          end
          content = Array(column['content'])
          return [runtime_widget_declaration('column', arguments, indentation, false)] unless column.key?('content')

          [runtime_widget_declaration('column', arguments, indentation, true),
           *([runtime_widget_dsl_source(content, indentation + 2, generic_sink: true)] unless content.empty?),
           "#{' ' * indentation}end"]
        end

        # A column filter as grid_filter(type, operator:); other shapes keep their literal.
        def runtime_grid_filter_expression(filter)
          return unless runtime_keys?(filter, %w[type operator]) && filter['type'].is_a?(String)
          return "grid_filter(#{filter.fetch('type').to_sym.inspect})" unless filter.key?('operator')
          return unless filter['operator'].is_a?(String)

          "grid_filter(#{filter.fetch('type').to_sym.inspect}, operator: #{filter.fetch('operator').to_sym.inspect})"
        end

        def runtime_keys?(value, allowed)
          value.is_a?(Hash) && (value.keys.map(&:to_s) - allowed).empty?
        end

        def runtime_alignment?(value)
          %w[none start center end].include?(value.to_s)
        end

        def runtime_grid_weight?(value)
          %w[grow auto].include?(value.to_s) || (1..12).cover?(Integer(value))
        rescue ArgumentError, TypeError
          false
        end

        def runtime_table_source(widget, indentation)
          padding = ' ' * indentation
          options = widget.fetch('options')
          arguments = [widget.fetch('name', '').inspect]
          arguments << "width_unit: #{options.fetch('width_unit').to_sym.inspect}" if
            options.fetch('width_unit', 'weight').to_s != 'weight'
          arguments << "tab_index: #{options.fetch('tab_index').to_i}" if options.fetch('tab_index', 0).to_i != 0
          append_runtime_appearance(arguments, options)
          lines = [runtime_widget_declaration('table', arguments, indentation, true)]
          Array(options['columns']).each do |column|
            lines << "#{padding}  column width: #{column.fetch('width').to_i}"
          end
          Array(options['rows']).each do |row|
            lines.concat(runtime_table_row_source(row, indentation + 2))
          end
          lines << "#{padding}end"
          lines.join("\n")
        end

        def runtime_table_row_source(row, indentation)
          padding = ' ' * indentation
          arguments = []
          append_runtime_appearance(arguments, row.fetch('options', {}))
          declaration = runtime_widget_declaration('row', arguments, indentation, true)
          lines = [declaration]
          cursor = 0
          Array(row['cells']).each do |cell|
            lines.concat(runtime_table_cell_source(cell, indentation + 2, cursor))
            cursor = cell.fetch('column', cursor).to_i + [cell.fetch('colspan', 1).to_i, 1].max
          end
          lines << "#{padding}end"
        end

        def runtime_table_cell_source(cell, indentation, cursor)
          padding = ' ' * indentation
          arguments = []
          column = cell.fetch('column', cursor).to_i
          arguments << "column: #{column}" unless column == cursor
          arguments << "colspan: #{cell.fetch('colspan').to_i}" if cell.fetch('colspan', 1).to_i > 1
          arguments << "rowspan: #{cell.fetch('rowspan').to_i}" if cell.fetch('rowspan', 1).to_i > 1
          arguments << 'header: true' if cell['header'] == true
          append_runtime_appearance(arguments, cell.fetch('options', {}))
          widgets = Array(cell['widgets'])
          declaration = runtime_widget_declaration('cell', arguments, indentation, !widgets.empty?)
          return [declaration] if widgets.empty?

          [declaration, runtime_widget_dsl_source(widgets, indentation + 2, generic_sink: true),
           "#{padding}end"]
        end

        def runtime_layout_grid_source(widget, indentation)
          padding = ' ' * indentation
          options = widget.fetch('options')
          arguments = [widget.fetch('name', '').inspect]
          arguments << "width: #{options.fetch('width').to_sym.inspect}" if
            options.fetch('width', 'full').to_s != 'full'
          arguments << "tab_index: #{options.fetch('tab_index').to_i}" if options.fetch('tab_index', 0).to_i != 0
          append_runtime_appearance(arguments, options)
          lines = [runtime_widget_declaration('layout_grid', arguments, indentation, true)]
          Array(options['rows']).each do |row|
            lines.concat(runtime_layout_grid_row_source(row, indentation + 2))
          end
          lines << "#{padding}end"
          lines.join("\n")
        end

        def runtime_layout_grid_row_source(row, indentation)
          padding = ' ' * indentation
          options = row.fetch('options', {})
          arguments = []
          %w[horizontal_alignment vertical_alignment].each do |name|
            value = options.fetch(name, 'none')
            arguments << "#{name}: #{value.to_sym.inspect}" unless value.to_s == 'none'
          end
          arguments << 'gutters: false' if options['gutters'] == false
          append_runtime_appearance(arguments, options)
          columns = Array(row['columns'])
          declaration = runtime_widget_declaration('row', arguments, indentation, !columns.empty?)
          return [declaration] if columns.empty?

          lines = [declaration]
          columns.each { lines.concat(runtime_layout_grid_column_source(_1, indentation + 2)) }
          lines << "#{padding}end"
        end

        def runtime_layout_grid_column_source(column, indentation)
          padding = ' ' * indentation
          options = column.fetch('options', {})
          arguments = %w[desktop tablet phone].filter_map do |viewport|
            value = options.fetch(viewport, 'grow')
            next if value.to_s == 'grow'

            "#{viewport}: #{value.to_s == 'auto' ? value.to_sym.inspect : value.to_i}"
          end
          alignment = options.fetch('vertical_alignment', 'none')
          arguments << "vertical_alignment: #{alignment.to_sym.inspect}" unless alignment.to_s == 'none'
          append_runtime_appearance(arguments, options)
          widgets = Array(column['widgets'])
          declaration = runtime_widget_declaration('column', arguments, indentation, !widgets.empty?)
          return [declaration] if widgets.empty?

          [declaration, runtime_widget_dsl_source(widgets, indentation + 2, generic_sink: true),
           "#{padding}end"]
        end

        def append_runtime_appearance(arguments, options)
          %w[style dynamic_class visible].each do |name|
            arguments << "#{name}: #{options.fetch(name).inspect}" unless options[name].to_s.empty?
          end
          arguments << "class_name: #{options.fetch('class').inspect}" unless options['class'].to_s.empty?
          arguments << "design: #{runtime_design_expression(options.fetch('design'))}" if options.key?('design')
        end

        def runtime_keywords_safe?(options)
          reserved = %w[events options class_name]
          options.keys.all? do |key|
            raw = key.to_s
            keyword = raw == 'class' ? 'class_name' : raw
            keyword.match?(/\A[a-z_]\w*\z/) && !reserved.include?(raw)
          end
        end

        def runtime_widget_declaration(method_name, arguments, indentation, block)
          padding = ' ' * indentation
          invocation = [method_name, arguments.join(', ')].reject(&:empty?).join(' ')
          positional_hash = arguments.one? && arguments.first.lstrip.start_with?('{')
          single_line = if positional_hash
                          "#{padding}#{method_name}(#{arguments.first})"
                        else
                          "#{padding}#{invocation}"
                        end
          return "#{single_line}#{' do' if block}" if
            arguments.none? { _1.include?("\n") } && single_line.length <= 100

          invocation = arguments.each_with_index.map do |argument, index|
            suffix = index == arguments.length - 1 ? '' : ','
            "#{padding}  #{argument}#{suffix}"
          end.join("\n")
          "#{padding}#{method_name}(\n#{invocation}\n#{padding})#{' do' if block}"
        end

        # design_values(Size: "Large", "Row gap": "M", Spacing: design_sides("margin-top": "M"))
        def runtime_design_expression(design, helper: 'design_values')
          pairs = design.map do |property, value|
            source = value.is_a?(Hash) ? runtime_design_expression(value, helper: 'design_sides') : value.inspect
            key = property.to_s.match?(/\A[A-Za-z_]\w*\z/) ? property.to_s : property.to_s.inspect
            "#{key}: #{source}"
          end
          "#{helper}(#{pairs.join(', ')})"
        end

        def pretty_ruby_value(value, continuation_indent)
          source = PP.pp(value, +'', 100).chomp
          source.gsub("\n", "\n#{' ' * continuation_indent}")
        end
      end
      # rubocop:enable Metrics
    end
  end
end
