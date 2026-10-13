# frozen_string_literal: true

module Mxrb
  class Exporter
    # Declares Java and JavaScript actions with their parameter and return types as Ruby.
    module CodeActionDeclarations
      private

      def code_action_declaration(document, language)
        doc = document.fetch(:doc)
        options = {
          parameters: bson_items(doc['Parameters']).map { code_action_parameter_spec(_1) },
          return_type: code_action_type_spec(doc.fetch('JavaReturnType')),
          type_parameters: bson_items(doc['TypeParameters']).map { code_action_type_parameter_spec(_1) },
          action_default_return_name: doc.fetch('ActionDefaultReturnName', ''),
          documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
          export_level: doc.fetch('ExportLevel', 'Hidden'),
          microflow_info: code_action_info_spec(doc['MicroflowActionInfo']),
          parameters_marker: bson_marker(doc['Parameters'], 2),
          type_parameters_marker: bson_marker(doc['TypeParameters'], 2)
        }
        options[:platform] = doc.fetch('Platform', '') if language == :javascript
        semantic_call_source("#{language}_action", document, options)
      end

      def code_action_parameter_spec(parameter)
        {
          id: document_id(parameter), name: parameter.fetch('Name'),
          category: parameter.fetch('Category', ''),
          description: parameter.fetch('Description', ''),
          required: parameter['IsRequired'] == true,
          type: code_action_parameter_type_spec(parameter.fetch('ParameterType'))
        }
      end

      def code_action_parameter_type_spec(parameter_type)
        kind = parameter_type.fetch('$Type')
        common = { id: document_id(parameter_type) }
        case kind
        when 'CodeActions$BasicParameterType'
          common.merge(kind: :basic, type: code_action_type_spec(parameter_type.fetch('Type')))
        when 'CodeActions$StringTemplateParameterType'
          common.merge(kind: :string_template, grammar: parameter_type.fetch('Grammar', ''))
        when 'CodeActions$EntityTypeParameterType'
          common.merge(
            kind: :entity_type_parameter,
            pointer: document_id_value(parameter_type['TypeParameterPointer'])
          )
        when 'JavaActions$MicroflowJavaActionParameterType'
          common.merge(kind: :microflow)
        when 'JavaScriptActions$NanoflowJavaScriptActionParameterType'
          common.merge(kind: :nanoflow)
        else
          raise KeyError, "unsupported code action parameter type #{kind}"
        end
      end

      def code_action_type_spec(type)
        kind = type.fetch('$Type')
        common = { id: document_id(type) }
        primitive = {
          'CodeActions$BooleanType' => :boolean,
          'CodeActions$DateTimeType' => :datetime,
          'CodeActions$DecimalType' => :decimal,
          'CodeActions$IntegerType' => :integer,
          'CodeActions$StringType' => :string,
          'CodeActions$VoidType' => :void
        }[kind]
        return common.merge(kind: primitive) if primitive

        case kind
        when 'CodeActions$ConcreteEntityType'
          common.merge(kind: :concrete_entity, entity: type.fetch('Entity', ''))
        when 'CodeActions$EnumerationType'
          common.merge(kind: :enumeration, enumeration: type.fetch('Enumeration', ''))
        when 'CodeActions$ParameterizedEntityType'
          common.merge(
            kind: :parameterized_entity,
            pointer: document_id_value(type['TypeParameterPointer'])
          )
        when 'CodeActions$ListType'
          common.merge(kind: :list, parameter: code_action_type_spec(type.fetch('Parameter')))
        else
          raise KeyError, "unsupported code action type #{kind}"
        end
      end

      def code_action_type_parameter_spec(parameter)
        { id: document_id(parameter), name: parameter.fetch('Name') }
      end

      def code_action_info_spec(info)
        return nil unless info.is_a?(Hash)

        spec = {
          id: document_id(info), caption: info.fetch('Caption', ''),
          category: info.fetch('Category', '')
        }
        {
          'IconData' => :icon, 'IconDataDark' => :icon_dark,
          'ImageData' => :image, 'ImageDataDark' => :image_dark
        }.each do |field, key|
          spec[key] = code_action_binary_spec(info[field]) if info.key?(field)
        end
        spec
      end

      def code_action_binary_spec(value)
        return { data: '', subtype: :generic } if value.nil?
        raise KeyError, "unsupported code action binary #{value.class}" unless value.is_a?(BSON::Binary)

        { data: Base64.strict_encode64(value.data), subtype: value.type.to_sym }
      end

      def document_id_value(value)
        IO::BsonCodec.extract_id(value).to_s
      end

      def semantic_code_action?(doc)
        code_action_type_spec(doc.fetch('JavaReturnType'))
        bson_items(doc['Parameters']).each do |parameter|
          code_action_parameter_type_spec(parameter.fetch('ParameterType'))
        end
        bson_items(doc['TypeParameters']).each { code_action_type_parameter_spec(_1) }
        code_action_info_spec(doc['MicroflowActionInfo'])
        true
      rescue KeyError, TypeError, NoMethodError
        false
      end
    end
  end
end
