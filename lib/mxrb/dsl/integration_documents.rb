# frozen_string_literal: true

require 'securerandom'

module Mxrb
  module Dsl
    # Semantic Ruby declarations for Mendix integration documents. The public
    # methods deliberately compile into the same native-document collection so
    # they retain the established authoritative lifecycle and container logic.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ModuleLength, Metrics/ParameterLists
    module IntegrationDocuments
      DATA_TYPES = {
        unknown: 'DataTypes$UnknownType',
        string: 'DataTypes$StringType',
        integer: 'DataTypes$IntegerType',
        long: 'DataTypes$LongType',
        decimal: 'DataTypes$DecimalType',
        boolean: 'DataTypes$BooleanType',
        datetime: 'DataTypes$DateTimeType',
        binary: 'DataTypes$BinaryType'
      }.freeze
      DATABASE_QUERY_TYPES = { select: 1, execute: 2 }.freeze

      def json_structure(name, snippet:, elements:, documentation: '', excluded: false,
                         export_level: 'Hidden', unit_id: nil, container_id: nil)
        doc = integration_identity(unit_id).merge(
          'Documentation' => documentation.to_s,
          'Elements' => integration_array(elements.map { json_element_document(_1) }, 2),
          'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s,
          'JsonSnippet' => snippet.to_s
        )
        semantic_native_document(
          name, 'JsonStructures$JsonStructure', doc, unit_id:, container_id:
        )
      end

      def import_mapping(name, json_structure:, elements:, documentation: '', excluded: false,
                         export_level: 'Hidden', parameter_type: :unknown, parameter_type_id: nil,
                         use_subtransactions: false, unit_id: nil, container_id: nil,
                         **options)
        doc = mapping_document(
          name, :import, json_structure:, elements:, documentation:, excluded:,
                         export_level:, unit_id:, parameter_type:, parameter_type_id:,
                         use_subtransactions:, options:
        )
        semantic_native_document(
          name, 'ImportMappings$ImportMapping', doc, unit_id:, container_id:
        )
      end

      def export_mapping(name, json_structure:, elements:, documentation: '', excluded: false,
                         export_level: 'Hidden', null_value: 'LeaveOutElement',
                         header_parameter: false, unit_id: nil, container_id: nil,
                         **options)
        doc = mapping_document(
          name, :export, json_structure:, elements:, documentation:, excluded:,
                         export_level:, unit_id:, null_value:, header_parameter:, options:
        )
        semantic_native_document(
          name, 'ExportMappings$ExportMapping', doc, unit_id:, container_id:
        )
      end

      def published_rest_service(name, path:, version:, resources:, service_name: nil,
                                 allowed_roles: [], authentication_types: [],
                                 authentication_microflow: '', documentation: '',
                                 public_documentation: '', excluded: false,
                                 export_level: 'Hidden', enable_cors: nil,
                                 requires_authentication: nil, unit_id: nil,
                                 container_id: nil)
        doc = integration_identity(unit_id).merge(
          'AllowedRoles' => integration_array(Array(allowed_roles).map(&:to_s), 1),
          'AuthenticationMicroflow' => authentication_microflow.to_s,
          'AuthenticationTypes' => integration_array(
            Array(authentication_types).map { integration_enum(_1) }, 1
          ),
          'CorsConfiguration' => nil,
          'Documentation' => documentation.to_s,
          'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s,
          'Parameters' => integration_array([], 3),
          'Path' => path.to_s,
          'PublicDocumentation' => public_documentation.to_s,
          'Resources' => integration_array(
            Array(resources).map { rest_resource_document(_1) }, 3
          ),
          'ServiceName' => (service_name || name).to_s,
          'Version' => version.to_s
        )
        doc['EnableCors'] = enable_cors unless enable_cors.nil?
        doc['RequiresAuthentication'] = requires_authentication == true unless requires_authentication.nil?
        semantic_native_document(
          name, 'Rest$PublishedRestService', doc, unit_id:, container_id:
        )
      end

      def oql_source_document(name, query:, documentation: '', excluded: false,
                              export_level: 'Hidden', unit_id: nil, container_id: nil)
        doc = integration_identity(unit_id).merge(
          'Documentation' => documentation.to_s,
          'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s,
          'Oql' => query.to_s
        )
        semantic_native_document(
          name, 'DomainModels$ViewEntitySourceDocument', doc, unit_id:, container_id:
        )
      end

      def database_connection(name, database_type:, connection_string:, username:, password:,
                              connection:, queries:, properties: [], documentation: '',
                              excluded: false, export_level: 'Hidden',
                              properties_marker: 2, queries_marker: 3,
                              unit_id: nil, container_id: nil)
        doc = integration_identity(unit_id).merge(
          'AdditionalProperties' => integration_array(
            Array(properties).map { database_property_document(_1) }, properties_marker
          ),
          'ConnectionInput' => database_connection_parts_document(connection),
          'ConnectionString' => connection_string.to_s,
          'DatabaseType' => database_type.to_s,
          'Documentation' => documentation.to_s,
          'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s,
          'Password' => password.to_s,
          'Queries' => integration_array(
            Array(queries).map { database_query_document(_1) }, queries_marker
          ),
          'UserName' => username.to_s
        )
        semantic_native_document(
          name, 'DatabaseConnector$DatabaseConnection', doc, unit_id:, container_id:
        )
      end

      private

      def semantic_native_document(name, type, doc, unit_id:, container_id:)
        native_document(
          name, type:, unit_id:, container_id:, containment: 'Documents',
                deep_structure: doc
        )
      end

      def mapping_document(_name, direction, json_structure:, elements:, documentation:,
                           excluded:, export_level:, unit_id:, options:, **settings)
        prefix = direction == :import ? 'ImportMappings' : 'ExportMappings'
        doc = integration_identity(unit_id).merge(
          'Documentation' => documentation.to_s,
          'Elements' => integration_array(
            Array(elements).map { mapping_element_document(_1, prefix) }, 2
          ),
          'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s,
          'JsonStructure' => json_structure.to_s,
          'MappingSourceReference' => nil,
          'MessageDefinition' => options.fetch(:message_definition, '').to_s,
          'MessageDefinition2' => options.fetch(:message_definition2, '').to_s,
          'OperationName' => options.fetch(:operation_name, '').to_s,
          'PublicName' => options.fetch(:public_name, '').to_s,
          'ServiceName' => options.fetch(:service_name, '').to_s,
          'WsdlFile' => options.fetch(:wsdl_file, '').to_s,
          'XmlSchema' => options.fetch(:xml_schema, '').to_s,
          'XsdRootElementName' => options.fetch(:xsd_root_element_name, '').to_s
        )
        if direction == :import
          doc.merge!(
            'ParameterType' => data_type_document(
              settings.fetch(:parameter_type, :unknown), settings[:parameter_type_id]
            ),
            'UseSubtransactionsForMicroflows' => settings.fetch(:use_subtransactions, false) == true
          )
        else
          doc.merge!(
            'IsHeaderParameter' => settings.fetch(:header_parameter, false) == true,
            'NullValueOption' => integration_enum(settings.fetch(:null_value, 'LeaveOutElement')),
            'ParameterName' => options.fetch(:parameter_name, '').to_s
          )
        end
        doc
      end

      def json_element_document(source)
        spec = integration_spec(source)
        integration_identity(spec[:id]).merge(
          '$Type' => 'JsonStructures$JsonElement',
          'Children' => integration_array(
            Array(spec[:children]).map { json_element_document(_1) }, 2
          ),
          'ElementType' => integration_enum(spec.fetch(:kind, :value)),
          'ErrorMessage' => spec.fetch(:error, '').to_s,
          'ExposedItemName' => spec.fetch(:item_name, '').to_s,
          'ExposedName' => spec.fetch(:name, '').to_s,
          'FractionDigits' => spec.fetch(:fraction_digits, -1).to_i,
          'IsDefaultType' => spec.fetch(:default_type, false) == true,
          'MaxLength' => spec.fetch(:max_length, -1).to_i,
          'MaxOccurs' => spec.fetch(:max_occurs, 1).to_i,
          'MinOccurs' => spec.fetch(:min_occurs, 0).to_i,
          'Nillable' => spec.fetch(:nillable, true) == true,
          'OriginalValue' => spec.fetch(:original, '').to_s,
          'Path' => spec.fetch(:path, '').to_s,
          'PrimitiveType' => integration_enum(spec.fetch(:primitive, :unknown)),
          'TotalDigits' => spec.fetch(:total_digits, -1).to_i,
          'WarningMessage' => spec.fetch(:warning, '').to_s
        )
      end

      def mapping_element_document(source, prefix)
        spec = integration_spec(source)
        kind = spec.fetch(:kind, :value).to_sym
        common = integration_identity(spec[:id]).merge(
          '$Type' => "#{prefix}$#{kind == :object ? 'Object' : 'Value'}MappingElement"
        )
        if kind == :object
          common['Children'] = integration_array(
            Array(spec[:children]).map { mapping_element_document(_1, prefix) }, 2
          )
          common.merge(mapping_object_fields(spec))
        else
          common.merge(mapping_value_fields(spec))
        end
      end

      def mapping_object_fields(spec)
        {
          'Association' => spec.fetch(:association, '').to_s,
          'CustomHandlerCall' => nil,
          'Documentation' => spec.fetch(:documentation, '').to_s,
          'ElementType' => 'Object',
          'Entity' => spec.fetch(:entity, '').to_s,
          'ExposedName' => spec.fetch(:name, '').to_s,
          'IsDefaultType' => spec.fetch(:default_type, false) == true,
          'JsonPath' => spec.fetch(:json_path, '').to_s,
          'MaxOccurs' => spec.fetch(:max_occurs, 1).to_i,
          'MinOccurs' => spec.fetch(:min_occurs, 0).to_i,
          'Nillable' => spec.fetch(:nillable, true) == true,
          'ObjectHandling' => integration_enum(spec.fetch(:object_handling, :create)),
          'ObjectHandlingBackup' => integration_enum(spec.fetch(:backup_handling, :create)),
          'ObjectHandlingBackupAllowOverride' => spec.fetch(:allow_override, false) == true,
          'XmlPath' => spec.fetch(:xml_path, '').to_s
        }
      end

      def mapping_value_fields(spec)
        {
          'Attribute' => spec.fetch(:attribute, '').to_s,
          'Converter' => spec.fetch(:converter, '').to_s,
          'Documentation' => spec.fetch(:documentation, '').to_s,
          'ElementType' => 'Value',
          'ExposedName' => spec.fetch(:name, '').to_s,
          'FractionDigits' => spec.fetch(:fraction_digits, -1).to_i,
          'IsContent' => spec.fetch(:content, false) == true,
          'IsKey' => spec.fetch(:key, false) == true,
          'IsXmlAttribute' => spec.fetch(:xml_attribute, false) == true,
          'JsonPath' => spec.fetch(:json_path, '').to_s,
          'MaxLength' => spec.fetch(:max_length, -1).to_i,
          'MaxOccurs' => spec.fetch(:max_occurs, 1).to_i,
          'MinOccurs' => spec.fetch(:min_occurs, 0).to_i,
          'Nillable' => spec.fetch(:nillable, true) == true,
          'OriginalValue' => spec.fetch(:original, '').to_s,
          'TotalDigits' => spec.fetch(:total_digits, -1).to_i,
          'Type' => data_type_document(spec.fetch(:type, :unknown), spec[:type_id]),
          'XmlPath' => spec.fetch(:xml_path, '').to_s,
          'XmlPrimitiveType' => integration_enum(spec.fetch(:primitive, :unknown))
        }
      end

      def rest_resource_document(source)
        spec = integration_spec(source)
        integration_identity(spec[:id]).merge(
          '$Type' => 'Rest$PublishedRestServiceResource',
          'Documentation' => spec.fetch(:documentation, '').to_s,
          'Name' => spec.fetch(:name).to_s,
          'Operations' => integration_array(
            Array(spec[:operations]).map { rest_operation_document(_1) }, 2
          )
        )
      end

      def rest_operation_document(source)
        spec = integration_spec(source)
        integration_identity(spec[:id]).merge(
          '$Type' => 'Rest$PublishedRestServiceOperation',
          'Commit' => integration_enum(spec.fetch(:commit, :no)),
          'Deprecated' => spec.fetch(:deprecated, false) == true,
          'Documentation' => spec.fetch(:documentation, '').to_s,
          'ExportMapping' => spec.fetch(:export_mapping, '').to_s,
          'HttpMethod' => integration_enum(spec.fetch(:method, :get)),
          'ImportMapping' => spec.fetch(:import_mapping, '').to_s,
          'Microflow' => spec.fetch(:microflow, '').to_s,
          'ObjectHandlingBackup' => integration_enum(spec.fetch(:object_handling, :create)),
          'Parameters' => integration_array([], 3),
          'Path' => spec.fetch(:path, '').to_s,
          'Summary' => spec.fetch(:summary, '').to_s
        )
      end

      def database_property_document(source)
        spec = integration_spec(source)
        integration_identity(spec[:id]).merge(
          '$Type' => 'DatabaseConnector$AdditionalProperty',
          'Key' => spec.fetch(:key).to_s,
          'Value' => integration_identity(spec[:value_id]).merge(
            '$Type' => 'DatabaseConnector$ValueAsString',
            'Value' => spec.fetch(:value, '').to_s
          )
        )
      end

      def database_connection_parts_document(source)
        spec = integration_spec(source)
        integration_identity(spec[:id]).merge(
          '$Type' => 'DatabaseConnector$ConnectionParts',
          'DatabaseName' => spec.fetch(:database, '').to_s,
          'Host' => spec.fetch(:host, '').to_s,
          'Port' => spec.fetch(:port, 0).to_i
        )
      end

      def database_query_document(source)
        spec = integration_spec(source)
        integration_identity(spec[:id]).merge(
          '$Type' => 'DatabaseConnector$DatabaseQuery',
          'Name' => spec.fetch(:name).to_s,
          'Parameters' => integration_array(
            Array(spec[:parameters]).map { database_parameter_document(_1) },
            spec.fetch(:parameters_marker, 2).to_i
          ),
          'Query' => spec.fetch(:query, '').to_s,
          'QueryType' => database_query_type(spec.fetch(:kind, :select)),
          'TableMappings' => integration_array(
            Array(spec[:tables]).map { database_table_document(_1) },
            spec.fetch(:tables_marker, 2).to_i
          )
        )
      end

      def database_parameter_document(source)
        spec = integration_spec(source)
        integration_identity(spec[:id]).merge(
          '$Type' => 'DatabaseConnector$QueryParameter',
          'DatabaseParameterName' => spec.fetch(:database_name, '').to_s,
          'DataType' => data_type_document(spec.fetch(:type, :unknown), spec[:type_id]),
          'DefaultValue' => spec.fetch(:default, '').to_s,
          'EmptyValueBecomesNull' => spec.fetch(:empty_as_null, false) == true,
          'Mode' => integration_enum(spec.fetch(:mode, :unknown)),
          'ParameterName' => spec.fetch(:name).to_s,
          'SqlDataType' => database_sql_type_document(spec.fetch(:sql_type, {})),
          'TableMapping' => spec[:table_mapping]
        )
      end

      def database_table_document(source)
        spec = integration_spec(source)
        integration_identity(spec[:id]).merge(
          '$Type' => 'DatabaseConnector$TableMapping',
          'Columns' => integration_array(
            Array(spec[:columns]).map { database_column_document(_1) },
            spec.fetch(:columns_marker, 2).to_i
          ),
          'Entity' => spec.fetch(:entity, '').to_s,
          'TableName' => spec.fetch(:table, '').to_s
        )
      end

      def database_column_document(source)
        spec = integration_spec(source)
        integration_identity(spec[:id]).merge(
          '$Type' => 'DatabaseConnector$ColumnMapping',
          'Attribute' => spec.fetch(:attribute, '').to_s,
          'ColumnName' => spec.fetch(:column, '').to_s,
          'SqlDataType' => database_sql_type_document(spec.fetch(:sql_type, {}))
        )
      end

      def database_sql_type_document(source)
        spec = integration_spec(source)
        kind = spec.fetch(:kind, :simple).to_sym
        type = if kind == :limited
                 'DatabaseConnector$LimitedLengthSqlDataType'
               else
                 'DatabaseConnector$SimpleSqlDataType'
               end
        document = integration_identity(spec[:id]).merge(
          '$Type' => type,
          'DataTypeName' => spec.fetch(:name, '').to_s
        )
        document['Length'] = spec.fetch(:length).to_i if kind == :limited
        document
      end

      def database_query_type(value)
        return value.to_i unless value.is_a?(Symbol)

        DATABASE_QUERY_TYPES.fetch(value) { value.to_s.to_i }
      end

      def data_type_document(type, id = nil)
        type_name = DATA_TYPES.fetch(type.to_sym) { type.to_s }
        integration_identity(id).merge('$Type' => type_name)
      end

      def integration_identity(id)
        { '$ID' => id.to_s.empty? ? SecureRandom.uuid : id.to_s }
      end

      def integration_array(items, marker)
        IO::BsonCodec.build_array(items, marker:)
      end

      def integration_enum(value)
        return value.to_s unless value.is_a?(Symbol)

        value.to_s.split('_').map!(&:capitalize).join
      end

      def integration_spec(source)
        source.to_h.transform_keys(&:to_sym)
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ModuleLength, Metrics/ParameterLists
  end
end
