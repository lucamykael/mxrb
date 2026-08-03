# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    PageBundle = Data.define(:qualified_name, :source, :unsupported_widgets)

    # Converts the web-page subset of the source model into a Runtime-loadable ES module.
    class PageBundleCompiler # rubocop:disable Metrics/ClassLength
      include ModelValues

      def initialize(source)
        @source = source
        @unsupported = []
        @uses_conditional = false
        @uses_dynamic_class = false
      end

      def compile(unit)
        @unit = unit
        @qualified_name = "#{unit.module_name}.#{unit.document['Name']}"
        @data_view_scopes = []
        @list_scopes = []
        @nanoflow_programs = NanoflowProgramCompiler.new(@source)
        content = page_content
        PageBundle.new(
          qualified_name: @qualified_name, source: module_source(content),
          unsupported_widgets: @unsupported.uniq.sort.freeze
        )
      end

      private

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
        name = parameter.to_s.split('.').last.to_s
        raise CompilationError, "invalid page slot #{parameter.inspect}" unless present_identifier?(name)

        name
      end

      def content_function(widgets)
        "renderKey => React.createElement(PageFragment, { renderKey }, #{children(widgets)})"
      end

      def children(widgets) = "[#{widgets.map { render_widget(_1) }.join(', ')}]"

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
      def render_widget(widget)
        rendered = case widget['$Type']
                   when 'Forms$DivContainer' then render_container(widget)
                   when 'Forms$LayoutGrid' then render_layout_grid(widget)
                   when 'Forms$LayoutGridRow' then render_grid_row(widget)
                   when 'Forms$LayoutGridColumn' then render_grid_column(widget)
                   when 'Forms$DynamicText' then render_text(widget)
                   when 'Forms$ActionButton' then render_action_button(widget)
                   when 'Forms$DataView' then render_data_view(widget)
                   when 'Forms$TextBox' then render_text_box(widget)
                   when 'Forms$DatePicker' then render_date_picker(widget)
                   when 'Forms$CheckBox' then render_check_box(widget)
                   when 'Forms$Label' then render_label(widget)
                   when 'Forms$TabControl' then render_tab_control(widget)
                   when 'Forms$StaticImageViewer' then render_static_image(widget)
                   when 'CustomWidgets$CustomWidget' then render_custom_widget(widget)
                   else render_unsupported(widget)
                   end
        rendered = wrap_dynamic_classes(widget, rendered)
        wrap_conditional_visibility(widget, rendered)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

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

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def render_custom_widget(widget)
        grid = DataGridBundleCompiler.new(@source, @qualified_name, widget)
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

        image = ImageBundleCompiler.new(@source, @qualified_name, widget)
        if image.supported?
          @uses_image = true
          @uses_custom_image = true
          return image.render
        end

        combo = ComboBoxBundleCompiler.new(
          @source, @qualified_name, widget,
          scope: scope_name(@data_view_scopes.last), entity: @data_view_scopes.last&.fetch(:entity, nil)
        )
        return render_unsupported(widget) unless combo.supported?

        @uses_form_widgets = true
        @uses_combo_box = true
        combo.render
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      def render_container(widget) # rubocop:disable Metrics/AbcSize
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
      end # rubocop:enable Metrics/AbcSize

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

      def wrap_conditional_visibility(widget, rendered) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

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

      def visibility_atom(expression, attributes) # rubocop:disable Metrics/MethodLength
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
      end # rubocop:enable Metrics/MethodLength

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

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def dynamic_class_expression(expression, attributes)
        terms = split_dynamic_class_terms(expression)
        compiled = terms.map { dynamic_class_term(_1, attributes) }
        return unless compiled.all?

        compiled.join(' + ')
      end

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
      # rubocop:disable Metrics/PerceivedComplexity
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
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
      # rubocop:enable Metrics/PerceivedComplexity

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

      def render_action_button(widget) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

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
        payload = open_link_config(action) || microflow_config(widget, action)
        return unless payload

        { action: payload, abortOnServerValidation: true }
      end

      def open_link_config(action) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

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
        scope = expression == '$currentObject' ? current_scope : expression
        return unless present_identifier?(name) && scope.to_s.match?(/\A\$[A-Za-z_]\w*\z|\Ap\./)

        [name.to_sym, { widget: scope, source: 'object' }]
      end

      def nanoflow_action?(action)
        action['$Type'] == 'Forms$CallNanoflowClientAction' &&
          present_identifier?(action['Nanoflow']) && parameter_mappings(action).empty? &&
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
            type: 'callNanoflow', argMap: {}, config: { nanoflow: },
            disabledDuringExecution: action.fetch('DisabledDuringExecution', true)
          },
          abortOnServerValidation: false, skipClientValidation: false
        }
      end

      def nanoflow_reference(name) = @nanoflow_programs.reference(name.to_s)

      def raw_js(value) = { '$raw' => value }

      def render_data_view(widget) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def data_view_object_property(widget, scope)
        source = widget['DataSource'] || {}
        parameter = source.dig('SourceVariable', 'PageParameter').to_s
        if present_identifier?(parameter)
          return "AssociationObjectProperty({ scope: #{JSON.generate("$#{parameter}")}, " \
                 'path: "", editable: true })'
        end
        return nanoflow_object_property(source, scope) if source['$Type'] == 'Forms$NanoflowSource'

        nil
      end

      def data_view_entity(widget)
        parameter = widget.dig('DataSource', 'SourceVariable', 'PageParameter').to_s
        page_parameter = array(@unit.document['Parameters']).find { _1['Name'] == parameter }
        page_parameter&.dig('ParameterType', 'Entity').to_s
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

      def render_text_box(widget) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        scope = scope_name(@data_view_scopes.last)
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
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def render_date_picker(widget) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        scope = scope_name(@data_view_scopes.last)
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
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def render_check_box(widget) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        scope = scope_name(@data_view_scopes.last)
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
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def render_label(widget)
        @uses_form_widgets = true
        key = widget_key(widget)
        props = common_props(widget).merge('$widgetId': key, class: css_class(widget), id: key)
        caption = translated_text(widget['Caption'])
        "React.createElement($Label, #{js_props(props, expressions: {
          caption: "TextProperty({ value: #{JSON.generate(caption)} })"
        })})"
      end

      def render_tab_control(widget) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
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
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

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
        @data_view_scopes.any? && %w[Forms$SaveChangesClientAction Forms$CancelChangesClientAction]
          .include?(action['$Type'])
      end

      def render_data_action_button(widget, action) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        type = action['$Type'] == 'Forms$SaveChangesClientAction' ? 'saveChanges' : 'cancelChanges'
        scope = scope_name(@data_view_scopes.last)
        key = widget_key(widget)
        action_config = {
          action: {
            type:, argMap: type == 'saveChanges' ? { '$object': { widget: scope, source: 'object' } } : {},
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
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def button_style(widget)
        style = widget['ButtonStyle'].to_s.downcase
        "btn-#{style.empty? ? 'default' : style}"
      end

      def action_handler(action) # rubocop:disable Metrics/MethodLength
        case action['$Type']
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
      end # rubocop:enable Metrics/MethodLength

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
        props = common_props(widget).merge(
          className: "#{css_class(widget)} mxrb-unsupported-widget".strip,
          'data-mxrb-widget-type': type
        )
        "React.createElement(\"div\", #{js_props(props)})"
      end

      def common_props(widget)
        { key: widget_key(widget), 'data-widget-id': widget_key(widget) }
      end

      def widget_key(widget)
        name = widget['Name'].to_s
        encoded = widget_id(widget)[0, 12]
        "p.#{@qualified_name}.#{name.empty? ? encoded : name}"
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
        <<~JS
          import React from "react";
          import { PageFragment } from "mendix/PageFragment";
          #{widget_imports}
          #{@nanoflow_programs.declarations}

          export const title = #{JSON.generate(page_title)};
          export const classes = #{JSON.generate(page_classes)};
          export const autofocus = "off";
          export const style = {};
          export const parameters = #{JSON.generate(page_parameters)};
          export const content = #{render_content(content)};
        JS
      end

      def page_parameters
        array(@unit.document['Parameters']).filter_map do |parameter|
          name = parameter['Name']
          type = parameter['ParameterType'] || {}
          next unless present_identifier?(name) && type['$Type'] == 'DataTypes$ObjectType'

          ["$#{name}", { kind: 'object' }]
        end.to_h
      end

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def widget_imports
        return '' unless @uses_data_grid || @uses_form_widgets || @uses_gallery || @uses_bound_text ||
                         @uses_tab_container || @uses_image || @uses_conditional || @uses_dynamic_class

        imports = ['import { asPluginWidgets } from "mendix";']
        widgets = []
        if @uses_data_grid
          imports.concat([
                           'import { DatabaseObjectListProperty } from "mendix/DatabaseObjectListProperty";',
                           'import { AttributeProperty } from "mendix/AttributeProperty";',
                           'import { ExpressionProperty } from "mendix/ExpressionProperty";',
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
          widgets << 'Container' if @uses_container
        end
        if @uses_combo_box
          imports.concat([
                           'import { AssociationProperty } from "mendix/AssociationProperty";',
                           'import { DatabaseObjectListProperty } from "mendix/DatabaseObjectListProperty";',
                           'import { MicroflowObjectListProperty } from "mendix/MicroflowObjectListProperty";',
                           'import { ListAttributeProperty } from "mendix/ListAttributeProperty";',
                           'import { SelectionProperty } from "mendix/SelectionProperty";',
                           'import { ExpressionProperty } from "mendix/ExpressionProperty";',
                           'import Combobox from "../widgets/com/mendix/widget/web/combobox/Combobox.mjs";'
                         ])
          widgets << 'Combobox'
        end
        imports << 'import { NanoflowObjectProperty } from "mendix/NanoflowObjectProperty";' \
          if @uses_nanoflow_object
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
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

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
    end # rubocop:enable Metrics/ClassLength
  end
end
