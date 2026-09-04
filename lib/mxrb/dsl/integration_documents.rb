# frozen_string_literal: true

require 'securerandom'
require 'base64'

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
        long: 'DataTypes$IntegerType',
        decimal: 'DataTypes$DecimalType',
        boolean: 'DataTypes$BooleanType',
        datetime: 'DataTypes$DateTimeType',
        date_time: 'DataTypes$DateTimeType',
        binary: 'DataTypes$BinaryType'
      }.freeze
      DATABASE_QUERY_TYPES = { select: 1, execute: 2 }.freeze
      REST_RESPONSES_MARKER = "\n\nResponses:\n"
      REST_SUCCESS_STATUS_CODES = {
        'ok' => 200, 'created' => 201, 'accepted' => 202,
        'nocontent' => 204
      }.freeze

      # Collects typed entity-message declarations for one Mendix collection.
      class MessageDefinitionCollectionBuilder
        attr_reader :definitions

        def initialize
          @definitions = []
        end

        def entity_message(name, entity:, id: nil, documentation: '', exposed_entity_id: nil,
                           children_marker: 2, **element, &block)
          exposed = MessageExposedEntityBuilder.new(
            id: exposed_entity_id, entity:, children_marker:, **element
          )
          exposed.instance_eval(&block) if block
          @definitions << {
            name: name.to_s, id: id&.to_s, documentation: documentation.to_s,
            exposed: exposed.to_h
          }
        end
      end

      # Collects exposed attributes below a typed entity-message declaration.
      class MessageExposedEntityBuilder
        attr_reader :attributes

        def initialize(id:, entity:, children_marker:, **element)
          @id = id&.to_s
          @entity = entity.to_s
          @children_marker = children_marker.to_i
          @element = element
          @attributes = []
        end

        def exposed_attribute(name, attribute:, id: nil, children_marker: 2, **element)
          @attributes << {
            name: name.to_s, attribute: attribute.to_s, id: id&.to_s,
            children_marker: children_marker.to_i, element:
          }
        end

        def to_h
          {
            id: @id, entity: @entity, children_marker: @children_marker,
            element: @element, attributes: @attributes
          }
        end
      end

      def dataset(name, documentation: '', excluded: false, export_level: 'Hidden',
                  unit_id: nil, container_id: nil, &block)
        builder = DataSetBuilder.new
        builder.instance_eval(&block) if block
        doc = integration_identity(unit_id).merge(
          'DataSetAccess' => dataset_access_document(builder.access),
          'Documentation' => documentation.to_s,
          'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s,
          'Parameters' => integration_array(
            builder.parameters.map { dataset_parameter_document(_1) }, 2
          ),
          'Source' => integration_identity(nil).merge(
            '$Type' => 'DataSets$OqlDataSetSource',
            'IEIQ' => builder.ieiq,
            'Query' => builder.query
          )
        )
        semantic_native_document(name, 'DataSets$DataSet', doc, unit_id:, container_id:)
      end

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

      def published_rest_service(name, path:, version:, resources: nil, service_name: nil,
                                 allowed_roles: [], authentication_types: [],
                                 authentication_microflow: '', documentation: '',
                                 public_documentation: '', excluded: false,
                                 export_level: 'Hidden', enable_cors: nil,
                                 requires_authentication: nil, unit_id: nil,
                                 container_id: nil, &block)
        resources = rest_service_resources(resources, block)
        resources = enrich_rest_service_resources(name, resources)
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
        capture_rest_response_metadata(name, doc, resources)
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

      def consumed_odata_service( # rubocop:disable Metrics/ParameterLists
        name, application_id: '', catalog_url: '', configuration_microflow: '',
        description: '', documentation: '', endpoint_id: '', environment_type: '',
        error_handling_microflow: '', excluded: false, export_level: 'Hidden',
        icon_base64: '', icon_subtype: :generic, last_updated: '', metadata: '',
        metadata_hash: '', metadata_url: '', minimum_mx_version: '', odata_version: '',
        proxy_host: '', proxy_password: '', proxy_port: '', proxy_type: '', proxy_username: '',
        recommended_mx_version: '', service_name: '', timeout_expression: '',
        use_query_segment: false, validated: false, version: '',
        http_configuration_id: nil, client_certificate: '', custom_location: '',
        http_authentication_password: '', http_authentication_username: '', http_method: '',
        override_location: false, use_http_authentication: false,
        http_headers_marker: 3, metadata_references_marker: 3,
        validated_entities_marker: 1, unit_id: nil, container_id: nil
      )
        http = integration_identity(http_configuration_id).merge(
          '$Type' => 'Microflows$HttpConfiguration',
          'ClientCertificate' => client_certificate.to_s,
          'CustomLocation' => custom_location.to_s,
          'CustomLocationTemplate' => nil,
          'HttpAuthenticationPassword' => http_authentication_password.to_s,
          'HttpAuthenticationUserName' => http_authentication_username.to_s,
          'HttpHeaderEntries' => integration_array([], http_headers_marker),
          'HttpMethod' => http_method.to_s,
          'OverrideLocation' => override_location == true,
          'UseHttpAuthentication' => use_http_authentication == true
        )
        doc = integration_identity(unit_id).merge(
          '$Type' => 'Rest$ConsumedODataService',
          'ApplicationId' => application_id.to_s, 'CatalogUrl' => catalog_url.to_s,
          'ConfigurationMicroflow' => configuration_microflow.to_s,
          'Description' => description.to_s, 'Documentation' => documentation.to_s,
          'EndpointId' => endpoint_id.to_s, 'EnvironmentType' => environment_type.to_s,
          'ErrorHandlingMicroflow' => error_handling_microflow.to_s,
          'Excluded' => excluded == true, 'ExportLevel' => export_level.to_s,
          'HttpConfiguration' => http,
          'Icon' => BSON::Binary.new(Base64.strict_decode64(icon_base64.to_s), icon_subtype.to_sym),
          'LastUpdated' => last_updated.to_s, 'Metadata' => metadata.to_s,
          'MetadataHash' => metadata_hash.to_s,
          'MetadataReferences' => integration_array([], metadata_references_marker),
          'MetadataUrl' => metadata_url.to_s, 'MinimumMxVersion' => minimum_mx_version.to_s,
          'ODataVersion' => odata_version.to_s, 'ProxyHost' => proxy_host.to_s,
          'ProxyPassword' => proxy_password.to_s, 'ProxyPort' => proxy_port.to_s,
          'ProxyType' => proxy_type.to_s, 'ProxyUsername' => proxy_username.to_s,
          'RecommendedMxVersion' => recommended_mx_version.to_s,
          'ServiceName' => service_name.to_s, 'TimeoutExpression' => timeout_expression.to_s,
          'UseQuerySegment' => use_query_segment == true, 'Validated' => validated == true,
          'ValidatedEntities' => integration_array([], validated_entities_marker),
          'Version' => version.to_s
        )
        semantic_native_document(
          name, 'Rest$ConsumedODataService', doc, unit_id:, container_id:
        )
      end

      def message_definition_collection(name, documentation: '', excluded: false,
                                        export_level: 'Hidden', definitions_marker: 2,
                                        unit_id: nil, container_id: nil, &block)
        builder = MessageDefinitionCollectionBuilder.new
        builder.instance_eval(&block) if block
        definitions = builder.definitions.map { message_definition_document(_1) }
        doc = integration_identity(unit_id).merge(
          'Documentation' => documentation.to_s, 'Excluded' => excluded == true,
          'ExportLevel' => export_level.to_s,
          'MessageDefinitions' => integration_array(definitions, definitions_marker)
        )
        semantic_native_document(
          name, 'MessageDefinitions$MessageDefinitionCollection', doc,
          unit_id:, container_id:
        )
      end

      private

      def message_definition_document(spec)
        exposed = spec.fetch(:exposed)
        integration_identity(spec[:id]).merge(
          '$Type' => 'MessageDefinitions$EntityMessageDefinition',
          'Documentation' => spec.fetch(:documentation),
          'ExposedEntity' => message_exposed_entity_document(exposed),
          'Name' => spec.fetch(:name)
        )
      end

      def message_exposed_entity_document(spec)
        fields = message_element_fields(spec.fetch(:element), default_element_type: :object)
        integration_identity(spec[:id]).merge(
          '$Type' => 'MessageDefinitions$ExposedEntity',
          'Children' => integration_array(
            spec.fetch(:attributes).map { message_exposed_attribute_document(_1) },
            spec.fetch(:children_marker)
          ),
          'Entity' => spec.fetch(:entity)
        ).merge(fields)
      end

      def message_exposed_attribute_document(spec)
        fields = message_element_fields(
          spec.fetch(:element).merge(exposed_name: spec.fetch(:name)),
          default_element_type: :value
        )
        integration_identity(spec[:id]).merge(
          '$Type' => 'MessageDefinitions$ExposedAttribute',
          'Attribute' => spec.fetch(:attribute),
          'Children' => integration_array([], spec.fetch(:children_marker))
        ).merge(fields)
      end

      def message_element_fields(source, default_element_type:)
        spec = integration_spec(source)
        {
          'Documentation' => spec.fetch(:documentation, '').to_s,
          'ElementType' => integration_enum(spec.fetch(:element_type, default_element_type)),
          'ErrorMessage' => spec.fetch(:error_message, '').to_s,
          'Example' => spec.fetch(:example, '').to_s,
          'ExposedItemName' => spec.fetch(:exposed_item_name, '').to_s,
          'ExposedName' => spec.fetch(:exposed_name, '').to_s,
          'FractionDigits' => spec.fetch(:fraction_digits, -1).to_i,
          'IsDefaultType' => spec.fetch(:default_type, false) == true,
          'MaxLength' => spec.fetch(:max_length, -1).to_i,
          'MaxOccurs' => spec.fetch(:max_occurs, 1).to_i,
          'MinOccurs' => spec.fetch(:min_occurs, 0).to_i,
          'Nillable' => spec.fetch(:nillable, true) == true,
          'OriginalName' => spec.fetch(:original_name, '').to_s,
          'Path' => spec.fetch(:path, '').to_s,
          'PrimitiveType' => integration_enum(spec.fetch(:primitive_type, :unknown)),
          'TotalDigits' => spec.fetch(:total_digits, -1).to_i,
          'WarningMessage' => spec.fetch(:warning_message, '').to_s
        }
      end

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
          'ElementType' => spec.fetch(:element_type, 'Object').to_s,
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
          'Parameters' => integration_array(
            Array(spec[:parameters]).map { rest_operation_parameter_document(_1) }, 3
          ),
          'Path' => spec.fetch(:path, '').to_s,
          'Summary' => spec.fetch(:summary, '').to_s
        )
      end

      # Published REST operations do not persist a configurable success-status
      # field in the Mendix 10/11 model. Response contracts are retained in
      # MXRB's typed architecture metadata, while non-200 statuses are applied
      # through System.HttpResponse in the native microflow.
      def rest_operation_responses(spec)
        responses = Array(spec[:responses])
        status = rest_operation_success_status(spec)
        return responses unless status && responses.none? do |response|
          integration_spec(response).fetch(:status).to_i == status
        end

        responses + [{ status:, description: '' }]
      end

      def capture_rest_response_metadata(service_name, document, resources)
        native_resources = IO::BsonCodec.parse_array(document.fetch('Resources')).fetch(:items)
        Array(resources).zip(native_resources).each do |resource_source, native_resource|
          resource = integration_spec(resource_source)
          native_operations = IO::BsonCodec.parse_array(
            native_resource.fetch('Operations')
          ).fetch(:items)
          Array(resource[:operations]).zip(native_operations).each do |operation_source, native_operation|
            operation = integration_spec(operation_source)
            responses = rest_operation_responses(operation)
            next if responses.empty?

            @rest_response_metadata ||= []
            @rest_response_metadata << {
              service_id: IO::BsonCodec.extract_id(document['$ID']),
              service_name: service_name.to_s,
              resource_id: IO::BsonCodec.extract_id(native_resource['$ID']),
              resource_name: resource.fetch(:name).to_s,
              operation_id: IO::BsonCodec.extract_id(native_operation['$ID']),
              method: operation.fetch(:method).to_s,
              path: operation.fetch(:path, '').to_s,
              microflow: operation.fetch(:microflow).to_s,
              responses: responses.map { integration_spec(_1) }
            }
          end
        end
      end

      def dataset_parameter_document(source)
        spec = integration_spec(source)
        integration_identity(nil).merge(
          '$Type' => 'DataSets$DataSetParameter',
          'Constraints' => integration_array([], 2),
          'Name' => spec.fetch(:name).to_s,
          'ParameterType' => dataset_type_document(spec.fetch(:type)),
          'ParameterTypeIsRange' => spec.fetch(:range, false) == true
        )
      end

      def dataset_type_document(source)
        spec = integration_spec(source)
        kind = spec.fetch(:kind).to_sym
        native = {
          string: 'String', integer: 'Integer', long: 'Integer', decimal: 'Decimal',
          boolean: 'Boolean', datetime: 'DateTime', object: 'Object',
          enumeration: 'Enumeration'
        }.fetch(kind) { raise ArgumentError, "unsupported dataset parameter type #{kind.inspect}" }
        integration_identity(nil).merge('$Type' => "DataTypes$#{native}Type").tap do |doc|
          doc['Entity'] = spec.fetch(:entity).to_s if kind == :object
          doc['Enumeration'] = spec.fetch(:enumeration).to_s if kind == :enumeration
        end
      end

      def dataset_access_document(access)
        integration_identity(nil).merge(
          '$Type' => 'DataSets$DataSetAccess',
          'ModuleRoleAccessList' => integration_array(
            access.map { dataset_role_access_document(_1) }, 2
          )
        )
      end

      def dataset_role_access_document(source)
        spec = integration_spec(source)
        integration_identity(nil).merge(
          '$Type' => 'DataSets$DataSetModuleRoleAccess',
          'ModuleRole' => spec.fetch(:role).to_s,
          'ParameterAccessList' => integration_array(
            Array(spec[:parameters]).map { dataset_parameter_access_document(_1) }, 2
          )
        )
      end

      def dataset_parameter_access_document(source)
        spec = integration_spec(source)
        integration_identity(nil).merge(
          '$Type' => 'DataSets$DataSetParameterAccess',
          'ConstraintAccessList' => integration_array(
            Array(spec[:constraints]).map { dataset_constraint_access_document(_1) }, 2
          ),
          'ParameterName' => spec.fetch(:name).to_s
        )
      end

      def dataset_constraint_access_document(source)
        spec = integration_spec(source)
        integration_identity(nil).merge(
          '$Type' => 'DataSets$DataSetConstraintAccess',
          'ConstraintText' => spec.fetch(:text).to_s,
          'Enabled' => spec.fetch(:enabled, true) == true
        )
      end

      def rest_operation_parameter_document(source)
        spec = integration_spec(source)
        integration_identity(spec[:id]).merge(
          '$Type' => 'Rest$RestOperationParameter',
          'Description' => spec.fetch(:description, '').to_s,
          'MicroflowParameter' => spec.fetch(:microflow_parameter).to_s,
          'Name' => spec.fetch(:name).to_s,
          'ParameterType' => integration_enum(spec.fetch(:parameter_type)),
          'Type' => rest_parameter_type_document(spec.fetch(:type, :string))
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

      def rest_success_status_code(value)
        raw = integration_enum(value)
        normalized = raw.gsub(/[^A-Za-z0-9]/, '').downcase
        code = raw[/\d{3}/]
        code&.to_i || REST_SUCCESS_STATUS_CODES[normalized]
      end

      def rest_operation_success_status(spec)
        return rest_success_status_code(spec[:success_status]) if spec[:success_status]

        success = Array(spec[:responses]).find do |response|
          integration_spec(response).fetch(:status).to_i.between?(200, 299)
        end
        success && integration_spec(success).fetch(:status).to_i
      end

      def integration_spec(source)
        source.to_h.transform_keys(&:to_sym)
      end

      def rest_service_resources(resources, block)
        raise ArgumentError, 'published_rest_service accepts resources: or a block, not both' \
          if resources && block
        return resources || [] unless block

        RestServiceBuilder.new.tap { _1.instance_eval(&block) }.resources
      end

      def enrich_rest_service_resources(service_name, resources)
        Array(resources).map do |resource_source|
          resource = integration_spec(resource_source)
          operations = Array(resource[:operations]).map do |operation_source|
            enrich_rest_operation(service_name, integration_spec(operation_source))
          end
          resource.merge(operations:)
        end
      end

      def enrich_rest_operation(service_name, operation)
        flow = rest_microflow(operation[:microflow])
        return operation unless flow

        apply_rest_success_status!(flow, operation)
        enriched = operation.dup
        enriched[:parameters] = rest_operation_parameters(operation, flow) \
          unless operation.key?(:parameters)
        mapping = rest_operation_export_mapping(service_name, flow)
        enriched[:export_mapping] = mapping if enriched[:export_mapping].to_s.empty? && mapping
        enriched
      end

      def apply_rest_success_status!(flow, operation)
        status = rest_operation_success_status(operation)
        return unless status && status != 200

        parameter = Array(flow[:parameters]).find { rest_http_response_parameter?(_1) }
        unless parameter
          parameter = {
            name: 'HttpResponse',
            type: {
              '$ID' => SecureRandom.uuid, '$Type' => 'DataTypes$ObjectType',
              'Entity' => 'System.HttpResponse'
            }
          }
          flow[:parameters] = Array(flow[:parameters]) + [parameter]
        end

        variable = parameter.fetch(:name, parameter['name']).to_s
        assignment = {
          type: :change_object, variable:,
          members: [{ attribute: 'System.HttpResponse.StatusCode', value: status }],
          commit: false, with_events: true, refresh: false
        }
        flow[:body] = [assignment] + Array(flow[:body]) unless
          rest_status_assignment?(flow[:body], variable, status)
        flow[:preserve_native_body] = false
      end

      def rest_http_response_parameter?(parameter)
        type = parameter[:type] || parameter['type']
        type.is_a?(Hash) && (type['Entity'] || type[:Entity] || type[:entity]) == 'System.HttpResponse'
      end

      def rest_status_assignment?(body, variable, status)
        Array(body).any? do |action|
          next false unless action[:type] == :change_object && action[:variable].to_s == variable

          Array(action[:members]).any? do |member|
            member[:attribute].to_s == 'System.HttpResponse.StatusCode' &&
              member[:value].to_i == status
          end
        end
      end

      def rest_microflow(reference)
        local_name = reference.to_s.split('.').last
        Array(respond_to?(:microflows) ? microflows : []).find { _1.fetch(:name).to_s == local_name }
      end

      def rest_operation_parameters(operation, flow)
        path_parameters = operation.fetch(:path, '').to_s.scan(/\{([^}]+)\}/).flatten
        Array(flow[:parameters]).reject { rest_context_parameter?(_1) }.map do |parameter|
          name = parameter.fetch(:name).to_s
          {
            name:, type: parameter.fetch(:type, :string),
            parameter_type: path_parameters.include?(name) ? :path : :query,
            microflow_parameter: qualified_rest_microflow_parameter(operation[:microflow], name)
          }
        end
      end

      def rest_context_parameter?(parameter)
        type = parameter[:type] || parameter['type']
        return false unless type.is_a?(Hash)

        entity = type['Entity'] || type[:Entity] || type[:entity]
        %w[System.HttpRequest System.HttpResponse].include?(entity.to_s)
      end

      def qualified_rest_microflow_parameter(microflow, parameter)
        flow = microflow.to_s
        flow = "#{name}.#{flow}" unless flow.include?('.')
        "#{flow}.#{parameter}"
      end

      def rest_parameter_type_document(type)
        return integration_identity(nil).merge(type.transform_keys(&:to_s).except('$ID')) if type.is_a?(Hash)

        normalized = type.to_s.sub(/Type\z/i, '').downcase.to_sym
        data_type_document(normalized)
      end

      def rest_operation_export_mapping(service_name, flow)
        entity_name, collection = rest_return_entity(flow[:return_type])
        return unless entity_name

        entity = rest_entity(entity_name)
        return unless entity

        rest_entity_export_mapping(service_name, entity_name, entity, collection:)
      end

      def rest_return_entity(return_type)
        return unless return_type.is_a?(Hash)

        type = return_type['$Type'] || return_type[:'$Type']
        return unless type.to_s.end_with?('$ListType') || type.to_s.end_with?('$ObjectType')

        entity = return_type['Entity'] || return_type[:Entity] || return_type[:entity]
        [entity, type.to_s.end_with?('$ListType')]
      end

      def rest_entity(entity_name)
        local_name = entity_name.to_s.split('.').last
        Array(respond_to?(:entities) ? entities : []).find { _1.fetch(:name).to_s == local_name }
      end

      def rest_entity_export_mapping(_service_name, entity_name, entity, collection:)
        suffix = collection ? 'List' : 'Object'
        context = entity.fetch(:name).to_s
        json_name = "JsonS_#{context}_#{suffix}"
        mapping_name = "EM_#{context}_#{suffix}"
        ensure_rest_json_structure(json_name, entity, collection:)
        ensure_rest_export_mapping(mapping_name, json_name, entity_name, entity, collection:)
        "#{name}.#{mapping_name}"
      end

      def ensure_rest_json_structure(document_name, entity, collection:)
        return if rest_native_document?(document_name, 'JsonStructures$JsonStructure')

        root_path = collection ? '(Array)' : '(Object)'
        object_path = collection ? '(Array)|(Object)' : root_path
        attributes = entity.fetch(:attributes, [])
        object = rest_json_object(entity.fetch(:name), attributes, object_path, collection:)
        elements = collection ? [rest_json_array(object, root_path)] : [object]
        snippet = JSON.generate(collection ? [rest_json_example(attributes)] : rest_json_example(attributes))
        json_structure document_name, snippet:, elements:
      end

      def ensure_rest_export_mapping(document_name, json_name, entity_name, entity, collection:)
        return if rest_native_document?(document_name, 'ExportMappings$ExportMapping')

        object_path = collection ? '(Array)|(Object)' : '(Object)'
        root = rest_mapping_object(entity_name, entity, object_path, collection:)
        export_mapping document_name, json_structure: "#{name}.#{json_name}", elements: [root]
      end

      def rest_native_document?(document_name, type)
        Array(respond_to?(:native_documents) ? native_documents : []).any? do |document|
          document.fetch(:name).to_s == document_name.to_s && document.fetch(:type).to_s == type
        end
      end

      def rest_json_array(object, path)
        { kind: :array, name: 'Root', path:, min_occurs: 1, max_occurs: 1, children: [object] }
      end

      def rest_json_object(entity_name, attributes, path, collection:)
        {
          kind: :object, name: collection ? entity_name.to_s : 'Root', path:,
          min_occurs: collection ? 0 : 1, max_occurs: collection ? -1 : 1,
          children: attributes.map { rest_json_value(_1, path) }
        }
      end

      def rest_json_value(attribute, parent_path)
        type = rest_attribute_type(attribute)
        {
          kind: :value, name: attribute.fetch(:name), path: "#{parent_path}|#{attribute.fetch(:name)}",
          primitive: type, original: rest_json_original(type),
          max_length: type == :string ? attribute.fetch(:length, 0).to_i : -1
        }
      end

      def rest_mapping_object(entity_name, entity, path, collection:)
        {
          kind: :object, element_type: 'Object', name: collection ? entity.fetch(:name) : 'Root',
          json_path: path, min_occurs: collection ? 0 : 1, max_occurs: collection ? -1 : 1,
          entity: entity_name.to_s, object_handling: :parameter, backup_handling: :error,
          children: entity.fetch(:attributes, []).map { rest_mapping_value(entity_name, _1, path) }
        }
      end

      def rest_mapping_value(entity_name, attribute, parent_path)
        type = rest_attribute_type(attribute)
        {
          kind: :value, name: attribute.fetch(:name),
          json_path: "#{parent_path}|#{attribute.fetch(:name)}",
          attribute: "#{entity_name}.#{attribute.fetch(:name)}", type:, primitive: type,
          max_length: type == :string ? attribute.fetch(:length, 0).to_i : -1,
          original: rest_json_original(type)
        }
      end

      def rest_attribute_type(attribute)
        type = attribute.fetch(:type, :string).to_sym
        return :decimal if type == :float
        return :long if type == :autonumber
        return :string if %i[enum hashstring].include?(type)

        type
      end

      def rest_json_original(type)
        return 'false' if type == :boolean
        return '0' if %i[integer long decimal].include?(type)

        '""'
      end

      def rest_json_example(attributes)
        attributes.to_h { [_1.fetch(:name), rest_json_example_value(rest_attribute_type(_1))] }
      end

      def rest_json_example_value(type)
        return false if type == :boolean
        return 0 if %i[integer long decimal].include?(type)

        ''
      end

      # Eloquent, hash-free resource declaration for published REST services.
      class RestServiceBuilder
        attr_reader :resources

        def initialize
          @resources = []
        end

        def resource(name, id: nil, documentation: '', &block)
          value = name.to_s
          raise ArgumentError, 'REST resource name cannot be empty' if value.empty?
          raise ArgumentError, "duplicate REST resource #{value}" if @resources.any? { _1[:name] == value }

          builder = RestResourceBuilder.new(value)
          builder.instance_eval(&block) if block
          @resources << {
            name: value, id: id&.to_s, documentation: documentation.to_s,
            operations: builder.operations
          }.compact
        end
      end

      # HTTP operations inside one published REST resource.
      class RestResourceBuilder
        HTTP_METHODS = %i[get post put patch delete].freeze

        attr_reader :operations

        def initialize(name)
          @name = name
          @operations = []
        end

        HTTP_METHODS.each do |method|
          define_method(method) do |name, path:, microflow:, **options, &block|
            operation(name, method:, path:, microflow:, **options, &block)
          end
        end

        def operation(name, method:, path:, microflow:, id: nil, import_mapping: '',
                      export_mapping: '', commit: :no, object_handling: :create,
                      deprecated: false, documentation: '', summary: '', success_status: nil,
                      parameters: nil, &block)
          verb = method.to_sym
          raise ArgumentError, "unsupported REST method #{method.inspect}" unless HTTP_METHODS.include?(verb)

          operation_name = name.to_s
          raise ArgumentError, 'REST operation name cannot be empty' if operation_name.empty?

          route = path.to_s
          if @operations.any? { _1[:method] == verb && _1[:path] == route }
            raise ArgumentError, "duplicate REST route #{verb.to_s.upcase} #{route} in #{@name}"
          end

          response_builder = RestOperationBuilder.new(parameters)
          response_builder.instance_eval(&block) if block
          @operations << {
            name: operation_name, method: verb, path: route, microflow: microflow.to_s,
            id: id&.to_s, import_mapping: import_mapping.to_s,
            export_mapping: export_mapping.to_s, commit:, object_handling:,
            deprecated: deprecated == true, documentation: documentation.to_s,
            summary: summary.to_s, success_status:, parameters: response_builder.parameters,
            responses: response_builder.responses
          }.compact
        end
      end

      # Documents parameters and response outcomes for one REST operation.
      class RestOperationBuilder
        attr_reader :responses

        def initialize(parameters = nil)
          @parameters = Array(parameters)
          @parameters_declared = !parameters.nil?
          @responses = []
        end

        def parameter(name, type:, maps_to:, in: :query, description: '', id: nil)
          @parameters_declared = true
          @parameters << {
            name: name.to_s, type:, parameter_type: binding.local_variable_get(:in),
            microflow_parameter: maps_to.to_s, description: description.to_s, id: id&.to_s
          }.compact
        end

        def parameters
          @parameters if @parameters_declared
        end

        def response(status, description: '')
          code = Integer(status)
          raise ArgumentError, "invalid HTTP response status #{status.inspect}" unless code.between?(100, 599)
          raise ArgumentError, "duplicate HTTP response status #{code}" if @responses.any? { _1[:status] == code }

          @responses << { status: code, description: description.to_s }
        end
      end

      # Hash-free declaration builder for an OQL-backed Mendix DataSet.
      class DataSetBuilder
        attr_reader :parameters, :access, :query, :ieiq

        def initialize
          @parameters = []
          @access = []
          @query = ''
          @ieiq = false
        end

        def parameter(name, type, range: false)
          @parameters << { name: name.to_s, type:, range: range == true }
        end

        def string = { kind: :string }
        def integer = { kind: :integer }
        def long = { kind: :long }
        def decimal = { kind: :decimal }
        def boolean = { kind: :boolean }
        def datetime = { kind: :datetime }
        def object_of(entity) = { kind: :object, entity: entity.to_s }
        def enum_of(enumeration) = { kind: :enumeration, enumeration: enumeration.to_s }

        def oql(value = nil, ieiq: false, &block)
          @query = (value || block&.call).to_s
          @ieiq = ieiq == true
        end

        def allow(role, &block)
          builder = DataSetRoleAccessBuilder.new
          builder.instance_eval(&block) if block
          @access << { role: role.to_s, parameters: builder.parameters }
        end
      end

      # Declares the parameters visible to one module role.
      class DataSetRoleAccessBuilder
        attr_reader :parameters

        def initialize
          @parameters = []
        end

        def parameter(name, &block)
          builder = DataSetParameterAccessBuilder.new
          builder.instance_eval(&block) if block
          @parameters << { name: name.to_s, constraints: builder.constraints }
        end
      end

      # Declares access constraints for one DataSet parameter.
      class DataSetParameterAccessBuilder
        attr_reader :constraints

        def initialize
          @constraints = []
        end

        def constraint(text, enabled: true)
          @constraints << { text: text.to_s, enabled: enabled == true }
        end
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ModuleLength, Metrics/ParameterLists
  end
end
