# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    PageBundle = Data.define(:qualified_name, :source, :unsupported_widgets, :unsupported_custom_widgets)

    # Converts the web-page subset of the source model into a Runtime-loadable ES module.
    # rubocop:disable Metrics, Style/MultilineBlockChain
    class PageBundleCompiler
      include ModelValues

      def initialize(source)
        @source = source
        @unsupported = []
        @unsupported_custom = []
        @data_view_scopes = []
        @list_scopes = []
        @snippet_scopes = []
        @snippet_stack = []
        @snippet_documents = []
        @uses_conditional = false
        @uses_dynamic_class = false
      end

      def compile(unit)
        prepare_compile(unit, 'p')
        build_bundle(module_source(page_content))
      end

      def compile_layout(unit)
        prepare_compile(unit, 'l')
        @layout_mode = true
        widgets = array(unit.document.dig('Content', 'Widgets'))
        build_bundle(layout_module_source(children(widgets)))
      end

      private

      def prepare_compile(unit, prefix)
        @unit = unit
        @qualified_name = "#{unit.module_name}.#{unit.document['Name']}"
        @scope_prefix = prefix
        @layout_mode = false
        @data_view_scopes = []
        @list_scopes = []
        @snippet_scopes = []
        @snippet_stack = []
        @snippet_documents = []
        @generic_widgets = {}
        @nanoflow_programs = NanoflowProgramCompiler.new(@source)
      end

      def build_bundle(source)
        PageBundle.new(
          qualified_name: @qualified_name, source:,
          unsupported_widgets: @unsupported.uniq.sort.freeze,
          unsupported_custom_widgets: @unsupported_custom.uniq.sort.freeze
        )
      end

      def arguments = array(@unit.document.dig('FormCall', 'Arguments'))

      def page_content
        entries = arguments.map do |argument|
          [slot_name(argument['Parameter']), content_function(array(argument['Widgets']))]
        end
        duplicate = entries.map(&:first).tally.find { |_name, count| count > 1 }&.first
        raise CompilationError, "duplicate page slot #{duplicate.inspect}" if duplicate

        entries.to_h
      end

      def slot_name(parameter)
        name = parameter.to_s
        valid = name.split('.').length >= 2 && name.split('.').all? { present_identifier?(_1) }
        raise CompilationError, "invalid page slot #{parameter.inspect}" unless valid

        name
      end

      def content_function(widgets)
        "renderKey => React.createElement(PageFragment, { renderKey }, #{children(widgets)})"
      end

      def children(widgets) = "[#{widgets.map { render_widget(_1) }.join(', ')}]"

      def render_widget(widget)
        rendered = case widget['$Type']
                   when 'Forms$DivContainer' then render_container(widget)
                   when 'Forms$LayoutGrid' then render_layout_grid(widget)
                   when 'Forms$LayoutGridRow' then render_grid_row(widget)
                   when 'Forms$LayoutGridColumn' then render_grid_column(widget)
                   when 'Forms$Table' then render_table(widget)
                   when 'Forms$DynamicText' then render_text(widget)
                   when 'Forms$Title' then render_title(widget)
                   when 'Forms$ActionButton' then render_action_button(widget)
                   when 'Forms$DataView' then render_data_view(widget)
                   when 'Forms$ListView' then render_list_view(widget)
                   when 'Forms$TextBox' then render_text_box(widget)
                   when 'Forms$TextArea' then render_text_area(widget)
                   when 'Forms$DatePicker' then render_date_picker(widget)
                   when 'Forms$CheckBox' then render_check_box(widget)
                   when 'Forms$RadioButtonGroup' then render_radio_button_group(widget)
                   when 'Forms$FileManager' then render_file_manager(widget)
                   when 'Forms$GroupBox' then render_group_box(widget)
                   when 'Forms$SnippetCallWidget' then render_snippet_call(widget)
                   when 'Forms$Label' then render_label(widget)
                   when 'Forms$TabControl' then render_tab_control(widget)
                   when 'Forms$StaticImageViewer' then render_static_image(widget)
                   when 'Forms$ScrollContainer' then render_scroll_container(widget)
                   when 'Forms$Placeholder' then render_placeholder(widget)
                   when 'Forms$SidebarToggleButton' then render_sidebar_toggle(widget)
                   when 'Forms$Header' then render_header(widget)
                   when 'Forms$NavigationTree' then render_menu(widget, 'NavigationTree')
                   when 'Forms$MenuBar' then render_menu(widget, 'MenuBar')
                   when 'Forms$SimpleMenuBar' then render_menu(widget, 'SimpleMenuBar')
                   when 'CustomWidgets$CustomWidget' then render_custom_widget(widget)
                   else render_unsupported(widget)
                   end
        rendered = wrap_dynamic_classes(widget, rendered)
        wrap_conditional_visibility(widget, rendered)
      end

      def render_layout_grid(widget)
        render_element('div', widget, array(widget['Rows']), 'mx-layoutgrid mx-layoutgrid-fluid')
      end

      def render_grid_row(widget)
        render_element('div', widget, array(widget['Columns']), 'row')
      end

      def render_grid_column(widget)
        classes = ['col', grid_weight_class('md', widget['Weight']),
                   grid_weight_class('sm', widget['TabletWeight']),
                   grid_weight_class('xs', widget['PhoneWeight'])].compact.join(' ')
        render_element('div', widget, array(widget['Widgets']), classes)
      end

      def render_table(widget)
        cells = array(widget['Cells']).group_by { integer_or(_1['TopRowIndex'], 0) }
        rows = array(widget['Rows']).map.with_index do |row, index|
          content = cells.fetch(index, []).sort_by { integer_or(_1['LeftColumnIndex'], 0) }
                                          .map { render_table_cell(_1) }
          props = common_props(row).merge(className: css_class(row))
          "React.createElement(\"tr\", #{js_props(props)}, [#{content.join(', ')}])"
        end
        props = common_props(widget).merge(
          className: ['mx-table', css_class(widget)].reject(&:empty?).join(' ')
        )
        body = "React.createElement(\"tbody\", null, [#{rows.join(', ')}])"
        "React.createElement(\"table\", #{js_props(props)}, #{body})"
      end

      def render_table_cell(cell)
        tag = cell['IsHeader'] == true ? 'th' : 'td'
        props = common_props(cell).merge(
          className: css_class(cell),
          colSpan: positive_integer(cell['Width'], 1), rowSpan: positive_integer(cell['Height'], 1),
          'data-column-index': integer_or(cell['LeftColumnIndex'], 0)
        )
        content = children(array(cell['Widgets']))
        "React.createElement(#{JSON.generate(tag)}, #{js_props(props)}, #{content})"
      end

      def integer_or(value, fallback)
        Integer(value)
      rescue ArgumentError, TypeError
        fallback
      end

      def render_scroll_container(widget)
        @uses_layout_widgets = true
        props = common_props(widget).merge(
          '$widgetId': widget_key(widget), class: css_class(widget),
          scrollPerRegion: widget['ScrollBehavior'] == 'PerRegion',
          layoutMode: widget['LayoutMode'].to_s.downcase,
          top: scroll_region(widget['Top']), bottom: scroll_region(widget['Bottom']),
          left: scroll_region(widget['Left']), right: scroll_region(widget['Right']),
          center: scroll_region(widget['CenterRegion'])
        )
        "React.createElement($ScrollContainer, #{js_literal(props)})"
      end

      def scroll_region(region)
        return { enabled: false } unless region

        {
          enabled: true, content: raw_js(children(array(region['Widgets']))),
          sizeMode: region['SizeMode'].to_s.downcase, sizeValue: region['Size'],
          class: region.dig('Appearance', 'Class').to_s,
          toggleMode: region['ToggleMode'].to_s.downcase,
          initiallyOpen: !region['ToggleMode'].to_s.include?('InitiallyClosed')
        }
      end

      def render_placeholder(widget)
        @uses_layout_widgets = true
        key = widget_key(widget)
        identifier = "#{@qualified_name}.#{widget['Name']}"
        "React.createElement($Placeholder, #{js_props(
          common_props(widget).merge('$widgetId': key),
          expressions: { content: "PlaceholderProperty({ id: #{JSON.generate(identifier)} })" }
        )})"
      end

      def render_sidebar_toggle(widget)
        @uses_layout_widgets = true
        key = widget_key(widget)
        props = common_props(widget).merge(
          '$widgetId': key, buttonId: key, class: css_class(widget),
          renderType: 'button', buttonClass: button_style(widget)
        )
        "React.createElement($SidebarToggle, #{js_props(props)})"
      end

      def render_header(widget)
        @uses_layout_widgets = true
        props = common_props(widget).merge(
          '$widgetId': widget_key(widget), class: css_class(widget), content: [],
          leftWidgets: array(widget['LeftWidgets']).map { render_widget(_1) },
          rightWidgets: array(widget['RightWidgets']).map { render_widget(_1) }
        )
        "React.createElement($Header, #{js_props(props)})"
      end

      def render_menu(widget, component)
        items = menu_items(widget['MenuSource'])
        return render_unsupported(widget) unless items

        @uses_layout_widgets = true
        props = common_props(widget).merge(
          '$widgetId': widget_key(widget), class: css_class(widget),
          menu: items.map.with_index { |item, index| compile_menu_item(item, widget, [index]) }
        )
        props[:orientation] = widget['Orientation'].to_s.downcase if component == 'SimpleMenuBar'
        "React.createElement($#{component}, #{js_literal(props)})"
      end

      def menu_items(source)
        case source&.fetch('$Type', nil)
        when 'Forms$MenuDocumentSource'
          qualified = source['Menu'].to_s
          unit = @source.units_of('Menus$MenuDocument').find do |candidate|
            "#{candidate.module_name}.#{candidate.document['Name']}" == qualified
          end
          array(unit.document.dig('ItemCollection', 'Items')) if unit
        when 'Forms$NavigationSource'
          profile = @source.units_of('Navigation$NavigationDocument').flat_map do |unit|
            array(unit.document['Profiles'])
          end.find { _1['Name'] == source['NavigationProfile'] }
          array(profile.dig('Menu', 'Items')) if profile
        end
      end

      def compile_menu_item(item, widget, path)
        result = {
          caption: raw_js("TextProperty({ value: #{JSON.generate(translated_text(item['Caption']))} })")
        }
        action = menu_action_config(item['Action'] || {})
        result[:action] = raw_js("ActionProperty(#{js_literal(action)})") if action
        icon = menu_icon_property(item['Icon'])
        result[:icon] = raw_js(icon) if icon
        nested_items = array(item['Items'])
        unless nested_items.empty?
          result[:items] = nested_items.map.with_index do |child, index|
            compile_menu_item(child, widget, path + [index])
          end
        end
        result
      end

      def menu_action_config(action)
        payload = open_page_config(action) || menu_microflow_config(action)
        return unless payload

        { action: payload, skipClientValidation: true }
      end

      def menu_microflow_config(action)
        return unless action['$Type'] == 'Forms$MicroflowAction'

        name = action.dig('MicroflowSettings', 'Microflow').to_s
        return unless present_identifier?(name) && microflow_argument_map(action['MicroflowSettings'] || {}) == {}

        {
          type: 'callMicroflow', argMap: {},
          config: {
            operationId: WebOperationCompiler.menu_operation_id(action), validate: 'view',
            allowedRoles: allowed_roles_for('Microflows$Microflow', name)
          },
          disabledDuringExecution: action.fetch('DisabledDuringExecution', true)
        }
      end

      def menu_icon_property(icon)
        reference = icon&.fetch('Image', '').to_s
        name = reference.split('.').last
        return if name.to_s.empty?

        css = name.gsub(/([a-z\d])([A-Z])/, '\\1-\\2').tr('_', '-').downcase
        "WebIconProperty({ icon: { type: \"icon\", iconClass: \"mx-icon-filled mx-icon-#{css}\" } })"
      end

      def grid_weight_class(size, weight)
        value = Integer(weight || -1)
        "col-#{size}-#{value}" if (1..12).cover?(value)
      end

      def render_element(tag, widget, widgets, base_class)
        props = common_props(widget).merge(
          className: [base_class, css_class(widget)].reject(&:empty?).join(' '),
          children: widgets.map { render_widget(_1) }
        )
        "React.createElement(#{JSON.generate(tag)}, #{js_props(props)})"
      end

      def render_custom_widget(widget)
        grid = DataGridBundleCompiler.new(
          @source, @qualified_name, widget,
          render_widgets: ->(widgets, scope, entity) { render_scoped_widgets(widgets, scope, entity) }
        )
        if grid.supported?
          @uses_data_grid = true
          return grid.render
        end

        gallery = GalleryBundleCompiler.new(@source, @qualified_name, widget)
        if gallery.supported?
          @uses_gallery = true
          nano_reference = nanoflow_reference(gallery.data_source.nanoflow_name) if gallery.data_source.nanoflow?
          return render_unsupported(widget) if gallery.data_source.nanoflow? && !nano_reference

          @list_scopes << { scope: gallery.widget_key, entity: gallery.entity_name }
          content = children(gallery.content_widgets)
          @list_scopes.pop
          return gallery.render(content, nanoflow_reference: nano_reference)
        end

        object_scope = current_object_scope
        image = ImageBundleCompiler.new(
          @source, @qualified_name, widget,
          scope: object_scope&.fetch(:scope, nil), entity: object_scope&.fetch(:entity, nil),
          key_prefix: @scope_prefix,
          action_property: lambda do |action|
            config = client_action_config(widget, action)
            "ActionProperty(#{js_literal(config)})" if config
          end
        )
        if image.supported?
          @uses_image = true
          @uses_custom_image = true
          return image.render
        end

        combo = ComboBoxBundleCompiler.new(
          @source, @qualified_name, widget,
          scope: scope_name(@data_view_scopes.last), entity: @data_view_scopes.last&.fetch(:entity, nil)
        )
        if combo.supported?
          @uses_form_widgets = true
          @uses_combo_box = true
          return combo.render
        end

        generic = GenericWidgetBundleCompiler.new(
          @source, @qualified_name, widget,
          scope: object_scope&.fetch(:scope, nil), entity: object_scope&.fetch(:entity, nil),
          render_widgets: ->(widgets) { raw_js(children(widgets)) }, key_prefix: @scope_prefix,
          action_property: lambda do |action|
            config = if nanoflow_action?(action)
                       nanoflow_action_config(action)
                     else
                       client_action_config(widget, action)
                     end
            "ActionProperty(#{js_literal(config)})" if config
          end
        )
        return render_unsupported(widget) unless generic.supported?

        @generic_widgets[generic.component_name] = generic.module_path
        generic.render
      end

      def render_scoped_widgets(widgets, scope, entity)
        @list_scopes << { scope:, entity: }
        children(widgets)
      ensure
        @list_scopes.pop
      end

      def render_container(widget)
        action = widget['OnClickAction'] || {}
        action_config = container_action_config(widget, action)
        return render_action_container(widget, action_config) if action_config

        props = common_props(widget).merge(
          className: css_class(widget), children: array(widget['Widgets']).map { render_widget(_1) }
        )
        handler = action_handler(action) if action['$Type'] && action['$Type'] != 'Forms$NoAction'
        props[:role] = 'button' if handler
        "React.createElement(#{JSON.generate(render_mode(widget))}, " \
          "#{js_props(props, expressions: { onClick: handler }.compact)})"
      end

      def render_action_container(widget, action_config)
        @uses_form_widgets = true
        @uses_container = true
        key = widget_key(widget)
        props = common_props(widget).merge(
          '$widgetId': key, class: css_class(widget), renderMode: render_mode(widget),
          content: array(widget['Widgets']).map { render_widget(_1) }
        )
        "React.createElement($Container, #{js_props(props, expressions: {
          onClick: "ActionProperty(#{js_literal(action_config)})"
        })})"
      end

      def container_action_config(widget, action)
        return nanoflow_action_config(action) if nanoflow_action?(action)

        client_action_config(widget, action)
      end

      def render_text(widget)
        return render_bound_text(widget) if bound_text_attributes(widget)

        props = common_props(widget).merge(className: css_class(widget))
        caption = translated_text(widget.dig('Content', 'Template'))
        "React.createElement(#{JSON.generate(text_mode(widget))}, #{js_props(props)}, #{JSON.generate(caption)})"
      end

      def render_title(widget)
        props = common_props(widget).merge(className: css_class(widget))
        "React.createElement(\"h1\", #{js_props(props)}, #{JSON.generate(page_title)})"
      end

      def render_group_box(widget)
        @uses_form_widgets = true
        @uses_group_box = true
        collapsible = case widget['Collapsible']
                      when 'YesInitiallyCollapsed' then 'yes'
                      when 'YesInitiallyExpanded' then 'expanded'
                      else 'no'
                      end
        props = common_props(widget).merge(
          '$widgetId': widget_key(widget), class: css_class(widget), id: widget_key(widget),
          renderMode: render_mode('RenderMode' => widget['HeaderMode']), collapsible:,
          content: array(widget['Widgets']).map { render_widget(_1) }
        )
        caption = translated_text(widget.dig('CaptionTemplate', 'Template'))
        "React.createElement($GroupBox, #{js_props(props, expressions: {
          header: "TextProperty({ value: #{JSON.generate(caption)} })"
        })})"
      end

      def render_snippet_call(widget)
        qualified = widget.dig('FormCall', 'Form').to_s
        snippet = snippet_index[qualified]
        return render_unsupported(widget) unless snippet && !@snippet_stack.include?(qualified)

        @snippet_stack << qualified
        @snippet_documents << snippet.document
        @snippet_scopes << snippet_scope_map(snippet.document)
        rendered = children(array(snippet.document['Widgets']))
        @snippet_scopes.pop
        @snippet_documents.pop
        @snippet_stack.pop
        "React.createElement(React.Fragment, #{js_props(common_props(widget))}, #{rendered})"
      ensure
        if @snippet_stack.last == qualified
          @snippet_scopes.pop
          @snippet_documents.pop
          @snippet_stack.pop
        end
      end

      def snippet_scope_map(document)
        scope = current_object_scope
        return {} unless scope

        object_parameters = array(document['Parameters']).select do |parameter|
          parameter.dig('ParameterType', '$Type') == 'DataTypes$ObjectType'
        end
        object_parameters.to_h { [_1['Name'].to_s, scope] }
      end

      def snippet_index
        @snippet_index ||= @source.units_of('Forms$Snippet').to_h do |unit|
          ["#{unit.module_name}.#{unit.document['Name']}", unit]
        end
      end

      def render_bound_text(widget)
        scope = current_object_scope
        attributes = bound_text_attributes(widget)
        parameters = array(widget.dig('Content', 'Parameters'))
        @uses_bound_text = true
        expressions = attributes.map.with_index do |attribute, index|
          ["value#{index + 1}".to_sym, bound_text_value(scope, attribute, parameters[index])]
        end.to_h
        "React.createElement($MxrbFormattedText, #{js_props(bound_text_props(widget), expressions:)})"
      end

      def bound_text_value(scope, attribute, parameter)
        entity, _, name = attribute.rpartition('.')
        attribute_property(scope.fetch(:scope), entity, name, path: attribute_reference_path(parameter))
      end

      def attribute_reference_path(parameter)
        steps = array(parameter&.dig('AttributeRef', 'EntityRef', 'Steps'))
        steps.flat_map { [_1['Association'], _1['DestinationEntity']] }
             .select { present_identifier?(_1) }.join('/')
      end

      def bound_text_props(widget)
        common_props(widget).merge(
          '$widgetId': widget_key(widget), class: css_class(widget), renderMode: text_mode(widget),
          template: translated_text(widget.dig('Content', 'Template'))
        )
      end

      def bound_text_attributes(widget)
        return unless current_object_scope

        parameters = array(widget.dig('Content', 'Parameters'))
        return if parameters.empty?

        attributes = parameters.map { text_parameter_attribute(_1) }
        attributes if attributes.all?
      end

      def text_parameter_attribute(parameter)
        attribute = parameter.dig('AttributeRef', 'Attribute').to_s
        return attribute if qualified_attribute?(attribute)

        match = parameter['Expression'].to_s.match(
          %r{\A(?:toString\()?\$currentObject/([A-Za-z_]\w*)\)?\z}
        )
        entity = current_object_scope&.fetch(:entity, '').to_s
        return unless match && present_identifier?(entity)

        "#{entity}.#{match[1]}"
      end

      def qualified_attribute?(attribute)
        entity, separator, name = attribute.rpartition('.')
        separator == '.' && present_identifier?(entity) && present_identifier?(name)
      end

      def current_object_scope
        scope = @list_scopes.last || @data_view_scopes.last
        return scope if scope.is_a?(Hash)
        return unless scope

        { scope:, entity: '' }
      end

      def scope_name(scope) = scope.is_a?(Hash) ? scope[:scope] : scope

      def wrap_conditional_visibility(widget, rendered)
        condition = conditional_visibility(widget['ConditionalVisibilitySettings'])
        return rendered unless condition

        @uses_conditional = true
        attributes, predicate = condition
        expressions = attributes.map.with_index do |attribute, index|
          entity, _, name = attribute.rpartition('.')
          ["value#{index + 1}".to_sym,
           attribute_property(current_object_scope.fetch(:scope), entity, name)]
        end.to_h.merge(test: "props => #{predicate}")
        visibility_key = "#{widget_key(widget)}$visibility"
        props = common_props(widget).merge(key: visibility_key, '$widgetId': visibility_key)
        "React.createElement($MxrbConditional, #{js_props(props, expressions:)}, #{rendered})"
      end

      def conditional_visibility(settings)
        expression = settings&.fetch('Expression', '').to_s.strip
        scope = current_object_scope
        return if expression.empty? || scope.nil? || !present_identifier?(scope[:entity])

        attributes = []
        predicate = visibility_logical(expression, attributes)
        [attributes, predicate] if predicate
      end

      def visibility_logical(expression, attributes)
        parts = expression.split(/\s+or\s+/i)
        return logical_predicate(parts, attributes, '||') if parts.length > 1

        parts = expression.split(/\s+and\s+/i)
        return logical_predicate(parts, attributes, '&&') if parts.length > 1

        visibility_atom(expression, attributes)
      end

      def logical_predicate(parts, attributes, operator)
        predicates = parts.map { visibility_logical(_1.strip, attributes) }
        return unless predicates.all?

        "(#{predicates.join(" #{operator} ")})"
      end

      def visibility_atom(expression, attributes)
        match = expression.strip.match(
          %r{\A\$currentObject/([A-Za-z_]\w*)(?:\s*(=|!=)\s*(.+))?\z}
        )
        return unless match

        attribute = "#{current_object_scope.fetch(:entity)}.#{match[1]}"
        index = attributes.index(attribute) || attributes.length.tap { attributes << attribute }
        value = "mxrbValue(props.value#{index + 1})"
        return "Boolean(#{value})" unless match[2]

        comparison = visibility_comparison(value, match[3].strip)
        return unless comparison

        match[2] == '!=' ? "!(#{comparison})" : comparison
      end

      def visibility_comparison(value, expected)
        case expected
        when 'empty' then "(#{value} == null || #{value} === \"\")"
        when 'true', 'false' then "#{value} === #{expected}"
        when /\A-?\d+(?:\.\d+)?\z/ then "Number(#{value}) === #{expected}"
        when /\A[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+\z/
          "String(#{value}) === #{JSON.generate(expected.split('.').last)}"
        when /\A'(.*)'\z/m then "String(#{value}) === #{JSON.generate(Regexp.last_match(1))}"
        end
      end

      def wrap_dynamic_classes(widget, rendered)
        expression = widget.dig('Appearance', 'DynamicClasses').to_s.strip
        scope = current_object_scope
        return rendered if expression.empty? || scope.nil? || !present_identifier?(scope[:entity])

        attributes = []
        resolver = dynamic_class_expression(expression, attributes)
        return rendered unless resolver

        @uses_dynamic_class = true
        expressions = attributes.map.with_index do |attribute, index|
          entity, _, name = attribute.rpartition('.')
          ["value#{index + 1}".to_sym, attribute_property(scope.fetch(:scope), entity, name)]
        end.to_h.merge(resolveClass: "props => String(#{resolver} || '').trim()")
        class_key = "#{widget_key(widget)}$class"
        props = common_props(widget).merge(key: class_key, '$widgetId': class_key)
        "React.createElement($MxrbDynamicClass, #{js_props(props, expressions:)}, #{rendered})"
      end

      def dynamic_class_expression(expression, attributes)
        terms = split_dynamic_class_terms(expression)
        compiled = terms.map { dynamic_class_term(_1, attributes) }
        return unless compiled.all?

        compiled.join(' + ')
      end

      def split_dynamic_class_terms(expression)
        parts = []
        start = 0
        depth = 0
        quote = nil
        expression.each_char.with_index do |character, index|
          if quote
            quote = nil if character == quote && expression[index - 1] != '\\'
          elsif ["'", '"'].include?(character)
            quote = character
          elsif character == '('
            depth += 1
          elsif character == ')'
            depth -= 1
          elsif character == '+' && depth.zero?
            parts << expression[start...index].strip
            start = index + 1
          end
        end
        parts << expression[start..].to_s.strip
        parts.reject(&:empty?)
      end

      def dynamic_class_term(term, attributes)
        stripped = unwrap_dynamic_class_parentheses(term.strip)
        quoted = quoted_dynamic_class(stripped)
        return quoted if quoted

        if (match = stripped.match(%r{\A\$currentObject/([A-Za-z_]\w*)\z}))
          return "String(#{dynamic_class_value(match[1], attributes)} ?? '')"
        end

        dynamic_class_conditional(stripped, attributes)
      end

      def quoted_dynamic_class(term)
        match = term.match(/\A'(.*)'\z/m) || term.match(/\A"(.*)"\z/m)
        JSON.generate(match[1]) if match
      end

      def unwrap_dynamic_class_parentheses(term)
        return term unless term.start_with?('(') && term.end_with?(')')

        term[1...-1].strip
      end

      def dynamic_class_conditional(term, attributes)
        match = term.match(/\Aif\s+(.+?)\s+then\s+(.+?)\s+else\s+(.+)\z/m)
        return unless match

        predicate = visibility_logical(match[1].strip, attributes)
        accepted = dynamic_class_expression(match[2].strip, attributes)
        rejected = dynamic_class_expression(match[3].strip, attributes)
        return unless predicate && accepted && rejected

        "(#{predicate} ? #{accepted} : #{rejected})"
      end

      def dynamic_class_value(name, attributes)
        attribute = "#{current_object_scope.fetch(:entity)}.#{name}"
        index = attributes.index(attribute) || attributes.length.tap { attributes << attribute }
        "mxrbValue(props.value#{index + 1})"
      end

      def render_action_button(widget)
        action = widget['Action'] || {}
        return render_data_action_button(widget, action) if data_action?(action)
        return render_nanoflow_action_button(widget, action) if nanoflow_action?(action)
        return render_client_action_button(widget, action) if client_action_config(widget, action)

        caption = translated_text(widget.dig('CaptionTemplate', 'Template'))
        classes = ['btn', 'mx-button', button_style(widget), css_class(widget)].reject(&:empty?).join(' ')
        props = common_props(widget).merge(type: 'button', className: classes)
        handler = action_handler(action)
        props[:disabled] = true unless handler
        "React.createElement(\"button\", #{js_props(props, expressions: { onClick: handler }.compact)}, " \
          "#{JSON.generate(caption)})"
      end

      def render_client_action_button(widget, action)
        @uses_form_widgets = true
        key = widget_key(widget)
        caption = translated_text(widget.dig('CaptionTemplate', 'Template'))
        "React.createElement($ActionButton, #{js_props(nanoflow_button_props(widget, key), expressions: {
          caption: "TextProperty({ value: #{JSON.generate(caption)} })",
          tooltip: 'TextProperty({ value: "" })',
          action: "ActionProperty(#{js_literal(client_action_config(widget, action))})"
        })})"
      end

      def client_action_config(widget, action)
        payload = close_page_config(action) || open_link_config(action) || open_page_config(action) ||
                  create_object_config(widget, action) || sign_out_config(action) ||
                  microflow_config(widget, action)
        return unless payload

        { action: payload, abortOnServerValidation: true }
      end

      def open_page_config(action)
        return unless action['$Type'] == 'Forms$FormAction'

        form = action.dig('FormSettings', 'Form').to_s
        return unless present_identifier?(form)
        return unless parameter_mappings(action['FormSettings'] || {}).empty?

        config = {
          name: "#{form.tr('.', '/')}.page.xml", location: 'content',
          allowedRoles: allowed_roles_for('Forms$Page', form)
        }
        {
          type: 'openPage', argMap: {}, config:,
          disabledDuringExecution: action.fetch('DisabledDuringExecution', true)
        }
      end

      def sign_out_config(action)
        return unless action['$Type'] == 'Forms$SignOutClientAction'

        {
          type: 'signOut', argMap: {}, config: { namedUser: true },
          disabledDuringExecution: action.fetch('DisabledDuringExecution', true)
        }
      end

      def create_object_config(widget, action)
        return unless action['$Type'] == 'Forms$CreateObjectClientAction'

        entity = action.dig('EntityRef', 'Entity').to_s
        form = action.dig('PageSettings', 'Form').to_s
        parameter = target_page_parameter(form, entity)
        target = page_unit(form)
        return unless present_identifier?(entity) && target && parameter

        {
          type: 'createObject', argMap: {},
          config: {
            entity:, operationId: WebOperationCompiler.operation_id(@qualified_name, widget['Name']),
            pageSettings: {
              name: "#{form.tr('.', '/')}.page.xml", location: page_location(target),
              resizable: target.document.fetch('PopupResizable', true),
              allowedRoles: allowed_roles_for('Forms$Page', form)
            },
            allowedRoles: allowed_roles_for('Forms$Page', form),
            objectParameter: "param#{parameter}"
          },
          disabledDuringExecution: action.fetch('DisabledDuringExecution', true)
        }
      end

      def page_location(unit)
        layout_name = unit.document.dig('FormCall', 'Form').to_s
        target_layout = @source.units_of('Forms$Layout').find do |candidate|
          "#{candidate.module_name}.#{candidate.document['Name']}" == layout_name
        end
        popup_layout_document?(target_layout&.document) ? 'modal' : 'content'
      end

      def allowed_roles_for(type, qualified_name)
        unit = @source.units_of(type).find do |candidate|
          "#{candidate.module_name}.#{candidate.document['Name']}" == qualified_name
        end
        module_roles = array(unit&.document&.fetch('AllowedModuleRoles', nil)).map(&:to_s)
        security = @source.documents('Security$ProjectSecurity').first
        array(security&.fetch('UserRoles', nil)).filter_map do |role|
          role['Name'].to_s if (array(role['ModuleRoles']).map(&:to_s) & module_roles).any?
        end
      end

      def close_page_config(action)
        return unless action['$Type'] == 'Forms$ClosePageClientAction'

        { type: 'closePage', argMap: {}, config: {},
          disabledDuringExecution: action.fetch('DisabledDuringExecution', true) }
      end

      def open_link_config(action)
        return unless action['$Type'] == 'Forms$OpenLinkClientAction'

        address = action['Address'] || {}
        config = { schema: action['LinkType'].to_s.downcase }
        arg_map = {}
        if address['IsDynamic'] == true
          attribute = address.dig('AttributeRef', 'Attribute').to_s
          scope = scope_name(@data_view_scopes.last)
          return unless scope && attribute.include?('.')

          config[:addressAttribute] = attribute.sub(/\.([^.]+)\z/, '/\\1')
          arg_map[:'$object'] = { widget: scope, source: 'object' }
        else
          config[:address] = address['Value'].to_s
        end
        { type: 'openLink', argMap: arg_map, config:,
          disabledDuringExecution: action.fetch('DisabledDuringExecution', true) }
      end

      def microflow_config(widget, action)
        return unless action['$Type'] == 'Forms$MicroflowAction'

        settings = action['MicroflowSettings'] || {}
        return unless present_identifier?(settings['Microflow'])

        arg_map = microflow_argument_map(settings)
        return unless arg_map

        {
          type: 'callMicroflow', argMap: arg_map,
          config: { operationId: WebOperationCompiler.operation_id(@qualified_name, widget['Name']) },
          disabledDuringExecution: action.fetch('DisabledDuringExecution', true)
        }
      end

      def microflow_argument_map(settings)
        pairs = parameter_mappings(settings).map { microflow_argument(_1) }
        return pairs.to_h if pairs.any? && pairs.all?
        return unless pairs.empty?

        inferred_microflow_argument_map(settings['Microflow'])
      end

      def inferred_microflow_argument_map(qualified_name)
        scope = current_object_scope
        return {} unless scope && present_identifier?(scope[:entity])

        inferred_microflow_parameters(qualified_name, scope[:entity]).to_h do |parameter|
          [parameter['Name'].to_sym, { widget: scope[:scope], source: 'object' }]
        end
      end

      def inferred_microflow_parameters(qualified_name, entity)
        flow = @source.units_of('Microflows$Microflow').find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == qualified_name
        end
        array(flow&.document&.dig('ObjectCollection', 'Objects')).select do |object|
          object['$Type'] == 'Microflows$MicroflowParameter' &&
            object.dig('VariableType', 'Entity') == entity
        end
      end

      def microflow_argument(mapping)
        name = mapping['Parameter'].to_s.split('.').last
        expression = mapping['Expression'].to_s
        current_scope = current_object_scope&.fetch(:scope)
        scope = if expression == '$currentObject'
                  current_scope
                elsif expression.empty?
                  microflow_variable_scope(mapping['Variable'])
                else
                  expression
                end
        return unless present_identifier?(name) && scope.to_s.match?(/\A\$[A-Za-z_]\w*\z|\Ap\./)

        [name.to_sym, { widget: scope, source: 'object' }]
      end

      def microflow_variable_scope(variable)
        return unless variable

        snippet = variable['SnippetParameter'].to_s
        unless snippet.empty?
          @snippet_scopes.reverse_each do |mapping|
            return mapping.fetch(snippet).fetch(:scope) if mapping.key?(snippet)
          end
        end
        page = variable['PageParameter'].to_s
        return "$#{page}" if present_identifier?(page)

        widget = variable['Widget'].to_s
        target = page_widget(widget)
        return widget_key(target) if present_identifier?(widget) && target

        local = variable['LocalVariable'].to_s
        "$#{local}" if present_identifier?(local)
      end

      def nanoflow_action?(action)
        action['$Type'] == 'Forms$CallNanoflowClientAction' &&
          present_identifier?(action['Nanoflow']) && nanoflow_argument_map(action) &&
          nanoflow_reference(action['Nanoflow'])
      end

      def parameter_mappings(action)
        array(action['ParameterMappings']).select { _1.is_a?(Hash) }
      end

      def render_nanoflow_action_button(widget, action)
        @uses_form_widgets = true
        key = widget_key(widget)
        caption = translated_text(widget.dig('CaptionTemplate', 'Template'))
        "React.createElement($ActionButton, #{js_props(nanoflow_button_props(widget, key), expressions: {
          caption: "TextProperty({ value: #{JSON.generate(caption)} })",
          tooltip: 'TextProperty({ value: "" })',
          action: "ActionProperty(#{js_literal(nanoflow_action_config(action))})"
        })})"
      end

      def nanoflow_button_props(widget, key)
        common_props(widget).merge(
          '$widgetId': key, buttonId: key, class: css_class(widget), renderType: 'button',
          buttonClass: button_style(widget)
        )
      end

      def nanoflow_action_config(action)
        nanoflow = raw_js(nanoflow_reference(action['Nanoflow']))
        {
          action: {
            type: 'callNanoflow', argMap: nanoflow_argument_map(action), config: { nanoflow: },
            disabledDuringExecution: action.fetch('DisabledDuringExecution', true)
          },
          abortOnServerValidation: false, skipClientValidation: false
        }
      end

      def nanoflow_argument_map(action)
        parameter_mappings(action).map { nanoflow_argument(_1) }.then do |pairs|
          pairs.all? ? pairs.to_h : nil
        end
      end

      def nanoflow_argument(mapping)
        name = mapping['Parameter'].to_s.split('.').last
        variable = mapping['Expression'].to_s[/\A\$([A-Za-z_]\w*)\z/, 1]
        return unless present_identifier?(name) && variable

        scope = current_object_scope
        page_parameter = array(@unit.document['Parameters']).any? { _1['Name'] == variable }
        widget = if page_parameter
                   "$#{variable}"
                 elsif scope && variable == scope[:entity].to_s.split('.').last
                   scope[:scope]
                 else
                   "$#{variable}"
                 end
        expression = {
          expr: { type: 'variable', variable: },
          args: { variable.to_sym => { widget:, source: 'object' } }
        }
        [name.to_sym, { expression:, kind: 'object' }]
      end

      def nanoflow_reference(name) = @nanoflow_programs.reference(name.to_s)

      def raw_js(value) = { '$raw' => value }

      def render_data_view(widget)
        @uses_form_widgets = true
        scope = widget_key(widget)
        object = data_view_object_property(widget, scope)
        return render_unsupported(widget) unless object

        @data_view_scopes << { scope:, entity: data_view_entity(widget) }
        body = array(widget['Widgets']).map { render_widget(_1) }
        footer = array(widget['FooterWidgets']).map { render_widget(_1) }
        @data_view_scopes.pop
        props = common_props(widget).merge(
          '$widgetId': scope, class: css_class(widget), body:, footer:,
          hideFooter: !widget.fetch('ShowFooter', true)
        )
        expressions = {
          object:,
          emptyMessage: "TextProperty({ value: #{JSON.generate(translated_text(widget['NoEntityMessage']))} })"
        }
        "React.createElement($DataView, #{js_props(props, expressions:)})"
      end

      def data_view_object_property(widget, scope)
        source = widget['DataSource'] || {}
        return listen_object_property(source, widget) if source['$Type'] == 'Forms$ListenTargetSource'

        source_scope = data_source_scope(source)
        path = entity_ref_path(source['EntityRef'])
        if source_scope
          if path.empty? && source.dig('SourceVariable', 'PageParameter')
            return "AssociationObjectProperty({ scope: #{JSON.generate(source_scope[:scope])}, " \
                   'path: "", editable: true })'
          end
          return association_object_property(source_scope[:scope], path, widget['Name'])
        end
        current_scope = current_object_scope
        return association_object_property(current_scope[:scope], path, widget['Name']) if current_scope && !path.empty?
        return microflow_object_property(source, widget, scope) if source['$Type'] == 'Forms$MicroflowSource'
        return nanoflow_object_property(source, scope) if source['$Type'] == 'Forms$NanoflowSource'

        nil
      end

      def listen_object_property(source, widget)
        target_name = source['ListenTarget'].to_s
        target = page_widget(target_name)
        return unless present_identifier?(target_name) && target

        @uses_listen_object = true
        config = {
          listenTo: widget_key(target), editable: true,
          operationId: WebOperationCompiler.operation_id(@qualified_name, widget['Name'])
        }
        "ListenObjectProperty(#{js_literal(config)})"
      end

      def page_widget(name)
        roots = [*@snippet_documents.reverse, @unit.document]
        roots.each do |root|
          widget = all_page_widgets(root).find { _1['Name'] == name }
          return widget if widget
        end
        nil
      end

      def all_page_widgets(value, result = [])
        case value
        when Hash
          result << value if value['$Type'].to_s.start_with?('Forms$', 'CustomWidgets$')
          value.each_value { all_page_widgets(_1, result) }
        when Array then value.each { all_page_widgets(_1, result) }
        end
        result
      end

      def data_view_entity(widget)
        source = widget['DataSource'] || {}
        if source['$Type'] == 'Forms$ListenTargetSource'
          target = page_widget(source['ListenTarget'].to_s)
          return target ? WebListDataSource.new(@source, target).entity : ''
        end

        entity = entity_ref_destination(source['EntityRef'])
        return entity unless entity.empty?

        parameter = source.dig('SourceVariable', 'PageParameter').to_s
        page_parameter = array(@unit.document['Parameters']).find { _1['Name'] == parameter }
        page_parameter&.dig('ParameterType', 'Entity').to_s.then do |parameter_entity|
          parameter_entity.empty? ? flow_return_entity(source) : parameter_entity
        end
      end

      def data_source_scope(source)
        variable = source['SourceVariable'] || {}
        parameter = variable['PageParameter'].to_s
        return { scope: "$#{parameter}" } if present_identifier?(parameter)

        snippet_parameter = variable['SnippetParameter'].to_s
        return unless present_identifier?(snippet_parameter)

        @snippet_scopes.reverse_each do |mapping|
          return mapping[snippet_parameter] if mapping.key?(snippet_parameter)
        end
        nil
      end

      def association_object_property(source_scope, path, widget_name)
        @uses_association_object = true
        config = { scope: source_scope, path:, editable: true }
        config[:operationId] = WebOperationCompiler.operation_id(@qualified_name, widget_name) unless path.empty?
        "AssociationObjectProperty(#{js_literal(config)})"
      end

      def microflow_object_property(source, widget, scope)
        settings = source['MicroflowSettings'] || source
        name = settings['Microflow'].to_s
        arg_map = microflow_argument_map(settings)
        return unless present_identifier?(name) && arg_map

        @uses_microflow_object = true
        config = {
          dataSourceId: scope, operationId: WebOperationCompiler.operation_id(@qualified_name, widget['Name']),
          editable: true, argMap: arg_map
        }
        "MicroflowObjectProperty(#{js_literal(config)})"
      end

      def nanoflow_object_property(source, scope)
        reference = nanoflow_reference(source['Nanoflow'])
        return unless reference && parameter_mappings(source).empty?

        @uses_nanoflow_object = true
        config = {
          dataSourceId: scope, editable: true,
          source: { nanoflow: raw_js(reference) }, argMap: {}
        }
        "NanoflowObjectProperty(#{js_literal(config)})"
      end

      def entity_ref_destination(reference)
        steps = array(reference&.fetch('Steps', nil))
        steps.last&.fetch('DestinationEntity', nil).to_s.then do |entity|
          entity.empty? ? reference&.fetch('Entity', nil).to_s : entity
        end
      end

      def entity_ref_path(reference)
        array(reference&.fetch('Steps', nil)).flat_map do |step|
          [step['Association'], step['DestinationEntity']]
        end.map(&:to_s).reject(&:empty?).join('/')
      end

      def flow_return_entity(source)
        type, name = if source['$Type'] == 'Forms$MicroflowSource'
                       ['Microflows$Microflow', source.dig('MicroflowSettings', 'Microflow')]
                     elsif source['$Type'] == 'Forms$NanoflowSource'
                       ['Microflows$Nanoflow', source['Nanoflow']]
                     end
        return '' unless type && present_identifier?(name)

        flow = @source.units_of(type).find { "#{_1.module_name}.#{_1.document['Name']}" == name }
        flow&.document&.dig('MicroflowReturnType', 'Entity').to_s
      end

      def render_list_view(widget)
        data_source = WebListDataSource.new(@source, widget)
        return render_unsupported(widget) unless data_source.supported? && present_identifier?(data_source.entity)

        key = widget_key(widget)
        list_value = list_view_property(widget, key, data_source)
        return render_unsupported(widget) unless list_value

        @uses_list_view = true
        @list_scopes << { scope: key, entity: data_source.entity }
        content = children(array(widget['Widgets']))
        @list_scopes.pop
        props = common_props(widget).merge(
          '$widgetId': key, class: css_class(widget), pageSize: positive_integer(widget['PageSize'], 20)
        )
        expressions = {
          listValue: list_value,
          itemTemplate: "TemplatedWidgetProperty({ children: () => #{content}, " \
                        "dataSourceId: #{JSON.generate(key)}, editable: #{widget['Editable'] == true} })"
        }
        "React.createElement($ListView, #{js_props(props, expressions:)})"
      end

      def list_view_property(widget, key, source)
        config = { dataSourceId: key }
        if source.xpath?
          config.merge!(
            operationId: WebOperationCompiler.operation_id(@qualified_name, widget['Name']),
            entity: source.entity, sort: []
          )
          return "DatabaseObjectListProperty(#{js_literal(config)})"
        end
        if source.association?
          current = current_object_scope
          return unless current

          config.merge!(
            operationId: WebOperationCompiler.operation_id(@qualified_name, widget['Name']),
            scope: current[:scope], directPath: source.association_path, sort: []
          )
          return "AssociationObjectListProperty(#{js_literal(config)})"
        end
        if source.microflow?
          settings = widget.dig('DataSource', 'MicroflowSettings') || widget['DataSource'] || {}
          arg_map = microflow_argument_map(settings)
          return unless arg_map

          config.merge!(
            operationId: WebOperationCompiler.operation_id(@qualified_name, widget['Name']),
            argMap: arg_map, fetchOnlyWithAllParams: false
          )
          return "MicroflowObjectListProperty(#{js_literal(config)})"
        end

        reference = nanoflow_reference(source.nanoflow_name)
        return unless reference

        config.merge!(source: { nanoflow: raw_js(reference) }, argMap: {}, fetchOnlyWithAllParams: false)
        "NanoflowObjectListProperty(#{js_literal(config)})"
      end

      def positive_integer(value, fallback)
        number = Integer(value || 0)
        number.positive? ? number : fallback
      rescue ArgumentError, TypeError
        fallback
      end

      def render_text_box(widget)
        scope = current_object_scope&.fetch(:scope, nil)
        attribute = widget.dig('AttributeRef', 'Attribute').to_s
        entity, separator, name = attribute.rpartition('.')
        return render_unsupported(widget) unless scope && separator == '.' &&
                                                 present_identifier?(entity) && present_identifier?(name)

        key = widget_key(widget)
        caption = translated_text(widget.dig('LabelTemplate', 'Template'))
        placeholder = translated_text(widget.dig('PlaceholderTemplate', 'Template'))
        input_props = common_props(widget).merge(
          '$widgetId': key, isPassword: widget['IsPasswordBox'] == true,
          mask: widget['InputMask'].to_s, readOnlyStyle: 'text',
          maxLength: widget['MaxLengthCode'].to_i.positive? ? widget['MaxLengthCode'].to_i : nil,
          autocomplete: widget['Autocomplete'] == false ? 'off' : 'on',
          submitWhileEditing: widget['SubmitBehaviour'] == 'OnTyping',
          submitDelay: widget['SubmitOnInputDelay'].to_i, id: key
        )
        input = "React.createElement($TextBox, #{js_props(input_props, expressions: {
          inputValue: attribute_property(scope, entity, name),
          placeholder: "TextProperty({ value: #{JSON.generate(placeholder)} })"
        })})"
        group_props = {
          key: "#{key}$formGroup", '$widgetId': "#{key}$formGroup",
          class: "mx-name-#{widget['Name']} mx-textbox", control: [input],
          width: 3, orientation: 'horizontal', labelFor: key
        }
        "React.createElement($FormGroup, #{js_props(group_props, expressions: {
          caption: "TextProperty({ value: #{JSON.generate(caption)} })",
          hasError: 'TextProperty({ value: false })'
        })})"
      end

      def render_text_area(widget)
        scope = current_object_scope&.fetch(:scope, nil)
        entity, separator, name = widget.dig('AttributeRef', 'Attribute').to_s.rpartition('.')
        return render_unsupported(widget) unless scope && separator == '.' &&
                                                 present_identifier?(entity) && present_identifier?(name)

        @uses_form_widgets = true
        @uses_text_area = true
        key = widget_key(widget)
        caption = translated_text(widget.dig('LabelTemplate', 'Template'))
        placeholder = translated_text(widget.dig('PlaceholderTemplate', 'Template'))
        max_length = widget['MaxLengthCode'].to_i
        input_props = common_props(widget).merge(
          '$widgetId': key, readOnlyStyle: 'text', numberOfLines: positive_integer(widget['NumberOfLines'], 5),
          autoGrow: widget['AutoGrow'] == true, maxLength: max_length.positive? ? max_length : nil,
          autocomplete: widget['Autocomplete'] == false ? 'off' : 'on',
          submitWhileEditing: %w[WhileEditing OnTyping].include?(widget['SubmitBehaviour']),
          submitDelay: widget['SubmitOnInputDelay'].to_i, id: key
        )
        input = "React.createElement($TextArea, #{js_props(input_props, expressions: {
          inputValue: attribute_property(scope, entity, name),
          placeholder: "TextProperty({ value: #{JSON.generate(placeholder)} })",
          textTooLongMessage: 'TextProperty({ value: "Text is too long" })',
          counterMessage: 'TextProperty({ value: "" })'
        })})"
        render_form_group(widget, key, caption, input, 'mx-textarea')
      end

      def render_radio_button_group(widget)
        scope = current_object_scope&.fetch(:scope, nil)
        entity, separator, name = widget.dig('AttributeRef', 'Attribute').to_s.rpartition('.')
        return render_unsupported(widget) unless scope && separator == '.' &&
                                                 present_identifier?(entity) && present_identifier?(name)

        @uses_form_widgets = true
        @uses_radio_button_group = true
        key = widget_key(widget)
        input = "React.createElement($RadioButtonGroup, #{js_props(
          common_props(widget).merge('$widgetId': key, readOnlyStyle: 'text', id: key,
                                     ariaRequired: false, tabIndex: widget['TabIndex'].to_i),
          expressions: { value: attribute_property(scope, entity, name) }
        )})"
        caption = translated_text(widget.dig('LabelTemplate', 'Template'))
        render_form_group(widget, key, caption, input, 'mx-radiogroup')
      end

      def render_file_manager(widget)
        scope = current_object_scope&.fetch(:scope, nil)
        return render_unsupported(widget) unless scope

        @uses_form_widgets = true
        @uses_file_manager = true
        key = widget_key(widget)
        config = { scope:, path: '', isEditable: true, allowUpload: widget['Type'] != 'Download' }
        props = common_props(widget).merge(
          '$widgetId': key, class: css_class(widget), id: key,
          widgetType: widget['Type'].to_s.downcase.then { _1.empty? ? 'both' : _1 },
          extensions: widget['AllowedExtensions'].to_s,
          maxFileSize: positive_integer(widget['MaxFileSize'], 200),
          showInBrowser: widget['ShowFileInBrowser'] == true
        )
        "React.createElement($FileManager, #{js_props(props, expressions: {
          content: "DynamicFileProperty(#{js_literal(config)})"
        })})"
      end

      def render_form_group(widget, key, caption, input, widget_class)
        group_props = {
          key: "#{key}$formGroup", '$widgetId': "#{key}$formGroup",
          class: "mx-name-#{widget['Name']} #{widget_class}", control: [input],
          width: 3, orientation: 'horizontal', labelFor: key
        }
        "React.createElement($FormGroup, #{js_props(group_props, expressions: {
          caption: "TextProperty({ value: #{JSON.generate(caption)} })",
          hasError: 'TextProperty({ value: false })'
        })})"
      end

      def render_date_picker(widget)
        scope = current_object_scope&.fetch(:scope, nil)
        entity, separator, name = widget.dig('AttributeRef', 'Attribute').to_s.rpartition('.')
        return render_unsupported(widget) unless scope && separator == '.' &&
                                                 present_identifier?(entity) && present_identifier?(name)

        @uses_form_widgets = true
        @uses_date_picker = true
        key = widget_key(widget)
        caption = translated_text(widget.dig('LabelTemplate', 'Template'))
        placeholder = translated_text(widget.dig('PlaceholderTemplate', 'Template'))
        date_format = widget.dig('FormattingInfo', 'DateFormat').to_s
        mode = date_format.casecmp('time').zero? ? 'time' : 'date'
        formatting = mode == 'time' ? { timeFormat: { type: 'time' } } : { dateFormat: { type: 'date' } }
        input_props = common_props(widget).merge(
          '$widgetId': key, mode:, showCalendarButton: widget.fetch('ShowCalendarButton', true),
          readOnlyStyle: 'text', id: key
        )
        input = "React.createElement($DatePicker, #{js_props(input_props, expressions: {
          inputValue: attribute_property(scope, entity, name, formatting:),
          placeholder: "TextProperty({ value: #{JSON.generate(placeholder)} })",
          buttonLabel: 'TextProperty({ value: "Show date picker" })'
        })})"
        group_props = {
          key: "#{key}$formGroup", '$widgetId': "#{key}$formGroup",
          class: "mx-name-#{widget['Name']} mx-datepicker", control: [input],
          width: 3, orientation: 'horizontal', labelFor: key
        }
        "React.createElement($FormGroup, #{js_props(group_props, expressions: {
          caption: "TextProperty({ value: #{JSON.generate(caption)} })",
          hasError: 'TextProperty({ value: false })'
        })})"
      end

      def render_check_box(widget)
        scope = current_object_scope&.fetch(:scope, nil)
        entity, separator, name = widget.dig('AttributeRef', 'Attribute').to_s.rpartition('.')
        return render_unsupported(widget) unless scope && separator == '.' &&
                                                 present_identifier?(entity) && present_identifier?(name)

        @uses_form_widgets = true
        key = widget_key(widget)
        input = "React.createElement($CheckBox, #{js_props(
          common_props(widget).merge('$widgetId': key, readOnlyStyle: 'text', id: key),
          expressions: { value: attribute_property(scope, entity, name) }
        )})"
        group_props = {
          key: "#{key}$formGroup", '$widgetId': "#{key}$formGroup",
          class: "mx-name-#{widget['Name']} mx-checkbox", control: [input],
          width: 3, orientation: 'horizontal', labelFor: key
        }
        caption = translated_text(widget.dig('LabelTemplate', 'Template'))
        "React.createElement($FormGroup, #{js_props(group_props, expressions: {
          caption: "TextProperty({ value: #{JSON.generate(caption)} })",
          hasError: 'TextProperty({ value: false })'
        })})"
      end

      def render_label(widget)
        @uses_form_widgets = true
        key = widget_key(widget)
        props = common_props(widget).merge('$widgetId': key, class: css_class(widget), id: key)
        caption = translated_text(widget['Caption'])
        "React.createElement($Label, #{js_props(props, expressions: {
          caption: "TextProperty({ value: #{JSON.generate(caption)} })"
        })})"
      end

      def render_tab_control(widget)
        @uses_tab_container = true
        key = widget_key(widget)
        tabs = array(widget['TabPages'])
        compiled = tabs.map do |tab|
          {
            name: tab['Name'].to_s,
            caption: raw_js("TextProperty({ value: #{JSON.generate(translated_text(tab['Caption']))} })"),
            isDelayed: false, refreshOnShow: tab['RefreshOnShow'] == true,
            content: raw_js(children(array(tab['Widgets'])))
          }
        end
        props = common_props(widget).merge(
          '$widgetId': key, class: css_class(widget), widgetId: key,
          defaultTab: default_tab_index(widget, tabs), tabs: compiled
        )
        "React.createElement($TabContainer, #{js_literal(props)})"
      end

      def default_tab_index(widget, tabs)
        pointer = IO::BsonCodec.extract_id(widget['DefaultPagePointer'])
        index = tabs.index { IO::BsonCodec.extract_id(_1['$ID']) == pointer }
        index || 0
      end

      def render_static_image(widget)
        uri = image_uri(widget['Image'])
        return render_unsupported(widget) unless uri

        @uses_image = true
        ImageBundleCompiler.render_static(
          widget_key(widget), css_class(widget), uri,
          width: widget['Width'], width_unit: widget['WidthUnit'], height: widget['Height'],
          height_unit: widget['HeightUnit'], responsive: widget['Responsive'] == true
        )
      end

      def image_uri(reference)
        module_name, collection_name, image_name = reference.to_s.split('.', 3)
        unit = @source.units_of('Images$ImageCollection').find do |candidate|
          candidate.module_name == module_name && candidate.document['Name'] == collection_name
        end
        return unless unit

        image = array(unit.document.fetch('Images', nil)).find { _1['Name'] == image_name }
        return unless image

        "img/#{[module_name, collection_name, image_name].join('$')}.#{image_format(image)}"
      end

      def attribute_property(scope, entity, attribute, path: '', formatting: {})
        config = {
          scope:, path:, entity:, attribute:,
          onChange: { type: 'doNothing', argMap: {}, config: {}, disabledDuringExecution: true },
          isList: false, validation: nil, formatting:
        }
        "AttributeProperty(#{js_literal(config)})"
      end

      def data_action?(action)
        current_object_scope && %w[
          Forms$SaveChangesClientAction Forms$CancelChangesClientAction Forms$DeleteClientAction
        ]
          .include?(action['$Type'])
      end

      def render_data_action_button(widget, action)
        type = {
          'Forms$SaveChangesClientAction' => 'saveChanges',
          'Forms$CancelChangesClientAction' => 'cancelChanges',
          'Forms$DeleteClientAction' => 'deleteObject'
        }.fetch(action['$Type'])
        scope = current_object_scope.fetch(:scope)
        key = widget_key(widget)
        object_argument = %w[saveChanges deleteObject].include?(type)
        action_config = {
          action: {
            type:, argMap: object_argument ? { '$object': { widget: scope, source: 'object' } } : {},
            config: {
              operationId: WebOperationCompiler.operation_id(@qualified_name, widget['Name']),
              closePage: action.fetch('ClosePage', true)
            },
            disabledDuringExecution: action.fetch('DisabledDuringExecution', true)
          },
          abortOnServerValidation: true
        }
        props = common_props(widget).merge(
          '$widgetId': key, buttonId: key, class: css_class(widget), renderType: 'button',
          buttonClass: button_style(widget)
        )
        caption = translated_text(widget.dig('CaptionTemplate', 'Template'))
        "React.createElement($ActionButton, #{js_props(props, expressions: {
          caption: "TextProperty({ value: #{JSON.generate(caption)} })",
          tooltip: 'TextProperty({ value: "" })', action: "ActionProperty(#{js_literal(action_config)})"
        })})"
      end

      def button_style(widget)
        style = widget['ButtonStyle'].to_s.downcase
        "btn-#{style.empty? ? 'default' : style}"
      end

      def action_handler(action)
        case action['$Type']
        when 'Forms$NoAction', nil
          nil
        when 'Forms$FormAction'
          open_form_handler(action.dig('FormSettings', 'Form'))
        when 'Forms$CreateObjectClientAction'
          create_object_handler(
            action.dig('EntityRef', 'Entity'), action.dig('PageSettings', 'Form')
          )
        else
          @unsupported << action['$Type'].to_s unless action['$Type'].to_s.empty?
          nil
        end
      end

      def open_form_handler(form)
        return unless present_identifier?(form)

        "() => window.mx?.ui?.openForm2?.(#{JSON.generate(form)}, {}, undefined, undefined, " \
          '{ location: "content" })'
      end

      def create_object_handler(entity, form)
        return unless present_identifier?(entity) && present_identifier?(form)

        parameter = target_page_parameter(form, entity)
        return unless parameter

        create_form_handler_source(entity, form, parameter)
      end

      def create_form_handler_source(entity, form, parameter)
        source = <<~JS
          () => window.mx?.data?.create?.({ entity: #{JSON.generate(entity)}, callback: object => {
            window.mx?.ui?.openForm2?.(#{JSON.generate(form)},
              { #{JSON.generate(parameter)}: object.getGuid() }, undefined, undefined,
              { location: "content" });
          }, error: window.mx?.ui?.onError })
        JS
        source.lines.map(&:strip).join(' ')
      end

      def target_page_parameter(form, entity)
        parameter = array(page_unit(form)&.document&.fetch('Parameters', nil))
                    .find { object_parameter?(_1, entity) }
        name = parameter&.fetch('Name', nil)
        "$#{name}" if present_identifier?(name)
      end

      def page_unit(qualified_name)
        @source.units_of('Forms$Page').find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == qualified_name
        end
      end

      def object_parameter?(parameter, entity)
        parameter.dig('ParameterType', '$Type') == 'DataTypes$ObjectType' &&
          parameter.dig('ParameterType', 'Entity') == entity
      end

      def present_identifier?(value) = value.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_.]*\z/)

      def render_unsupported(widget)
        type = widget['$Type'].to_s
        @unsupported << type
        @unsupported_custom << custom_widget_identifier(widget) if type == 'CustomWidgets$CustomWidget'
        props = common_props(widget).merge(
          className: "#{css_class(widget)} mxrb-unsupported-widget".strip,
          'data-mxrb-widget-type': type
        )
        "React.createElement(\"div\", #{js_props(props)})"
      end

      def custom_widget_identifier(widget)
        type_id = IO::BsonCodec.extract_id(widget.dig('Object', 'TypePointer'))
        schema = @source.document_index.values.find do |document|
          IO::BsonCodec.extract_id(document.dig('ObjectType', '$ID')) == type_id
        end
        schema&.fetch('WidgetId', nil).to_s.then { _1.empty? ? 'CustomWidgets$CustomWidget' : _1 }
      end

      def common_props(widget)
        { key: widget_key(widget), 'data-widget-id': widget_key(widget) }
      end

      def widget_key(widget)
        name = widget['Name'].to_s
        encoded = widget_id(widget)[0, 12]
        "#{@scope_prefix || 'p'}.#{@qualified_name}.#{name.empty? ? encoded : name}"
      end

      def widget_id(widget)
        identifier = widget['$ID']
        return identifier.data.unpack1('H*') if identifier.respond_to?(:data)

        identifier&.dig('$binary', 'base64').to_s.gsub(/[^A-Za-z0-9]/, '')
      end

      def css_class(widget)
        name = widget['Name'].to_s
        appearance = widget.dig('Appearance', 'Class').to_s
        named = "mx-name-#{name}" unless name.empty?
        [named, widget['Class'], appearance].map(&:to_s).reject(&:empty?).uniq.join(' ')
      end

      def render_mode(widget) = widget['RenderMode'].to_s.downcase.then { _1.empty? ? 'div' : _1 }

      def text_mode(widget)
        { 'Text' => 'span', 'Paragraph' => 'p', 'Heading1' => 'h1', 'Heading2' => 'h2',
          'Heading3' => 'h3', 'Heading4' => 'h4', 'Heading5' => 'h5', 'Heading6' => 'h6' }
          .merge('H1' => 'h1', 'H2' => 'h2', 'H3' => 'h3', 'H4' => 'h4', 'H5' => 'h5', 'H6' => 'h6')
          .fetch(widget['RenderMode'].to_s, 'span')
      end

      def translated_text(text)
        array(text&.fetch('Items', nil)).find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', '') ||
          array(text&.fetch('Items', nil)).first&.fetch('Text', '') || ''
      end

      def js_props(props, expressions: {})
        pairs = props.map do |key, value|
          rendered = value.is_a?(Array) ? "[#{value.join(', ')}]" : JSON.generate(value)
          "#{JSON.generate(key)}: #{rendered}"
        end
        pairs.concat(expressions.map { |key, value| "#{JSON.generate(key)}: #{value}" })
        "{ #{pairs.join(', ')} }"
      end

      def js_literal(value)
        return value['$raw'] if value.is_a?(Hash) && value.key?('$raw')

        case value
        when Hash
          "{ #{value.map { |key, item| "#{JSON.generate(key)}: #{js_literal(item)}" }.join(', ')} }"
        when Array then "[#{value.map { js_literal(_1) }.join(', ')}]"
        else JSON.generate(value)
        end
      end

      def module_source(content)
        rendered_content = render_content(content)
        content_source = if parent_layout_name.empty?
                           rendered_content
                         else
                           "Object.assign({}, parentContent, #{rendered_content})"
                         end
        <<~JS
          import React from "react";
          import { PageFragment } from "mendix/PageFragment";
          #{parent_layout_import}
          #{widget_imports}
          #{@nanoflow_programs.declarations}

          export const title = #{JSON.generate(page_title)};
          export const classes = #{JSON.generate(page_classes)};
          export const autofocus = "off";
          #{cancel_changes_export}
          export const style = {};
          export const parameters = #{JSON.generate(page_parameters)};
          export const content = #{content_source};
        JS
      end

      def cancel_changes_export
        return '' unless popup_page?

        "export const cancelChangesOperationId = #{JSON.generate(cancel_changes_operation_id)};"
      end

      def cancel_changes_operation_id
        WebOperationCompiler.operation_id(@qualified_name, '$cancelChanges')
      end

      def popup_page?
        !@layout_mode && popup_layout_document?(layout&.document)
      end

      def popup_layout_document?(document)
        return false unless document

        name = document['Name'].to_s
        return true if name.match?(/popup/i)

        document['CanvasWidth'].to_i.positive? && document['CanvasWidth'].to_i <= 800 &&
          %w[Forms$NavigationTree Forms$MenuBar Forms$SimpleMenuBar Forms$Header].none? do |type|
            nested_widgets(document, type).any?
          end
      end

      def nested_widgets(value, type, result = [])
        case value
        when Hash
          result << value if value['$Type'] == type
          value.each_value { nested_widgets(_1, type, result) }
        when Array then value.each { nested_widgets(_1, type, result) }
        end
        result
      end

      def layout_module_source(rendered)
        parent = parent_layout_name.empty? ? '{}' : 'parentContent'
        <<~JS
          import React from "react";
          #{parent_layout_import}
          #{widget_imports}
          #{@nanoflow_programs.declarations}

          export const content = Object.assign({}, #{parent}, {
            "Main": #{rendered}
          });
        JS
      end

      def parent_layout_import
        return '' if parent_layout_name.empty?

        "import { content as parentContent } from \"../layouts/#{parent_layout_name}.js\";"
      end

      def parent_layout_name
        reference = if @layout_mode
                      @unit.document.dig('Content', 'LayoutCall', 'Form')
                    else
                      @unit.document.dig('FormCall', 'Form')
                    end.to_s
        return '' unless present_qualified_name?(reference)

        layout = @source.units_of('Forms$Layout').find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == reference
        end
        layout && @source.web_layout?(layout) ? reference : ''
      end

      def present_qualified_name?(value)
        value.split('.').length >= 2 && value.split('.').all? { present_identifier?(_1) }
      end

      def page_parameters
        array(@unit.document['Parameters']).filter_map do |parameter|
          name = parameter['Name']
          type = parameter['ParameterType'] || {}
          next unless present_identifier?(name) && type['$Type'] == 'DataTypes$ObjectType'

          ["$#{name}", { kind: 'object' }]
        end.to_h
      end

      def widget_imports
        return '' unless @uses_data_grid || @uses_form_widgets || @uses_gallery || @uses_bound_text ||
                         @uses_tab_container || @uses_image || @uses_conditional || @uses_dynamic_class ||
                         @uses_list_view || @generic_widgets&.any? || @uses_layout_widgets

        imports = ['import { asPluginWidgets } from "mendix";']
        widgets = []
        if @uses_layout_widgets
          imports.concat([
                           'import { PlaceholderProperty } from "mendix/PlaceholderProperty";',
                           'import { TextProperty } from "mendix/TextProperty";',
                           'import { ActionProperty } from "mendix/ActionProperty";',
                           'import { WebIconProperty } from "mendix/WebIconProperty";',
                           'import { ScrollContainer } from "mendix/widgets/web/ScrollContainer";',
                           'import { Placeholder } from "mendix/widgets/web/Placeholder";',
                           'import { SidebarToggle } from "mendix/widgets/web/SidebarToggle";',
                           'import { Header } from "mendix/widgets/web/Header";',
                           'import { NavigationTree } from "mendix/widgets/web/NavigationTree";',
                           'import { MenuBar } from "mendix/widgets/web/MenuBar";',
                           'import { SimpleMenuBar } from "mendix/widgets/web/SimpleMenuBar";'
                         ])
          widgets.concat(%w[ScrollContainer Placeholder SidebarToggle Header NavigationTree MenuBar SimpleMenuBar])
        end
        (@generic_widgets || {}).sort.each do |name, path|
          imports.concat([
                           "import * as #{name}WidgetModule from \"../widgets/#{path}.mjs\";",
                           "const #{name} = Object.getOwnPropertyDescriptor(#{name}WidgetModule, " \
                           "#{JSON.generate(name)})?.value || " \
                           "Object.getOwnPropertyDescriptor(#{name}WidgetModule, \"default\")?.value;"
                         ])
          widgets << name
        end
        if @generic_widgets&.any?
          imports.concat([
                           'import { AttributeProperty } from "mendix/AttributeProperty";',
                           'import { ExpressionProperty } from "mendix/ExpressionProperty";',
                           'import { ListExpressionProperty } from "mendix/ListExpressionProperty";',
                           'import { DatabaseObjectListProperty } from "mendix/DatabaseObjectListProperty";'
                         ])
        end
        if @uses_data_grid
          imports.concat([
                           'import { DatabaseObjectListProperty } from "mendix/DatabaseObjectListProperty";',
                           'import { AttributeProperty } from "mendix/AttributeProperty";',
                           'import { ExpressionProperty } from "mendix/ExpressionProperty";',
                           'import { ListExpressionProperty } from "mendix/ListExpressionProperty";',
                           'import { TemplatedWidgetProperty } from "mendix/TemplatedWidgetProperty";',
                           'import Datagrid from "../widgets/com/mendix/widget/web/datagrid/Datagrid.mjs";'
                         ])
          widgets << 'Datagrid'
        end
        if @uses_form_widgets
          imports.concat([
                           'import { AssociationObjectProperty } from "mendix/AssociationObjectProperty";',
                           'import { AttributeProperty } from "mendix/AttributeProperty";',
                           'import { ActionProperty } from "mendix/ActionProperty";',
                           'import { TextProperty } from "mendix/TextProperty";',
                           'import { DataView } from "mendix/widgets/web/DataView";',
                           'import { TextBox } from "mendix/widgets/web/TextBox";',
                           'import { CheckBox } from "mendix/widgets/web/CheckBox";',
                           'import { Label } from "mendix/widgets/web/Label";',
                           'import { Container } from "mendix/widgets/web/Container";',
                           'import { FormGroup } from "mendix/widgets/web/FormGroup";',
                           'import { ActionButton } from "mendix/widgets/web/ActionButton";'
                         ])
          widgets.concat(%w[DataView TextBox CheckBox Label FormGroup ActionButton])
          if @uses_date_picker
            imports << 'import { DatePicker } from "mendix/widgets/web/DatePicker";'
            widgets << 'DatePicker'
          end
          if @uses_text_area
            imports << 'import { TextArea } from "mendix/widgets/web/TextArea";'
            widgets << 'TextArea'
          end
          if @uses_radio_button_group
            imports << 'import { RadioButtonGroup } from "mendix/widgets/web/RadioButtonGroup";'
            widgets << 'RadioButtonGroup'
          end
          if @uses_group_box
            imports << 'import { GroupBox } from "mendix/widgets/web/GroupBox";'
            widgets << 'GroupBox'
          end
          if @uses_file_manager
            imports.concat([
                             'import { DynamicFileProperty } from "mendix/DynamicFileProperty";',
                             'import { FileManager } from "mendix/widgets/web/FileManager";'
                           ])
            widgets << 'FileManager'
          end
          imports << 'import { MicroflowObjectProperty } from "mendix/MicroflowObjectProperty";' \
            if @uses_microflow_object
          imports << 'import { ListenObjectProperty } from "mendix/ListenObjectProperty";' \
            if @uses_listen_object
          widgets << 'Container' if @uses_container
        end
        if @uses_combo_box
          imports.concat([
                           'import { AssociationProperty } from "mendix/AssociationProperty";',
                           'import { DatabaseObjectListProperty } from "mendix/DatabaseObjectListProperty";',
                           'import { MicroflowObjectListProperty } from "mendix/MicroflowObjectListProperty";',
                           'import { ListAttributeProperty } from "mendix/ListAttributeProperty";',
                           'import { ListAssociationProperty } from "mendix/ListAssociationProperty";',
                           'import { ListExpressionProperty } from "mendix/ListExpressionProperty";',
                           'import { SelectionProperty } from "mendix/SelectionProperty";',
                           'import { ExpressionProperty } from "mendix/ExpressionProperty";',
                           'import Combobox from "../widgets/com/mendix/widget/web/combobox/Combobox.mjs";'
                         ])
          widgets << 'Combobox'
        end
        imports << 'import { NanoflowObjectProperty } from "mendix/NanoflowObjectProperty";' \
          if @uses_nanoflow_object
        if @uses_list_view
          imports.concat([
                           'import { DatabaseObjectListProperty } from "mendix/DatabaseObjectListProperty";',
                           'import { AssociationObjectListProperty } from "mendix/AssociationObjectListProperty";',
                           'import { MicroflowObjectListProperty } from "mendix/MicroflowObjectListProperty";',
                           'import { NanoflowObjectListProperty } from "mendix/NanoflowObjectListProperty";',
                           'import { TemplatedWidgetProperty } from "mendix/TemplatedWidgetProperty";',
                           'import { ListView } from "mendix/widgets/web/ListView";'
                         ])
          widgets << 'ListView'
        end
        if @uses_gallery
          imports.concat([
                           'import { DatabaseObjectListProperty } from "mendix/DatabaseObjectListProperty";',
                           'import { MicroflowObjectListProperty } from "mendix/MicroflowObjectListProperty";',
                           'import { NanoflowObjectListProperty } from "mendix/NanoflowObjectListProperty";',
                           'import { SelectionProperty } from "mendix/SelectionProperty";',
                           'import { TemplatedWidgetProperty } from "mendix/TemplatedWidgetProperty";',
                           'import { ExpressionProperty } from "mendix/ExpressionProperty";',
                           'import { Gallery } from "../widgets/com/mendix/widget/web/gallery/Gallery.mjs";'
                         ])
          widgets << 'Gallery'
        end
        if @uses_tab_container
          imports.concat([
                           'import { TextProperty } from "mendix/TextProperty";',
                           'import { TabContainer } from "mendix/widgets/web/TabContainer";'
                         ])
          widgets << 'TabContainer'
        end
        if @uses_image
          imports.concat([
                           'import { ExpressionProperty } from "mendix/ExpressionProperty";',
                           'import { WebStaticImageProperty } from "mendix/WebStaticImageProperty";'
                         ])
          imports << if @uses_custom_image
                       'import { Image } from "../widgets/com/mendix/widget/web/image/Image.mjs";'
                     else
                       'import { Image } from "mendix/widgets/web/Image";'
                     end
          widgets << 'Image'
        end
        if @uses_bound_text
          imports.concat([
                           'import { AttributeProperty } from "mendix/AttributeProperty";',
                           'const MxrbFormattedText = ({ template, renderMode, class: className, ...props }) => ' \
                           'React.createElement(renderMode, { className }, Object.keys(props)' \
                           '.filter(key => /^value\\d+$/.test(key))' \
                           '.sort((left, right) => Number(left.slice(5)) - Number(right.slice(5)))' \
                           '.reduce((text, key, index) => text.split(`{${index + 1}}`)' \
                           '.join(props[key]?.displayValue ?? " "), template));',
                           'MxrbFormattedText.displayName = "MxrbFormattedText";'
                         ])
          widgets << 'MxrbFormattedText'
        end
        if @uses_conditional
          imports.concat([
                           'import { AttributeProperty } from "mendix/AttributeProperty";',
                           'const mxrbValue = property => property?.value ?? property?.displayValue;',
                           'const MxrbConditional = ({ test, children, ...props }) => ' \
                           'test(props) ? children : null;',
                           'MxrbConditional.displayName = "MxrbConditional";'
                         ])
          widgets << 'MxrbConditional'
        end
        if @uses_dynamic_class
          imports.concat([
                           'import { AttributeProperty } from "mendix/AttributeProperty";',
                           'const mxrbValue = property => property?.value ?? property?.displayValue;',
                           'const MxrbDynamicClass = ({ resolveClass, children, ...props }) => {' \
                           ' const dynamicClass = resolveClass(props);' \
                           ' const currentClass = children.props.class || children.props.className || "";' \
                           ' const mergedClass = [currentClass, dynamicClass].filter(Boolean).join(" ").trim();' \
                           ' const classProp = typeof children.type === "string" ?' \
                           ' { className: mergedClass } : { class: mergedClass };' \
                           ' return React.cloneElement(children, classProp); };',
                           'MxrbDynamicClass.displayName = "MxrbDynamicClass";'
                         ])
          widgets << 'MxrbDynamicClass'
        end
        imports.uniq.push(
          "const { #{widgets.map { "$#{_1}" }.join(', ')} } = asPluginWidgets({ #{widgets.join(', ')} });"
        ).join("\n")
      end

      def page_title = translated_text(@unit.document['Title'])

      def page_classes
        [layout&.document&.dig('Appearance', 'Class'), @unit.document.dig('Appearance', 'Class')]
          .map(&:to_s).reject(&:empty?).join(' ')
      end

      def render_content(content)
        JSON.pretty_generate(content).sub(/\A\{/, '{').sub(/\}\z/, '}')
            .gsub(/"(renderKey =>[^\n]+)"/) { Regexp.last_match(1).gsub('\\"', '"') }
      end

      def layout
        qualified = @unit.document.dig('FormCall', 'Form').to_s
        @source.units_of('Forms$Layout').find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == qualified
        end
      end
    end
    # rubocop:enable Metrics, Style/MultilineBlockChain
  end
end
