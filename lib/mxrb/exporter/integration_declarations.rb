# frozen_string_literal: true

module Mxrb
  class Exporter
    # Declares task queues, schedules, authentication, OData, web services and message definitions as Ruby.
    module IntegrationDeclarations
      XML_SCHEMA_FIELDS = %w[
        $ID $Type Documentation Excluded ExportLevel FilePath Name SchemaContentss
      ].freeze

      XML_SCHEMA_ENTRY_FIELDS = %w[
        $ID $Type Contents LocalizedContentsFormat LocalizedLocationFormat Location TargetNamespace
      ].freeze

      SCHEDULED_EVENT_FIELDS = %w[
        $ID $Type Documentation Enabled Excluded ExportLevel Interval IntervalType
        Microflow Name OnOverlap Schedule StartDateTime TimeZone
      ].freeze

      SCHEDULE_FIELDS = {
        'ScheduledEvents$MinuteSchedule' => %w[$ID $Type Multiplier],
        'ScheduledEvents$HourSchedule' => %w[$ID $Type MinuteOffset Multiplier],
        'ScheduledEvents$DaySchedule' => %w[$ID $Type HourOfDay MinuteOfHour],
        'ScheduledEvents$WeekSchedule' => %w[
          $ID $Type Friday HourOfDay MinuteOfHour Monday Saturday Sunday Thursday
          Tuesday Wednesday
        ]
      }.freeze

      CONSUMED_ODATA_FIELDS = %w[
        $ID $Type ApplicationId CatalogUrl ConfigurationMicroflow Description Documentation
        EndpointId EnvironmentType ErrorHandlingMicroflow Excluded ExportLevel HttpConfiguration
        Icon LastUpdated Metadata MetadataHash MetadataReferences MetadataUrl MinimumMxVersion Name
        ODataVersion ProxyHost ProxyPassword ProxyPort ProxyType ProxyUsername RecommendedMxVersion
        ServiceName TimeoutExpression UseQuerySegment Validated ValidatedEntities Version
      ].freeze

      HTTP_CONFIGURATION_FIELDS = %w[
        $ID $Type ClientCertificate CustomLocation CustomLocationTemplate
        HttpAuthenticationPassword HttpAuthenticationUserName HttpHeaderEntries HttpMethod
        OverrideLocation UseHttpAuthentication
      ].freeze

      AUTHENTICATION_FIELDS = %w[$ID $Type AuthenticationDetails Name].freeze

      BASIC_AUTHENTICATION_FIELDS = %w[$ID $Type Password Username].freeze

      AUTHENTICATION_TYPES = {
        'Authentication$BasicAuthenticationDetails' => :basic,
        'Authentication$OAuth20ClientCredentialsDetails' => :oauth2_client_credentials,
        'Authentication$OAuth20AuthCodeDetails' => :oauth2_authorization_code
      }.freeze

      CONSUMED_APP_SERVICE_FIELDS = %w[
        $ID $Type Actions AppServiceLocation AppStoreGuid AppStoreVersion AppStoreVersionGuid
        Documentation Excluded FromAppStore LocationConstant Msd Name TimeOut UseTimeOut
      ].freeze

      APP_SERVICE_ACTION_FIELDS = %w[
        $ID $Type Caption Description ImageString Microflow Name Parameters ReturnType
        ReturnTypeCanBeEmpty
      ].freeze

      APP_SERVICE_PARAMETER_FIELDS = %w[$ID $Type CanBeEmpty Name Type].freeze

      PUBLISHED_WEB_SERVICE_FIELDS = %w[
        $ID $Type Documentation Excluded Name VersionedWebServices
      ].freeze

      WEB_SERVICE_VERSION_FIELDS = %w[
        $ID $Type AppServiceState Caption Description Documentation HeaderAuthentication
        HeaderMicroflow Image ImportMapping IsLockedByContract MsdEnumerationsByContract
        Name Operations TargetNamespace Validate VersionNumber
      ].freeze

      WEB_SERVICE_OPERATION_FIELDS = %w[
        $ID $Type DataEntity Description Documentation ImageId IsLockedByContract Microflow Name
        Parameters ReturnElementName ReturnElementNameByContract ReturnType ReturnTypeIsNillable
        ReturnTypeIsOptional ReturnTypeName ReturnTypeSpecification
      ].freeze

      WEB_SERVICE_PARAMETER_FIELDS = %w[
        $ID $Type DataEntity ElementName IsLockedByContract IsNillable IsOptional
        IsOptionalByContract MicroflowParameter MsdMicroflowParameterByContract ObjectElementName
        ObjectElementNameByContract Type
      ].freeze

      WEB_SERVICE_DATA_ENTITY_FIELDS = %w[
        $ID $Type ChildMembers ElementName Entity IsKey IsLockedByContract IsNillable
        IsNillableByContract IsOptional IsOptionalByContract ObjectElementName
      ].freeze

      IMPORTED_WEB_SERVICE_FIELDS = %w[
        $ID $Type Description Documentation Excluded ExportLevel Name UseMtom WsdlUrl
      ].freeze

      WSDL_DESCRIPTION_FIELDS = %w[
        $ID $Type ImportsHaveLocations SchemaContentss Services TargetNamespace WsdlContentss
      ].freeze

      WSDL_ENTRY_FIELDS = %w[
        $ID $Type Contents LocalizedContentsFormat LocalizedLocationFormat Location
      ].freeze

      PUBLISHED_ODATA_FIELDS = %w[
        $ID $Type AllowedModuleRoles AuthenticationMicroflow AuthenticationTypes Description
        Documentation EntitySets EntityTypes Enumerations Excluded ExportLevel
        IncludeMetadataByDefault Microflows Name Namespace ODataVersion Path PublishAssociations
        ReplaceIllegalChars ServiceName Summary SupportsGraphQL UseGeneralization Version
      ].freeze

      PUBLISHED_ODATA_ENTITY_FIELDS = %w[
        $ID $Type ChildMembers Description Entity ExposedName Summary
      ].freeze

      PUBLISHED_ODATA_ID_FIELDS = %w[
        $ID $Type Description ExposedName IsPartOfKey Summary
      ].freeze

      PUBLISHED_ODATA_ATTRIBUTE_FIELDS = %w[
        $ID $Type Attribute CanBeEmpty Description EdmType EnumerationAsString ExposedName
        Filterable IsPartOfKey Sortable StringAsGuid Summary
      ].freeze

      PUBLISHED_ODATA_SET_FIELDS = %w[
        $ID $Type AlternativeExposedName DeleteMode EntityTypePointer ExposedName InsertMode
        PageSize QueryOptions ReadMode UpdateMode UsePaging
      ].freeze

      PUBLISHED_ODATA_QUERY_FIELDS = %w[$ID $Type Countable SkipSupported TopSupported].freeze

      MESSAGE_COLLECTION_FIELDS = %w[
        $ID $Type Documentation Excluded ExportLevel MessageDefinitions Name
      ].freeze

      MESSAGE_DEFINITION_FIELDS = %w[$ID $Type Documentation ExposedEntity Name].freeze

      private

      def semantic_task_queue?(doc)
        config = doc['Config']
        config.is_a?(Hash) && config['$Type'] == 'Queues$BasicQueueConfig' &&
          (config.key?('ParallelismExpression') ^ config.key?('Parallelism'))
      end

      def task_queue_declaration(document)
        doc = document.fetch(:doc)
        config = doc.fetch('Config')
        options = {
          documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
          export_level: doc.fetch('ExportLevel', 'Hidden'), config_id: document_id(config)
        }
        if config.key?('ParallelismExpression')
          options[:parallelism_expression] = config.fetch('ParallelismExpression').to_s
          options[:cluster_wide] = config['ClusterWide'] == true
        else
          options[:parallelism] = config.fetch('Parallelism').to_i
        end
        semantic_call_source(:task_queue, document, options)
      end

      def regular_expression_declaration(document)
        doc = document.fetch(:doc)
        semantic_call_source(:regular_expression, document, {
                               expression: doc.fetch('Expression', ''), documentation: doc.fetch('Documentation', ''),
                               excluded: doc['Excluded'] == true, export_level: doc.fetch('ExportLevel', 'Hidden')
                             })
      end

      def semantic_xml_schema?(doc)
        return false unless (doc.keys - XML_SCHEMA_FIELDS).empty?

        bson_items(doc['SchemaContentss']).all? do |entry|
          entry.is_a?(Hash) && entry['$Type'] == 'XmlSchemas$XmlSchemaContents' &&
            (entry.keys - XML_SCHEMA_ENTRY_FIELDS).empty?
        end
      end

      def xml_schema_declaration(document)
        doc = document.fetch(:doc)
        entries = bson_items(doc['SchemaContentss']).map do |entry|
          {
            id: document_id(entry), contents: entry.fetch('Contents', ''),
            localized_contents_format: entry.fetch('LocalizedContentsFormat', ''),
            localized_location_format: entry.fetch('LocalizedLocationFormat', ''),
            location: entry.fetch('Location', ''),
            target_namespace: entry.fetch('TargetNamespace', '')
          }
        end
        semantic_call_source(:xml_schema, document, {
                               entries:, file_path: doc.fetch('FilePath', ''),
                               documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
                               export_level: doc.fetch('ExportLevel', 'Hidden'),
                               entries_marker: bson_marker(doc['SchemaContentss'], 2)
                             })
      end

      def semantic_scheduled_event?(doc)
        return false unless (doc.keys - SCHEDULED_EVENT_FIELDS).empty?
        return true if doc['Schedule'].nil?

        schedule = doc['Schedule']
        allowed = schedule.is_a?(Hash) && SCHEDULE_FIELDS[schedule['$Type']]
        allowed && (schedule.keys - allowed).empty?
      end

      def scheduled_event_declaration(document)
        doc = document.fetch(:doc)
        interval_type = doc.fetch('IntervalType', 'Day').to_s
        options = {
          microflow: doc.fetch('Microflow', ''), interval: doc.fetch('Interval', 1),
          unit: "#{underscore(interval_type)}s".to_sym, enabled: doc['Enabled'] == true,
          documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
          export_level: doc.fetch('ExportLevel', 'Hidden'), interval_type:,
          start_at: doc['StartDateTime']&.iso8601(3),
          time_zone: doc.fetch('TimeZone', 'UTC'), on_overlap: doc.fetch('OnOverlap', 'SkipNext')
        }
        options.merge!(scheduled_event_schedule_options(doc['Schedule']))
        semantic_call_source(:scheduled_event, document, options)
      end

      def scheduled_event_schedule_options(schedule)
        return { schedule: nil } unless schedule

        type = schedule.fetch('$Type')
        options = {
          schedule: underscore(type.delete_prefix('ScheduledEvents$').delete_suffix('Schedule')).to_sym,
          schedule_id: document_id(schedule)
        }
        %w[Multiplier MinuteOffset HourOfDay MinuteOfHour].each do |field|
          options[underscore(field).to_sym] = schedule[field] if schedule.key?(field)
        end
        weekdays = %w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday]
        options[:weekdays] = weekdays.select { schedule[_1] == true }.map { underscore(_1).to_sym } \
          if weekdays.any? { schedule.key?(_1) }
        options
      end

      def semantic_authentication?(doc)
        return false unless (doc.keys - AUTHENTICATION_FIELDS).empty?

        details = doc['AuthenticationDetails']
        return false unless details.is_a?(Hash) && AUTHENTICATION_TYPES.key?(details['$Type'])

        fields = if details['$Type'] == 'Authentication$BasicAuthenticationDetails'
                   BASIC_AUTHENTICATION_FIELDS
                 elsif details['$Type'] == 'Authentication$OAuth20AuthCodeDetails'
                   OAUTH_AUTH_CODE_FIELDS
                 else
                   OAUTH_AUTHENTICATION_FIELDS
                 end
        return false unless (details.keys - fields).empty?
        return authentication_string_fields?(details, fields - %w[$ID $Type]) if
          details['$Type'] == 'Authentication$BasicAuthenticationDetails'
        return false unless details.key?('Scopes')

        expected_grant = if details['$Type'] == 'Authentication$OAuth20AuthCodeDetails'
                           'AuthorizationCode'
                         else
                           'ClientCredentials'
                         end
        return false unless details['GrantType'] == expected_grant

        authentication_string_fields?(details, fields - %w[$ID $Type Scopes]) &&
          bson_items(details['Scopes']).all? { _1.is_a?(String) }
      end

      def authentication_string_fields?(details, fields)
        fields.all? { details.fetch(_1, '').is_a?(String) }
      end

      def authentication_declaration(document)
        details = document.fetch(:doc).fetch('AuthenticationDetails')
        kind = AUTHENTICATION_TYPES.fetch(details.fetch('$Type'))
        options = { type: kind, details_id: document_id(details) }
        if kind == :basic
          options.merge!(username: details.fetch('Username', ''), password: details.fetch('Password', ''))
        else
          options.merge!(
            provider_name: details.fetch('ProviderName', ''),
            well_known_endpoint: details.fetch('WellKnownEndPoint', ''),
            tenant_id: details.fetch('TenantId', ''), client_id: details.fetch('ClientId', ''),
            client_secret: details.fetch('ClientSecret', ''),
            token_endpoint: details.fetch('TokenEndPoint', ''),
            scopes: bson_items(details['Scopes']), scopes_marker: bson_marker(details['Scopes'], 1),
            audience: details.fetch('Audience', '')
          )
          if kind == :oauth2_authorization_code
            options.merge!(
              response_type: details.fetch('ResponseType', ''),
              response_mode: details.fetch('ResponseMode', ''),
              authorization_endpoint: details.fetch('AuthorizationEndpoint', ''),
              callback_url: details.fetch('CallbackUrl', '')
            )
          end
        end
        semantic_call_source(:authentication, document, options)
      end

      def semantic_consumed_odata_service?(doc)
        http = doc['HttpConfiguration']
        return false unless (doc.keys - CONSUMED_ODATA_FIELDS).empty?
        return false unless http.is_a?(Hash) && http['$Type'] == 'Microflows$HttpConfiguration'
        return false unless (http.keys - HTTP_CONFIGURATION_FIELDS).empty?
        return false unless http['CustomLocationTemplate'].nil?

        %w[MetadataReferences ValidatedEntities].all? { bson_items(doc[_1]).empty? } &&
          bson_items(http['HttpHeaderEntries']).empty? && doc['Icon'].is_a?(BSON::Binary)
      end

      def consumed_odata_service_declaration(document)
        doc = document.fetch(:doc)
        http = doc.fetch('HttpConfiguration')
        direct = {
          application_id: 'ApplicationId', catalog_url: 'CatalogUrl',
          configuration_microflow: 'ConfigurationMicroflow', description: 'Description',
          documentation: 'Documentation', endpoint_id: 'EndpointId',
          environment_type: 'EnvironmentType', error_handling_microflow: 'ErrorHandlingMicroflow',
          excluded: 'Excluded', export_level: 'ExportLevel', last_updated: 'LastUpdated',
          metadata: 'Metadata', metadata_hash: 'MetadataHash', metadata_url: 'MetadataUrl',
          minimum_mx_version: 'MinimumMxVersion', odata_version: 'ODataVersion',
          proxy_host: 'ProxyHost', proxy_password: 'ProxyPassword', proxy_port: 'ProxyPort',
          proxy_type: 'ProxyType', proxy_username: 'ProxyUsername',
          recommended_mx_version: 'RecommendedMxVersion', service_name: 'ServiceName',
          timeout_expression: 'TimeoutExpression', use_query_segment: 'UseQuerySegment',
          validated: 'Validated', version: 'Version'
        }
        options = direct.to_h { |key, field| [key, doc[field]] }
        options.merge!(
          icon_base64: Base64.strict_encode64(doc.fetch('Icon').data),
          icon_subtype: doc.fetch('Icon').type.to_sym,
          http_configuration_id: document_id(http),
          client_certificate: http.fetch('ClientCertificate', ''),
          custom_location: http.fetch('CustomLocation', ''),
          http_authentication_password: http.fetch('HttpAuthenticationPassword', ''),
          http_authentication_username: http.fetch('HttpAuthenticationUserName', ''),
          http_method: http.fetch('HttpMethod', ''),
          override_location: http['OverrideLocation'] == true,
          use_http_authentication: http['UseHttpAuthentication'] == true,
          http_headers_marker: bson_marker(http['HttpHeaderEntries'], 3),
          metadata_references_marker: bson_marker(doc['MetadataReferences'], 3),
          validated_entities_marker: bson_marker(doc['ValidatedEntities'], 1)
        )
        semantic_call_source(:consumed_odata_service, document, options)
      end

      def semantic_consumed_app_service?(doc)
        return false unless (doc.keys - CONSUMED_APP_SERVICE_FIELDS).empty?
        return false unless doc['Msd'].nil? || doc['Msd'].is_a?(Hash)

        bson_items(doc['Actions']).all? do |action|
          action.is_a?(Hash) && action['$Type'] == 'AppServices$AppServiceActionImpl' &&
            (action.keys - APP_SERVICE_ACTION_FIELDS).empty? &&
            bson_items(action['Parameters']).all? do |parameter|
              parameter.is_a?(Hash) &&
                parameter['$Type'] == 'AppServices$AppServiceActionParameter' &&
                (parameter.keys - APP_SERVICE_PARAMETER_FIELDS).empty?
            end
        end
      end

      def consumed_app_service_declaration(document)
        doc = document.fetch(:doc)
        options = {
          actions: bson_items(doc['Actions']).map { consumed_app_service_action_spec(_1) },
          location: doc.fetch('AppServiceLocation', 'Constant'),
          location_constant: doc.fetch('LocationConstant', ''), contract: doc['Msd'],
          app_store_guid: doc.fetch('AppStoreGuid', ''),
          app_store_version: doc.fetch('AppStoreVersion', ''),
          app_store_version_guid: doc.fetch('AppStoreVersionGuid', ''),
          documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
          from_app_store: doc['FromAppStore'] == true, timeout: doc.fetch('TimeOut', 30),
          use_timeout: doc['UseTimeOut'] == true, actions_marker: bson_marker(doc['Actions'], 2)
        }
        semantic_call_source(:consumed_app_service, document, options)
      end

      def consumed_app_service_action_spec(action)
        {
          id: document_id(action), name: action.fetch('Name'),
          caption: action.fetch('Caption', ''), description: action.fetch('Description', ''),
          image: action.fetch('ImageString', ''), microflow: action.fetch('Microflow', ''),
          parameters: bson_items(action['Parameters']).map do |parameter|
            {
              id: document_id(parameter), name: parameter.fetch('Name'),
              type: parameter.fetch('Type', 'String'),
              can_be_empty: parameter['CanBeEmpty'] == true
            }
          end,
          parameters_marker: bson_marker(action['Parameters'], 2),
          return_type: action.fetch('ReturnType', 'Void'),
          return_type_can_be_empty: action['ReturnTypeCanBeEmpty'] == true
        }
      end

      def semantic_published_web_service?(doc)
        return false unless (doc.keys - PUBLISHED_WEB_SERVICE_FIELDS).empty?

        bson_items(doc['VersionedWebServices']).all? { semantic_web_service_version?(_1) }
      end

      def semantic_web_service_version?(version)
        version.is_a?(Hash) && version['$Type'] == 'WebServices$VersionedServiceImpl' &&
          (version.keys - WEB_SERVICE_VERSION_FIELDS).empty? &&
          bson_items(version['Operations']).all? { semantic_web_service_operation?(_1) }
      end

      def semantic_web_service_operation?(operation)
        operation.is_a?(Hash) && operation['$Type'] == 'WebServices$PublishedOperationImpl' &&
          (operation.keys - WEB_SERVICE_OPERATION_FIELDS).empty? &&
          semantic_web_service_data_entity?(operation['DataEntity']) &&
          bson_items(operation['Parameters']).all? { semantic_web_service_parameter?(_1) }
      end

      def semantic_web_service_parameter?(parameter)
        parameter.is_a?(Hash) && parameter['$Type'] == 'WebServices$PublishedParameterImpl' &&
          (parameter.keys - WEB_SERVICE_PARAMETER_FIELDS).empty? &&
          semantic_web_service_data_entity?(parameter['DataEntity'])
      end

      def semantic_web_service_data_entity?(entity)
        entity.is_a?(Hash) && entity['$Type'] == 'WebServices$DataEntityImpl' &&
          (entity.keys - WEB_SERVICE_DATA_ENTITY_FIELDS).empty? &&
          bson_items(entity['ChildMembers']).empty?
      end

      def published_web_service_declaration(document)
        doc = document.fetch(:doc)
        options = {
          versions: bson_items(doc['VersionedWebServices']).map { published_web_service_version_spec(_1) },
          documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
          versions_marker: bson_marker(doc['VersionedWebServices'], 2)
        }
        semantic_call_source(:published_web_service, document, options)
      end

      def published_web_service_version_spec(version)
        {
          id: document_id(version), app_service_state: version.fetch('AppServiceState', 'Consumable'),
          caption: version.fetch('Caption', ''), description: version.fetch('Description', ''),
          documentation: version.fetch('Documentation', ''),
          header_authentication: version.fetch('HeaderAuthentication', 'None'),
          header_microflow: version.fetch('HeaderMicroflow', ''), image: version.fetch('Image', ''),
          import_mapping: version.fetch('ImportMapping', ''),
          locked_by_contract: version['IsLockedByContract'] == true,
          contract_enumerations: version['MsdEnumerationsByContract'],
          operations: bson_items(version['Operations']).map { published_web_service_operation_spec(_1) },
          operations_marker: bson_marker(version['Operations'], 3),
          target_namespace: version.fetch('TargetNamespace', ''),
          validate: version['Validate'] == true, version: version.fetch('VersionNumber', 0)
        }
      end

      def published_web_service_operation_spec(operation)
        {
          id: document_id(operation), name: operation.fetch('Name'),
          data_entity: published_web_service_data_entity_spec(operation.fetch('DataEntity')),
          description: operation.fetch('Description', ''),
          documentation: operation.fetch('Documentation', ''), image: operation.fetch('ImageId', ''),
          locked_by_contract: operation['IsLockedByContract'] == true,
          microflow: operation.fetch('Microflow', ''),
          parameters: bson_items(operation['Parameters']).map { published_web_service_parameter_spec(_1) },
          parameters_marker: bson_marker(operation['Parameters'], 2),
          return_element_name: operation.fetch('ReturnElementName', ''),
          contract_return_element_name: operation.fetch('ReturnElementNameByContract', ''),
          return_type: operation.fetch('ReturnType', 'Void'),
          return_nillable: operation['ReturnTypeIsNillable'] == true,
          return_optional: operation['ReturnTypeIsOptional'] == true,
          return_type_name: operation.fetch('ReturnTypeName', 'Nothing'),
          return_type_specification: operation.fetch('ReturnTypeSpecification', '')
        }
      end

      def published_web_service_parameter_spec(parameter)
        {
          id: document_id(parameter),
          data_entity: published_web_service_data_entity_spec(parameter.fetch('DataEntity')),
          element_name: parameter.fetch('ElementName', ''),
          locked_by_contract: parameter['IsLockedByContract'] == true,
          nillable: parameter['IsNillable'] == true, optional: parameter['IsOptional'] == true,
          optional_by_contract: parameter['IsOptionalByContract'] == true,
          microflow_parameter: parameter.fetch('MicroflowParameter', ''),
          contract_parameter: parameter['MsdMicroflowParameterByContract'],
          object_element_name: parameter.fetch('ObjectElementName', ''),
          contract_object_element_name: parameter.fetch('ObjectElementNameByContract', ''),
          type: parameter.fetch('Type', 'String')
        }
      end

      def published_web_service_data_entity_spec(entity)
        {
          id: document_id(entity), children_marker: bson_marker(entity['ChildMembers'], 2),
          element_name: entity.fetch('ElementName', ''), entity: entity.fetch('Entity', ''),
          key: entity['IsKey'] == true, locked_by_contract: entity['IsLockedByContract'] == true,
          nillable: entity['IsNillable'] == true,
          nillable_by_contract: entity['IsNillableByContract'] == true,
          optional: entity['IsOptional'] == true,
          optional_by_contract: entity['IsOptionalByContract'] == true,
          object_element_name: entity.fetch('ObjectElementName', '')
        }
      end

      def semantic_imported_web_service?(doc)
        return false unless (doc.keys - IMPORTED_WEB_SERVICE_FIELDS).empty?

        description = doc['Description']
        description.is_a?(Hash) && description['$Type'] == 'WebServices$WsdlDescriptionImpl' &&
          (description.keys - WSDL_DESCRIPTION_FIELDS).empty? &&
          bson_items(description['Services']).empty? &&
          bson_items(description['WsdlContentss']).all? { semantic_wsdl_entry?(_1) } &&
          bson_items(description['SchemaContentss']).all? { semantic_wsdl_schema_entry?(_1) }
      end

      def semantic_wsdl_entry?(entry)
        entry.is_a?(Hash) && entry['$Type'] == 'WebServices$WsdlEntryImpl' &&
          (entry.keys - WSDL_ENTRY_FIELDS).empty?
      end

      def semantic_wsdl_schema_entry?(entry)
        entry.is_a?(Hash) && entry['$Type'] == 'XmlSchemas$XmlSchemaContents' &&
          (entry.keys - XML_SCHEMA_ENTRY_FIELDS).empty?
      end

      def imported_web_service_declaration(document)
        doc = document.fetch(:doc)
        description = doc.fetch('Description')
        options = {
          wsdl_entries: bson_items(description['WsdlContentss']).map { wsdl_entry_spec(_1) },
          schema_entries: bson_items(description['SchemaContentss']).map { xml_schema_entry_spec(_1) },
          target_namespace: description.fetch('TargetNamespace', ''),
          wsdl_url: doc.fetch('WsdlUrl', ''), use_mtom: doc['UseMtom'] == true,
          imports_have_locations: description['ImportsHaveLocations'] == true,
          documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
          export_level: doc.fetch('ExportLevel', 'Hidden'),
          description_id: document_id(description),
          wsdl_entries_marker: bson_marker(description['WsdlContentss'], 2),
          schema_entries_marker: bson_marker(description['SchemaContentss'], 2),
          services_marker: bson_marker(description['Services'], 2)
        }
        semantic_call_source(:imported_web_service, document, options)
      end

      def wsdl_entry_spec(entry)
        {
          id: document_id(entry), contents: entry.fetch('Contents', ''),
          localized_contents_format: entry.fetch('LocalizedContentsFormat', ''),
          localized_location_format: entry.fetch('LocalizedLocationFormat', ''),
          location: entry.fetch('Location', '')
        }
      end

      def xml_schema_entry_spec(entry)
        wsdl_entry_spec(entry).merge(target_namespace: entry.fetch('TargetNamespace', ''))
      end

      def semantic_published_odata_service?(doc)
        return false unless (doc.keys - PUBLISHED_ODATA_FIELDS).empty?
        return false unless bson_items(doc['Enumerations']).empty? && bson_items(doc['Microflows']).empty?

        entities = bson_items(doc['EntityTypes'])
        ids = entities.to_h { [document_id(_1), true] }
        entities.all? { semantic_published_odata_entity?(_1) } &&
          bson_items(doc['EntitySets']).all? { semantic_published_odata_set?(_1, ids) }
      end

      def semantic_published_odata_entity?(entity)
        return false unless entity['$Type'] == 'ODataPublish$EntityType'
        return false unless (entity.keys - PUBLISHED_ODATA_ENTITY_FIELDS).empty?

        bson_items(entity['ChildMembers']).all? do |member|
          fields = if member['$Type'] == 'ODataPublish$PublishedId'
                     PUBLISHED_ODATA_ID_FIELDS
                   else
                     PUBLISHED_ODATA_ATTRIBUTE_FIELDS
                   end
          %w[ODataPublish$PublishedId ODataPublish$PublishedAttribute].include?(member['$Type']) &&
            (member.keys - fields).empty?
        end
      end

      def semantic_published_odata_set?(entity_set, entity_ids)
        return false unless entity_set['$Type'] == 'ODataPublish$EntitySet'
        return false unless (entity_set.keys - PUBLISHED_ODATA_SET_FIELDS).empty?
        return false unless entity_ids[document_id_value(entity_set['EntityTypePointer'])]
        return false unless entity_set.dig('ReadMode', '$Type') == 'ODataPublish$ReadSource'

        %w[InsertMode UpdateMode DeleteMode].all? do |field|
          entity_set.dig(field, '$Type') == 'ODataPublish$ChangeNotSupported'
        end && semantic_published_odata_query?(entity_set['QueryOptions'])
      end

      def semantic_published_odata_query?(query)
        query.is_a?(Hash) && query['$Type'] == 'ODataPublish$QueryOptions' &&
          (query.keys - PUBLISHED_ODATA_QUERY_FIELDS).empty?
      end

      def published_odata_service_declaration(document)
        doc = document.fetch(:doc)
        entities = bson_items(doc['EntityTypes'])
        names_by_id = entities.to_h { [document_id(_1), _1.fetch('ExposedName')] }
        options = {
          path: doc.fetch('Path'), namespace: doc.fetch('Namespace'),
          version: doc.fetch('Version'), service_name: doc.fetch('ServiceName'),
          allowed_roles: bson_items(doc['AllowedModuleRoles']),
          authentication_types: bson_items(doc['AuthenticationTypes']).map { underscore(_1).to_sym },
          authentication_microflow: doc.fetch('AuthenticationMicroflow', ''),
          documentation: doc.fetch('Documentation', ''), summary: doc.fetch('Summary', ''),
          description: doc.fetch('Description', ''), excluded: doc['Excluded'] == true,
          export_level: doc.fetch('ExportLevel', 'Hidden'),
          publish_associations: doc['PublishAssociations'] == true,
          replace_illegal_chars: doc['ReplaceIllegalChars'] == true,
          use_generalization: doc['UseGeneralization'] == true,
          odata_version: doc.fetch('ODataVersion', 'OData4'),
          include_metadata_by_default: doc['IncludeMetadataByDefault'] == true,
          supports_graphql: doc['SupportsGraphQL'] == true,
          entity_types: entities.map { published_odata_entity_spec(_1) },
          entity_sets: bson_items(doc['EntitySets']).map do |entity_set|
            published_odata_set_spec(entity_set, names_by_id)
          end
        }
        semantic_call_source(:published_odata_service, document, options)
      end

      def published_odata_entity_spec(entity)
        {
          id: document_id(entity), name: entity.fetch('ExposedName'),
          entity: entity.fetch('Entity'), summary: entity.fetch('Summary', ''),
          description: entity.fetch('Description', ''),
          members: bson_items(entity['ChildMembers']).map { published_odata_member_spec(_1) }
        }
      end

      def published_odata_member_spec(member)
        spec = {
          id: document_id(member),
          kind: member['$Type'] == 'ODataPublish$PublishedId' ? :id : :attribute,
          name: member.fetch('ExposedName'), key: member['IsPartOfKey'] == true,
          summary: member.fetch('Summary', ''), description: member.fetch('Description', '')
        }
        return spec if spec.fetch(:kind) == :id

        spec.merge(
          attribute: member.fetch('Attribute'), optional: member['CanBeEmpty'] == true,
          edm_type: member.fetch('EdmType', ''), filterable: member['Filterable'] == true,
          sortable: member['Sortable'] == true,
          enumeration_as_string: member['EnumerationAsString'] == true,
          string_as_guid: member['StringAsGuid'] == true
        )
      end

      def published_odata_set_spec(entity_set, names_by_id)
        {
          id: document_id(entity_set), name: entity_set.fetch('ExposedName'),
          alternative_name: entity_set.fetch('AlternativeExposedName', ''),
          entity_type: names_by_id.fetch(document_id_value(entity_set.fetch('EntityTypePointer'))),
          paging: entity_set['UsePaging'] == true, page_size: entity_set.fetch('PageSize', 100),
          read: published_odata_mode_spec(entity_set.fetch('ReadMode'), :source),
          insert: published_odata_mode_spec(entity_set.fetch('InsertMode'), :not_supported),
          update: published_odata_mode_spec(entity_set.fetch('UpdateMode'), :not_supported),
          delete: published_odata_mode_spec(entity_set.fetch('DeleteMode'), :not_supported),
          query: published_odata_query_spec(entity_set.fetch('QueryOptions'))
        }
      end

      def published_odata_mode_spec(mode, kind)
        { id: document_id(mode), kind: }
      end

      def published_odata_query_spec(query)
        {
          id: document_id(query), countable: query['Countable'] == true,
          skip: query['SkipSupported'] == true, top: query['TopSupported'] == true
        }
      end

      def semantic_message_definition_collection?(doc)
        return false unless (doc.keys - MESSAGE_COLLECTION_FIELDS).empty?

        bson_items(doc['MessageDefinitions']).all? do |definition|
          semantic_entity_message_definition?(definition)
        end
      end

      def semantic_entity_message_definition?(definition)
        return false unless definition.is_a?(Hash)
        return false unless definition['$Type'] == 'MessageDefinitions$EntityMessageDefinition'
        return false unless (definition.keys - MESSAGE_DEFINITION_FIELDS).empty?

        entity = definition['ExposedEntity']
        entity.is_a?(Hash) && entity['$Type'] == 'MessageDefinitions$ExposedEntity' &&
          (entity.keys - MESSAGE_EXPOSED_ENTITY_FIELDS).empty? &&
          bson_items(entity['Children']).all? { semantic_exposed_attribute?(_1) }
      end

      def semantic_exposed_attribute?(attribute)
        attribute.is_a?(Hash) &&
          attribute['$Type'] == 'MessageDefinitions$ExposedAttribute' &&
          (attribute.keys - MESSAGE_EXPOSED_ATTRIBUTE_FIELDS).empty? &&
          bson_items(attribute['Children']).empty?
      end

      def message_definition_collection_declaration(document)
        doc = document.fetch(:doc)
        options = {
          unit_id: document.fetch(:id), container_id: document.fetch(:container_id),
          documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
          export_level: doc.fetch('ExportLevel', 'Hidden'),
          definitions_marker: bson_marker(doc['MessageDefinitions'], 2)
        }
        lines = semantic_block_call_lines(
          :message_definition_collection, document.fetch(:name), options, indent: 0
        )
        bson_items(doc['MessageDefinitions']).each do |definition|
          lines.concat(message_definition_source_lines(definition))
        end
        lines << 'end'
        lines.join("\n")
      end

      def message_definition_source_lines(definition)
        entity = definition.fetch('ExposedEntity')
        options = {
          id: document_id(definition), documentation: definition.fetch('Documentation', ''),
          exposed_entity_id: document_id(entity), entity: entity.fetch('Entity', ''),
          children_marker: bson_marker(entity['Children'], 2)
        }.merge(message_element_spec(entity))
        lines = semantic_block_call_lines(:entity_message, definition.fetch('Name'), options, indent: 2)
        bson_items(entity['Children']).each do |attribute|
          attribute_options = {
            attribute: attribute.fetch('Attribute', ''), id: document_id(attribute),
            children_marker: bson_marker(attribute['Children'], 2)
          }.merge(message_element_spec(attribute))
          lines.concat(
            semantic_call_lines(
              :exposed_attribute, attribute.fetch('ExposedName', ''),
              attribute_options, indent: 4
            )
          )
        end
        lines << '  end'
        lines
      end

      def message_element_spec(element)
        {
          documentation: element.fetch('Documentation', ''),
          element_type: underscore(element.fetch('ElementType', 'Value')).to_sym,
          error_message: element.fetch('ErrorMessage', ''), example: element.fetch('Example', ''),
          exposed_item_name: element.fetch('ExposedItemName', ''),
          exposed_name: element.fetch('ExposedName', ''),
          fraction_digits: element.fetch('FractionDigits', -1),
          default_type: element['IsDefaultType'] == true,
          max_length: element.fetch('MaxLength', -1), max_occurs: element.fetch('MaxOccurs', 1),
          min_occurs: element.fetch('MinOccurs', 0), nillable: element['Nillable'] == true,
          original_name: element.fetch('OriginalName', ''), path: element.fetch('Path', ''),
          primitive_type: underscore(element.fetch('PrimitiveType', 'Unknown')).to_sym,
          total_digits: element.fetch('TotalDigits', -1),
          warning_message: element.fetch('WarningMessage', '')
        }
      end
    end
  end
end
