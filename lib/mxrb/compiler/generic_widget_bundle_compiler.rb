# frozen_string_literal: true

require 'json'
require 'zip'

module Mxrb
  module Compiler
    # Compiles schema-described pluggable widgets whose properties use the standard client contracts.
    # rubocop:disable Metrics
    class GenericWidgetBundleCompiler
      include ModelValues

      attr_reader :component_name, :module_path

      def initialize(source, page_name, widget, scope:, entity:, render_widgets: nil, key_prefix: 'p',
                     action_property: nil)
        @source = source
        @page_name = page_name
        @widget = widget
        @scope = scope
        @entity = entity.to_s
        @render_widgets = render_widgets
        @key_prefix = key_prefix
        @action_property = action_property
        @index = source.document_index
        @widget_type = find_widget_type
        @values = property_values(widget['Object'])
        @list_data_source = @values.values.find do |type, value, _metadata|
          type == 'DataSource' && database_list_property(value)
        end&.last
        @component_name = widget_id.to_s.split('.').last
        @module_path = widget_id.to_s.tr('.', '/')
      end

      def supported?
        present_identifier?(@component_name) && package_module? &&
          @values.values.all? { supported_property?(_1) }
      end

      def render
        properties = @values.each_with_object({}) do |(key, pair), result|
          compiled = compile_property(pair)
          result[key.to_sym] = compiled unless compiled.equal?(:undefined)
        end
        properties.merge!(key: widget_key, '$widgetId': widget_key, class: css_class)
        "React.createElement($#{@component_name}, #{javascript(properties)})"
      end

      private

      def widget_id = @widget_type&.fetch('WidgetId', nil)

      def find_widget_type
        object_type_id = IO::BsonCodec.extract_id(@widget.dig('Object', 'TypePointer'))
        @index.values.find do |document|
          IO::BsonCodec.extract_id(document.dig('ObjectType', '$ID')) == object_type_id
        end
      end

      def property_values(object)
        array(object&.fetch('Properties', nil)).filter_map do |property|
          type = @index[IO::BsonCodec.extract_id(property['TypePointer'])]
          next unless type

          value_type = type.fetch('ValueType', {})
          [type.fetch('PropertyKey'), [value_type['Type'], property['Value'], value_type]]
        end.to_h
      end

      def supported_property?(pair)
        type, value, metadata = pair
        return true if %w[Boolean Integer Decimal Enumeration String System].include?(type)
        return value['DataSource'].nil? || !database_list_property(value).nil? if type == 'DataSource'
        return true if type == 'Association'
        return true if type == 'Attribute' && value['AttributeRef'].nil?
        return true if type == 'Selection'
        return value['Icon'].nil? if type == 'Icon'
        return value['Image'].to_s.empty? if type == 'Image'
        return true if %w[Expression TextTemplate].include?(type) && expression_property(type, value, metadata)
        return true if type == 'Attribute' && attribute_property(value, metadata)
        return no_action?(value) || !compiled_action(value).nil? if type == 'Action'
        return array(value['Widgets']).empty? || @render_widgets if type == 'Widgets'
        return supported_objects?(value) if type == 'Object'

        false
      end

      def compile_property(pair)
        type, value, metadata = pair
        case type
        when 'Boolean' then value['PrimitiveValue'] == 'true'
        when 'Integer' then value['PrimitiveValue'].to_i
        when 'Decimal' then value['PrimitiveValue'].to_f
        when 'Enumeration', 'String' then value['PrimitiveValue'].to_s
        when 'Expression', 'TextTemplate' then raw(expression_property(type, value, metadata))
        when 'DataSource' then database_list_property(value)&.then { raw(_1) } || :undefined
        when 'Action' then compiled_action(value)&.then { raw(_1) } || :undefined
        when 'Association' then :undefined
        when 'Attribute' then attribute_property(value, metadata)&.then { raw(_1) } || :undefined
        when 'Selection' then raw(selection_property(value))
        when 'Icon', 'Image' then :undefined
        when 'Widgets' then compile_widgets(value, metadata)
        when 'Object' then compile_objects(value)
        else :undefined
        end
      end

      def compile_widgets(value, metadata = nil)
        widgets = array(value['Widgets'])
        return [] if widgets.empty?

        rendered = @render_widgets.call(widgets)
        return rendered unless data_source_bound?(metadata)

        raw("TemplatedWidgetProperty(#{javascript(
          children: raw("() => #{javascript(rendered)}"), dataSourceId: widget_key, editable: false
        )})")
      end

      def supported_objects?(value)
        array(value['Objects']).all? do |object|
          values = property_values(object)
          !values.empty? && values.values.all? { supported_property?(_1) }
        end
      end

      def compile_objects(value)
        array(value['Objects']).map do |object|
          values = property_values(object)
          with_list_data_source(values) do
            values.each_with_object({}) do |(key, pair), result|
              compiled = compile_property(pair)
              result[key.to_sym] = compiled unless compiled.equal?(:undefined)
            end
          end
        end
      end

      def with_list_data_source(values)
        previous = @list_data_source
        @list_data_source = values.values.find do |type, value, _metadata|
          type == 'DataSource' && database_list_property(value)
        end&.last
        yield
      ensure
        @list_data_source = previous
      end

      def selection_property(value)
        "SelectionProperty(#{javascript(selectionType: value.fetch('Selection', 'None'), dataSourceId: widget_key)})"
      end

      def expression_property(type, value, metadata = nil)
        expression = type == 'Expression' ? compile_expression(value['Expression']) : compile_template(value)
        return unless expression

        list_bound = data_source_bound?(metadata) && @list_data_source
        args = expression_variables(expression).to_h do |variable|
          [variable.to_sym, { widget: list_bound ? widget_key : @scope, source: 'object' }]
        end
        property = list_bound ? 'ListExpressionProperty' : 'ExpressionProperty'
        config = { expression: { expr: expression, args: } }
        config[:dataSourceId] = widget_key if list_bound
        "#{property}(#{javascript(config)})"
      end

      def database_list_property(value)
        source = value['DataSource'] || {}
        return unless source['$Type'] == 'CustomWidgets$CustomWidgetXPathSource'

        entity = source.dig('EntityRef', 'Entity').to_s
        return unless present_qualified_name?(entity)

        config = {
          dataSourceId: widget_key, entity:,
          operationId: WebOperationCompiler.operation_id(@page_name, @widget['Name']),
          sort: sort_items(source)
        }
        "DatabaseObjectListProperty(#{javascript(config)})"
      end

      def compiled_action(value)
        action = value['Action'] || {}
        return if action['$Type'].to_s.empty? || action['$Type'] == 'Forms$NoAction'

        @action_property&.call(action)
      end

      def sort_items(source)
        array(source.dig('SortBar', 'SortItems')).filter_map do |item|
          attribute = item.dig('AttributeRef', 'Attribute').to_s.split('.').last
          next unless present_identifier?(attribute)

          [attribute, item['SortOrder'].to_s.casecmp('descending').zero? ? 'desc' : 'asc']
        end
      end

      def compile_expression(source)
        value = source.to_s.strip
        return { type: 'literal', value: nil } if value.empty? || value == 'empty'
        return variable_expression(value) if value.match?(%r{\A\$[A-Za-z_]\w*(?:/[A-Za-z_]\w*)*\z})
        return { type: 'literalNumeric', value: } if value.match?(/\A-?\d+(?:\.\d+)?\z/)
        return { type: 'literal', value: value == 'true' } if %w[true false].include?(value)
        return { type: 'literal', value: value[1..-2] } if quoted?(value)

        nil
      end

      def variable_expression(source)
        _variable, *path = source.delete_prefix('$').split('/')
        { type: 'variable', variable: 'currentObject' }.tap do |result|
          result[:path] = path.join('/') unless path.empty?
        end
      end

      def compile_template(value)
        template = value['TextTemplate']
        text = translated_text(template)
        parameters = array(template&.fetch('Parameters', nil))
        return { type: 'literal', value: text } if parameters.empty?

        expressions = parameters.map { template_parameter(_1) }
        return unless expressions.all?
        return expressions.first if text == '{1}' && expressions.one?

        format_expression(text, expressions)
      end

      def template_parameter(parameter)
        attribute = parameter.dig('AttributeRef', 'Attribute').to_s
        return compile_expression(parameter['Expression']) if attribute.empty?

        name = attribute.split('.').last
        variable = { type: 'variable', variable: 'currentObject', path: name }
        enumeration = enumeration_name(attribute)
        return variable unless enumeration

        { type: 'function', name: 'getCaption',
          parameters: [variable, { type: 'literal', value: enumeration }] }
      end

      def format_expression(text, expressions)
        pieces = text.split(/(\{\d+\})/).filter_map do |piece|
          index = piece[/\A\{(\d+)\}\z/, 1]
          index ? expressions[index.to_i - 1] : ({ type: 'literal', value: piece } unless piece.empty?)
        end
        pieces.compact.reduce { |left, right| { type: 'function', name: '+', parameters: [left, right] } }
      end

      def attribute_property(value, metadata = nil)
        attribute = value.dig('AttributeRef', 'Attribute').to_s
        return unless (@scope || @list_data_source) && attribute.include?('.')

        entity, _, name = attribute.rpartition('.')
        if data_source_bound?(metadata) && @list_data_source
          return "ListAttributeProperty(#{javascript(
            path: '', entity:, attribute: name, dataSourceId: widget_key, isList: false
          )})"
        end

        "AttributeProperty(#{javascript(
          scope: @scope, path: '', entity:, attribute: name,
          onChange: { type: 'doNothing', argMap: {}, config: {}, disabledDuringExecution: true },
          isList: false, validation: nil, formatting: {}
        )})"
      end

      def data_source_bound?(metadata)
        !metadata.to_h.fetch('DataSourceProperty', '').to_s.empty?
      end

      def expression_variables(expression)
        case expression
        when Hash
          own = expression[:type] == 'variable' ? [expression[:variable]] : []
          own + expression.values.flat_map { expression_variables(_1) }
        when Array then expression.flat_map { expression_variables(_1) }
        else []
        end.uniq
      end

      def enumeration_name(attribute)
        module_name, entity_name, attribute_name = attribute.split('.', 3)
        domain = @source.units_of('DomainModels$DomainModel').find { _1.module_name == module_name }
        entity = array(domain&.document&.fetch('Entities', nil)).find { _1['Name'] == entity_name }
        member = array(entity&.fetch('Attributes', nil)).find { _1['Name'] == attribute_name }
        member&.dig('NewType', 'Enumeration').to_s.then { _1.empty? ? nil : _1 }
      end

      def translated_text(template)
        items = array(template&.dig('Template', 'Items'))
        items.find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', '') ||
          items.first&.fetch('Text', '') || ''
      end

      def package_module?
        root = File.dirname(@source.path)
        direct = File.join(root, 'widgets', "#{@module_path}.mjs")
        return true if File.file?(direct)

        entry = "#{@module_path}.mjs"
        Dir.glob(File.join(root, 'widgets', '*.mpk')).any? do |path|
          Zip::File.open(path) { _1.find_entry(entry) }
        rescue Zip::Error
          false
        end
      end

      def no_action?(value) = value['Action'].nil? || value.dig('Action', '$Type') == 'Forms$NoAction'
      def widget_key = "#{@key_prefix}.#{@page_name}.#{@widget['Name']}"

      def css_class
        ["mx-name-#{@widget['Name']}", @widget.dig('Appearance', 'Class')]
          .map(&:to_s).reject(&:empty?).uniq.join(' ')
      end

      def present_identifier?(value) = value.to_s.match?(/\A[A-Za-z_$][A-Za-z0-9_$]*\z/)

      def present_qualified_name?(value)
        value.to_s.split('.').length >= 2 && value.to_s.split('.').all? { present_identifier?(_1) }
      end

      def quoted?(value) = value.start_with?("'", '"') && value.end_with?(value[0])
      def raw(value) = { '$raw' => value }

      def javascript(value)
        return value['$raw'] if value.is_a?(Hash) && value.key?('$raw')
        return "[#{value.map { javascript(_1) }.join(', ')}]" if value.is_a?(Array)
        if value.is_a?(Hash)
          return "{ #{value.map { |key, item| "#{JSON.generate(key)}: #{javascript(item)}" }.join(', ')} }"
        end

        JSON.generate(value)
      end
    end
    # rubocop:enable Metrics
  end
end
