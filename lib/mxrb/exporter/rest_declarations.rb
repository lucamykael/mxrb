# frozen_string_literal: true

module Mxrb
  class Exporter
    # Declares JSON structures, mappings, published REST services and datasets as Ruby.
    module RestDeclarations
      private

      def json_structure_declaration(document)
        doc = document.fetch(:doc)
        semantic_call_source(:json_structure, document, {
                               snippet: doc.fetch('JsonSnippet', ''),
                               documentation: doc.fetch('Documentation', ''),
                               excluded: doc['Excluded'] == true,
                               export_level: doc.fetch('ExportLevel', 'Hidden'),
                               elements: bson_items(doc['Elements']).map { json_element_spec(_1) }
                             })
      end

      def mapping_declaration(document, direction)
        doc = document.fetch(:doc)
        options = {
          json_structure: doc.fetch('JsonStructure', ''),
          documentation: doc.fetch('Documentation', ''),
          excluded: doc['Excluded'] == true,
          export_level: doc.fetch('ExportLevel', 'Hidden'),
          elements: bson_items(doc['Elements']).map { mapping_element_spec(_1) },
          message_definition: doc.fetch('MessageDefinition', ''),
          message_definition2: doc.fetch('MessageDefinition2', ''),
          operation_name: doc.fetch('OperationName', ''),
          public_name: doc.fetch('PublicName', ''),
          service_name: doc.fetch('ServiceName', ''),
          wsdl_file: doc.fetch('WsdlFile', ''),
          xml_schema: doc.fetch('XmlSchema', ''),
          xsd_root_element_name: doc.fetch('XsdRootElementName', '')
        }
        if direction == :import
          options[:parameter_type] = data_type_spec(doc['ParameterType'])
          options[:parameter_type_id] = document_id(doc['ParameterType'])
          options[:use_subtransactions] = doc['UseSubtransactionsForMicroflows'] == true
        else
          options[:null_value] = doc.fetch('NullValueOption', 'LeaveOutElement')
          options[:header_parameter] = doc['IsHeaderParameter'] == true
          options[:parameter_name] = doc.fetch('ParameterName', '')
        end
        semantic_call_source("#{direction}_mapping", document, options)
      end

      def published_rest_declaration(document = nil, mod: nil, **legacy_document)
        document ||= legacy_document
        doc = document.fetch(:doc)
        options = {
          path: doc.fetch('Path', ''),
          version: doc.fetch('Version', ''),
          service_name: doc.fetch('ServiceName', document.fetch(:name)),
          allowed_roles: bson_items(doc['AllowedRoles']),
          authentication_types: bson_items(doc['AuthenticationTypes']).map { underscore(_1) },
          authentication_microflow: doc.fetch('AuthenticationMicroflow', ''),
          documentation: doc.fetch('Documentation', ''),
          public_documentation: doc.fetch('PublicDocumentation', ''),
          excluded: doc['Excluded'] == true,
          export_level: doc.fetch('ExportLevel', 'Hidden'),
          enable_cors: doc['EnableCors'],
          requires_authentication: doc['RequiresAuthentication']
        }.reject { |key, _| %i[enable_cors requires_authentication].include?(key) && !doc.key?(camelize_key(key)) }
        identity = {
          unit_id: document.fetch(:id),
          container_id: document.fetch(:container_id)
        }
        values = identity.merge(options)
        lines = ["published_rest_service #{symbol(document.fetch(:name))},"]
        values.each_with_index do |(key, value), index|
          comma = index == values.size - 1 ? ' do' : ','
          lines << "                       #{key}: #{native_ruby(value, 23)}#{comma}"
        end
        resources = bson_items(doc['Resources'])
        resources.each do |resource|
          spec = rest_resource_spec(resource)
          resource_options = []
          resource_options << "id: #{ruby(spec.fetch(:id))}" unless spec.fetch(:id).empty?
          unless spec.fetch(:documentation).empty?
            resource_options << "documentation: #{ruby(spec.fetch(:documentation))}"
          end
          suffix = resource_options.empty? ? '' : ", #{resource_options.join(', ')}"
          lines << "  resource #{symbol(spec.fetch(:name))}#{suffix} do"
          used_names = Hash.new(0)
          native_operations = bson_items(resource['Operations'])
          spec.fetch(:operations).each_with_index do |operation, index|
            native_operation = native_operations.fetch(index)
            operation = operation.dup
            operation[:documentation], legacy_responses = split_rest_responses(operation[:documentation])
            responses = rest_responses_for(document, native_operation, mod:)
            responses = legacy_responses if responses.empty?
            parameters = Array(operation.delete(:parameters))
            base = underscore(operation.fetch(:microflow).to_s.split('.').last)
            base = "#{operation.fetch(:method)}_#{index + 1}" if base.empty?
            used_names[base] += 1
            name = used_names[base] == 1 ? base : "#{base}_#{used_names[base]}"
            operation_options = operation.except(:method).reject do |key, value|
              key == :name || value.nil? || (value == '' && key != :path) || value == false ||
                (key == :commit && value == :no) || (key == :object_handling && value == :create)
            end
            rendered = operation_options.map { |key, value| "#{key}: #{native_ruby(value)}" }
            call = "    #{operation.fetch(:method)} #{symbol(name)}, #{rendered.join(', ')}"
            if responses.empty? && parameters.empty?
              lines << call
            else
              lines << "#{call} do"
              parameters.each do |parameter|
                lines << rest_parameter_declaration(parameter)
              end
              responses.each do |response|
                lines << "      response #{response.fetch(:status)}, description: #{ruby(response.fetch(:description))}"
              end
              lines << '    end'
            end
          end
          lines << '  end'
        end
        lines << 'end'
        lines.join("\n")
      end

      def export_rest_metadata(modules)
        entries = modules.flat_map do |mod|
          mod.infrastructure_documents.flat_map do |document|
            next [] unless document[:type] == 'Rest$PublishedRestService'

            rest_metadata_entries(mod, document)
          end
        end
        @rest_response_metadata = entries
        write(
          File.join(@output_dir, '.mxrb', 'rest_metadata.json'),
          JSON.pretty_generate('version' => 1, 'operations' => entries)
        )
      end

      def rest_metadata_entries(mod, document)
        bson_items(document.dig(:doc, 'Resources')).flat_map do |resource|
          bson_items(resource['Operations']).filter_map do |operation|
            _prose, legacy = split_rest_responses(operation['Documentation'])
            stored = architecture_rest_response(mod.name, document, resource, operation)
            responses = stored ? rest_response_specs(stored[:responses]) : legacy
            responses = native_rest_response(operation) if responses.empty?
            next if responses.empty?

            {
              'module' => mod.name.to_s,
              'service_id' => document.fetch(:id).to_s,
              'service_name' => document.fetch(:name).to_s,
              'resource_id' => document_id(resource),
              'resource_name' => resource.fetch('Name', '').to_s,
              'operation_id' => document_id(operation),
              'method' => underscore(operation.fetch('HttpMethod', 'Get')),
              'path' => operation.fetch('Path', '').to_s,
              'microflow' => operation.fetch('Microflow', '').to_s,
              'responses' => responses
            }
          end
        end
      end

      def architecture_rest_response(module_name, document, resource, operation)
        metadata = Array(architecture_module(module_name)&.fetch(:rest_responses, []))
        operation_id = document_id(operation)
        exact = metadata.find do |entry|
          !operation_id.empty? && entry[:operation_id].to_s == operation_id
        end
        return exact if exact

        metadata.find do |entry|
          entry[:service_name].to_s == document.fetch(:name).to_s &&
            entry[:resource_name].to_s == resource.fetch('Name', '').to_s &&
            entry[:method].to_s.casecmp?(operation.fetch('HttpMethod', '').to_s) &&
            entry[:path].to_s == operation.fetch('Path', '').to_s &&
            entry[:microflow].to_s == operation.fetch('Microflow', '').to_s
        end
      end

      def rest_response_specs(responses)
        Array(responses).map do |response|
          value = response.to_h.transform_keys(&:to_sym)
          {
            status: value.fetch(:status).to_i,
            description: value.fetch(:description, '').to_s
          }
        end
      end

      def native_rest_response(operation)
        raw = operation['SuccessStatusCode']
        return [] if raw.nil? || raw.to_s.empty?

        value = raw.is_a?(Hash) ? (raw['Value'] || raw['Name'] || raw['$Type']) : raw
        status = value.to_s[/\d{3}/]&.to_i
        status&.between?(200, 299) ? [{ status:, description: '' }] : []
      end

      def rest_responses_for(document, operation, mod:)
        return [] unless mod

        entries = Array(@rest_response_metadata)
        operation_id = document_id(operation)
        entry = entries.find do |candidate|
          candidate.fetch('module') == mod.name.to_s &&
            candidate.fetch('service_id') == document.fetch(:id).to_s &&
            candidate.fetch('operation_id') == operation_id
        end
        entry ? rest_response_specs(entry.fetch('responses')) : []
      end

      def semantic_call_source(method, document, options)
        identity = {
          unit_id: document.fetch(:id),
          container_id: document.fetch(:container_id)
        }
        values = identity.merge(options)
        lines = ["#{method} #{symbol(document.fetch(:name))},"]
        values.each_with_index do |(key, value), index|
          rendered = native_ruby(value, 16)
          comma = index == values.size - 1 ? '' : ','
          lines << "                #{key}: #{rendered}#{comma}"
        end
        lines.join("\n")
      end

      def json_element_spec(element)
        {
          id: document_id(element), kind: underscore(element['ElementType']).to_sym,
          name: element.fetch('ExposedName', ''), item_name: element.fetch('ExposedItemName', ''),
          path: element.fetch('Path', ''), primitive: underscore(element['PrimitiveType']).to_sym,
          original: element.fetch('OriginalValue', ''), min_occurs: element.fetch('MinOccurs', 0),
          max_occurs: element.fetch('MaxOccurs', 1), nillable: element['Nillable'] == true,
          max_length: element.fetch('MaxLength', -1), total_digits: element.fetch('TotalDigits', -1),
          fraction_digits: element.fetch('FractionDigits', -1),
          default_type: element['IsDefaultType'] == true,
          error: element.fetch('ErrorMessage', ''), warning: element.fetch('WarningMessage', ''),
          children: bson_items(element['Children']).map { json_element_spec(_1) }
        }
      end

      def mapping_element_spec(element)
        object = element['$Type'].to_s.include?('ObjectMappingElement')
        common = {
          id: document_id(element), kind: object ? :object : :value,
          element_type: element.fetch('ElementType', object ? 'Object' : 'Value'),
          name: element.fetch('ExposedName', ''),
          documentation: element.fetch('Documentation', ''),
          json_path: element.fetch('JsonPath', ''), xml_path: element.fetch('XmlPath', ''),
          min_occurs: element.fetch('MinOccurs', 0), max_occurs: element.fetch('MaxOccurs', 1),
          nillable: element['Nillable'] == true,
          children: bson_items(element['Children']).map { mapping_element_spec(_1) }
        }
        if object
          return common.merge(
            association: element.fetch('Association', ''), entity: element.fetch('Entity', ''),
            default_type: element['IsDefaultType'] == true,
            object_handling: underscore(element.fetch('ObjectHandling', 'Create')).to_sym,
            backup_handling: underscore(element.fetch('ObjectHandlingBackup', 'Create')).to_sym,
            allow_override: element['ObjectHandlingBackupAllowOverride'] == true
          )
        end

        common.merge(
          attribute: element.fetch('Attribute', ''), converter: element.fetch('Converter', ''),
          type: data_type_spec(element['Type']), type_id: document_id(element['Type']),
          primitive: underscore(element.fetch('XmlPrimitiveType', 'Unknown')).to_sym,
          fraction_digits: element.fetch('FractionDigits', -1),
          max_length: element.fetch('MaxLength', -1), total_digits: element.fetch('TotalDigits', -1),
          content: element['IsContent'] == true, key: element['IsKey'] == true,
          xml_attribute: element['IsXmlAttribute'] == true,
          original: element.fetch('OriginalValue', '')
        )
      end

      def rest_resource_spec(resource)
        {
          id: document_id(resource), name: resource.fetch('Name'),
          documentation: resource.fetch('Documentation', ''),
          operations: bson_items(resource['Operations']).map { rest_operation_spec(_1) }
        }
      end

      def rest_operation_spec(operation)
        {
          id: document_id(operation), method: underscore(operation.fetch('HttpMethod', 'Get')).to_sym,
          path: operation.fetch('Path', ''), microflow: operation.fetch('Microflow', ''),
          import_mapping: operation.fetch('ImportMapping', ''),
          export_mapping: operation.fetch('ExportMapping', ''),
          commit: underscore(operation.fetch('Commit', 'No')).to_sym,
          object_handling: underscore(operation.fetch('ObjectHandlingBackup', 'Create')).to_sym,
          deprecated: operation['Deprecated'] == true,
          documentation: operation.fetch('Documentation', ''),
          summary: operation.fetch('Summary', ''),
          success_status: operation['SuccessStatusCode'],
          parameters: bson_items(operation['Parameters']).map { rest_operation_parameter_spec(_1) }
        }
      end

      def rest_operation_parameter_spec(parameter)
        {
          id: document_id(parameter), name: parameter.fetch('Name', ''),
          description: parameter.fetch('Description', ''),
          microflow_parameter: parameter.fetch('MicroflowParameter', ''),
          parameter_type: underscore(parameter.fetch('ParameterType', 'Query')).to_sym,
          type: data_type_spec(parameter.fetch('Type', {}))
        }
      end

      def rest_parameter_declaration(parameter)
        options = [
          "type: #{symbol(parameter.fetch(:type))}",
          "in: #{symbol(parameter.fetch(:parameter_type))}",
          "maps_to: #{ruby(parameter.fetch(:microflow_parameter))}"
        ]
        description = parameter.fetch(:description, '').to_s
        options << "description: #{ruby(description)}" unless description.empty?
        "      parameter #{symbol(parameter.fetch(:name))}, #{options.join(', ')}"
      end

      def split_rest_responses(documentation)
        marker = Dsl::IntegrationDocuments::REST_RESPONSES_MARKER
        value = documentation.to_s
        prose, encoded = if value.start_with?(marker.lstrip)
                           ['', value.delete_prefix(marker.lstrip)]
                         else
                           value.split(marker, 2)
                         end
        return [documentation.to_s, []] unless encoded

        responses = encoded.lines.filter_map do |line|
          match = line.chomp.match(/\A-\s+(\d{3}):\s*(.*)\z/)
          { status: match[1].to_i, description: match[2] } if match
        end
        [prose, responses]
      end

      def semantic_dataset?(doc)
        doc.dig('Source', '$Type') == 'DataSets$OqlDataSetSource' && doc.dig('Source', 'Query').is_a?(String)
      end

      def dataset_declaration(document)
        doc = document.fetch(:doc)
        lines = ["dataset #{symbol(document.fetch(:name))} do"]
        bson_items(doc['Parameters']).each do |parameter|
          type = dataset_type_source(parameter.fetch('ParameterType'))
          lines << "  parameter #{symbol(parameter.fetch('Name'))}, #{type}"
        end
        access = doc.dig('DataSetAccess', 'ModuleRoleAccessList')
        bson_items(access).each do |role|
          lines << "  allow #{ruby(role.fetch('ModuleRole'))} do"
          bson_items(role['ParameterAccessList']).each do |parameter|
            constraints = bson_items(parameter['ConstraintAccessList'])
            if constraints.empty?
              lines << "    parameter #{symbol(parameter.fetch('ParameterName'))}"
              next
            end
            lines << "    parameter #{symbol(parameter.fetch('ParameterName'))} do"
            constraints.each do |constraint|
              suffix = constraint['Enabled'] == true ? '' : ', enabled: false'
              lines << "      constraint #{ruby(constraint.fetch('ConstraintText'))}#{suffix}"
            end
            lines << '    end'
          end
          lines << '  end'
        end
        query = doc.dig('Source', 'Query').to_s
        ieiq = doc.dig('Source', 'IEIQ') == true ? ', ieiq: true' : ''
        lines << "  oql <<~OQL#{ieiq}"
        query.each_line { lines << "    #{_1.chomp}" }
        lines << '  OQL'
        lines << 'end'
        lines.join("\n")
      end

      def dataset_type_source(type)
        kind = type.fetch('$Type').to_s.delete_prefix('DataTypes$').delete_suffix('Type')
        case kind
        when 'Object' then "object_of(#{ruby(type.fetch('Entity'))})"
        when 'Enumeration' then "enum_of(#{ruby(type.fetch('Enumeration'))})"
        else underscore(kind)
        end
      end

      def semantic_rest_service?(doc, mod: nil) # rubocop:disable Lint/UnusedMethodArgument
        return false unless doc.key?('Resources') && doc.key?('Path')
        return false unless bson_items(doc['Parameters']).empty?

        true
      end

      def semantic_rest_operation_parameters?(operation, mod)
        actual = bson_items(operation['Parameters'])
        return true if actual.empty?

        expected = inferred_rest_operation_parameters(operation, mod)
        return false unless expected&.length == actual.length

        actual.zip(expected).all? do |parameter, inferred|
          rest_operation_parameter_signature(parameter) == inferred
        end
      end

      def inferred_rest_operation_parameters(operation, mod)
        return unless mod

        reference = operation['Microflow'].to_s
        flow = mod.microflows.find { _1.name.to_s == reference.split('.').last }
        return unless flow

        qualified_flow = reference.include?('.') ? reference : "#{mod.name}.#{reference}"
        path_parameters = operation.fetch('Path', '').to_s.scan(/\{([^}]+)\}/).flatten
        return unless flow.parameters.all? do |parameter|
          name = parameter['Name'] || parameter['name']
          type = parameter['VariableType'] || parameter['Type'] || parameter['type']
          name && type.is_a?(Hash)
        end

        flow.parameters.map do |parameter|
          name = parameter['Name'] || parameter['name']
          type = parameter['VariableType'] || parameter['Type'] || parameter['type']
          {
            name: name.to_s,
            description: '',
            microflow_parameter: "#{qualified_flow}.#{name}",
            parameter_type: path_parameters.include?(name.to_s) ? 'Path' : 'Query',
            type: rest_parameter_type_signature(type)
          }
        end
      end

      def rest_operation_parameter_signature(parameter)
        allowed = %w[$ID $Type Description MicroflowParameter Name ParameterType Type]
        return unless parameter.is_a?(Hash) && (parameter.keys - allowed).empty?
        return unless parameter['$Type'] == 'Rest$RestOperationParameter'
        return unless parameter['Type'].is_a?(Hash)

        {
          name: parameter['Name'].to_s,
          description: parameter.fetch('Description', '').to_s,
          microflow_parameter: parameter['MicroflowParameter'].to_s,
          parameter_type: parameter['ParameterType'].to_s,
          type: rest_parameter_type_signature(parameter['Type'])
        }
      end

      def rest_parameter_type_signature(type)
        type.to_h.each_with_object({}) do |(key, value), signature|
          next if key.to_s == '$ID'

          signature[key.to_s] = value.is_a?(Hash) ? rest_parameter_type_signature(value) : value
        end
      end

      def data_type_spec(type_doc)
        type = type_doc.to_h.fetch('$Type', 'DataTypes$UnknownType')
        underscore(type.delete_prefix('DataTypes$').delete_suffix('Type')).to_sym
      end
    end
  end
end
