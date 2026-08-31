# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'pp'
require 'time'
require_relative '../native_fragment_store'

module Mxrb
  module RubyApp
    # Projects a Mendix model into conventional executable Ruby source while
    # retaining the complete Mendix-mode tree as the reversible sidecar.
    # rubocop:disable Metrics
    class Exporter
      REST_STATUS_CODES = {
        'ok' => 200, 'created' => 201, 'accepted' => 202,
        'nocontent' => 204, 'movedpermanently' => 301, 'found' => 302,
        'badrequest' => 400, 'unauthorized' => 401, 'forbidden' => 403,
        'notfound' => 404, 'conflict' => 409, 'internalservererror' => 500
      }.freeze
      CONSTANT_TYPES = {
        'string' => :string, 'integer' => :integer, 'boolean' => :boolean,
        'decimal' => :decimal, 'datetime' => :datetime
      }.freeze
      RUBY_KEYWORDS = %w[
        alias and begin break case class def defined do else elsif end ensure false
        for if in module next nil not or redo rescue retry return self super then
        true undef unless until when while yield
      ].freeze
      RECORD_RESERVED = %w[attributes id initialize mendix_id mendix_name to_h type].freeze
      ZERO_UUID = '00000000-0000-0000-0000-000000000000'
      SYSTEM_INDEX_MEMBER_TYPES = %w[Owner CreatedDate ChangedDate ChangedBy].freeze

      def initialize(mpr_path, output_dir, mendix_sidecar:)
        @mpr_path = File.expand_path(mpr_path)
        @output_dir = File.expand_path(output_dir)
        @mendix_sidecar = File.expand_path(mendix_sidecar)
      end

      def export!
        FileUtils.mkdir_p(@output_dir)
        @native_fragment_store = NativeFragmentStore.new(
          File.join(@output_dir, '.mxrb', 'native_fragments')
        )
        runtime_mpr = copy_runtime_mpr
        embedded_sources = read_embedded_sources
        @embedded_sources = embedded_sources
        Mxrb.open(@mpr_path) do |project|
          @project = project
          @known_entity_names = project.modules.flat_map do |mod|
            mod.entities.map { "#{mod.name}.#{_1.name}" }
          end.freeze
          @coverage = []
          @nanoflow_entries = []
          @page_entries = []
          modules = project.modules.map { export_module(_1) }
          @security_manifest = export_project_security(project)
          @module_manifests = modules
          write_support_files
          copy_frontend_theme
          restore_embedded_sources(embedded_sources)
          refresh_native_frontend_sources(project, modules, embedded_sources)
          write_manifest(project, modules, runtime_mpr)
        end
        @output_dir
      ensure
        @project = nil
        @embedded_sources = nil
        @module_manifests = nil
        @security_manifest = nil
        @known_entity_names = nil
        @native_fragment_store = nil
      end

      private

      def read_embedded_sources
        mpr = IO::MprFile.open(@mpr_path, readonly: true)
        mpr.ruby_app_sources
      ensure
        mpr&.close
      end

      def restore_embedded_sources(files)
        files.each do |file|
          next if file.fetch(:path).start_with?('frontend/src/generated/')

          contents = file.fetch(:contents)
          checksum = Digest::SHA256.hexdigest(contents)
          raise SerializationError, "embedded Ruby source checksum mismatch: #{file.fetch(:path)}" \
            unless checksum == file.fetch(:sha256)

          path = RubyApp.safe_source_path(@output_dir, file.fetch(:path))
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, contents)
          File.chmod(RubyApp.safe_source_mode(file[:mode], file.fetch(:path)), path)
        end
      end

      # Generated frontend projections normally remain user-editable and are
      # restored byte-for-byte. A Ruby class with an explicit `native`
      # declaration is authoritative, though, so its page/nanoflow projection
      # must be refreshed from the just-compiled MPR instead of reviving stale
      # TypeScript from the previous round trip.
      def refresh_native_frontend_sources(project, modules, embedded_sources)
        names = embedded_native_document_names(embedded_sources)
        return if names.empty?

        modules.each do |mod|
          root = underscore(mod.fetch('name'))
          mod.fetch('pages').each do |page|
            next unless names.include?(page.fetch('name'))

            page_name = page.fetch('name').split('.', 2).last
            export_frontend_page(page, root, page_name)
            @page_entries.pop
          end
        end
        project.modules.each do |mod|
          root = underscore(mod.name)
          mod.nanoflows.each do |flow|
            qualified = "#{mod.name}.#{flow.name}"
            next unless names.include?(qualified)

            relative = File.join(
              'frontend', 'src', 'generated', 'nanoflows', root, "#{underscore(flow.name)}.ts"
            )
            write(relative, nanoflow_typescript(flow, qualified))
          end
        end
        write_generated_frontend_contract
      end

      def embedded_native_document_names(files)
        files.filter_map do |file|
          next unless file.fetch(:path).match?(%r{\Aapp/(?:pages|services)/.+\.rb\z})

          source = file.fetch(:contents).to_s
          next unless source.match?(/^\s*native(?:\s|\()/)

          match = source.match(/^\s*mendix_name\s+(['"])([^'"]+)\1/)
          match && match[2]
        end.uniq
      end

      def copy_runtime_mpr
        directory = File.join(@output_dir, '.mxrb', 'runtime')
        FileUtils.mkdir_p(directory)
        destination = File.join(directory, File.basename(@mpr_path))
        FileUtils.cp(@mpr_path, destination)
        source_contents = File.join(File.dirname(@mpr_path), 'mprcontents')
        FileUtils.cp_r(source_contents, directory, remove_destination: true) if File.directory?(source_contents)
        destination
      end

      def export_module(mod)
        namespace = ruby_constant(mod.name)
        root = underscore(mod.name)
        entities = mod.entities.map { export_entity(_1, mod, namespace, root) }
        duplicate_flows = duplicate_flow_ids(mod.microflows + mod.nanoflows)
        microflows = mod.microflows.map do |flow|
          export_service(
            flow, mod, namespace, root, :microflow,
            duplicate_name: duplicate_flows.include?(flow.id.to_s)
          )
        end
        nanoflows = mod.nanoflows.map do |flow|
          export_nanoflow(
            flow, mod, namespace, root,
            duplicate_name: duplicate_flows.include?(flow.id.to_s)
          )
        end
        pages = mod.pages.map { export_page(_1, mod, namespace, root) }
        endpoints = export_endpoints(mod)
        module_security = export_module_security(mod, namespace, root)
        {
          'name' => mod.name, 'ruby_namespace' => namespace,
          'module_roles' => module_security.fetch('roles'),
          'module_security' => module_security,
          'models' => entities.reject { _1['dto'] },
          'dtos' => entities.select { _1['dto'] },
          'services' => microflows, 'nanoflows' => nanoflows, 'pages' => pages,
          'endpoints' => endpoints,
          'constants' => mod.constants.map { export_constant(mod, _1, namespace, root) },
          'enumerations' => mod.enumerations.map { export_enumeration(mod, _1, namespace, root) },
          'associations' => mod.associations.map { association_manifest(mod, _1) },
          'scheduled_events_authoritative' => true,
          'scheduled_events' => mod.scheduled_events.map do |event|
            export_scheduled_event(mod, event, namespace, root)
          end
        }
      end

      def export_module_security(mod, namespace, root)
        id = mod.module_security_id.to_s
        qualified = "#{mod.name}.ModuleSecurity"
        relative = embedded_security_path(id, mod.name, module_security: true) ||
                   File.join('app', 'security', root, 'module_security.rb')
        roles = mod.module_roles.map do |role|
          {
            'id' => role.fetch(:id, '').to_s,
            'name' => role.fetch(:name).to_s,
            'description' => role.fetch(:description, '').to_s
          }
        end
        manifest = { 'id' => id, 'name' => qualified, 'roles' => roles, 'path' => relative }
        write(relative, module_security_source(namespace, mod.name, manifest))
        add_coverage(id, qualified, 'module_security', relative, 'executable_bidirectional') \
          unless id.empty?
        manifest
      end

      def export_project_security(project)
        pair = project.all_units.filter_map do |unit|
          document = project.parse_bson(unit)
          [unit, document] if document['$Type'] == 'Security$ProjectSecurity'
        end.first
        return nil unless pair

        unit, document = pair
        id = native_identifier(document['$ID'])
        id = unit.fetch('UnitID').to_s if id.empty?
        relative = embedded_security_path(id, 'ProjectSecurity') ||
                   File.join('app', 'security', 'project_security.rb')
        policy = document['PasswordPolicySettings'] if document['PasswordPolicySettings'].is_a?(Hash)
        manifest = {
          'id' => id,
          'security_level' => document['SecurityLevel'].to_s,
          'admin_user_role' => document['AdminUserRole'].to_s,
          'demo_users_enabled' => document['EnableDemoUsers'] == true,
          'guest_access_enabled' => document['EnableGuestAccess'] == true,
          'guest_user_role' => document['GuestUserRole'].to_s,
          'sign_in_microflow' => document['SignInMicroflow']&.to_s,
          'user_roles' => native_items(document['UserRoles']).map { project_user_role_manifest(_1) },
          'demo_users' => native_items(document['DemoUsers']).map { project_demo_user_manifest(_1) },
          'password_policy' => if policy
                                 {
                                   'id' => native_identifier(policy['$ID']),
                                   'properties' => runtime_value(
                                     policy.reject { |key, _value| %w[$ID $Type].include?(key) }
                                   )
                                 }
                               end
        }
        write(relative, project_security_source(manifest))
        add_coverage(id, 'ProjectSecurity', 'project_security', relative, 'executable_bidirectional')
        manifest.merge('path' => relative)
      end

      def project_user_role_manifest(role)
        {
          'id' => native_identifier(role['$ID']), 'name' => role['Name'].to_s,
          'description' => role['Description'].to_s,
          'check_security' => role['CheckSecurity'] == true,
          'guid' => native_identifier(role['GUID']),
          'manageable_roles' => native_items(role['ManageableRoles']).map(&:to_s),
          'manage_all_roles' => role['ManageAllRoles'] == true,
          'manage_users_without_roles' => role['ManageUsersWithoutRoles'] == true,
          'module_roles' => native_items(role['ModuleRoles']).map(&:to_s)
        }
      end

      def project_demo_user_manifest(user)
        {
          'id' => native_identifier(user['$ID']), 'name' => user['UserName'].to_s,
          'entity' => user['Entity'].to_s,
          'roles' => native_items(user['UserRoles']).map(&:to_s),
          'password_redacted' => true
        }
      end

      def export_scheduled_event(mod, event, namespace, root)
        name = event['Name'].to_s
        qualified = "#{mod.name}.#{name}"
        id = native_identifier(event['$ID'])
        schedule = event['Schedule'].is_a?(Hash) ? event['Schedule'] : {}
        enabled = event['Enabled'] == true
        unbound = !enabled && event['Microflow'].to_s.empty? && schedule.empty?
        schedule_manifest = if schedule.empty?
                              nil
                            else
                              {
                                'id' => native_identifier(schedule['$ID']),
                                'type' => schedule['$Type'].to_s,
                                'properties' => runtime_value(
                                  schedule.reject { |key, _value| %w[$ID $Type].include?(key) }
                                )
                              }
                            end
        relative = embedded_scheduled_event_path(id, qualified) ||
                   File.join('app', 'scheduled_events', root, "#{underscore(name)}.rb")
        manifest = {
          'name' => qualified, 'id' => id, 'documentation' => event['Documentation'].to_s,
          'export_level' => (event['ExportLevel'] || 'Hidden').to_s,
          'microflow' => event['Microflow'].to_s,
          'start_at' => scheduled_event_start(event['StartDateTime']),
          'time_zone' => event['TimeZone'].to_s,
          'on_overlap' => event['OnOverlap'].to_s,
          'enabled' => enabled, 'unbound' => unbound,
          'interval_type' => event['IntervalType'].to_s,
          'interval' => event.fetch('Interval', 1),
          'schedule' => schedule_manifest,
          'path' => relative
        }
        write(relative, scheduled_event_source(namespace, ruby_constant(name), manifest))
        add_coverage(id, qualified, 'scheduled_event', relative, 'executable_bidirectional')
        manifest
      end

      def export_entity(entity, mod, namespace, root)
        dto = !entity.persistable && !entity.oql_view?
        class_name = ruby_constant(entity.name, suffix: dto ? 'Dto' : nil)
        base_name = underscore(entity.name)
        base_name = "#{base_name}_dto" if dto && !base_name.end_with?('_dto')
        category = dto ? 'dtos' : 'models'
        relative = File.join('app', category, root, "#{base_name}.rb")
        qualified = "#{mod.name}.#{entity.name}"
        attributes = entity.attributes.map { attribute_manifest(_1) }
        module_associations = mod.respond_to?(:associations) ? mod.associations : []
        associations = module_associations.select do |association|
          association.from_entity_id.to_s == entity.id.to_s
        end
        associations = associations.map { association_manifest(mod, _1) }
        access_rules = runtime_value(entity.access_rules || [])
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
          'name' => qualified, 'id' => entity.id, 'ruby_class' => "#{namespace}::#{class_name}",
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

      def generalization_manifest(entity)
        target = entity.respond_to?(:generalization_target) ? entity.generalization_target : nil
        return unless target

        {
          'target' => target,
          'id' => IO::BsonCodec.extract_id(
            entity.respond_to?(:generalization) ? entity.generalization&.fetch('$ID', nil) : nil
          )
        }.compact
      end

      def lifecycle_manifest(callback)
        {
          'id' => callback.fetch(:id, '').to_s,
          'event' => callback.fetch(:event).to_s,
          'handler' => callback.fetch(:handler).to_s,
          'pass_event_object' => callback.fetch(:pass_event_object, true) == true,
          'raise_error_on_false' => callback.fetch(:raise_error_on_false, false) == true
        }
      end

      def validation_rule_manifest(rule)
        info = rule['RuleInfo'].is_a?(Hash) ? rule['RuleInfo'] : {}
        type = info['$Type'].to_s
        short_kind = type.sub(/\ADomainModels\$/, '').sub(/RuleInfo\z/, '')
        kind = %w[Required Unique].include?(short_kind) ? short_kind.downcase : type
        message = rule['Message'].is_a?(Hash) ? rule['Message'] : {}
        {
          'id' => native_identifier(rule['$ID']),
          'attribute' => rule['Attribute'].to_s.split('.').last,
          'kind' => kind,
          'message_id' => native_identifier(message['$ID']),
          'translations' => native_items(message['Items']).map do |translation|
            {
              'id' => native_identifier(translation['$ID']),
              'language_code' => translation['LanguageCode'].to_s,
              'text' => translation['Text'].to_s
            }
          end,
          'rule_info_id' => native_identifier(info['$ID']),
          'rule_info' => runtime_value(info.reject { |key, _value| %w[$ID $Type].include?(key) })
        }
      end

      def export_service(flow, mod, namespace, root, kind, duplicate_name: false)
        class_name = flow_ruby_constant(flow, duplicate_name:)
        relative = File.join(
          'app', 'services', root, "#{flow_file_stem(flow, duplicate_name:)}.rb"
        )
        qualified = "#{mod.name}.#{flow.name}"
        native_source = native_flow_source(flow, kind)
        write(
          relative,
          service_source(namespace, class_name, qualified, flow.id, native_source:, native_kind: kind)
        )
        status = native_source ? 'native_projection_source_preserved' : 'runtime_source_preserved'
        add_coverage(flow.id, qualified, kind.to_s, relative, status)
        {
          'name' => qualified, 'id' => flow.id,
          'ruby_class' => "#{namespace}::#{class_name}", 'path' => relative,
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
        operation_path = operation['Path'].to_s.sub(%r{\A/+}, '')
        {
          'name' => resource['Name'].to_s, 'method' => operation['HttpMethod'].to_s.upcase,
          'path' => "/#{[service_path, operation_path].reject(&:empty?).join('/')}",
          'microflow' => microflow, 'success_status' => rest_success_status(operation['SuccessStatusCode'])
        }
      end

      def rest_success_status(value)
        return 200 if value.nil? || value.to_s.empty?

        raw = value.is_a?(Hash) ? (value['Value'] || value['Name'] || value['$Type']) : value
        integer = raw.to_s[/\d{3}/]
        return integer.to_i if integer

        REST_STATUS_CODES.fetch(raw.to_s.gsub(/[^A-Za-z]/, '').downcase, 200)
      end

      def export_nanoflow(flow, mod, namespace, root = nil, duplicate_name: false)
        root ||= namespace
        namespace = ruby_constant(mod.name) if root == namespace
        qualified = "#{mod.name}.#{flow.name}"
        relative = File.join(
          'frontend', 'src', 'generated', 'nanoflows', root,
          "#{flow_file_stem(flow, duplicate_name:)}.ts"
        )
        write(relative, nanoflow_typescript(flow, qualified))
        native_source = native_flow_source(flow, :nanoflow)
        ruby_path = File.join(
          'app', 'services', root, "#{flow_file_stem(flow, duplicate_name:)}_nanoflow.rb"
        )
        if native_source
          write(
            ruby_path,
            service_source(
              namespace, flow_ruby_constant(flow, duplicate_name:), qualified, flow.id,
              native_source:, native_kind: :nanoflow
            )
          )
        end
        entry = {
          'name' => qualified, 'id' => flow.id, 'path' => relative,
          'kind' => 'nanoflow', 'runtime' => 'frontend'
        }
        entry['ruby_path'] = ruby_path if native_source
        @nanoflow_entries << entry.merge('import_name' => "Nanoflow#{@nanoflow_entries.size}")
        add_coverage(
          flow.id, qualified, 'nanoflow', native_source ? ruby_path : relative,
          native_source ? 'native_projection_source_preserved' : 'frontend_executable'
        )
        entry
      end

      def native_flow_source(flow, kind)
        return unless flow.is_a?(Model::Microflow)

        converter = Mxrb::Exporter.allocate
        converter.instance_variable_set(:@mpr_path, @mpr_path)
        method = kind.to_sym == :nanoflow ? :nanoflow_source : :microflow_source
        source = converter.send(method, flow)
        return unless source.include?('body_fingerprint')

        declaration = source.lines.index { _1.match?(/^\s*(?:microflow|nanoflow)\s/) }
        return unless declaration

        source.lines[(declaration + 1)...-1].map { _1.delete_prefix('  ') }.join.rstrip
      rescue StandardError, SyntaxError
        nil
      end

      def nanoflow_typescript(flow, qualified)
        plan = nanoflow_plan(flow, qualified)
        parameters = nanoflow_parameter_type(flow.parameters)
        result_type = nanoflow_result_type(flow.respond_to?(:return_type) ? flow.return_type : nil)
        start = plan.fetch('objects').find { _1['type'] == 'StartEvent' }
        cases = plan.fetch('objects').filter_map do |object|
          nanoflow_typescript_case(object, plan.fetch('flows'), result_type)
        end
        <<~TS
          import { defineNanoflow } from '../../bridge/nanoflow';
          import type { EntityRecord, EntityTypeMap, NanoflowParameters, RuntimeValue } from '../../types';

          type Parameters = NanoflowParameters & #{parameters};

          export default defineNanoflow<Parameters, #{result_type}>({
            name: #{JSON.generate(qualified)},
            id: #{JSON.generate(flow.id.to_s)},
            parameters: #{JSON.generate(plan.fetch('parameters'))}
          }, async runtime => {
            let current = #{JSON.generate(start && start['id'])};
            for (let step = 0; step < 10_000; step += 1) {
              switch (current) {
          #{cases.join("\n")}
                default:
                  throw runtime.missing(current);
              }
            }
            throw runtime.exceeded();
          });
        TS
      end

      def nanoflow_parameter_type(parameters)
        fields = parameters.filter_map do |parameter|
          next unless parameter.is_a?(Hash)

          "  #{JSON.generate(parameter['Name'].to_s)}: #{typescript_flow_type(parameter['VariableType'])};"
        end
        "{\n#{fields.join("\n")}\n}"
      end

      def nanoflow_result_type(type)
        typescript_flow_type('$Type' => type.to_s).delete_suffix(' | null')
      end

      def typescript_flow_type(type)
        type = {} unless type.is_a?(Hash)
        kind = (type['$Type'] || type['Type']).to_s
        entity = type['Entity'].to_s
        return "#{typescript_entity_reference(entity)} | null" if
          kind.end_with?('ObjectType') && !entity.empty?
        return "Array<#{typescript_entity_reference(entity)}>" if
          kind.end_with?('ListType') && !entity.empty?
        return 'boolean' if kind.match?(/Boolean/)
        return 'number' if kind.match?(/Integer|Long|Decimal|Float/)
        return 'string' if kind.match?(/String|DateTime|Enumeration/)
        return 'undefined' if kind.empty? || kind.match?(/Void|MicroflowReturnType/)

        'RuntimeValue | undefined'
      end

      def nanoflow_typescript_case(object, flows, result_type)
        return if object['type'] == 'MicroflowParameter'

        outgoing = flows.select { _1['origin'] == object['id'] }
        body = case object['type']
               when 'EndEvent' then nanoflow_end_source(object, result_type)
               when 'ExclusiveSplit' then nanoflow_split_source(object, outgoing)
               when 'ActionActivity' then nanoflow_action_source(object['action']) + nanoflow_next_source(outgoing)
               else nanoflow_next_source(outgoing)
               end
        <<~TS.chomp
                case #{JSON.generate(object['id'])}: {
          #{indent(body, 10)}
                }
        TS
      end

      def nanoflow_end_source(object, result_type)
        expression = JSON.generate(object['return'].to_s)
        value = case result_type
                when 'boolean' then "runtime.boolean(#{expression})"
                when 'number' then "runtime.number(#{expression})"
                when 'string' then "runtime.string(#{expression})"
                when 'undefined' then 'undefined'
                else "runtime.value(#{expression}) as #{result_type}"
                end
        "return runtime.complete(#{value});"
      end

      def nanoflow_split_source(object, flows)
        cases = flows.reject { _1['case'].to_s.empty? }.map do |edge|
          "case #{JSON.generate(edge['case'].to_s)}: current = #{JSON.generate(edge['destination'])}; break;"
        end
        fallback = flows.find { _1['case'].to_s.empty? }
        default = if fallback
                    "current = #{JSON.generate(fallback['destination'])}; break;"
                  else
                    "throw runtime.stopped(#{JSON.generate(object['type'])});"
                  end
        <<~TS.chomp
          switch (String(runtime.condition(#{JSON.generate(object['condition'].to_s)}))) {
          #{indent(cases.join("\n"), 2)}
            default: #{default}
          }
          break;
        TS
      end

      def nanoflow_action_source(action)
        action ||= {}
        case action['type']
        when 'LogMessage'
          "runtime.log(#{JSON.generate(action['message'].to_s)});\n"
        when 'CreateVariable', 'ChangeVariable'
          "runtime.set(#{JSON.generate(action['variable'].to_s)}, " \
            "runtime.value(#{JSON.generate(action['value'].to_s)}));\n"
        when 'Change'
          changes = action.fetch('changes', []).to_h do |change|
            [change['member'].to_s, change['value'].to_s]
          end
          "runtime.change(#{JSON.generate(action['variable'].to_s)}, #{JSON.generate(changes)});\n"
        when 'MicroflowCall'
          variable = action['result_variable'].to_s
          invocation = "runtime.callMicroflow(#{JSON.generate(action['microflow'].to_s)}, " \
                       "#{JSON.generate(action.fetch('arguments', {}))})"
          if variable.empty?
            "await #{invocation};\n"
          else
            "const response = await #{invocation};\n" \
              "runtime.set(#{JSON.generate(variable)}, response);\n"
          end
        when 'ShowMessage'
          "runtime.showMessage(#{JSON.generate(action['message'].to_s)}.replace(" \
            '/\\{(\\d+)\\}/g, (_placeholder, rawIndex) => ' \
            "runtime.string(#{JSON.generate(action.fetch('parameters', []))}[Number(rawIndex) - 1])), " \
            "#{JSON.generate(action['level'].to_s.downcase)}, " \
            "#{action['blocking'] == true});\n"
        else
          "throw runtime.unsupported(#{JSON.generate(action['type'].to_s)});\n"
        end
      end

      def nanoflow_next_source(flows)
        edge = flows.first
        return "throw runtime.stopped('node');" unless edge

        "current = #{JSON.generate(edge['destination'])};\nbreak;"
      end

      def indent(source, spaces)
        prefix = ' ' * spaces
        source.to_s.lines.map { "#{prefix}#{_1}" }.join.chomp
      end

      def nanoflow_plan(flow, qualified)
        {
          'name' => qualified, 'id' => flow.id,
          'parameters' => flow.parameters.filter_map { _1['Name'] if _1.is_a?(Hash) },
          'objects' => flow.objects.filter_map { nanoflow_object(_1) },
          'flows' => flow.flows.reject { _1['IsErrorHandler'] == true }.map do |edge|
            {
              'origin' => native_identifier(edge['OriginPointer']),
              'destination' => native_identifier(edge['DestinationPointer']),
              'case' => nanoflow_case(edge)
            }
          end
        }
      end

      def nanoflow_object(object)
        return unless object.is_a?(Hash)

        type = object['$Type'].to_s.delete_prefix('Microflows$')
        result = { 'id' => native_identifier(object), 'type' => type }
        result['return'] = object['ReturnValue'].to_s if type == 'EndEvent'
        result['condition'] = object.dig('SplitCondition', 'Expression').to_s if type == 'ExclusiveSplit'
        result['action'] = nanoflow_action(object['Action']) if type == 'ActionActivity'
        result
      end

      def nanoflow_action(action)
        return {} unless action.is_a?(Hash)

        type = action['$Type'].to_s.delete_prefix('Microflows$').delete_suffix('Action')
        result = { 'type' => type }
        case type
        when 'CreateVariable'
          result.merge!('variable' => action['VariableName'].to_s, 'value' => action['InitialValue'].to_s)
        when 'ChangeVariable'
          result.merge!('variable' => action['ChangeVariableName'].to_s, 'value' => action['Value'].to_s)
        when 'Change'
          changes = native_items(action['Items']).map do |item|
            member = (item['Attribute'].to_s.empty? ? item['Association'] : item['Attribute']).to_s
            { 'member' => member.split(%r{[./]}).last, 'value' => item['Value'].to_s }
          end
          result.merge!('variable' => action['ChangeVariableName'].to_s, 'changes' => changes)
        when 'LogMessage'
          result['message'] = translated_text_template(action['MessageTemplate'])
        when 'MicroflowCall'
          call = action['MicroflowCall'] || {}
          arguments = native_items(call['ParameterMappings']).to_h do |mapping|
            [mapping['Parameter'].to_s.split('.').last, mapping['Argument'].to_s]
          end
          result.merge!(
            'microflow' => call['Microflow'].to_s,
            'arguments' => arguments,
            'result_variable' => action['UseReturnVariable'] == true ? action['ResultVariableName'].to_s : ''
          )
        when 'ShowMessage'
          template = action['Template'] || {}
          result.merge!(
            'message' => translated_text_template(template),
            'parameters' => native_items(template['Parameters']).map { _1['Expression'].to_s },
            'level' => action['Type'].to_s,
            'blocking' => action['Blocking'] == true
          )
        end
        result
      end

      def translated_text_template(template)
        text = template.is_a?(Hash) ? template['Text'] : nil
        return text.to_s unless text.is_a?(Hash)

        translations = native_items(text['Items'])
        selected = translations.find { _1['LanguageCode'].to_s == 'en_US' } || translations.first
        selected.is_a?(Hash) ? selected['Text'].to_s : ''
      end

      def typescript_entity_reference(entity)
        known = @known_entity_names
        available = known ? known.include?(entity.to_s) : !entity.to_s.start_with?('System.')
        return "EntityTypeMap[#{JSON.generate(entity)}]" if available

        'EntityRecord'
      end

      def nanoflow_case(edge)
        value = native_items(edge['CaseValues']).first || edge['NewCaseValue'] || {}
        value['$Type'] == 'Microflows$NoCase' ? '' : value['Value'].to_s
      end

      def native_items(value)
        IO::BsonCodec.parse_array(value)[:items]
      rescue StandardError
        Array(value).drop(value.is_a?(Array) && value.first.is_a?(Integer) ? 1 : 0)
      end

      def native_identifier(value)
        IO::BsonCodec.extract_id(value.is_a?(Hash) ? value['$ID'] : value).to_s
      end

      def export_page(page, mod, namespace, root)
        class_name = ruby_constant(page.name, suffix: 'Page')
        relative = File.join('app', 'pages', root, "#{underscore(page.name)}_page.rb")
        qualified = "#{mod.name}.#{page.name}"
        widgets = page.widgets.map { widget_manifest(_1) }
        write(
          relative,
          page_source(namespace, class_name, qualified, page.id, page.title, widgets,
                      appearance_class: page.appearance_class,
                      appearance_style: page.appearance_style,
                      data_source: page.data_source)
        )
        add_coverage(page.id, qualified, 'page', relative, 'native_projection_source_preserved')
        manifest = {
          'name' => qualified, 'id' => page.id, 'title' => page.title,
          'ruby_class' => "#{namespace}::#{class_name}", 'path' => relative,
          'appearance_class' => page.appearance_class,
          'appearance_style' => page.appearance_style,
          'data_source' => page.data_source,
          'allowed_module_roles' => page.allowed_module_roles.map(&:to_s),
          'widgets' => widgets
        }
        export_frontend_page(manifest, root, page.name)
        manifest
      end

      def export_frontend_page(manifest, root, page_name)
        relative = File.join(
          'frontend', 'src', 'generated', 'pages', root, "#{underscore(page_name)}.tsx"
        )
        component = "#{typescript_identifier(manifest.fetch('name'))}Page"
        definition = manifest.slice('name', 'title', 'appearance_class', 'appearance_style', 'widgets')
        declarations = []
        compiled_widgets = definition.fetch('widgets').each_with_index.map do |widget, index|
          frontend_widget_jsx(widget, [index], declarations, 6)
        end
        widget_tree = compiled_widgets.map(&:first).join("\n")
        definition_source = frontend_page_definition_source(definition, compiled_widgets.map(&:last))
        write(relative, <<~TS)
          import type { PageComponentProps, PageDefinition, WidgetDefinition } from '../../types';

          #{declarations.join("\n\n")}

          export const definition = #{definition_source} satisfies PageDefinition;

          export default function #{component}({ busy, Widget: PageWidget }: PageComponentProps) {
            return <main className="mxrb-page region-content mx-scrollcontainer-wrapper"
              aria-busy={busy} data-page={definition.name}>
          #{widget_tree}
            </main>;
          }
        TS
        @page_entries << {
          'name' => manifest.fetch('name'), 'path' => relative,
          'import_name' => component
        }
      end

      def frontend_widget_jsx(widget, path, declarations, indent)
        identifier = "widget#{path.join('_')}"
        children = Array(widget['children'])
        compiled = widget.reject { |key, _value| key == 'children' }
        nested_widgets = children.each_with_index.map do |child, index|
          frontend_widget_jsx(child, path + [index], declarations, indent + 2)
        end
        source = JSON.pretty_generate(compiled)
        unless nested_widgets.empty?
          source = source.sub(/\n}\z/, ",\n  \"children\": [#{nested_widgets.map(&:last).join(', ')}]\n}")
        end
        declarations << "const #{identifier} = #{source} satisfies WidgetDefinition;"
        padding = ' ' * indent
        return ["#{padding}<PageWidget widget={#{identifier}} index={#{path.last}} />", identifier] if children.empty?

        nested = nested_widgets.map(&:first).join("\n")
        jsx = <<~TS.chomp
          #{padding}<PageWidget widget={#{identifier}} index={#{path.last}}>
          #{nested}
          #{padding}</PageWidget>
        TS
        [jsx, identifier]
      end

      def frontend_page_definition_source(definition, widget_identifiers)
        source = JSON.pretty_generate(definition.reject { |key, _value| key == 'widgets' })
        source.sub(/\n}\z/, ",\n  \"widgets\": [#{widget_identifiers.join(', ')}]\n}")
      end

      def attribute_manifest(attribute)
        value = {
          'name' => attribute.name, 'ruby_name' => ruby_method_name(attribute.name),
          'type' => attribute.type.to_s, 'required' => attribute.required == true,
          'unique' => optional_attribute_value(attribute, :unique) == true,
          'default' => attribute.default_value,
          'documentation' => optional_attribute_value(attribute, :documentation).to_s,
          'length' => optional_attribute_value(attribute, :length),
          'id' => attribute.id
        }
        localize_date = optional_attribute_value(attribute, :localize_date)
        value['localize_date'] = localize_date unless localize_date.nil?
        enumeration = native_identifier(attribute.respond_to?(:enumeration) ? attribute.enumeration : nil)
        value['enumeration'] = enumeration unless enumeration.empty?
        value
      end

      def optional_attribute_value(attribute, name)
        attribute.public_send(name) if attribute.respond_to?(name)
      end

      def export_enumeration(mod, enumeration, namespace, root)
        name = enumeration['Name'].to_s
        class_name = ruby_constant(name)
        id = native_identifier(enumeration['$ID'])
        qualified = "#{mod.name}.#{name}"
        relative = embedded_enumeration_path(id, qualified) ||
                   File.join('app', 'enumerations', root, "#{underscore(name)}.rb")
        manifest = {
          'name' => qualified,
          'id' => id,
          'ruby_class' => "#{namespace}::#{class_name}",
          'path' => relative,
          'documentation' => enumeration['Documentation'].to_s,
          'values' => native_items(enumeration['Values']).map do |value|
            value_name = value['Name'].to_s
            captions = translated_captions(value['Caption'])
            {
              'name' => value_name, 'id' => native_identifier(value['$ID']),
              'caption' => captions['en_US'] || captions.values.first || value_name,
              'captions' => captions
            }
          end
        }
        write(relative, enumeration_source(namespace, class_name, manifest))
        add_coverage(manifest.fetch('id'), manifest.fetch('name'), 'enumeration', relative,
                     'executable_bidirectional')
        manifest
      end

      def export_constant(mod, constant, namespace, root)
        name = constant['Name'].to_s
        class_name = ruby_constant(name)
        id = native_identifier(constant['$ID'])
        qualified = "#{mod.name}.#{name}"
        relative = embedded_constant_path(id, qualified) ||
                   File.join('app', 'constants', root, "#{underscore(name)}.rb")
        exposed = constant['ExposedToClient'] == true
        manifest = {
          'name' => qualified, 'id' => id,
          'ruby_class' => "#{namespace}::#{class_name}", 'path' => relative,
          'documentation' => constant['Documentation'].to_s,
          'type' => constant_type(constant).to_s,
          'exposed_to_client' => exposed, 'excluded' => constant['Excluded'] == true,
          'export_level' => (constant['ExportLevel'] || 'Hidden').to_s,
          'default_redacted' => !exposed
        }
        manifest['default'] = constant['DefaultValue'].to_s if exposed
        write(relative, constant_source(namespace, class_name, manifest))
        add_coverage(id, qualified, 'constant', relative, 'executable_bidirectional')
        manifest
      end

      def embedded_constant_path(id, qualified)
        Array(@embedded_sources).find do |file|
          next unless file.fetch(:path).match?(%r{\Aapp/constants/.+\.rb\z})

          source = file.fetch(:contents).to_s
          matches_id = source.match?(
            /^\s*mendix_name\s+['"][^'"]+['"],\s+id:\s+['"]#{Regexp.escape(id)}['"]/
          )
          matches_id ||
            source.match?(/^\s*mendix_name\s+['"]#{Regexp.escape(qualified)}['"]/)
        end&.fetch(:path)
      end

      def constant_type(constant)
        raw = constant.dig('Type', '$Type') || constant['DataType']
        normalized = raw.to_s.delete_prefix('DataTypes$').delete_suffix('Type').downcase
        CONSTANT_TYPES.fetch(normalized) do
          raise ValidationError,
                "unsupported native constant type #{raw.inspect} for #{constant['Name']}"
        end
      end

      def embedded_enumeration_path(id, qualified)
        Array(@embedded_sources).find do |file|
          next unless file.fetch(:path).match?(%r{\Aapp/enumerations/.+\.rb\z})

          source = file.fetch(:contents).to_s
          source.match?(
            /^\s*mendix_name\s+['"][^'"]+['"],\s+id:\s+['"]#{Regexp.escape(id)}['"]/
          ) || source.match?(/^\s*mendix_name\s+['"]#{Regexp.escape(qualified)}['"]/)
        end&.fetch(:path)
      end

      def embedded_security_path(id, name, module_security: false)
        Array(@embedded_sources).find do |file|
          next unless file.fetch(:path).match?(%r{\Aapp/security/.+\.rb\z})

          source = file.fetch(:contents).to_s
          id_match = !id.to_s.empty? && source.match?(
            /^\s*(?:mendix_name\s+['"][^'"]+['"],\s+id:|mendix_id)\s+['"]#{Regexp.escape(id)}['"]/
          )
          name_match = module_security && source.match?(
            /^\s*mendix_name\s+['"]#{Regexp.escape(name.to_s)}['"]/
          )
          id_match || name_match
        end&.fetch(:path)
      end

      def embedded_scheduled_event_path(id, qualified)
        Array(@embedded_sources).find do |file|
          next unless file.fetch(:path).match?(%r{\Aapp/scheduled_events/.+\.rb\z})

          source = file.fetch(:contents).to_s
          id_match = !id.to_s.empty? && source.match?(
            /^\s*mendix_name\s+['"][^'"]+['"],\s+id:\s+['"]#{Regexp.escape(id)}['"]/
          )
          id_match || source.match?(
            /^\s*mendix_name\s+['"]#{Regexp.escape(qualified)}['"]/
          )
        end&.fetch(:path)
      end

      def scheduled_event_start(value)
        return value.utc.iso8601 if value.respond_to?(:utc) && value.respond_to?(:iso8601)

        value.to_s
      end

      def translated_caption(caption, fallback)
        text = translated_captions(caption).values.first.to_s
        text.empty? ? fallback : text
      end

      def translated_captions(caption)
        native_items(caption.is_a?(Hash) ? caption['Items'] : nil).filter_map do |translation|
          next unless translation.is_a?(Hash)

          language = translation['LanguageCode'].to_s
          next if language.empty?

          [language, translation['Text'].to_s]
        end.to_h
      end

      def widget_manifest(widget)
        type = runtime_widget_type(widget)
        raw_options = widget.fetch(:options, {})
        options = runtime_widget_options(raw_options)
        options['native_fragment'] = native_widget_fragment_manifest(raw_options) if
          type == 'native_widget'
        value = { 'type' => type, 'name' => widget.fetch(:name, '').to_s }
        value['options'] = options unless options.empty?
        caption = options['caption']
        value['caption'] = caption unless caption.to_s.empty?
        events = runtime_value(widget.fetch(:events, []))
        value['events'] = events unless events.empty?
        children = Array(widget[:children]).map { widget_manifest(_1) }
        value['children'] = children unless children.empty?
        %i[body footer].each do |region|
          widgets = Array(widget[region]).map { widget_manifest(_1) }
          value[region.to_s] = widgets unless widgets.empty?
        end
        regions = widget[:regions]
        if regions.is_a?(Hash)
          value['regions'] = regions.to_h do |name, widgets|
            [name.to_s, Array(widgets).map { widget_manifest(_1) }]
          end
        end
        slots = Array(widget[:slots]).map do |slot|
          manifest = {
            'path' => runtime_value(slot.fetch(:path)),
            'widgets' => Array(slot[:widgets]).map { widget_manifest(_1) }
          }
          manifest['role'] = slot.fetch(:role).to_s if slot.key?(:role)
          manifest
        end
        value['slots'] = slots unless slots.empty?
        value
      end

      def runtime_widget_options(value)
        if runtime_native_widget_hash?(value)
          manifest = runtime_value(value)
          raw_options = value[:options] || value['options']
          manifest.fetch('options')['native_fragment'] = native_widget_fragment_manifest(raw_options)
          return manifest
        end

        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            next if key.to_s == 'deep_structure'

            result[key.to_s] = runtime_widget_options(child)
          end
        when Array then value.map { runtime_widget_options(_1) }
        else runtime_value(value)
        end
      end

      def runtime_native_widget_hash?(value)
        return false unless value.is_a?(Hash)

        type = value[:type] || value['type']
        options = value[:options] || value['options']
        type.to_s == 'native_widget' && options.is_a?(Hash)
      end

      def native_widget_fragment_manifest(options)
        deep_structure = options[:deep_structure] || options['deep_structure']
        raise SerializationError, 'native widget deep_structure must be a Hash' unless
          deep_structure.is_a?(Hash)
        raise SerializationError, 'native fragment store is not initialized' unless
          @native_fragment_store

        { 'digest' => @native_fragment_store.put(deep_structure) }
      end

      def runtime_widget_type(widget)
        type = widget.fetch(:type).to_s
        return type unless type == 'text_box'

        path = widget.dig(:options, :attribute).to_s.tr('/', '.')
        module_name, entity_name, attribute_name = path.split('.', 3)
        return type unless attribute_name

        entity = @project.modules.find { _1.name == module_name }
                         &.entities&.find { _1.name == entity_name }
        attribute = entity&.attributes&.find { _1.name == attribute_name }
        %i[integer long decimal autonumber].include?(attribute&.type) ? 'number_input' : type
      end

      def runtime_value(value)
        case value
        when BSON::Binary
          {
            '$binary' => Base64.strict_encode64(value.data),
            '$subtype' => value.type.to_s
          }
        when Hash
          value.each_with_object({}) do |(key, child), result|
            next if key.to_s == 'deep_structure'

            result[key.to_s] = runtime_value(child)
          end
        when Array then value.map { runtime_value(_1) }
        when Symbol then value.to_s
        when String, Numeric, TrueClass, FalseClass, NilClass then value
        else value.to_s
        end
      end

      def entity_source(namespace, class_name, qualified, id, attributes, associations = [],
                        dto:, persistable:,
                        access_rules: [], indexes: [], system_members: nil,
                        generalization: nil, oql_view: nil, lifecycle: [], validation_rules: [])
        declarations = attributes.map do |attribute|
          localize_date = if attribute.key?('localize_date')
                            ", localize_date: #{attribute.fetch('localize_date').inspect}"
                          else
                            ''
                          end
          "    attribute :#{attribute.fetch('ruby_name')}, type: :#{attribute.fetch('type')}, " \
            "mendix_name: #{attribute.fetch('name').inspect}, required: #{attribute.fetch('required')}, " \
            "unique: #{attribute.fetch('unique')}, default: #{attribute.fetch('default').inspect}, " \
            "documentation: #{attribute.fetch('documentation').inspect}, " \
            "length: #{attribute['length'].inspect}#{localize_date}, " \
            "enumeration: #{attribute['enumeration'].inspect}"
        end
        association_declarations = associations.map do |association|
          "    association #{association.fetch('to_entity').inspect}, " \
            "name: #{association.fetch('name').split('.', 2).last.inspect}, " \
            "id: #{association.fetch('id').inspect}, type: :#{association.fetch('type')}, " \
            "owner: :#{association.fetch('owner')}, " \
            "documentation: #{association.fetch('documentation').inspect}, " \
            "parent_delete: :#{association.fetch('parent_delete')}, " \
            "child_delete: :#{association.fetch('child_delete')}, " \
            "storage_format: :#{association.fetch('storage_format')}"
        end
        access_declarations = if access_rules.empty?
                                ['    clear_access_rules!']
                              else
                                access_rules.map { access_rule_source(_1) }
                              end
        index_declarations = if indexes.empty?
                               ['    clear_indexes!']
                             else
                               indexes.map { index_source(_1) }
                             end
        system_declarations = if system_members
                                ['    system_members ' \
                                 "owner: #{system_members.fetch('owner', false)}, " \
                                 "created_date: #{system_members.fetch('created_date', false)}, " \
                                 "changed_date: #{system_members.fetch('changed_date', false)}, " \
                                 "changed_by: #{system_members.fetch('changed_by', false)}"]
                              else
                                []
                              end
        semantic_declarations = []
        if generalization
          semantic_declarations << "    generalizes #{generalization.fetch('target').inspect}, " \
                                   "id: #{generalization.fetch('id', nil).inspect}"
        end
        semantic_declarations << oql_view_source(oql_view) if oql_view
        lifecycle_declarations = if lifecycle.empty?
                                   ['    clear_native_lifecycle!']
                                 else
                                   lifecycle.map { lifecycle_source(_1) }
                                 end
        validation_declarations = if validation_rules.empty?
                                    ['    clear_validation_rules!']
                                  else
                                    validation_rules.map { validation_rule_source(_1) }
                                  end
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            class #{class_name} < Mxrb::RubyApp::#{dto ? 'DTO' : 'Record'}
              mendix_name #{qualified.inspect}, id: #{id.inspect}
              persistence #{persistable}
          #{(declarations + association_declarations + index_declarations + system_declarations + semantic_declarations + lifecycle_declarations + validation_declarations + access_declarations).join("\n")}
            end
          end
        RUBY
      end

      def index_source(index)
        members = index.fetch('members').map do |member|
          "{ id: #{member.fetch('id').inspect}, name: #{member.fetch('name').inspect}, " \
            "ascending: #{member.fetch('ascending')}, type: :#{member.fetch('type')} }"
        end
        "    index id: #{index.fetch('id').inspect}, guid: #{index.fetch('guid').inspect}, " \
          "include_offline: #{index.fetch('include_offline')}, members: [#{members.join(', ')}]"
      end

      def oql_view_source(view)
        options = %w[source query document_id source_id].filter_map do |name|
          value = view[name]
          "#{name}: #{value.inspect}" unless value.nil?
        end
        "    oql_view #{options.join(', ')}"
      end

      def lifecycle_source(callback)
        "    #{callback.fetch('event')} microflow: #{callback.fetch('handler').inspect}, " \
          "id: #{callback.fetch('id').inspect}, " \
          "pass_event_object: #{callback.fetch('pass_event_object')}, " \
          "raise_error_on_false: #{callback.fetch('raise_error_on_false')}"
      end

      def validation_rule_source(rule)
        kind = rule.fetch('kind')
        kind = %w[required unique].include?(kind) ? ":#{kind}" : kind.inspect
        "    validation_rule #{rule.fetch('attribute').inspect}, kind: #{kind}, " \
          "id: #{rule.fetch('id').inspect}, message_id: #{rule.fetch('message_id').inspect}, " \
          "translations: #{rule.fetch('translations').inspect}, " \
          "rule_info_id: #{rule.fetch('rule_info_id').inspect}, " \
          "rule_info: #{rule.fetch('rule_info').inspect}"
      end

      def access_rule_source(rule)
        roles = rule.fetch('roles').map(&:inspect).join(', ')
        members = rule.fetch('members').map do |member|
          "{ id: #{member.fetch('id').inspect}, name: #{member.fetch('name').inspect}, " \
            "reference: #{member.fetch('reference').inspect}, rights: :#{member.fetch('rights')}, " \
            "kind: :#{member.fetch('kind')} }"
        end
        "    access_rule #{roles}, id: #{rule.fetch('id').inspect}, " \
          "documentation: #{rule.fetch('documentation').inspect}, create: #{rule.fetch('create')}, " \
          "delete: #{rule.fetch('delete')}, default_rights: :#{rule.fetch('default_rights')}, " \
          "xpath: #{rule.fetch('xpath').inspect}, " \
          "xpath_caption: #{rule.fetch('xpath_caption', nil).inspect}, " \
          "members: [#{members.join(', ')}]"
      end

      def enumeration_source(namespace, class_name, enumeration)
        declarations = enumeration.fetch('values').map do |value|
          "    value #{value.fetch('name').inspect}, id: #{value.fetch('id').inspect}, " \
            "captions: #{value.fetch('captions').inspect}"
        end
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            class #{class_name} < Mxrb::RubyApp::Enumeration
              mendix_name #{enumeration.fetch('name').inspect}, id: #{enumeration.fetch('id').inspect}
              documentation #{enumeration.fetch('documentation').inspect}
          #{declarations.join("\n")}
            end
          end
        RUBY
      end

      def constant_source(namespace, class_name, constant)
        default = if constant.fetch('default_redacted')
                    '    preserve_default!'
                  else
                    "    default #{constant.fetch('default').inspect}"
                  end
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            class #{class_name} < Mxrb::RubyApp::Constant
              mendix_name #{constant.fetch('name').inspect}, id: #{constant.fetch('id').inspect}
              documentation #{constant.fetch('documentation').inspect}
              type #{constant.fetch('type').to_sym.inspect}
              exposed_to_client #{constant.fetch('exposed_to_client')}
              excluded #{constant.fetch('excluded')}
              export_level #{constant.fetch('export_level').inspect}
          #{default}
            end
          end
        RUBY
      end

      def module_security_source(namespace, module_name, security)
        roles = security.fetch('roles').map do |role|
          "    module_role #{role.fetch('name').inspect}, id: #{role.fetch('id').inspect}, " \
            "description: #{role.fetch('description').inspect}"
        end
        roles = ['    clear_module_roles!'] if roles.empty?
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            class Security < Mxrb::RubyApp::ModuleSecurity
              mendix_name #{module_name.inspect}, id: #{security.fetch('id').inspect}
          #{roles.join("\n")}
            end
          end
        RUBY
      end

      def project_security_source(security)
        user_roles = security.fetch('user_roles').map do |role|
          "    user_role #{role.fetch('name').inspect}, id: #{role.fetch('id').inspect}, " \
            "guid: #{role.fetch('guid').inspect}, description: #{role.fetch('description').inspect}, " \
            "check_security: #{role.fetch('check_security')}, " \
            "manageable_roles: #{role.fetch('manageable_roles').inspect}, " \
            "manage_all_roles: #{role.fetch('manage_all_roles')}, " \
            "manage_users_without_roles: #{role.fetch('manage_users_without_roles')}, " \
            "module_roles: #{role.fetch('module_roles').inspect}"
        end
        user_roles = ['    clear_user_roles!'] if user_roles.empty?
        demo_users = security.fetch('demo_users').map do |user|
          "    demo_user #{user.fetch('name').inspect}, id: #{user.fetch('id').inspect}, " \
            "entity: #{user.fetch('entity').inspect}, roles: #{user.fetch('roles').inspect}, " \
            'password: nil'
        end
        demo_users = ['    clear_demo_users!'] if demo_users.empty?
        policy = security['password_policy']
        policy_source = if policy
                          "    password_policy id: #{policy.fetch('id').inspect}, " \
                            "properties: #{policy.fetch('properties').inspect}"
                        end
        sign_in_source = if security['sign_in_microflow']
                           "    sign_in_microflow #{security.fetch('sign_in_microflow').inspect}"
                         end
        <<~RUBY
          # frozen_string_literal: true

          class ApplicationSecurity < Mxrb::RubyApp::ProjectSecurity
            mendix_id #{security.fetch('id').inspect}
            security_level #{security.fetch('security_level').inspect}
            admin_user_role #{security.fetch('admin_user_role').inspect}
            demo_users enabled: #{security.fetch('demo_users_enabled')}
            guest_access enabled: #{security.fetch('guest_access_enabled')}, role: #{security.fetch('guest_user_role').inspect}
          #{sign_in_source}
          #{user_roles.join("\n")}
          #{demo_users.join("\n")}
          #{policy_source}
          end
        RUBY
      end

      def scheduled_event_source(namespace, class_name, event)
        schedule = event['schedule']
        binding = if event.fetch('unbound', false)
                    "    unbound\n"
                  else
                    "    microflow #{event.fetch('microflow').inspect}\n"
                  end
        schedule_source = if schedule
                            "    schedule #{schedule.fetch('type').inspect}, " \
                              "id: #{schedule.fetch('id').inspect},\n" \
                              "             properties: #{schedule.fetch('properties').inspect}\n"
                          else
                            ''
                          end
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            class #{class_name} < Mxrb::RubyApp::ScheduledEvent
              mendix_name #{event.fetch('name').inspect}, id: #{event.fetch('id').inspect}
              documentation #{event.fetch('documentation').inspect}
              export_level #{event.fetch('export_level').inspect}
          #{binding.rstrip}
              start_at #{event.fetch('start_at').inspect}
              time_zone #{event.fetch('time_zone').inspect}
              on_overlap #{event.fetch('on_overlap').inspect}
              enabled value: #{event.fetch('enabled')}
              interval_type #{event.fetch('interval_type').inspect}
              interval #{event.fetch('interval').inspect}
          #{schedule_source.rstrip}
            end
          end
        RUBY
      end

      def service_source(namespace, class_name, qualified, id, native_source: nil,
                         native_kind: :microflow)
        native = if native_source
                   "\n    native :#{native_kind} do\n" \
                     "#{indent(native_source, 6)}\n    end\n"
                 else
                   ''
                 end
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            class #{class_name} < Mxrb::RubyApp::Service
              mendix_name #{qualified.inspect}, id: #{id.inspect}
          #{native}

              def call(**arguments)
                native_call(arguments)
              end
            end
          end
        RUBY
      end

      def page_source(namespace, class_name, qualified, id, title, widgets,
                      appearance_class:, appearance_style:, data_source:)
        widget_source = runtime_widget_dsl_source(widgets, 6)
        <<~RUBY
          # frozen_string_literal: true

          module #{namespace}
            class #{class_name} < Mxrb::RubyApp::Page
              mendix_name #{qualified.inspect}, id: #{id.inspect}
              configure(
                title: #{title.inspect},
                appearance_class: #{appearance_class.inspect},
                appearance_style: #{appearance_style.inspect},
                data_source: #{data_source.inspect}
              ) do
          #{widget_source}
              end
            end
          end
        RUBY
      end

      def runtime_widget_dsl_source(widgets, indentation, generic_sink: false)
        Array(widgets).map do |widget|
          runtime_widget_call_source(widget, indentation, generic_sink:)
        end.join("\n")
      end

      def runtime_widget_call_source(widget, indentation, generic_sink: false)
        padding = ' ' * indentation
        type = widget.fetch('type').to_sym
        options = widget.fetch('options', {})
        if type == :data_view && runtime_data_view_supported?(options, widget)
          return runtime_data_view_source(widget, indentation)
        end
        if type == :native_widget && runtime_native_widget_supported?(options, widget)
          return runtime_native_widget_source(widget, indentation)
        end
        if type == :tab_control && runtime_tab_control_supported?(options, widget)
          return runtime_tab_control_source(widget, indentation)
        end

        if runtime_structured_widget?(type, options, widget)
          return runtime_table_source(widget, indentation) if type == :table

          return runtime_layout_grid_source(widget, indentation)
        end
        if generic_sink && runtime_data_grid_supported?(type, options, widget)
          return runtime_data_grid_source(widget, indentation)
        end

        typed = if generic_sink
                  runtime_dsl_sink_typed?(type, options, widget)
                else
                  Page::WidgetTree::WIDGET_METHODS.include?(type) &&
                    !Page::WidgetTree::STRUCTURED_METHODS.include?(type) &&
                    runtime_keywords_safe?(options)
                end
        method_name = typed ? type.to_s : 'widget'
        arguments = []
        arguments << type.inspect unless typed
        arguments << widget.fetch('name', '').inspect
        if typed
          options.each do |key, value|
            keyword = runtime_widget_keyword(type, key, generic_sink:)
            arguments << "#{keyword}: #{pretty_ruby_value(value, indentation + 2)}"
          end
        elsif widget.key?('options')
          arguments << "options: #{pretty_ruby_value(options, indentation + 2)}"
        end
        event_source = generic_sink && typed ? runtime_widget_event_source(widget, indentation + 2) : ''
        emit_events = widget.key?('events') && (!generic_sink || !typed)
        arguments << "events: #{pretty_ruby_value(widget.fetch('events'), indentation + 2)}" if emit_events
        children = Array(widget['children'])
        region_source = runtime_widget_regions_source(widget, indentation + 2, generic_sink:)
        block = !event_source.empty? || !children.empty? || !region_source.empty?
        declaration = runtime_widget_declaration(method_name, arguments, indentation, block)
        return declaration unless block

        nested = runtime_widget_dsl_source(children, indentation + 2, generic_sink:)
        body = [event_source, nested, region_source].reject(&:empty?).join("\n")
        "#{declaration}\n#{body}\n#{padding}end"
      end

      STRUCTURED_OPTION_KEYS = {
        table: %w[width_unit tab_index class style dynamic_class visible columns rows],
        layout_grid: %w[width tab_index class style dynamic_class visible rows]
      }.freeze
      DSL_SINK_OPTIONS = {
        button: %w[caption parameters class style dynamic_class visible],
        check_box: %w[attribute caption class style dynamic_class visible],
        container: %w[class style dynamic_class visible],
        date_picker: %w[attribute caption class style dynamic_class visible],
        drop_down: %w[attribute caption class style dynamic_class visible],
        number_input: %w[attribute caption class style dynamic_class visible],
        page_title: %w[class style dynamic_class visible],
        pluggable_widget: %w[
          widget_id widget_name properties class style dynamic_class visible platform
        ],
        radio_button_group: %w[attribute caption horizontal class style dynamic_class visible],
        reference_selector: %w[attribute caption display_attribute class style dynamic_class visible],
        snippet: %w[snippet],
        static_image: %w[
          image alternative_text width height width_unit height_unit responsive
          class style dynamic_class visible
        ],
        text: %w[caption parameters class style dynamic_class visible],
        text_area: %w[attribute caption lines class style dynamic_class visible],
        text_box: %w[attribute caption class style dynamic_class visible]
      }.freeze
      DSL_SINK_BLOCK_METHODS = (DSL_SINK_OPTIONS.keys - [:snippet]).freeze
      DSL_SINK_REQUIRED_OPTIONS = {
        button: %w[caption], pluggable_widget: %w[widget_id widget_name properties],
        radio_button_group: %w[horizontal],
        snippet: %w[snippet],
        static_image: %w[image alternative_text width height width_unit height_unit responsive],
        text: %w[caption], text_area: %w[lines]
      }.freeze
      WIDGET_EVENT_METHODS = %w[on_change on_click on_enter on_leave].freeze
      WIDGET_EVENT_HANDLERS = %w[microflow nanoflow page action].freeze

      def runtime_native_widget_supported?(options, widget)
        return false unless runtime_keys?(widget, %w[type name options events])
        return false unless widget['name'].is_a?(String) && widget.key?('options')
        return false unless options.keys.map(&:to_s).sort == %w[native_fragment native_type]
        return false unless options['native_type'].is_a?(String) && !options['native_type'].empty?
        return false unless Array(widget['events']).empty?

        fragment = options['native_fragment']
        runtime_keys?(fragment, %w[digest]) && fragment.keys.map(&:to_s) == %w[digest] &&
          fragment['digest'].to_s.match?(NativeFragmentStore::DIGEST_PATTERN)
      end

      def runtime_native_widget_source(widget, indentation)
        options = widget.fetch('options')
        fragment = options.fetch('native_fragment')
        arguments = [
          widget.fetch('name').inspect,
          "type: #{options.fetch('native_type').inspect}",
          "deep_structure: native_fragment(#{fragment.fetch('digest').inspect})"
        ]
        runtime_widget_declaration('native_widget', arguments, indentation, false)
      end

      def runtime_tab_control_supported?(options, widget)
        return false unless runtime_keys?(widget, %w[type name options events])
        return false unless widget['name'].is_a?(String) && widget.key?('options')
        return false unless options.keys.map(&:to_s).sort == %w[tabs]
        return false unless Array(widget['events']).empty?
        return false unless options.fetch('tabs').is_a?(Array) && options.fetch('tabs').any?

        options.fetch('tabs').all? do |tab|
          runtime_keys?(tab, %w[name caption widgets]) &&
            tab['name'].is_a?(String) && tab['caption'].is_a?(String) &&
            tab['widgets'].is_a?(Array) && runtime_widget_collection_supported?(tab['widgets'])
        end
      end

      def runtime_tab_control_source(widget, indentation)
        padding = ' ' * indentation
        lines = [runtime_widget_declaration(
          'tab_control', [widget.fetch('name', '').inspect], indentation, true
        )]
        widget.fetch('options', {}).fetch('tabs', []).each do |tab|
          arguments = [tab.fetch('name').inspect, "caption: #{tab.fetch('caption').inspect}"]
          widgets = tab.fetch('widgets')
          lines << runtime_widget_declaration('tab_page', arguments, indentation + 2, widgets.any?)
          next if widgets.empty?

          lines << runtime_widget_dsl_source(widgets, indentation + 4, generic_sink: true)
          lines << "#{' ' * (indentation + 2)}end"
        end
        lines << "#{padding}end"
        lines.join("\n")
      end

      def runtime_dsl_sink_typed?(type, options, widget)
        allowed = DSL_SINK_OPTIONS[type]
        return false unless allowed && (options.keys.map(&:to_s) - allowed).empty?
        return false unless (DSL_SINK_REQUIRED_OPTIONS.fetch(type, []) - options.keys.map(&:to_s)).empty?
        return false if !DSL_SINK_BLOCK_METHODS.include?(type) && widget_block?(widget)
        return false unless runtime_dsl_sink_regions_supported?(type, widget)

        runtime_widget_events_supported?(widget)
      end

      def runtime_dsl_sink_regions_supported?(type, widget)
        named_regions = %w[body footer regions].any? { widget.key?(_1) }
        return false if named_regions
        return true unless widget.key?('slots')

        type == :pluggable_widget && Array(widget['slots']).all? { !_1.key?('role') }
      end

      def widget_block?(widget)
        Array(widget['events']).any? || Array(widget['children']).any?
      end

      def runtime_widget_events_supported?(widget)
        Array(widget['events']).all? do |event|
          runtime_keys?(event, %w[event kind handler arguments]) &&
            WIDGET_EVENT_METHODS.include?(event['event'].to_s) &&
            WIDGET_EVENT_HANDLERS.include?(event['kind'].to_s) &&
            !event['handler'].to_s.empty? &&
            (!event.key?('arguments') || event['arguments'].is_a?(Hash))
        end
      end

      def runtime_widget_event_source(widget, indentation)
        Array(widget['events']).map do |event|
          arguments = ["#{event.fetch('kind')}: #{event.fetch('handler').inspect}"]
          pass = event.fetch('arguments', {})
          arguments << "pass: #{pretty_ruby_value(pass, indentation + 2)}" unless pass.empty?
          runtime_widget_declaration(event.fetch('event'), arguments, indentation, false)
        end.join("\n")
      end

      def runtime_widget_regions_source(widget, indentation, generic_sink:)
        sources = %w[body footer].filter_map do |name|
          next unless widget.key?(name)

          runtime_named_widget_region_source(name, widget.fetch(name), indentation, generic_sink:)
        end
        widget.fetch('regions', {}).each do |name, widgets|
          sources << runtime_named_widget_region_source(
            'region', widgets, indentation, generic_sink:, name:
          )
        end
        Array(widget['slots']).each do |slot|
          sources << runtime_widget_slot_source(slot, indentation, generic_sink:)
        end
        sources.join("\n")
      end

      def runtime_named_widget_region_source(method_name, widgets, indentation, generic_sink:, name: nil)
        arguments = name.nil? ? [] : [name.inspect]
        declaration = runtime_widget_declaration(method_name, arguments, indentation, Array(widgets).any?)
        return declaration if Array(widgets).empty?

        padding = ' ' * indentation
        nested = runtime_widget_dsl_source(widgets, indentation + 2, generic_sink:)
        "#{declaration}\n#{nested}\n#{padding}end"
      end

      def runtime_widget_slot_source(slot, indentation, generic_sink:)
        arguments = ["path: #{pretty_ruby_value(slot.fetch('path'), indentation + 2)}"]
        arguments << "role: #{slot.fetch('role').inspect}" if slot.key?('role')
        widgets = Array(slot['widgets'])
        declaration = runtime_widget_declaration('slot', arguments, indentation, widgets.any?)
        return declaration if widgets.empty?

        padding = ' ' * indentation
        nested = runtime_widget_dsl_source(widgets, indentation + 2, generic_sink:)
        "#{declaration}\n#{nested}\n#{padding}end"
      end

      def runtime_widget_keyword(type, key, generic_sink:)
        return 'from' if generic_sink && type == :snippet && key.to_s == 'snippet'
        return 'class_name' if key.to_s == 'class'

        key.to_s
      end

      def runtime_structured_widget?(type, options, widget)
        allowed = STRUCTURED_OPTION_KEYS[type]
        return false unless allowed && (options.keys.map(&:to_s) - allowed).empty?
        return false unless Array(widget['events']).empty? && Array(widget['children']).empty?

        type == :table ? runtime_table_supported?(options) : runtime_layout_grid_supported?(options)
      end

      def runtime_table_supported?(options)
        return false unless %w[weight percentage pixels].include?(options.fetch('width_unit', 'weight').to_s)

        columns = Array(options['columns'])
        rows = Array(options['rows'])
        return false if columns.empty? || columns.any? { !runtime_keys?(_1, %w[width]) || _1['width'].to_i <= 0 }
        return false unless rows.all? { runtime_table_row_supported?(_1) }

        runtime_table_geometry_supported?(columns.size, rows)
      end

      def runtime_table_row_supported?(row)
        return false unless runtime_keys?(row, %w[options cells])
        return false unless runtime_keys?(row.fetch('options', {}), %w[class style dynamic_class visible])

        Array(row['cells']).all? do |cell|
          runtime_keys?(cell, %w[column colspan rowspan header options widgets]) &&
            runtime_keys?(cell.fetch('options', {}), %w[class style dynamic_class]) &&
            cell.fetch('colspan', 1).to_i.positive? && cell.fetch('rowspan', 1).to_i.positive? &&
            (!cell.key?('column') || cell['column'].to_i >= 0) &&
            Array(cell['widgets']).all? { runtime_nested_widget_supported?(_1) }
        end
      end

      def runtime_table_geometry_supported?(column_count, rows)
        occupied = {}
        rows.each_with_index do |row, row_index|
          cursor = 0
          Array(row['cells']).each do |cell|
            cursor += 1 while occupied[[row_index, cursor]]
            column = cell.fetch('column', cursor).to_i
            right = column + cell.fetch('colspan', 1).to_i
            bottom = row_index + cell.fetch('rowspan', 1).to_i
            return false if right > column_count || bottom > rows.size

            coordinates = (row_index...bottom).to_a.product((column...right).to_a)
            return false if coordinates.any? { occupied[_1] }

            coordinates.each { occupied[_1] = true }
            cursor = right
          end
        end
        true
      end

      def runtime_layout_grid_supported?(options)
        return false unless %w[full fixed].include?(options.fetch('width', 'full').to_s)

        Array(options['rows']).all? do |row|
          runtime_keys?(row, %w[options columns]) && runtime_layout_grid_row_supported?(row)
        end
      end

      def runtime_layout_grid_row_supported?(row)
        options = row.fetch('options', {})
        return false unless runtime_keys?(
          options,
          %w[horizontal_alignment vertical_alignment gutters class style dynamic_class visible]
        )
        return false unless %w[horizontal_alignment vertical_alignment].all? do |name|
          runtime_alignment?(options.fetch(name, 'none'))
        end

        Array(row['columns']).all? do |column|
          runtime_keys?(column, %w[options widgets]) &&
            runtime_layout_grid_column_supported?(column)
        end
      end

      def runtime_layout_grid_column_supported?(column)
        options = column.fetch('options', {})
        return false unless runtime_keys?(
          options, %w[desktop tablet phone vertical_alignment class style dynamic_class]
        )
        return false unless runtime_alignment?(options.fetch('vertical_alignment', 'none'))
        return false unless %w[desktop tablet phone].all? { runtime_grid_weight?(options.fetch(_1, 'grow')) }

        Array(column['widgets']).all? { runtime_nested_widget_supported?(_1) }
      end

      def runtime_nested_widget_supported?(widget)
        return false unless runtime_keys?(
          widget, %w[type name caption options events children body footer regions slots]
        )
        return false unless widget.key?('type') && widget.key?('name')
        return false if widget.key?('caption')
        return false unless widget.key?('options') && widget['options'].is_a?(Hash)
        return false if widget.key?('events') && !widget['events'].is_a?(Array)
        return false unless %w[children body footer].all? do |name|
          !widget.key?(name) || runtime_widget_collection_supported?(widget[name])
        end
        return false unless widget.fetch('regions', {}).is_a?(Hash)
        return false unless widget.fetch('regions', {}).values.all? do |widgets|
          runtime_widget_collection_supported?(widgets)
        end

        Array(widget['slots']).all? do |slot|
          runtime_keys?(slot, %w[path role widgets]) && slot.key?('path') && slot.key?('widgets') &&
            slot['path'].is_a?(Array) && slot['path'].all? { _1.is_a?(String) || _1.is_a?(Integer) } &&
            (!slot.key?('role') || slot['role'].is_a?(String)) &&
            runtime_widget_collection_supported?(slot.fetch('widgets'))
        end
      end

      def runtime_widget_collection_supported?(widgets)
        widgets.is_a?(Array) && widgets.all? { runtime_nested_widget_supported?(_1) }
      end

      DATA_VIEW_OPTION_KEYS = %w[
        source editable read_only_style label_width show_footer no_entity_message tab_index
        class style dynamic_class visibility editability design_properties unknown_native
      ].freeze
      DATA_VIEW_DECLARATION_KEYS = %w[
        editable read_only_style label_width show_footer no_entity_message tab_index
        class style dynamic_class
      ].freeze
      DATA_VIEW_SOURCE_KEYS = {
        'context' => %w[kind entity variable force_full_objects unknown_native entity_ref_native],
        'association' => %w[
          kind entity steps variable force_full_objects unknown_native entity_ref_native
        ],
        'microflow' => %w[kind name mappings force_full_objects unknown_native settings_native],
        'nanoflow' => %w[kind name mappings force_full_objects unknown_native],
        'listen' => %w[kind target force_full_objects unknown_native],
        'native' => %w[kind native_type force_full_objects unknown_native]
      }.freeze
      DATA_VIEW_CONDITION_KEYS = %w[
        expression roles attribute conditions ignore_security source_variable unknown_native
      ].freeze
      PAGE_VARIABLE_KEYS = %w[kind name sub_key use_all_pages unknown_native].freeze

      def runtime_data_view_supported?(options, widget)
        return false unless runtime_keys?(
          widget, %w[type name options events body footer]
        )
        return false unless runtime_keys?(options, DATA_VIEW_OPTION_KEYS)
        return false unless runtime_data_view_options_supported?(options)
        return false unless Array(widget['events']).empty?
        return false unless widget.key?('body') && runtime_data_view_region_supported?(widget['body'])
        return false if widget.key?('footer') && !runtime_data_view_region_supported?(widget['footer'])

        true
      end

      def runtime_data_view_region_supported?(widgets)
        widgets.is_a?(Array) && widgets.all? do |widget|
          widget.is_a?(Hash) && widget.key?('type')
        end
      end

      def runtime_data_view_options_supported?(options)
        source = options['source']
        return false unless runtime_data_view_source_supported?(source)
        return false unless %w[always never conditional conditionally].include?(options['editable'].to_s)
        return false unless %w[control text inherit].include?(options['read_only_style'].to_s)
        return false unless non_negative_integer?(options['label_width'])
        return false unless non_negative_integer?(options['tab_index'])
        return false unless [true, false].include?(options['show_footer'])
        return false unless options['no_entity_message'].is_a?(String)
        return false unless %w[class style dynamic_class].all? do |name|
          !options.key?(name) || options[name].is_a?(String)
        end
        return false if options.key?('visibility') &&
                        !runtime_data_view_condition_supported?(options['visibility'])
        return false if options.key?('editability') &&
                        !runtime_data_view_condition_supported?(options['editability'])
        return false if options.key?('design_properties') && !options['design_properties'].is_a?(Array)
        return false if options.key?('unknown_native') && !options['unknown_native'].is_a?(Hash)

        true
      end

      def runtime_data_view_source_supported?(source)
        return false unless source.is_a?(Hash)

        kind = source['kind'].to_s
        allowed = DATA_VIEW_SOURCE_KEYS[kind]
        return false unless allowed && runtime_keys?(source, allowed)
        return false unless runtime_page_variable_supported?(source['variable'])
        return false if %w[context association].include?(kind) && source['entity'].to_s.empty?
        return false if %w[microflow nanoflow].include?(kind) && source['name'].to_s.empty?
        return false if kind == 'listen' && source['target'].to_s.empty?
        return false unless runtime_data_view_steps_supported?(source['steps'])
        return false unless runtime_data_view_mappings_supported?(source['mappings'])

        true
      end

      def runtime_page_variable_supported?(variable)
        return true if variable.nil?
        return false unless runtime_keys?(variable, PAGE_VARIABLE_KEYS)

        kind = variable.fetch('kind', 'page_parameter').to_s
        return false unless %w[page_parameter snippet_parameter local_variable widget current].include?(kind)

        kind == 'current' || !variable['name'].to_s.empty?
      end

      def runtime_data_view_steps_supported?(steps)
        return true if steps.nil?

        steps.is_a?(Array) && steps.all? do |step|
          runtime_keys?(step, %w[association entity unknown_native]) &&
            !step['association'].to_s.empty? && !step['entity'].to_s.empty?
        end
      end

      def runtime_data_view_mappings_supported?(mappings)
        return true if mappings.nil?

        mappings.is_a?(Array) && mappings.all? do |mapping|
          runtime_keys?(mapping, %w[parameter expression variable unknown_native]) &&
            !mapping['parameter'].to_s.empty? &&
            runtime_page_variable_supported?(mapping['variable'])
        end
      end

      def runtime_data_view_condition_supported?(condition)
        runtime_keys?(condition, DATA_VIEW_CONDITION_KEYS) &&
          runtime_page_variable_supported?(condition['source_variable']) &&
          (!condition.key?('expression') || condition['expression'].is_a?(String)) &&
          (!condition.key?('attribute') || condition['attribute'].is_a?(String)) &&
          (!condition.key?('roles') ||
            Array(condition['roles']).all? { _1.is_a?(String) }) &&
          (!condition.key?('conditions') || condition['conditions'].is_a?(Array)) &&
          (!condition.key?('ignore_security') ||
            [true, false].include?(condition['ignore_security'])) &&
          (!condition.key?('unknown_native') || condition['unknown_native'].is_a?(Hash))
      end

      def runtime_data_view_source(widget, indentation)
        padding = ' ' * indentation
        options = widget.fetch('options')
        arguments = [widget.fetch('name', '').inspect]
        arguments << "from: #{pretty_ruby_value(options.fetch('source'), indentation + 2)}"
        DATA_VIEW_DECLARATION_KEYS.each do |name|
          next unless options.key?(name)

          keyword = name == 'class' ? 'class_name' : name
          arguments << "#{keyword}: #{pretty_ruby_value(options.fetch(name), indentation + 2)}"
        end
        body = runtime_data_view_body_source(widget, options, indentation + 2)
        declaration = runtime_widget_declaration('data_view', arguments, indentation, !body.empty?)
        return declaration if body.empty?

        "#{declaration}\n#{body.join("\n")}\n#{padding}end"
      end

      def runtime_data_view_body_source(widget, options, indentation)
        lines = %w[body footer].filter_map do |name|
          next unless widget.key?(name)

          runtime_named_widget_region_source(
            name, widget.fetch(name), indentation, generic_sink: true
          )
        end
        %w[visibility editability].each do |name|
          next unless options.key?(name)

          method_name = name == 'visibility' ? 'visible_when' : 'editable_when'
          lines << runtime_data_view_condition_source(
            method_name, options.fetch(name), indentation
          )
        end
        if options.key?('design_properties')
          arguments = options.fetch('design_properties').map do |value|
            pretty_ruby_value(value, indentation + 2)
          end
          lines << runtime_widget_declaration('design_properties', arguments, indentation, false)
        end
        if options.key?('unknown_native')
          lines << runtime_widget_declaration(
            'unknown_native', [pretty_ruby_value(options.fetch('unknown_native'), indentation + 2)],
            indentation, false
          )
        end
        lines
      end

      def runtime_data_view_condition_source(method_name, condition, indentation)
        arguments = []
        arguments << pretty_ruby_value(condition.fetch('expression'), indentation + 2) if
          condition.key?('expression')
        {
          'roles' => 'roles', 'attribute' => 'attribute', 'conditions' => 'conditions',
          'ignore_security' => 'ignore_security', 'source_variable' => 'source',
          'unknown_native' => 'native'
        }.each do |name, keyword|
          arguments << "#{keyword}: #{pretty_ruby_value(condition.fetch(name), indentation + 2)}" if
            condition.key?(name)
        end
        runtime_widget_declaration(method_name, arguments, indentation, false)
      end

      def non_negative_integer?(value)
        Integer(value) >= 0
      rescue ArgumentError, TypeError
        false
      end

      def runtime_data_grid_supported?(type, options, widget)
        return false unless type == :data_grid
        return false unless runtime_keys?(options, %w[entity selection columns])
        return false unless Array(widget['children']).empty?
        return false unless runtime_dsl_sink_regions_supported?(type, widget)
        return false unless runtime_widget_events_supported?(widget)

        Array(options['columns']).all? do |column|
          runtime_keys?(column, %w[name attribute caption filter]) && column.key?('name')
        end
      end

      def runtime_data_grid_source(widget, indentation)
        padding = ' ' * indentation
        options = widget.fetch('options')
        arguments = [widget.fetch('name', '').inspect]
        %w[entity selection].each do |name|
          arguments << "#{name}: #{pretty_ruby_value(options.fetch(name), indentation + 2)}" if options.key?(name)
        end
        lines = [runtime_widget_declaration('data_grid', arguments, indentation, true)]
        Array(options['columns']).each do |column|
          column_arguments = [column.fetch('name').inspect]
          %w[attribute caption filter].each do |name|
            column_arguments << "#{name}: #{pretty_ruby_value(column.fetch(name), indentation + 4)}" if
              column.key?(name)
          end
          lines << runtime_widget_declaration('column', column_arguments, indentation + 2, false)
        end
        events = runtime_widget_event_source(widget, indentation + 2)
        lines << events unless events.empty?
        lines << "#{padding}end"
        lines.join("\n")
      end

      def runtime_keys?(value, allowed)
        value.is_a?(Hash) && (value.keys.map(&:to_s) - allowed).empty?
      end

      def runtime_alignment?(value)
        %w[none start center end].include?(value.to_s)
      end

      def runtime_grid_weight?(value)
        %w[grow auto].include?(value.to_s) || (1..12).cover?(Integer(value))
      rescue ArgumentError, TypeError
        false
      end

      def runtime_table_source(widget, indentation)
        padding = ' ' * indentation
        options = widget.fetch('options')
        arguments = [widget.fetch('name', '').inspect]
        arguments << "width_unit: #{options.fetch('width_unit').to_sym.inspect}" if
          options.fetch('width_unit', 'weight').to_s != 'weight'
        arguments << "tab_index: #{options.fetch('tab_index').to_i}" if options.fetch('tab_index', 0).to_i != 0
        append_runtime_appearance(arguments, options)
        lines = [runtime_widget_declaration('table', arguments, indentation, true)]
        Array(options['columns']).each do |column|
          lines << "#{padding}  column width: #{column.fetch('width').to_i}"
        end
        Array(options['rows']).each do |row|
          lines.concat(runtime_table_row_source(row, indentation + 2))
        end
        lines << "#{padding}end"
        lines.join("\n")
      end

      def runtime_table_row_source(row, indentation)
        padding = ' ' * indentation
        arguments = []
        append_runtime_appearance(arguments, row.fetch('options', {}))
        declaration = runtime_widget_declaration('row', arguments, indentation, true)
        lines = [declaration]
        cursor = 0
        Array(row['cells']).each do |cell|
          lines.concat(runtime_table_cell_source(cell, indentation + 2, cursor))
          cursor = cell.fetch('column', cursor).to_i + [cell.fetch('colspan', 1).to_i, 1].max
        end
        lines << "#{padding}end"
      end

      def runtime_table_cell_source(cell, indentation, cursor)
        padding = ' ' * indentation
        arguments = []
        column = cell.fetch('column', cursor).to_i
        arguments << "column: #{column}" unless column == cursor
        arguments << "colspan: #{cell.fetch('colspan').to_i}" if cell.fetch('colspan', 1).to_i > 1
        arguments << "rowspan: #{cell.fetch('rowspan').to_i}" if cell.fetch('rowspan', 1).to_i > 1
        arguments << 'header: true' if cell['header'] == true
        append_runtime_appearance(arguments, cell.fetch('options', {}))
        widgets = Array(cell['widgets'])
        declaration = runtime_widget_declaration('cell', arguments, indentation, !widgets.empty?)
        return [declaration] if widgets.empty?

        [declaration, runtime_widget_dsl_source(widgets, indentation + 2, generic_sink: true),
         "#{padding}end"]
      end

      def runtime_layout_grid_source(widget, indentation)
        padding = ' ' * indentation
        options = widget.fetch('options')
        arguments = [widget.fetch('name', '').inspect]
        arguments << "width: #{options.fetch('width').to_sym.inspect}" if
          options.fetch('width', 'full').to_s != 'full'
        arguments << "tab_index: #{options.fetch('tab_index').to_i}" if options.fetch('tab_index', 0).to_i != 0
        append_runtime_appearance(arguments, options)
        lines = [runtime_widget_declaration('layout_grid', arguments, indentation, true)]
        Array(options['rows']).each do |row|
          lines.concat(runtime_layout_grid_row_source(row, indentation + 2))
        end
        lines << "#{padding}end"
        lines.join("\n")
      end

      def runtime_layout_grid_row_source(row, indentation)
        padding = ' ' * indentation
        options = row.fetch('options', {})
        arguments = []
        %w[horizontal_alignment vertical_alignment].each do |name|
          value = options.fetch(name, 'none')
          arguments << "#{name}: #{value.to_sym.inspect}" unless value.to_s == 'none'
        end
        arguments << 'gutters: false' if options['gutters'] == false
        append_runtime_appearance(arguments, options)
        columns = Array(row['columns'])
        declaration = runtime_widget_declaration('row', arguments, indentation, !columns.empty?)
        return [declaration] if columns.empty?

        lines = [declaration]
        columns.each { lines.concat(runtime_layout_grid_column_source(_1, indentation + 2)) }
        lines << "#{padding}end"
      end

      def runtime_layout_grid_column_source(column, indentation)
        padding = ' ' * indentation
        options = column.fetch('options', {})
        arguments = %w[desktop tablet phone].filter_map do |viewport|
          value = options.fetch(viewport, 'grow')
          next if value.to_s == 'grow'

          "#{viewport}: #{value.to_s == 'auto' ? value.to_sym.inspect : value.to_i}"
        end
        alignment = options.fetch('vertical_alignment', 'none')
        arguments << "vertical_alignment: #{alignment.to_sym.inspect}" unless alignment.to_s == 'none'
        append_runtime_appearance(arguments, options)
        widgets = Array(column['widgets'])
        declaration = runtime_widget_declaration('column', arguments, indentation, !widgets.empty?)
        return [declaration] if widgets.empty?

        [declaration, runtime_widget_dsl_source(widgets, indentation + 2, generic_sink: true),
         "#{padding}end"]
      end

      def append_runtime_appearance(arguments, options)
        %w[style dynamic_class visible].each do |name|
          arguments << "#{name}: #{options.fetch(name).inspect}" unless options[name].to_s.empty?
        end
        arguments << "class_name: #{options.fetch('class').inspect}" unless options['class'].to_s.empty?
      end

      def runtime_keywords_safe?(options)
        reserved = %w[events options class_name]
        options.keys.all? do |key|
          raw = key.to_s
          keyword = raw == 'class' ? 'class_name' : raw
          keyword.match?(/\A[a-z_]\w*\z/) && !reserved.include?(raw)
        end
      end

      def runtime_widget_declaration(method_name, arguments, indentation, block)
        padding = ' ' * indentation
        invocation = [method_name, arguments.join(', ')].reject(&:empty?).join(' ')
        single_line = "#{padding}#{invocation}"
        return "#{single_line}#{' do' if block}" if
          arguments.none? { _1.include?("\n") } && single_line.length <= 100

        invocation = arguments.each_with_index.map do |argument, index|
          suffix = index == arguments.length - 1 ? '' : ','
          "#{padding}  #{argument}#{suffix}"
        end.join("\n")
        "#{padding}#{method_name}(\n#{invocation}\n#{padding})#{' do' if block}"
      end

      def pretty_ruby_value(value, continuation_indent)
        source = PP.pp(value, +'', 100).chomp
        source.gsub("\n", "\n#{' ' * continuation_indent}")
      end

      def write_support_files
        write('Gemfile', gemfile)
        write('.ruby-version', "4.0\n")
        write('.gitignore', ruby_gitignore)
        write('.env.example', ruby_env_example)
        %w[development qa staging production].each do |name|
          write(File.join('config', 'environments', "#{name}.env.example"), environment_example(name))
        end
        write('project.rb', project_source)
        write(File.join('config', 'application.rb'), application_source)
        write(File.join('config', 'adapters.rb'), adapters_source)
        write(File.join('bin', 'server'), server_source)
        File.chmod(0o755, File.join(@output_dir, 'bin', 'server'))
        write(File.join('frontend', 'package.json'), frontend_package)
        write(File.join('frontend', 'vite.config.ts'), vite_config)
        write(File.join('frontend', 'tsconfig.json'), frontend_tsconfig)
        write(File.join('frontend', 'eslint.config.js'), frontend_eslint_config)
        write(File.join('frontend', '.prettierrc.json'), frontend_prettier_config)
        write(File.join('frontend', '.prettierignore'), frontend_prettier_ignore)
        write(File.join('frontend', 'index.html'), frontend_index)
        write(File.join('frontend', 'src', 'vite-env.d.ts'), "/// <reference types=\"vite/client\" />\n")
        copy_frontend_template
        write(File.join('frontend', 'package-lock.json'), frontend_package_lock)
        write_generated_frontend_contract
        write('README.md', readme)
      end

      def copy_frontend_template
        source = File.join(__dir__, 'frontend_template')
        Find.find(source) do |path|
          next if path == source || File.directory?(path)

          write(File.join('frontend', Pathname.new(path).relative_path_from(Pathname.new(source)).to_s),
                File.binread(path))
        end
      end

      def write_generated_frontend_contract
        write(File.join('frontend', 'src', 'generated', 'types.ts'), frontend_types)
        write(File.join('frontend', 'src', 'generated', 'pages.ts'), generated_frontend_pages)
        write(File.join('frontend', 'src', 'generated', 'nanoflows.ts'), generated_frontend_nanoflows)
        write(File.join('frontend', 'src', 'generated', 'bridge', 'api.ts'),
              frontend_api_client)
        write(File.join('frontend', 'src', 'generated', 'bridge', 'nanoflow.ts'),
              frontend_nanoflow_runtime)
        write(File.join('frontend', 'src', 'generated', 'bridge', 'marketplace.tsx'),
              frontend_marketplace_runtime)
        write(File.join('frontend', 'src', 'generated', 'README.md'), <<~MARKDOWN)
          # Generated bridge

          This directory is owned by MXRB and is the only frontend area regenerated from the
          portable model. Build application code in `features`, `components`, `hooks`, `layouts`,
          `core`, and `styles`; those directories survive every Ruby/TypeScript/MPR round-trip.
        MARKDOWN
      end

      def generated_frontend_pages
        frontend_pages.gsub("from './generated/pages/", "from './pages/")
      end

      def generated_frontend_nanoflows
        frontend_nanoflows.gsub("from './generated/nanoflows/", "from './nanoflows/")
      end

      def copy_frontend_theme
        root = File.join(@output_dir, 'frontend', 'src', 'generated', 'platform')
        FileUtils.mkdir_p(root)
        %w[theme themesource].each do |directory|
          source = File.join(@mendix_sidecar, directory)
          next unless File.directory?(source)

          copy_frontend_web_assets(source, File.join(root, directory))
        end
        fallback = File.join(root, 'theme', 'web', 'main.scss')
        write(relative(fallback), '') unless File.file?(fallback)
      end

      def copy_frontend_web_assets(source, destination)
        FileUtils.rm_rf(destination)
        Find.find(source) do |path|
          relative_path = path.delete_prefix("#{source}/")
          Find.prune if File.directory?(path) && relative_path.split(File::SEPARATOR).include?('native')
          next if path == source
          next if File.file?(path) && %w[.js .jsx].include?(File.extname(path).downcase)

          target = File.join(destination, relative_path)
          if File.directory?(path)
            FileUtils.mkdir_p(target)
          else
            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.cp(path, target)
          end
        end
      end

      def write_manifest(project, modules, runtime_mpr)
        native_coverage(project)
        payload = {
          'format_version' => 1, 'mode' => 'ruby',
          'project' => { 'name' => project.name, 'mendix_version' => project.mendix_version },
          'security' => @security_manifest,
          'navigation' => runtime_value(project.navigation.to_h),
          'source' => {
            'name' => File.basename(@mpr_path),
            'sha256' => Digest::SHA256.file(@mpr_path).hexdigest
          },
          'modules' => modules, 'coverage' => @coverage,
          'frontend' => {
            'framework' => 'react', 'language' => 'typescript', 'bundler' => 'vite',
            'source' => 'frontend/src', 'generated' => 'frontend/src/generated',
            'application_owned' => %w[
              frontend/src/app frontend/src/components frontend/src/core frontend/src/features
              frontend/src/hooks frontend/src/layouts frontend/src/styles
            ],
            'types' => 'frontend/src/generated/types.ts',
            'typecheck' => 'npm run typecheck', 'lint' => 'npm run lint',
            'test' => 'npm run test', 'format_check' => 'npm run format:check',
            'build' => 'frontend/dist'
          },
          'round_trip' => {
            'compiler' => 'project.rb',
            'mendix_project' => relative(File.join(@mendix_sidecar, 'project.rb')),
            'runtime_mpr' => relative(runtime_mpr),
            'editable_mendix_source' => relative(@mendix_sidecar)
          }
        }
        preset = Preset.detect(@output_dir)
        payload['ruby_stack'] = Preset.manifest(preset) if preset
        write(MANIFEST_PATH, JSON.pretty_generate(payload) << "\n")
      end

      def native_coverage(project)
        known_ids = @coverage.to_h { [_1.fetch('id').to_s, true] }
        project.all_units.each do |unit|
          next if known_ids[unit.fetch('UnitID').to_s]

          document = project.parse_bson(unit)
          name = document['Name'] || document['name'] || document['$Type']
          projected = Mxrb::Exporter.ruby_projected_document_type?(document['$Type'])
          add_coverage(
            unit['UnitID'], name.to_s, document['$Type'].to_s,
            relative(@mendix_sidecar),
            projected ? 'mendix_dsl_bidirectional' : 'preserved_native'
          )
        end
      end

      def add_coverage(id, name, kind, path, status)
        @coverage << {
          'id' => id.to_s, 'name' => name.to_s, 'kind' => kind.to_s,
          'ruby_path' => path, 'status' => status
        }
      end

      def ruby_constant(value, suffix: nil)
        parts = value.to_s.gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
                     .split(/[^A-Za-z0-9]+/).reject(&:empty?)
        constant = parts.map { _1[0].upcase + _1[1..].to_s.downcase }.join
        constant = "Artifact#{constant}" if constant.empty? || constant.match?(/\A\d/)
        constant = "#{constant}#{suffix}" if suffix && !constant.end_with?(suffix)
        constant
      end

      def duplicate_flow_ids(flows)
        duplicate_groups = Array(flows).group_by { _1.name.to_s }
                                       .select { |_name, group| group.size > 1 }
        duplicate_groups.each do |name, group|
          ids = group.map { _1.id.to_s }
          if ids.any?(&:empty?) || ids.uniq.size != ids.size
            raise SerializationError,
                  "duplicate flow #{name} requires distinct explicit unit ids"
          end
        end
        duplicate_groups.values.flatten.map { _1.id.to_s }.uniq.freeze
      end

      def flow_file_stem(flow, duplicate_name:)
        base = underscore(flow.name)
        return base unless duplicate_name

        "#{base}_#{flow_identity_suffix(flow)}"
      end

      def flow_ruby_constant(flow, duplicate_name:)
        return ruby_constant(flow.name) unless duplicate_name

        ruby_constant("#{flow.name}_#{flow_identity_suffix(flow)}")
      end

      def flow_identity_suffix(flow)
        identifier = underscore(flow.id)
        raise SerializationError, "duplicate flow #{flow.name} has no unit id" if identifier.empty?

        identifier
      end

      def ruby_method_name(value)
        name = underscore(value)
        name = "field_#{name}" if name.match?(/\A\d/) || RUBY_KEYWORDS.include?(name) || RECORD_RESERVED.include?(name)
        name.empty? ? 'field' : name
      end

      def underscore(value)
        value.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
             .gsub(/([a-z\d])([A-Z])/, '\\1_\\2')
             .gsub(/[^A-Za-z0-9]+/, '_').gsub(/\A_+|_+\z/, '').downcase
      end

      def relative(path)
        Pathname.new(path).relative_path_from(Pathname.new(@output_dir)).to_s
      end

      def write(relative_path, contents)
        path = File.join(@output_dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
      end

      def gemfile
        <<~RUBY
          # frozen_string_literal: true

          source 'https://rubygems.org'
          gem 'mxrb'

          group :development do
            gem 'ruby-lsp', require: false
          end
        RUBY
      end

      def ruby_gitignore
        <<~TEXT
          .env
          .env.*
          !.env.example
          config/environments/*.env
          !config/environments/*.env.example
          .mxrb/runtime/*.sqlite3
          frontend/node_modules/
          frontend/dist/
        TEXT
      end

      def ruby_env_example
        <<~TEXT
          # Base values; environment profiles override this file.
          MXRB_ENV=development
        TEXT
      end

      def environment_example(name)
        <<~TEXT
          # Copy to #{name}.env. Process ENV has highest precedence.
          MXRB_DATABASE_PATH=.mxrb/runtime/#{name}.sqlite3
          MXRB_SHARED_STORE_PATH=.mxrb/runtime/#{name}-shared.sqlite3
          MXRB_SESSION_TTL=3600
          MXRB_SCHEDULER_LEASE_TTL=300
          MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS=false
          MXRB_AUTH_TOKENS=
          MXRB_USERS_JSON=
        TEXT
      end

      def project_source
        <<~RUBY
          # frozen_string_literal: true

          require 'mxrb' unless defined?(Mxrb::RubyApp)

          mendix_version = #{@project.mendix_version.inspect}
          Mxrb::RubyApp.compile(__dir__, mendix_version:)
        RUBY
      end

      def application_source
        <<~RUBY
          # frozen_string_literal: true

          require 'mxrb'

          MXRB_APPLICATION_ROOT = File.expand_path('..', __dir__)
        RUBY
      end

      def adapters_source
        <<~RUBY
          # frozen_string_literal: true

          # Register only the integrations this application uses. Credentials
          # belong in ignored environment files or a deployment secret manager.
          #
          # Mxrb::RubyApp::Registry.register_adapter(:app_service) do |name, document, variables|
          #   MyAppServiceClient.call(name, document:, variables:)
          # end
          #
          # Legacy Custom Actions use Ruby implementations only. Register every
          # permitted action explicitly by its qualified Mendix name.
          #
          # Mxrb::RubyApp::Registry.register_java_custom_action('MyModule.MyAction') do |arguments|
          #   MyRubyAction.call(arguments)
          # end
          #
          # Supported kinds: :app_service, :web_service, :import_xml,
          # :import_mapping, :export_mapping, and :document.
        RUBY
      end

      def server_source
        <<~RUBY
          #!/usr/bin/env ruby
          # frozen_string_literal: true

          require_relative '../config/application'

          host = ENV.fetch('HOST', '127.0.0.1')
          port = Integer(ENV.fetch('PORT', '9292'))
          frontend_port = Integer(ENV.fetch('FRONTEND_PORT', '5173'))
          supervisor = Mxrb::RubyApp::Supervisor.new(
            MXRB_APPLICATION_ROOT, host:, api_port: port, frontend_port:
          )
          puts "[mxrb] Ruby API: http://\#{host}:\#{port}"
          puts "[mxrb] React + Vite: http://\#{host}:\#{frontend_port}"
          trap('INT') { Thread.new { supervisor.shutdown } }
          supervisor.start
        RUBY
      end

      def frontend_package
        JSON.pretty_generate(
          'name' => underscore(@project.name), 'private' => true, 'version' => '0.0.0',
          'type' => 'module',
          'scripts' => {
            'dev' => 'vite', 'typecheck' => 'tsc --noEmit',
            'lint' => 'eslint . --max-warnings=0',
            'format' => 'prettier --write .', 'format:check' => 'prettier --check .',
            'test' => 'vitest run', 'test:watch' => 'vitest',
            'build' => 'npm run typecheck && vite build', 'preview' => 'vite preview',
            'check' => 'npm run format:check && npm run lint && npm run test && npm run build'
          },
          'dependencies' => {
            'react' => '^19.2.8', 'react-dom' => '^19.2.8',
            'react-router-dom' => '^7.18.2'
          },
          'devDependencies' => {
            '@eslint/js' => '^10.0.1',
            '@testing-library/jest-dom' => '^7.0.1',
            '@testing-library/react' => '^16.3.2',
            '@testing-library/user-event' => '^14.6.4',
            '@types/node' => '^26.2.0', '@types/react' => '^19.2.18',
            '@types/react-dom' => '^19.2.4', '@vitejs/plugin-react' => '^6.0.5',
            'eslint' => '^10.8.1', 'eslint-plugin-react-hooks' => '^7.1.1',
            'globals' => '^17.11.0',
            'jsdom' => '^30.0.1', 'prettier' => '^3.9.6',
            'sass-embedded' => '^1.90.0', 'typescript' => '^6.0.3',
            'typescript-eslint' => '^8.67.0', 'vite' => '^8.2.1', 'vitest' => '^4.1.10'
          }
        ) << "\n"
      end

      def frontend_package_lock
        template = File.join(__dir__, 'frontend_template', 'package-lock.json')
        payload = JSON.parse(File.read(template))
        name = underscore(@project.name)
        payload['name'] = name
        payload.dig('packages', '')['name'] = name
        JSON.pretty_generate(payload) << "\n"
      end

      def frontend_tsconfig
        <<~JSON
          {
            "compilerOptions": {
              "target": "ES2022",
              "useDefineForClassFields": true,
              "lib": ["ES2022", "DOM", "DOM.Iterable"],
              "allowJs": false,
              "skipLibCheck": true,
              "esModuleInterop": true,
              "allowSyntheticDefaultImports": true,
              "strict": true,
              "noImplicitAny": true,
              "useUnknownInCatchVariables": true,
              "forceConsistentCasingInFileNames": true,
              "module": "ESNext",
              "moduleResolution": "Bundler",
              "resolveJsonModule": true,
              "isolatedModules": true,
              "noEmit": true,
              "jsx": "react-jsx",
              "types": ["vite/client", "vitest/globals"]
            },
            "include": ["src", "vite.config.ts", "vitest.config.ts"]
          }
        JSON
      end

      def frontend_eslint_config
        <<~'JS'
          import eslint from '@eslint/js';
          import reactHooks from 'eslint-plugin-react-hooks';
          import globals from 'globals';
          import tseslint from 'typescript-eslint';

          export default tseslint.config(
            { ignores: ['dist', 'node_modules', 'src/generated'] },
            eslint.configs.recommended,
            ...tseslint.configs.recommended,
            {
              files: ['**/*.{ts,tsx}'],
              languageOptions: { globals: { ...globals.browser, ...globals.node } },
              plugins: { 'react-hooks': reactHooks },
              rules: {
                'react-hooks/rules-of-hooks': 'error',
              },
            },
          );
        JS
      end

      def frontend_prettier_config
        JSON.pretty_generate(
          'singleQuote' => true, 'trailingComma' => 'all', 'printWidth' => 100,
          'semi' => true
        ) << "\n"
      end

      def frontend_prettier_ignore
        <<~TEXT
          dist
          node_modules
          src/generated
        TEXT
      end

      def vite_config
        <<~JS
          import { defineConfig } from 'vite';
          import react from '@vitejs/plugin-react';

          const apiPort = process.env.MXRB_API_PORT || '9292';

          export default defineConfig({
            plugins: [react()],
            css: {
              preprocessorOptions: {
                scss: {
                  // Mendix Atlas still depends on the legacy global Sass module model.
                  silenceDeprecations: ['import', 'global-builtin'],
                },
              },
            },
            server: { proxy: { '/api': `http://127.0.0.1:${apiPort}` } },
          });
        JS
      end

      def frontend_index
        <<~HTML
          <!doctype html>
          <html lang="en">
            <head>
              <meta charset="utf-8" />
              <meta name="viewport" content="width=device-width,initial-scale=1" />
              <title>#{escape_html(@project.name)} · MXRB Ruby</title>
            </head>
            <body>
              <div id="root"></div>
              <script type="module" src="/src/main.tsx"></script>
            </body>
          </html>
        HTML
      end

      def frontend_nanoflows
        imports = @nanoflow_entries.map do |entry|
          relative = entry.fetch('path').delete_prefix('frontend/src/')
          "import #{entry.fetch('import_name')} from './#{relative.delete_suffix('.ts')}';"
        end
        mappings = @nanoflow_entries.map do |entry|
          "  #{entry.fetch('name').inspect}: #{entry.fetch('import_name')}"
        end
        <<~TS
          import type { RegisteredNanoflow } from './types';

          #{imports.join("\n")}

          const nanoflows: Record<string, RegisteredNanoflow> = {
          #{mappings.join(",\n")}
          };

          export default nanoflows;
        TS
      end

      def frontend_pages
        imports = @page_entries.map do |entry|
          relative = entry.fetch('path').delete_prefix('frontend/src/')
          "import #{entry.fetch('import_name')} from './#{relative.delete_suffix('.tsx')}';"
        end
        mappings = @page_entries.map do |entry|
          "  #{JSON.generate(entry.fetch('name'))}: #{entry.fetch('import_name')}"
        end
        <<~TS
          import type { ComponentType } from 'react';
          import type { PageComponentProps } from './types';

          #{imports.join("\n")}

          const pages: Record<string, ComponentType<PageComponentProps>> = {
          #{mappings.join(",\n")}
          };

          export default pages;
        TS
      end

      def frontend_api_client
        <<~'TS'
          import type { ApiFailure, RuntimeValue } from '../types';

          const errorMessage = (payload: unknown, status: number): string => {
            if (payload && typeof payload === 'object' && 'error' in payload) {
              const error = payload.error;
              if (error && typeof error === 'object' && 'message' in error) return String(error.message);
            }
            return `HTTP ${status}`;
          };

          export const api = async <T = RuntimeValue | undefined>(
            path: string, options: RequestInit = {}
          ): Promise<T> => {
            const headers = new Headers(options.headers);
            headers.set('Content-Type', 'application/json');
            if (csrfToken && !['GET', 'HEAD'].includes(options.method || 'GET')) {
              headers.set('X-CSRF-Token', csrfToken);
            }
            const response = await fetch(path, { ...options, headers, credentials: 'same-origin' });
            const payload: unknown = await response.json();
            if (!response.ok) {
              const error: ApiFailure = new Error(errorMessage(payload, response.status));
              error.status = response.status;
              throw error;
            }
            return payload as T;
          };

          let csrfToken: string | null = null;
          export const setCsrfToken = (value: string | null): void => { csrfToken = value; };
        TS
      end

      def frontend_nanoflow_runtime
        <<~'TS'
          import type {
            EntityRecord, NanoflowExecution, NanoflowMetadata, NanoflowMicroflowInvoker,
            NanoflowParameters, RegisteredNanoflow, RuntimeValue
          } from '../types';

          type ChangeExpressions = Record<string, string>;
          type Comparable = string | number;

          const isRecord = (value: RuntimeValue | undefined): value is EntityRecord => {
            return Boolean(value && typeof value === 'object'
              && 'id' in value && 'type' in value && 'attributes' in value);
          };

          const attributes = (value: RuntimeValue | undefined): Record<string, RuntimeValue | undefined> => {
            return isRecord(value) ? value.attributes : {};
          };

          const memberName = (value: string): string => value.split(/[./]/).at(-1) || value;

          export class NanoflowRuntime<P extends NanoflowParameters = NanoflowParameters> {
            readonly variables: NanoflowParameters;
            readonly #changes = new Map<string, EntityRecord>();
            readonly #messages: Array<{ message: string; level: string; blocking: boolean }> = [];

            constructor(parameters: P, readonly metadata: NanoflowMetadata,
              readonly microflowInvoker?: NanoflowMicroflowInvoker) {
              this.variables = structuredClone(parameters);
            }

            value(source: string | undefined, context: EntityRecord | null = null): RuntimeValue | undefined {
              const text = (source || '').trim();
              if (/\s(?:and|or)\s|(?:=|!=|>=|<=|>|<)/.test(text)) {
                return this.condition(text, context);
              }
              const wrapped = text.match(/^toString\((.*)\)$/);
              if (wrapped) return this.string(wrapped[1], context);
              if (text === '$currentObject') return context;
              const variable = text.match(/^\$([A-Za-z_]\w*)$/);
              if (variable) return this.variables[variable[1]] ?? context;
              const member = text.match(/^\$([A-Za-z_]\w*)\/([A-Za-z_][\w.]*)$/);
              if (member) {
                return attributes(this.variables[member[1]] ?? context)[memberName(member[2])];
              }
              if (text === 'empty') return null;
              if (text === 'true') return true;
              if (text === 'false') return false;
              if (/^-?\d+(?:\.\d+)?$/.test(text)) return Number(text);
              if (/^'.*'$/.test(text)) return text.slice(1, -1).replaceAll("''", "'");
              return text;
            }

            condition(source: string | undefined, context: EntityRecord | null = null): boolean {
              const text = (source || '').trim().replace(/^\((.*)\)$/, '$1');
              const orParts = text.split(/\s+or\s+/);
              if (orParts.length > 1) return orParts.some(part => this.condition(part, context));
              const andParts = text.split(/\s+and\s+/);
              if (andParts.length > 1) return andParts.every(part => this.condition(part, context));
              const comparison = text.match(/^(.*?)\s*(=|!=|>=|<=|>|<)\s*(.*?)$/);
              if (!comparison) return Boolean(this.value(text, context));
              const left = this.value(comparison[1], context);
              const right = this.value(comparison[3], context);
              switch (comparison[2]) {
                case '=': return left === right;
                case '!=': return left !== right;
                case '>': return this.comparable(left) > this.comparable(right);
                case '<': return this.comparable(left) < this.comparable(right);
                case '>=': return this.comparable(left) >= this.comparable(right);
                case '<=': return this.comparable(left) <= this.comparable(right);
                default: return false;
              }
            }

            boolean(source: string | undefined, context: EntityRecord | null = null): boolean {
              return this.condition(source, context);
            }

            number(source: string | undefined, context: EntityRecord | null = null): number {
              return Number(this.value(source, context));
            }

            string(source: string | undefined, context: EntityRecord | null = null): string {
              return String(this.value(source, context) ?? '');
            }

            set(name: string, value: RuntimeValue | undefined): void {
              this.variables[name] = value;
            }

            log(message: string): void {
              console.info(`[nanoflow] ${message || this.metadata.name}`);
            }

            change(variable: string, expressions: ChangeExpressions): void {
              const record = this.variables[variable];
              if (!isRecord(record)) throw new Error(`Nanoflow object $${variable} is missing`);
              Object.entries(expressions).forEach(([member, expression]) => {
                record.attributes[member] = this.value(expression, record);
              });
              this.#changes.set(`${record.type}:${record.id}`, record);
            }

            async callMicroflow(name: string, expressions: Record<string, string>): Promise<RuntimeValue | undefined> {
              if (!this.microflowInvoker) {
                throw new Error(`Nanoflow ${this.metadata.name} cannot call ${name}: invoker is unavailable`);
              }
              const parameters = Object.fromEntries(
                Object.entries(expressions).map(([key, expression]) => [key, this.value(expression)])
              );
              const response = await this.microflowInvoker(name, parameters);
              if (response && typeof response === 'object' && 'result' in response) {
                return (response as { result?: RuntimeValue }).result;
              }
              return response as RuntimeValue | undefined;
            }

            showMessage(message: string, level = 'information', blocking = false): void {
              this.#messages.push({ message, level, blocking });
            }

            complete<R>(result: R): NanoflowExecution<R> {
              return {
                result, variables: this.variables, changes: [...this.#changes.values()],
                messages: [...this.#messages]
              };
            }

            missing(current: string | null): Error {
              return new Error(`Nanoflow ${this.metadata.name} points to missing object ${current || '(none)'}`);
            }

            stopped(type: string): Error {
              return new Error(`Nanoflow ${this.metadata.name} stops at ${type}`);
            }

            unsupported(type: string): Error {
              return new Error(`Unsupported frontend nanoflow action: ${type || '(empty)'}`);
            }

            exceeded(): Error {
              return new Error(`Nanoflow ${this.metadata.name} exceeded 10000 steps`);
            }

            private comparable(value: RuntimeValue | undefined): Comparable {
              return typeof value === 'number' ? value : String(value ?? '');
            }
          }

          export const defineNanoflow = <P extends NanoflowParameters, R extends RuntimeValue | undefined>(
            metadata: NanoflowMetadata,
            compiled: (runtime: NanoflowRuntime<P>) => NanoflowExecution<R> | Promise<NanoflowExecution<R>>
          ): RegisteredNanoflow => ({
            ...metadata,
            execute: async (parameters, invokeMicroflow) =>
              compiled(new NanoflowRuntime(parameters as P, metadata, invokeMicroflow))
          });
        TS
      end

      def frontend_marketplace_runtime
        <<~'TS'
          import { useState } from 'react';
          import type { ReactNode } from 'react';
          import type { EntityRecord, RuntimeValue, WidgetDefinition } from '../types';

          export interface MarketplaceWidgetRegion {
            path: Array<string | number>;
            role: string;
            content: ReactNode;
          }

          export interface MarketplaceWidgetProps {
            widget: WidgetDefinition;
            context: EntityRecord | null;
            children?: ReactNode;
            regions?: MarketplaceWidgetRegion[];
            onChange(attribute: string | undefined, value: RuntimeValue): unknown;
          }

          type Properties = Record<string, unknown>;

          const asProperties = (value: unknown): Properties =>
            value && typeof value === 'object' && !Array.isArray(value) ? value as Properties : {};

          const firstText = (properties: Properties, keys: string[], fallback: string): string => {
            for (const key of keys) {
              const value = properties[key];
              if (typeof value === 'string' && value.trim()) return value;
              if (typeof value === 'number' || typeof value === 'boolean') return String(value);
            }
            return fallback;
          };

          const findAttribute = (value: unknown): string | undefined => {
            if (!value || typeof value !== 'object') return undefined;
            if (Array.isArray(value)) {
              for (const child of value) {
                const found = findAttribute(child);
                if (found) return found;
              }
              return undefined;
            }
            for (const [key, child] of Object.entries(value as Properties)) {
              if (/attribute/i.test(key) && typeof child === 'string' && child.includes('.')) return child;
              const found = findAttribute(child);
              if (found) return found;
            }
            return undefined;
          };

          const memberName = (value: string | undefined): string =>
            (value || '').split(/[./]/).pop() || '';

          const numericValue = (value: RuntimeValue | undefined, fallback = 0): number => {
            const number = Number(value);
            return Number.isFinite(number) ? number : fallback;
          };

          const normalizedRole = (role: string): string => role.replace(/[^a-z0-9]/gi, '').toLowerCase();

          const regionsByRole = (regions: MarketplaceWidgetRegion[], role: string): MarketplaceWidgetRegion[] =>
            regions.filter(region => normalizedRole(region.role) === normalizedRole(role));

          const regionsByPath = (
            regions: MarketplaceWidgetRegion[],
            path: Array<string | number>
          ): MarketplaceWidgetRegion[] => regions.filter(region => path.every(
            (part, index) => String(region.path[index]) === String(part)
          ));

          const regionContent = (
            regions: MarketplaceWidgetRegion[],
            role: string,
            fallback?: ReactNode
          ): ReactNode => {
            const matches = regionsByRole(regions, role);
            return matches.length ? matches.map(region => region.content) : fallback;
          };

          const renderRegions = (regions: MarketplaceWidgetRegion[], fallback?: ReactNode): ReactNode =>
            regions.length ? regions.map((region, index) => (
              <div key={`${region.path.map(String).join('.')}-${region.role}-${index}`}
                className="mxrb-marketplace-region" data-region-role={region.role}
                data-region-path={region.path.map(String).join('.')}>
                {region.content}
              </div>
            )) : fallback;

          const groupIndex = (region: MarketplaceWidgetRegion): string | undefined => {
            const groupPath = region.path.map(String);
            const groups = groupPath.findIndex((part, index) =>
              part === 'groups' && groupPath[index + 1] === 'objects'
            );
            return groups >= 0 ? groupPath[groups + 2] : undefined;
          };

          const accordion = (
            label: string,
            regions: MarketplaceWidgetRegion[],
            fallback?: ReactNode
          ): ReactNode => {
            const indices = [...new Set(regions.map(groupIndex).filter((index): index is string => Boolean(index)))];
            if (!indices.length) return <details><summary>{label}</summary>{renderRegions(regions, fallback)}</details>;

            const ungrouped = regions.filter(region => groupIndex(region) === undefined);
            return <div className="mxrb-marketplace-accordion">
              {indices.map(index => {
                const group = regionsByPath(regions, ['groups', 'objects', index]);
                return <details key={index}>
                  <summary>{regionContent(group, 'headerContent', label)}</summary>
                  {regionContent(group, 'content')}
                </details>;
              })}
              {renderRegions(ungrouped)}
            </div>;
          };

          const chart = (name: string, children?: ReactNode) => <>
            <figure className="mxrb-marketplace-chart">
              <svg viewBox="0 0 240 100" role="img" aria-label={name}>
                <title>{name}</title>
                <polyline points="8,82 48,55 88,68 128,25 168,42 228,12" fill="none"
                  stroke="currentColor" strokeWidth="4" />
                <line x1="8" y1="90" x2="232" y2="90" stroke="currentColor" />
              </svg>
              <figcaption>{name}</figcaption>
            </figure>
            {children}
          </>;

          export function MarketplaceWidget({
            widget, context, children, regions = [], onChange
          }: MarketplaceWidgetProps) {
            const options = widget.options || {};
            const properties = asProperties(options.properties);
            const id = String(options.widget_id || options.native_type || widget.name).toLowerCase();
            const name = String(options.widget_name || widget.name);
            const attribute = findAttribute(properties);
            const current = context?.attributes?.[memberName(attribute)];
            const [localValue, setLocalValue] = useState<RuntimeValue>(current ?? 0);
            const update = (value: RuntimeValue) => {
              setLocalValue(value);
              return onChange(attribute, value);
            };
            const label = firstText(
              properties,
              ['label', 'value', 'caption', 'title', 'legend', 'textMessage', 'alternativeText'],
              name
            );
            const content = renderRegions(regions, children);

            if (/(area|bar|bubble|column|custom|heatmap|line|pie|time)chart/.test(id)
                || id.includes('timeseries') || id.includes('heatmap')) return chart(name, content);
            if (id.includes('progresscircle') || id.includes('progressbar')) {
              const value = numericValue(current ?? localValue, 50);
              return <label>{label}<progress value={value} max={100}>{value}%</progress></label>;
            }
            if (id.includes('rangeslider')) {
              const start = Array.isArray(localValue) ? numericValue(localValue[0]) : numericValue(localValue);
              return <label>{label}<input aria-label={`${label} minimum`} type="range" value={start}
                onChange={event => update(Number(event.target.value))} /></label>;
            }
            if (id.includes('slider')) {
              return <label>{label}<input aria-label={label} type="range"
                value={numericValue(current ?? localValue)}
                onChange={event => update(Number(event.target.value))} /></label>;
            }
            if (id.includes('starrating') || id.endsWith('.rating')) {
              const rating = numericValue(current ?? localValue);
              return <fieldset className="mxrb-marketplace-rating"><legend>{label}</legend>
                {[1, 2, 3, 4, 5].map(value => <button type="button" key={value}
                  aria-label={`${value} stars`} aria-pressed={value <= rating}
                  onClick={() => update(value)}>{value <= rating ? '★' : '☆'}</button>)}
              </fieldset>;
            }
            if (id.includes('switch')) {
              return <label><input type="checkbox" checked={Boolean(current ?? localValue)}
                onChange={event => update(event.target.checked)} />{label}</label>;
            }
            if (id.includes('badgebutton')) return <button type="button">{label}</button>;
            if (id.includes('badge')) return <output className="mxrb-marketplace-badge">{label}</output>;
            if (id.includes('accordion')) return accordion(label, regions, children);
            if (id.includes('fieldset')) return <fieldset><legend>{label}</legend>
              {regionContent(regions, 'content', children)}
            </fieldset>;
            if (id.includes('accessibilityhelper')) return <div aria-live="polite">
              {regionContent(regions, 'content', children)}
            </div>;
            if (id.includes('htmlelement')) return <article>{content || label}</article>;
            if (id.endsWith('.image')) {
              const source = firstText(properties, ['imageUrl', 'url'], '');
              return source ? <img src={source} alt={label} /> : <span>{label}</span>;
            }
            if (id.includes('languageselector')) return <label>{label}<select defaultValue="pt-BR">
              <option value="pt-BR">Português</option><option value="en-US">English</option>
            </select></label>;
            if (id.includes('popupmenu')) return <details><summary>{label}</summary>{content || 'Menu'}</details>;
            if (id.includes('timeline')) return <ol className="mxrb-marketplace-timeline"><li>{label}</li>{content}</ol>;
            if (id.includes('tooltip')) return <span className="mxrb-marketplace-tooltip">
              {regionContent(regions, 'trigger', children || label)}
              <span role="tooltip">{regionContent(regions, 'htmlMessage')}</span>
            </span>;
            if (id.includes('carousel')) return <div className="mxrb-marketplace-carousel">
              {regionContent(regions, 'content', children)}
            </div>;
            if (id.includes('safearea')) return <div className="mxrb-marketplace-safe-area">
              {regionContent(regions, 'content', children)}
            </div>;
            if (id.includes('treenode') || id.includes('treeview')) return <ul><li>{label}{content}</li></ul>;
            if (id.includes('videoplayer')) {
              const source = firstText(properties, ['videoUrl', 'videoURL', 'url'], '');
              return <video controls src={source || undefined}>{label}</video>;
            }
            if (id.includes('barcodescanner')) return <button type="button">{label}</button>;

            return <section className="mxrb-marketplace-generic" aria-label={name}>
              <strong>{name}</strong>{content}
            </section>;
          }
        TS
      end

      def frontend_types # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        modules = @module_manifests || []
        entities = modules.flat_map { |mod| Array(mod['models']) + Array(mod['dtos']) }
        pages = modules.flat_map { |mod| Array(mod['pages']) }
        enumerations = modules.flat_map { |mod| Array(mod['enumerations']) }
        enumeration_types = enumerations.map do |enumeration|
          name = typescript_identifier(enumeration.fetch('name'))
          values = enumeration.fetch('values', []).map { JSON.generate(_1.fetch('name')) }
          "export type #{name} = #{values.empty? ? 'never' : values.join(' | ')};"
        end
        entity_types = entities.flat_map do |entity|
          name = typescript_identifier(entity.fetch('name'))
          attributes = entity.fetch('attributes', []).map do |attribute|
            optional = attribute['required'] ? '' : '?'
            type = typescript_attribute_type(attribute, enumerations)
            "  #{JSON.generate(attribute.fetch('name'))}#{optional}: #{type};"
          end
          [
            "export interface #{name}Attributes {\n#{attributes.join("\n")}\n}",
            "export type #{name}Record = EntityRecord<#{name}Attributes, #{JSON.generate(entity.fetch('name'))}>;"
          ]
        end
        entity_map = entities.map do |entity|
          "  #{JSON.generate(entity.fetch('name'))}: #{typescript_identifier(entity.fetch('name'))}Record;"
        end
        page_types = pages.map do |page|
          name = typescript_identifier(page.fetch('name'))
          widgets = page.fetch('widgets', []).flat_map { frontend_widget_names(_1) }.uniq
          widget_names = widgets.empty? ? 'never' : widgets.map { JSON.generate(_1) }.join(' | ')
          "export type #{name}WidgetName = #{widget_names};"
        end
        page_map = pages.map do |page|
          name = typescript_identifier(page.fetch('name'))
          qualified = JSON.generate(page.fetch('name'))
          "  #{qualified}: PageDefinition<#{qualified}, #{name}WidgetName>;"
        end
        <<~TS
          // Generated from the Mendix domain, page, widget, effect, and API contracts.
          import type { ComponentType, ReactNode } from 'react';

          export type RuntimeScalar = string | number | boolean | null;
          export type RuntimeValue = RuntimeScalar | EntityRecord | RuntimeValue[] | { [key: string]: RuntimeValue };
          export type RuntimeVariables = Record<string, RuntimeValue | undefined>;

          export interface EntityRecord<
            Attributes extends object = Record<string, RuntimeValue | undefined>,
            Name extends string = string
          > {
            id: string;
            type: Name;
            attributes: Attributes;
            transient?: boolean;
          }

          export interface WidgetEvent {
            event: string;
            kind: 'microflow' | 'nanoflow' | 'page' | string;
            handler: string;
            arguments?: RuntimeVariables;
          }

          export interface WidgetColumn {
            name?: string;
            attribute?: string;
            caption?: string;
            width?: number;
          }

          export interface DataViewSource {
            kind: 'context' | 'association' | 'microflow' | 'nanoflow' | 'listen' | 'native' | string;
            name?: string;
            entity?: string;
            target?: string;
            variable?: {
              kind?: string;
              name?: string;
              sub_key?: string;
              use_all_pages?: boolean;
            };
            steps?: Array<{ association?: string; entity?: string }>;
            mappings?: Array<Record<string, RuntimeValue>>;
          }

          export interface WidgetTab {
            name: string;
            caption?: string;
            widgets?: WidgetDefinition[];
          }

          export interface WidgetSlot {
            path: Array<string | number>;
            role?: string;
            widgets: WidgetDefinition[];
          }

          export interface WidgetOptions {
            [key: string]: unknown;
            association?: string;
            attribute?: string;
            caption?: string;
            class?: string;
            columns?: WidgetColumn[];
            display_attribute?: string;
            dynamic_class?: string;
            entity?: string;
            items?: RuntimeValue[] | Record<string, RuntimeValue>;
            lines?: number;
            native_type?: string;
            options?: RuntimeValue[] | Record<string, RuntimeValue>;
            pageSize?: number;
            page_size?: number;
            parameters?: string[];
            read_only?: boolean;
            sort?: Array<{ attribute: string; direction?: string }>;
            source?: DataViewSource;
            style?: string;
            tabs?: WidgetTab[];
            target_entity?: string;
            toolbar?: { buttons?: Array<{ type: string }> };
            values?: RuntimeValue[] | Record<string, RuntimeValue>;
            visible?: string | boolean;
            platform?: string;
            properties?: Record<string, unknown>;
            widget_id?: string;
            widget_name?: string;
          }

          export interface WidgetDefinition<Name extends string = string> {
            type: string;
            name: Name;
            caption?: string;
            options?: WidgetOptions;
            events?: WidgetEvent[];
            children?: WidgetDefinition[];
            body?: WidgetDefinition[];
            footer?: WidgetDefinition[];
            regions?: Record<string, WidgetDefinition[]>;
            slots?: WidgetSlot[];
          }

          export interface PageDefinition<Name extends string = string, WidgetName extends string = string> {
            name: Name;
            title: string;
            appearance_class?: string;
            appearance_style?: string;
            data_source?: { kind: 'microflow' | 'nanoflow' | string; name: string } | null;
            widgets: WidgetDefinition<WidgetName>[];
          }

          export interface PageComponentProps {
            busy: boolean;
            Widget: ComponentType<PageWidgetProps>;
          }

          export interface PageWidgetProps {
            widget: WidgetDefinition;
            index: number;
            children?: ReactNode;
          }

          export interface AttributeDefinition {
            name: string;
            type: string;
            enumeration?: string;
          }

          export interface EntityDefinition {
            name: string;
            attributes?: AttributeDefinition[];
          }

          export interface EnumerationDefinition {
            id: string;
            name: string;
            values: Array<{ name: string; caption: string }>;
          }

          export interface AssociationDefinition {
            name: string;
            from_entity: string;
            to_entity: string;
            type: string;
          }

          export interface NavigationItem {
            page?: string;
            caption?: Record<string, string>;
            items?: NavigationItem[];
          }

          export interface NavigationProfile {
            kind: string;
            home_page?: string;
            items?: NavigationItem[];
          }

          export interface RuntimeModule {
            name: string;
            models?: EntityDefinition[];
            dtos?: EntityDefinition[];
            pages: PageDefinition[];
            enumerations?: EnumerationDefinition[];
            associations?: AssociationDefinition[];
          }

          export interface ApplicationSchema {
            project: { name: string; mendix_version: string };
            navigation?: { profiles?: NavigationProfile[] };
            modules: RuntimeModule[];
          }

          export interface OpenPageEffect {
            type: 'open_page';
            page: string;
            arguments?: Record<string, RuntimeValue>;
          }

          export interface ShowMessageEffect {
            type: 'show_message';
            message: string;
            level?: string;
            blocking?: boolean;
          }

          export interface RuntimeEffect {
            type: string;
            [key: string]: RuntimeValue | undefined;
          }

          export interface InvocationResult {
            result?: RuntimeValue;
            context?: EntityRecord | null;
            effects?: Array<OpenPageEffect | ShowMessageEffect | RuntimeEffect>;
          }

          export interface EntityCollectionResponse<T extends EntityRecord = EntityRecord> {
            records: T[];
          }

          export interface Session {
            id?: string;
            username?: string;
            csrf?: string;
            [key: string]: RuntimeValue | undefined;
          }

          export interface LoginResponse {
            csrf: string;
            user?: string;
            roles?: string[];
          }

          export interface ApiFailure extends Error {
            status?: number;
          }

          export type ApiRequest = <T = RuntimeValue | undefined>(
            path: string, options?: RequestInit
          ) => Promise<T>;

          export type NanoflowParameters = RuntimeVariables;
          export type NanoflowMicroflowInvoker = (
            name: string, parameters?: RuntimeVariables
          ) => Promise<unknown>;

          export interface NanoflowMetadata {
            name: string;
            id: string;
            parameters: string[];
          }

          export interface NanoflowExecution<R = RuntimeValue | undefined> {
            result: R;
            variables: NanoflowParameters;
            changes: EntityRecord[];
            messages: Array<{ message: string; level: string; blocking: boolean }>;
          }

          export interface RegisteredNanoflow extends NanoflowMetadata {
            execute(
              parameters: NanoflowParameters, invokeMicroflow?: NanoflowMicroflowInvoker
            ): Promise<NanoflowExecution>;
          }

          #{enumeration_types.join("\n")}

          #{entity_types.join("\n\n")}

          export interface EntityTypeMap {
          #{entity_map.join("\n")}
          }
          export type EntityName = keyof EntityTypeMap;

          #{page_types.join("\n")}

          export interface PageTypeMap {
          #{page_map.join("\n")}
          }
          export type PageName = keyof PageTypeMap;
        TS
      end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

      def frontend_widget_names(widget)
        nested = Array(widget['children']) + Array(widget['body']) + Array(widget['footer'])
        nested.concat(Array(widget['slots']).flat_map { Array(_1['widgets']) })
        regions = widget.fetch('regions', {})
        nested.concat(regions.values.flat_map { Array(_1) }) if regions.is_a?(Hash)
        Array(widget.dig('options', 'rows')).each do |row|
          nested.concat(Array(row['widgets']))
          nested.concat(Array(row['columns']).flat_map { Array(_1['widgets']) })
          nested.concat(Array(row['cells']).flat_map { Array(_1['widgets']) })
        end
        [widget['name'].to_s, *nested.flat_map { frontend_widget_names(_1) }].reject(&:empty?)
      end

      def typescript_attribute_type(attribute, enumerations)
        if attribute['type'] == 'enum'
          enumeration = enumerations.find do |candidate|
            [candidate['id'], candidate['name']].include?(attribute['enumeration'])
          end
          return typescript_identifier(enumeration['name']) if enumeration
        end

        {
          'boolean' => 'boolean', 'integer' => 'number', 'long' => 'number',
          'autonumber' => 'number', 'decimal' => 'number', 'datetime' => 'string',
          'binary' => 'string'
        }.fetch(attribute['type'].to_s, 'string')
      end

      def typescript_identifier(value)
        parts = value.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?)
        identifier = parts.map { _1[0].to_s.upcase + _1[1..].to_s }.join
        return 'MxrbType' if identifier.empty?

        identifier.match?(/\A[A-Za-z_]/) ? identifier : "Mx#{identifier}"
      end

      def readme
        <<~MARKDOWN
          # #{@project.name}

          Executable Ruby application exported by MXRB.

          ## Run

          ```sh
          bundle install
          npm ci --prefix frontend
          bundle exec mxrb run .
          ```

          `mxrb run` supervises the Ruby API and React + TypeScript + Vite development server
          together. Vite proxies `/api` to Ruby, so both processes behave as one
          application. Use `--server-port` for Ruby and `--client-port` for Vite;
          `--api-port` and `--port` remain compatibility aliases. Generated models,
          DTOs, services, and pages live under `app/`.
          The generated `frontend/src/generated/types.ts` covers domain records, pages, widgets,
          contexts, effects, and API payloads; `npm run typecheck` validates it strictly.
          Service bodies are ordinary Ruby; their default implementation delegates to
          MXRB's pure-Ruby interpreter.

          The frontend follows a conventional application layout. Add product code under
          `frontend/src/features`, `components`, `hooks`, `layouts`, `core`, or `styles`.
          MXRB owns only `frontend/src/generated`, which contains the reversible bridge,
          projected pages/flows, and schema types. Application-owned files are embedded in
          the MPR and restored byte-for-byte; generated files are rebuilt on every export.

          ```sh
          npm ci --prefix frontend
          npm run check --prefix frontend
          ```

          The complete gate runs Prettier, ESLint, Vitest/Testing Library, strict TypeScript,
          and the production Vite build using the committed frontend lockfile.

          Browser CRUD uses the same authenticated entity API as microflows. Configure
          users and bearer tokens through ignored environment files. External app/web
          services, mappings, XML imports, and documents are explicit Ruby integrations
          registered in `config/adapters.rb`; keep credentials out of that committed file.

          ## Recompile to Mendix

          ```sh
          bundle exec mxrb generate project.rb build/#{File.basename(@mpr_path)}
          ```

          The complete bidirectional Mendix source remains under `.mxrb/mendix`. The
          `.mxrb/ruby-app.json` coverage manifest maps stable Mendix IDs to Ruby files and
          records artifacts that remain preserved natively.
        MARKDOWN
      end

      def escape_html(value)
        value.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end
    end
    # rubocop:enable Metrics
  end
end
