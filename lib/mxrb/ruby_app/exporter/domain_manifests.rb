# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Exports entities, associations, indexes, OQL views, services and REST endpoints.
      module DomainManifests
        REST_STATUS_CODES = {
          'ok' => 200, 'created' => 201, 'accepted' => 202,
          'nocontent' => 204, 'movedpermanently' => 301, 'found' => 302,
          'badrequest' => 400, 'unauthorized' => 401, 'forbidden' => 403,
          'notfound' => 404, 'conflict' => 409, 'internalservererror' => 500
        }.freeze

        ZERO_UUID = '00000000-0000-0000-0000-000000000000'

        SYSTEM_INDEX_MEMBER_TYPES = %w[CreatedDate ChangedDate].freeze

        private

        def export_entity(entity, mod, namespace, root)
          dto = !entity.persistable && !entity.oql_view?
          class_name = ruby_constant(entity.name, suffix: dto ? 'Dto' : nil)
          base_name = underscore(entity.name)
          base_name = "#{base_name}_dto" if dto && !base_name.end_with?('_dto')
          category = dto ? 'dtos' : 'models'
          relative = embedded_identity_path(:record, entity.id) || File.join('app', category, root, "#{base_name}.rb")
          qualified = "#{mod.name}.#{entity.name}"
          attributes = entity.attributes.map { attribute_manifest(_1) }
          module_associations = mod.respond_to?(:associations) ? mod.associations : []
          associations = module_associations.select do |association|
            association.from_entity_id.to_s == entity.id.to_s
          end
          associations = associations.map { association_manifest(mod, _1) }
          access_rules = access_rules_with_source_identity(runtime_value(entity.access_rules || []))
          indexes = entity.respond_to?(:indexes) ? entity.indexes.to_a.map { index_manifest(entity, _1) } : []
          generalization = generalization_manifest(entity)
          oql_view = oql_view_manifest(entity, mod)
          lifecycle = entity.respond_to?(:lifecycle) ? entity.lifecycle.to_a.map { lifecycle_manifest(_1) } : []
          validation_rules = if entity.respond_to?(:validation_rules)
                               entity.validation_rules.to_a.map { validation_rule_manifest(_1) }
                             else
                               []
                             end
          system_members = if entity.respond_to?(:generalization_target) && entity.generalization_target
                             nil
                           else
                             runtime_value(entity.system_members || {})
                           end
          write(
            relative,
            entity_source(
              namespace, class_name, qualified, entity.id, attributes, associations,
              access_rules:, indexes:, system_members:, generalization:, oql_view:,
              lifecycle:, validation_rules:,
              dto:, persistable: entity.persistable == true
            )
          )
          add_coverage(entity.id, qualified, dto ? 'dto' : 'model', relative, 'executable_bidirectional')
          {
            'name' => qualified, 'id' => entity.id,
            'ruby_class' => embedded_identity_class(:record, entity.id, "#{namespace}::#{class_name}"),
            'path' => relative, 'dto' => dto, 'persistable' => entity.persistable == true,
            'attributes' => attributes,
            'associations' => associations,
            'system_members' => system_members,
            'indexes' => indexes,
            'generalization' => generalization,
            'oql_view' => oql_view,
            'access_rules' => access_rules,
            'lifecycle' => lifecycle,
            'validation_rules' => validation_rules
          }
        end

        def association_manifest(mod, association)
          entities = @project.modules.flat_map do |project_module|
            project_module.entities.map do |entity|
              [entity.id.to_s, "#{project_module.name}.#{entity.name}"]
            end
          end.to_h
          {
            'name' => "#{mod.name}.#{association.name}", 'id' => association.id,
            'type' => association.association_type.to_s,
            'from_entity' => entities[association.from_entity_id.to_s] || association.from_entity_id.to_s,
            'to_entity' => entities[association.to_entity_id.to_s] || association.to_entity_id.to_s,
            'owner' => association.owner.to_s,
            'storage_format' => association.storage_format.to_s,
            'documentation' => association.documentation.to_s,
            'parent_delete' => association.parent_delete_behavior.to_s,
            'child_delete' => association.child_delete_behavior.to_s
          }
        end

        def index_manifest(entity, index)
          members = IO::BsonCodec.parse_array(index['Attributes'] || index['attributes'])[:items]
          {
            'id' => IO::BsonCodec.extract_id(index['$ID']),
            'guid' => IO::BsonCodec.extract_id(index['GUID']),
            'include_offline' => index.fetch('IncludeInOffline', false) == true,
            'members' => members.map do |member|
              type = (member['Type'] || member['type'] || 'Normal').to_s
              name = index_member_name(entity, member, type)

              {
                'id' => IO::BsonCodec.extract_id(member['$ID']), 'name' => name,
                'ascending' => member.fetch('Ascending', true) == true,
                'type' => type
              }
            end
          }
        end

        def index_member_name(entity, member, type)
          explicit = (member['Attribute'] || member['attribute']).to_s.split('.').last.to_s
          return explicit unless explicit.empty?

          pointer = IO::BsonCodec.extract_id(member['AttributePointer'] || member['attributePointer'])
          unless pointer.nil? || pointer == ZERO_UUID
            attribute = entity.attributes.find { _1.id.to_s == pointer }
            return attribute.name unless attribute.nil?

            raise SerializationError,
                  "unresolved index attribute pointer #{pointer} in #{entity.qualified_name}"
          end
          return type if SYSTEM_INDEX_MEMBER_TYPES.include?(type)

          raise SerializationError, "unsupported index member in #{entity.qualified_name}"
        end

        def oql_view_manifest(entity, mod)
          return unless entity.respond_to?(:oql_view?) && entity.oql_view?

          source = entity.oql_source_document if entity.respond_to?(:oql_source_document)
          documents = mod.respond_to?(:oql_view_documents) ? mod.oql_view_documents : []
          document = documents.find do |candidate|
            [candidate.fetch(:name), "#{mod.name}.#{candidate.fetch(:name)}"].include?(source.to_s)
          end
          result = {
            'source' => source,
            'source_id' => IO::BsonCodec.extract_id(
              entity.respond_to?(:source) ? entity.source&.fetch('$ID', nil) : nil
            )
          }
          if document
            result['document_id'] = document.fetch(:id)
            result['query'] = document.fetch(:doc).fetch('Oql', '')
          elsif entity.respond_to?(:oql_query) && !entity.oql_query.to_s.empty?
            result['query'] = entity.oql_query
          end
          result.compact
        end

        def export_service(flow, mod, namespace, root, kind, duplicate_name: false)
          class_name = flow_ruby_constant(flow, duplicate_name:)
          relative = embedded_identity_path(:service, flow.id) || File.join(
            'app', 'services', root, "#{flow_file_stem(flow, duplicate_name:)}.rb"
          )
          qualified = "#{mod.name}.#{flow.name}"
          native_source = native_flow_source(flow, kind)
          write(
            relative,
            service_source(
              namespace, class_name, qualified, flow.id,
              native_source:, native_kind: kind,
              export_level: kind == :rule ? flow.export_level : 'Hidden'
            )
          )
          status = native_source ? 'native_projection_source_preserved' : 'runtime_source_preserved'
          add_coverage(flow.id, qualified, kind.to_s, relative, status)
          {
            'name' => qualified, 'id' => flow.id,
            'ruby_class' => embedded_identity_class(:service, flow.id, "#{namespace}::#{class_name}"),
            'path' => relative,
            'kind' => kind.to_s, 'parameters' => flow.parameters.map { flow_parameter_manifest(_1) },
            'allowed_module_roles' => flow.allowed_module_roles.map(&:to_s)
          }
        end

        def flow_parameter_manifest(parameter)
          variable_type = parameter['VariableType'] || parameter['Type'] || {}
          {
            'name' => parameter['Name'].to_s,
            'type' => variable_type['$Type'].to_s,
            'entity' => variable_type['Entity'],
            'required' => parameter['IsRequired'] != false
          }.compact
        end

        def export_endpoints(mod)
          mod.infrastructure_documents.filter_map do |document|
            next unless document[:type] == 'Rest$PublishedRestService'

            rest_service_manifest(mod, document)
          end
        end

        def rest_service_manifest(mod, document)
          source = document.fetch(:doc)
          operations = IO::BsonCodec.parse_array(source['Resources'])[:items].flat_map do |resource|
            IO::BsonCodec.parse_array(resource['Operations'])[:items].map do |operation|
              rest_operation_manifest(mod, source, resource, operation)
            end
          end
          add_coverage(
            document.fetch(:id), "#{mod.name}.#{document.fetch(:name)}", 'published_rest_service',
            relative(@mendix_sidecar), 'executable_backend_route'
          )
          {
            'name' => "#{mod.name}.#{document.fetch(:name)}", 'path' => source['Path'].to_s,
            'version' => source['Version'].to_s, 'enable_cors' => source['EnableCors'] == true,
            'requires_authentication' => source['RequiresAuthentication'] == true,
            'operations' => operations
          }
        end

        def rest_operation_manifest(mod, service, resource, operation)
          microflow = operation['Microflow'].to_s
          microflow = "#{mod.name}.#{microflow}" unless microflow.empty? || microflow.include?('.')
          service_path = service['Path'].to_s.sub(%r{\A/+}, '').sub(%r{/+\z}, '')
          resource_path = rest_runtime_resource_path(resource, operation)
          operation_path = operation['Path'].to_s.sub(%r{\A/+}, '')
          declared_status = operation['SuccessStatusCode']
          declared_status = rest_metadata_success_status(service, resource, operation) \
            if declared_status.to_s.empty?
          declared_status = rest_documented_success_status(operation['Documentation']) \
            if declared_status.to_s.empty?
          {
            'name' => resource['Name'].to_s, 'method' => operation['HttpMethod'].to_s.upcase,
            'path' => "/#{[service_path, resource_path, operation_path].reject(&:empty?).join('/')}",
            'microflow' => microflow,
            'success_status' => rest_success_status(declared_status)
          }
        end

        def rest_metadata_success_status(service, resource, operation)
          service_id = native_identifier(service['$ID'])
          resource_id = native_identifier(resource['$ID'])
          operation_id = native_identifier(operation['$ID'])
          entry = Array(@rest_response_metadata).find do |candidate|
            candidate['service_id'].to_s == service_id &&
              candidate['resource_id'].to_s == resource_id &&
              candidate['operation_id'].to_s == operation_id
          end
          response = Array(entry&.fetch('responses', nil)).find do |candidate|
            candidate.fetch('status').to_i.between?(200, 299)
          end
          response&.fetch('status', nil)
        end

        def rest_documented_success_status(documentation)
          marker = Dsl::IntegrationDocuments::REST_RESPONSES_MARKER
          value = documentation.to_s
          encoded = if value.start_with?(marker.lstrip)
                      value.delete_prefix(marker.lstrip)
                    else
                      value.split(marker, 2)[1]
                    end
          return unless encoded

          encoded.lines.filter_map { _1.chomp[/\A-\s+(2\d{2}):/, 1] }.first
        end

        def rest_runtime_resource_path(resource, operation)
          has_parameters = IO::BsonCodec.parse_array(operation['Parameters'])[:items].any?
          has_mapping = %w[ImportMapping ExportMapping].any? { !operation[_1].to_s.empty? }
          return '' unless has_parameters || has_mapping

          resource['Name'].to_s.sub(%r{\A/+}, '').sub(%r{/+\z}, '')
        end

        def rest_success_status(value)
          return 200 if value.nil? || value.to_s.empty?

          raw = value.is_a?(Hash) ? (value['Value'] || value['Name'] || value['$Type']) : value
          integer = raw.to_s[/\d{3}/]
          return integer.to_i if integer

          REST_STATUS_CODES.fetch(raw.to_s.gsub(/[^A-Za-z]/, '').downcase, 200)
        end
      end
      # rubocop:enable Metrics
    end
  end
end
