# frozen_string_literal: true

module Mxrb
  class Writer
    # Native page variables and association paths shared by data sources/actions.
    module DataSourceBindings
      VARIABLE_FIELDS = { local_variable: 'LocalVariable', page_parameter: 'PageParameter',
                          snippet_parameter: 'SnippetParameter', widget: 'Widget' }.freeze
      private_constant :VARIABLE_FIELDS

      private

      def data_view_entity_ref_doc(source)
        native = deep_copy(source.fetch(:entity_ref_native, {}))
        fields = if source.fetch(:kind).to_sym == :association
                   { '$Type' => 'DomainModels$IndirectEntityRef',
                     'Steps' => IO::BsonCodec.build_array(Array(source[:steps]).map { data_view_ref_step(_1) }, marker: 2) }
                 else
                   { '$Type' => 'DomainModels$DirectEntityRef', 'Entity' => source.fetch(:entity).to_s }
                 end
        native.merge('$ID' => SecureRandom.uuid).merge(fields)
      end

      def data_view_ref_step(step)
        step = symbolize_data_view_value(step)
        deep_copy(step.fetch(:unknown_native, {})).merge(
          '$ID' => SecureRandom.uuid, '$Type' => 'DomainModels$EntityRefStep',
          'Association' => step.fetch(:association).to_s, 'DestinationEntity' => step.fetch(:entity).to_s
        )
      end

      def data_view_mappings_doc(mappings, kind)
        IO::BsonCodec.build_array(Array(mappings).map { data_view_mapping_doc(_1, kind) }, marker: 2)
      end

      def data_view_mapping_doc(mapping, kind)
        mapping = symbolize_data_view_value(mapping)
        type = kind == :nanoflow ? 'Forms$NanoflowParameterMapping' : 'Forms$MicroflowParameterMapping'
        deep_copy(mapping.fetch(:unknown_native, {})).merge(
          '$ID' => SecureRandom.uuid, '$Type' => type,
          'Expression' => mapping.fetch(:expression, '').to_s, 'Parameter' => mapping.fetch(:parameter).to_s,
          'Variable' => data_view_page_variable_doc(mapping[:variable])
        )
      end

      def data_view_page_variable_doc(raw_variable)
        return nil unless raw_variable

        variable = symbolize_data_view_value(raw_variable)
        doc = data_view_variable_base(variable)
        field = VARIABLE_FIELDS[variable.fetch(:kind, :page_parameter).to_sym]
        doc[field] = variable.fetch(:name, '').to_s if field
        doc[field] = doc[field].split('.').last.to_s if field == 'LocalVariable'
        doc
      end

      def data_view_variable_base(variable)
        deep_copy(variable.fetch(:unknown_native, {})).merge(
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$PageVariable',
          'LocalVariable' => '', 'PageParameter' => '', 'SnippetParameter' => '', 'Widget' => '',
          'SubKey' => variable.fetch(:sub_key, '').to_s, 'UseAllPages' => variable[:use_all_pages] == true
        )
      end
    end

    # Serializes client data sources while preserving unknown native properties.
    module DataSources
      include DataSourceBindings
      SOURCE_TYPES = { context: 'Forms$DataViewSource', association: 'Forms$DataViewSource',
                       microflow: 'Forms$MicroflowSource', nanoflow: 'Forms$NanoflowSource',
                       listen: 'Forms$ListenTargetSource' }.freeze
      private_constant :SOURCE_TYPES

      private

      def data_view_doc(source, widgets, module_name: nil)
        source = qualify_data_view_source(symbolize_data_view_value(source), module_name)
        data_view_defaults.merge(
          '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DataView', 'Name' => 'dataView',
          'Appearance' => appearance_doc, 'DataSource' => data_view_source_doc(source),
          'FooterWidgets' => IO::BsonCodec.build_array([], marker: 2), 'NoEntityMessage' => text_doc(''),
          'Widgets' => IO::BsonCodec.build_array(widgets, marker: 2)
        )
      end

      def data_view_defaults
        { 'ConditionalEditabilitySettings' => nil, 'ConditionalVisibilitySettings' => nil,
          'Editability' => 'Always', 'LabelWidth' => 0, 'ReadOnlyStyle' => 'Control',
          'ShowFooter' => false, 'TabIndex' => 0 }
      end

      def data_view_source_doc(source)
        source = symbolize_data_view_value(source)
        fields = data_view_source_fields(source)
        native = deep_copy(source.fetch(:unknown_native, {})).reject { |key, _| %w[$ID $Type].include?(key.to_s) }
        type = SOURCE_TYPES.fetch(source.fetch(:kind).to_sym) { source.fetch(:native_type) }
        native.merge('$ID' => SecureRandom.uuid, '$Type' => type,
                     'ForceFullObjects' => source[:force_full_objects] == true).merge(fields)
      end

      def data_view_source_fields(source)
        case source.fetch(:kind).to_sym
        when :context, :association then data_view_context_fields(source)
        when :nanoflow then data_view_nanoflow_fields(source)
        when :microflow then { 'MicroflowSettings' => data_view_microflow_settings(source) }
        when :listen then { 'ListenTarget' => source.fetch(:target) }
        when :native then {}
        else raise ArgumentError, "unsupported data view source #{source.fetch(:kind).inspect}"
        end
      end

      def data_view_context_fields(source)
        { 'EntityRef' => data_view_entity_ref_doc(source),
          'SourceVariable' => data_view_page_variable_doc(source[:variable]) }
      end

      def data_view_nanoflow_fields(source)
        { 'Nanoflow' => source.fetch(:name),
          'ParameterMappings' => data_view_mappings_doc(source[:mappings], :nanoflow) }
      end

      def data_view_microflow_settings(source)
        client_microflow_settings_doc(source.fetch(:name)).merge(deep_copy(source.fetch(:settings_native, {})))
                                                          .merge('ParameterMappings' => data_view_mappings_doc(
                                                            source[:mappings], :microflow
                                                          ))
      end

      def client_microflow_settings_doc(name)
        { '$ID' => SecureRandom.uuid, '$Type' => 'Forms$MicroflowSettings',
          'Asynchronous' => false, 'ConfirmationInfo' => nil, 'FormValidations' => 'All',
          'Microflow' => name, 'OutputMappings' => IO::BsonCodec.build_array([], marker: 3),
          'ParameterMappings' => IO::BsonCodec.build_array([], marker: 2),
          'ProgressBar' => 'None', 'ProgressMessage' => nil }
      end
    end
  end
end
