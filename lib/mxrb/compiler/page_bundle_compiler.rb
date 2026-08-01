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
      end

      def compile(unit)
        @unit = unit
        @qualified_name = "#{unit.module_name}.#{unit.document['Name']}"
        @data_view_scopes = []
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

      def render_widget(widget) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
        case widget['$Type']
        when 'Forms$DivContainer' then render_container(widget)
        when 'Forms$LayoutGrid' then render_layout_grid(widget)
        when 'Forms$LayoutGridRow' then render_grid_row(widget)
        when 'Forms$LayoutGridColumn' then render_grid_column(widget)
        when 'Forms$DynamicText' then render_text(widget)
        when 'Forms$ActionButton' then render_action_button(widget)
        when 'Forms$DataView' then render_data_view(widget)
        when 'Forms$TextBox' then render_text_box(widget)
        when 'CustomWidgets$CustomWidget' then render_custom_widget(widget)
        else render_unsupported(widget)
        end
      end # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength

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

      def render_custom_widget(widget)
        compiler = DataGridBundleCompiler.new(@source, @qualified_name, widget)
        return render_unsupported(widget) unless compiler.supported?

        @uses_data_grid = true
        compiler.render
      end

      def render_container(widget)
        props = common_props(widget).merge(
          className: css_class(widget), children: array(widget['Widgets']).map { render_widget(_1) }
        )
        "React.createElement(#{JSON.generate(render_mode(widget))}, #{js_props(props)})"
      end

      def render_text(widget)
        props = common_props(widget).merge(className: css_class(widget))
        caption = translated_text(widget.dig('Content', 'Template'))
        "React.createElement(#{JSON.generate(text_mode(widget))}, #{js_props(props)}, #{JSON.generate(caption)})"
      end

      def render_action_button(widget) # rubocop:disable Metrics/AbcSize
        action = widget['Action'] || {}
        return render_data_action_button(widget, action) if data_action?(action)

        caption = translated_text(widget.dig('CaptionTemplate', 'Template'))
        classes = ['btn', 'mx-button', button_style(widget), css_class(widget)].reject(&:empty?).join(' ')
        props = common_props(widget).merge(type: 'button', className: classes)
        handler = action_handler(action)
        props[:disabled] = true unless handler
        "React.createElement(\"button\", #{js_props(props, expressions: { onClick: handler }.compact)}, " \
          "#{JSON.generate(caption)})"
      end # rubocop:enable Metrics/AbcSize

      def render_data_view(widget) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        @uses_form_widgets = true
        scope = widget_key(widget)
        parameter = widget.dig('DataSource', 'SourceVariable', 'PageParameter').to_s
        return render_unsupported(widget) unless present_identifier?(parameter)

        @data_view_scopes << scope
        body = array(widget['Widgets']).map { render_widget(_1) }
        footer = array(widget['FooterWidgets']).map { render_widget(_1) }
        @data_view_scopes.pop
        props = common_props(widget).merge(
          '$widgetId': scope, class: css_class(widget), body:, footer:,
          hideFooter: !widget.fetch('ShowFooter', true)
        )
        expressions = {
          object: "AssociationObjectProperty({ scope: #{JSON.generate("$#{parameter}")}, " \
                  'path: "", editable: true })',
          emptyMessage: "TextProperty({ value: #{JSON.generate(translated_text(widget['NoEntityMessage']))} })"
        }
        "React.createElement($DataView, #{js_props(props, expressions:)})"
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def render_text_box(widget) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        scope = @data_view_scopes.last
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

      def attribute_property(scope, entity, attribute)
        config = {
          scope:, path: '', entity:, attribute:,
          onChange: { type: 'doNothing', argMap: {}, config: {}, disabledDuringExecution: true },
          isList: false, validation: nil, formatting: {}
        }
        "AttributeProperty(#{js_literal(config)})"
      end

      def data_action?(action)
        @data_view_scopes.any? && %w[Forms$SaveChangesClientAction Forms$CancelChangesClientAction]
          .include?(action['$Type'])
      end

      def render_data_action_button(widget, action) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        type = action['$Type'] == 'Forms$SaveChangesClientAction' ? 'saveChanges' : 'cancelChanges'
        scope = @data_view_scopes.last
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

      def widget_imports # rubocop:disable Metrics/MethodLength
        return '' unless @uses_data_grid || @uses_form_widgets

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
                           'import { FormGroup } from "mendix/widgets/web/FormGroup";',
                           'import { ActionButton } from "mendix/widgets/web/ActionButton";'
                         ])
          widgets.concat(%w[DataView TextBox FormGroup ActionButton])
        end
        imports.uniq.push(
          "const { #{widgets.map { "$#{_1}" }.join(', ')} } = asPluginWidgets({ #{widgets.join(', ')} });"
        ).join("\n")
      end # rubocop:enable Metrics/MethodLength

      def page_title = translated_text(@unit.document['Title'])
      def page_classes = layout&.document&.dig('Appearance', 'Class').to_s

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
