# frozen_string_literal: true

require 'base64'
require 'securerandom'

module Mxrb
  module Dsl
    # Semantic declarations for Java and JavaScript action signatures. The
    # implementation remains in javasource/javascriptsource; this document
    # describes the Mendix-facing contract that Studio Pro edits and invokes.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ModuleLength, Metrics/ParameterLists
    module CodeActions
      def java_action(name, parameters:, return_type:, type_parameters: [],
                      action_default_return_name: 'ReturnValueName', documentation: '',
                      excluded: false, export_level: 'Hidden', microflow_info: nil,
                      parameters_marker: 2, type_parameters_marker: 2,
                      unit_id: nil, container_id: nil)
        code_action_document(
          name,
          'JavaActions$JavaAction',
          parameters:, return_type:, type_parameters:,
          action_default_return_name:, documentation:, excluded:, export_level:,
          microflow_info:, parameters_marker:, type_parameters_marker:,
          unit_id:, container_id:
        )
      end

      def javascript_action(name, parameters:, return_type:, platform:,
                            type_parameters: [], action_default_return_name: 'ReturnValueName',
                            documentation: '', excluded: false, export_level: 'Hidden',
                            microflow_info: nil, parameters_marker: 2,
                            type_parameters_marker: 2, unit_id: nil, container_id: nil)
        code_action_document(
          name,
          'JavaScriptActions$JavaScriptAction',
          parameters:, return_type:,
          type_parameters:, action_default_return_name:, documentation:, excluded:,
          export_level:, microflow_info:, parameters_marker:, type_parameters_marker:,
          unit_id:, container_id:, platform:
        )
      end

      private

      def code_action_document(name, type, parameters:, return_type:, type_parameters:,
                               action_default_return_name:, documentation:, excluded:,
                               export_level:, microflow_info:, parameters_marker:,
                               type_parameters_marker:, unit_id:, container_id:, platform: nil)
        prefix = type.split('$', 2).first
        document = code_action_identity(unit_id).merge(
          'ActionDefaultReturnName' => action_default_return_name.to_s,
          'Documentation' => documentation.to_s,
          'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s,
          'JavaReturnType' => code_action_type_document(return_type),
          'MicroflowActionInfo' => code_action_info_document(microflow_info),
          'Parameters' => code_action_array(
            Array(parameters).map { code_action_parameter_document(_1, prefix) },
            parameters_marker
          ),
          'TypeParameters' => code_action_array(
            Array(type_parameters).map { code_action_type_parameter_document(_1) },
            type_parameters_marker
          )
        )
        document['Platform'] = platform.to_s unless platform.nil?
        native_document(
          name, type:, unit_id:, container_id:, containment: 'Documents',
                deep_structure: document
        )
      end

      def code_action_parameter_document(source, prefix)
        spec = code_action_spec(source)
        code_action_identity(spec[:id]).merge(
          '$Type' => "#{prefix}$#{prefix == 'JavaActions' ? 'JavaActionParameter' : 'JavaScriptActionParameter'}",
          'Category' => spec.fetch(:category, '').to_s,
          'Description' => spec.fetch(:description, '').to_s,
          'IsRequired' => spec.fetch(:required, true) == true,
          'Name' => spec.fetch(:name).to_s,
          'ParameterType' => code_action_parameter_type_document(spec.fetch(:type))
        )
      end

      def code_action_parameter_type_document(source)
        spec = code_action_spec(source)
        kind = spec.fetch(:kind).to_sym
        identity = code_action_identity(spec[:id])
        case kind
        when :basic
          identity.merge(
            '$Type' => 'CodeActions$BasicParameterType',
            'Type' => code_action_type_document(spec.fetch(:type))
          )
        when :string_template
          identity.merge(
            '$Type' => 'CodeActions$StringTemplateParameterType',
            'Grammar' => spec.fetch(:grammar, '').to_s
          )
        when :entity_type_parameter
          identity.merge(
            '$Type' => 'CodeActions$EntityTypeParameterType',
            'TypeParameterPointer' => spec.fetch(:pointer, '').to_s
          )
        when :microflow
          identity.merge('$Type' => 'JavaActions$MicroflowJavaActionParameterType')
        else
          raise ArgumentError, "unsupported code action parameter type #{kind.inspect}"
        end
      end

      def code_action_type_document(source)
        spec = code_action_spec(source)
        kind = spec.fetch(:kind).to_sym
        identity = code_action_identity(spec[:id])
        type = {
          boolean: 'Boolean', datetime: 'DateTime', decimal: 'Decimal', integer: 'Integer',
          string: 'String', void: 'Void'
        }[kind]
        return identity.merge('$Type' => "CodeActions$#{type}Type") if type

        case kind
        when :concrete_entity
          identity.merge(
            '$Type' => 'CodeActions$ConcreteEntityType',
            'Entity' => spec.fetch(:entity, '').to_s
          )
        when :enumeration
          identity.merge(
            '$Type' => 'CodeActions$EnumerationType',
            'Enumeration' => spec.fetch(:enumeration, '').to_s
          )
        when :parameterized_entity
          identity.merge(
            '$Type' => 'CodeActions$ParameterizedEntityType',
            'TypeParameterPointer' => spec.fetch(:pointer, '').to_s
          )
        when :list
          identity.merge(
            '$Type' => 'CodeActions$ListType',
            'Parameter' => code_action_type_document(spec.fetch(:parameter))
          )
        else
          raise ArgumentError, "unsupported code action data type #{kind.inspect}"
        end
      end

      def code_action_type_parameter_document(source)
        spec = code_action_spec(source)
        code_action_identity(spec[:id]).merge(
          '$Type' => 'CodeActions$TypeParameter', 'Name' => spec.fetch(:name).to_s
        )
      end

      def code_action_info_document(source)
        return nil if source.nil?

        spec = code_action_spec(source)
        document = code_action_identity(spec[:id]).merge(
          '$Type' => 'CodeActions$MicroflowActionInfo',
          'Caption' => spec.fetch(:caption, '').to_s,
          'Category' => spec.fetch(:category, '').to_s
        )
        {
          icon: 'IconData', icon_dark: 'IconDataDark',
          image: 'ImageData', image_dark: 'ImageDataDark'
        }.each do |key, field|
          document[field] = code_action_binary(spec[key]) if spec.key?(key)
        end
        document
      end

      def code_action_binary(source)
        return source if source.is_a?(BSON::Binary)

        spec = code_action_spec(source)
        BSON::Binary.new(
          Base64.strict_decode64(spec.fetch(:data).to_s),
          spec.fetch(:subtype, :generic).to_sym
        )
      end

      def code_action_identity(id)
        { '$ID' => id.to_s.empty? ? SecureRandom.uuid : id.to_s }
      end

      def code_action_array(items, marker)
        IO::BsonCodec.build_array(items, marker: marker.to_i)
      end

      def code_action_spec(value)
        value.to_h.transform_keys(&:to_sym)
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ModuleLength, Metrics/ParameterLists
  end
end
