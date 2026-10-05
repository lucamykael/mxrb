# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Runtime contracts are independent of BSON identities and reconstruction
    # artifacts. Keep every named parameter instead of selecting the first one.
    module PresentationContracts
      module_function

      def value_type(kind:, entity: nil, enumeration: nil)
        { 'kind' => kind.to_s, 'entity' => entity, 'enumeration' => enumeration }.compact
      end

      def parameter(name:, type: nil, required: true, default: '')
        { 'name' => name.to_s, 'type' => type, 'required' => required, 'default' => default }.compact
      end

      def variable(name:, type: nil, default: '')
        { 'name' => name.to_s, 'type' => type, 'default' => default }.compact
      end

      def declared_type(definition)
        kind = declared_kind(definition)
        target = { 'object' => :entity, 'list' => :entity, 'enumeration' => :enumeration }[kind]
        raise ArgumentError, "#{kind} values require an #{target}" if target && !definition[target]

        value_type(kind:, entity: definition[:entity], enumeration: definition[:enumeration])
      end

      def declared_kind(definition)
        kind = definition[:type]
        kind ||= definition[:entity] ? 'object' : 'enumeration' if definition[:entity] || definition[:enumeration]
        kind = 'datetime' if kind == 'date_time'
        allowed = %w[string boolean integer long decimal float datetime object list enumeration]
        raise ArgumentError, "invalid page value type #{kind.inspect}" unless allowed.include?(kind)

        kind
      end

      def declared_values(definition, key)
        Array(definition[key]).map do |entry|
          values = { name: entry.fetch(:name), type: declared_type(entry), default: entry.fetch(:default_value) }
          if key == :parameters
            parameter(**values, required: entry.fetch(:required))
          else
            variable(**values)
          end
        end
      end

      def declared(definition)
        configuration(parameters: declared_values(definition, :parameters),
                      variables: declared_values(definition, :variables),
                      popup: definition[:popup_options], autofocus: definition[:autofocus])
      end

      def popup(mode:, width: 0, height: 0, resizable: true, close_action: '')
        { mode: mode.to_s, width:, height:, resizable:, close_action: }
      end

      def configuration(parameters: [], variables: [], popup: nil, autofocus: nil)
        { parameters:, variables:, popup:, autofocus: }.reject do |_key, value|
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end

      def source(value, kind: :configuration)
        return "[#{value.map { source(_1, kind:) }.join(', ')}]" if value.is_a?(Array)
        return value.inspect unless value.is_a?(Hash)

        fields = value.map do |key, item|
          child = { 'parameters' => :parameter, 'variables' => :variable, 'type' => :value_type,
                    'popup' => :popup }.fetch(key.to_s, kind)
          "#{key}: #{source(item, kind: child)}"
        end
        "Mxrb::RubyApp::PresentationContracts.#{kind}(#{fields.join(', ')})"
      end

      def items(value)
        if value.is_a?(Array)
          value.drop(value.first.is_a?(Integer) ? 1 : 0)
        else
          []
        end
      end

      def data_type(document)
        document = document.to_h
        kind = document.fetch('$Type', 'DataTypes$UnknownType').split('$').last.delete_suffix('Type')
        { 'kind' => kind.downcase, 'entity' => document['Entity'],
          'enumeration' => document['Enumeration'] }.compact
      end

      def parameters(document)
        items(document['Parameters']).map do |parameter|
          { 'name' => parameter.fetch('Name'),
            'type' => data_type(parameter['ParameterType'] || parameter['VariableType']),
            'required' => parameter.fetch('IsRequired', true),
            'default' => parameter.fetch('DefaultValue', '') }
        end
      end

      def variables(document)
        items(document['Variables']).map do |variable|
          { 'name' => variable.fetch('Name'), 'type' => data_type(variable['VariableType']),
            'default' => variable.fetch('DefaultValue', '') }
        end
      end

      def page(document, layouts: {})
        configuration(parameters: parameters(document), variables: variables(document),
                      popup: page_popup(document, layouts), autofocus: document['Autofocus'])
      end

      def popup_mode(document, layouts)
        layout = layouts[document.dig('FormCall', 'Form') || document.dig('LayoutCall', 'Layout')] || {}
        layout_type = document['LayoutType'] || layout['LayoutType'] || layout.dig('Content', 'LayoutType')
        return { 'ModalPopup' => 'modal', 'Popup' => 'popup' }[layout_type] if layout_type

        'modal' if %w[PopupWidth PopupHeight].any? { document[_1].to_i.positive? }
      end

      def page_popup(document, layouts)
        mode = popup_mode(document, layouts)
        return unless mode

        popup(mode:, width: document.fetch('PopupWidth', 0), height: document.fetch('PopupHeight', 0),
              resizable: document.fetch('PopupResizable', true), close_action: document.fetch('PopupCloseAction', ''))
      end
    end
  end
end
