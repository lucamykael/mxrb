# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Exports module layers, module and project security, and scheduled events.
      module ModuleExports
        private

        def export_module(mod)
          namespace = ruby_constant(mod.name)
          root = underscore(mod.name)
          entities = mod.entities.map { export_entity(_1, mod, namespace, root) }
          duplicate_flows = duplicate_flow_ids(mod.microflows + mod.nanoflows + mod.rules)
          microflows = mod.microflows.map do |flow|
            export_service(
              flow, mod, namespace, root, :microflow,
              duplicate_name: duplicate_flows.include?(flow.id.to_s)
            )
          end
          microflows.concat(mod.rules.map do |flow|
            export_service(flow, mod, namespace, root, :rule,
                           duplicate_name: duplicate_flows.include?(flow.id.to_s))
          end)
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
            'datasets' => mod.application_documents.filter_map do |document|
              export_dataset(mod, document, namespace, root) if document[:type] == Runtime::OqlDatasets::TYPE
            end,
            'enumerations' => mod.enumerations.map { export_enumeration(mod, _1, namespace, root) },
            'regular_expressions' => mod.domain_documents.filter_map do |document|
              export_regular_expression(mod, document, namespace, root) if document[:type] == RegularExpression::TYPE
            end,
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
          relative = embedded_identity_path(:module_security, id) ||
                     embedded_security_path(id, mod.name, module_security: true) ||
                     File.join('app', 'security', root, 'module_security.rb')
          roles = mod.module_roles.map do |role|
            {
              'id' => role.fetch(:id, '').to_s,
              'name' => role.fetch(:name).to_s,
              'description' => role.fetch(:description, '').to_s
            }
          end
          manifest = {
            'id' => id, 'name' => qualified, 'roles' => roles, 'path' => relative,
            'ruby_class' => embedded_identity_class(:module_security, id, "#{namespace}::Security")
          }
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
          relative = embedded_identity_path(:project_security, id) || embedded_security_path(id, 'ProjectSecurity') ||
                     File.join('app', 'security', 'project_security.rb')
          policy = document['PasswordPolicySettings'] if document['PasswordPolicySettings'].is_a?(Hash)
          file_access = project_access_container_manifest(document['FileDocumentAccess'])
          image_access = project_access_container_manifest(document['ImageAccess'])
          manifest = {
            'id' => id,
            'security_level' => document['SecurityLevel'].to_s,
            'check_security' => document.fetch('CheckSecurity', true) == true,
            'strict_page_url_check' => document.fetch('StrictPageUrlCheck', true) == true,
            'admin_user_name' => document.fetch('AdminUserName', 'MxAdmin').to_s,
            'admin_user_role' => document['AdminUserRole'].to_s,
            'demo_users_enabled' => document['EnableDemoUsers'] == true,
            'guest_access_enabled' => document['EnableGuestAccess'] == true,
            'guest_user_role' => document['GuestUserRole'].to_s,
            'sign_in_microflow' => document['SignInMicroflow']&.to_s,
            'strict_mode' => document.fetch('StrictMode', false) == true,
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
          manifest['file_document_access'] = file_access if file_access
          manifest['image_access'] = image_access if image_access
          write(relative, project_security_source(manifest))
          add_coverage(id, 'ProjectSecurity', 'project_security', relative, 'executable_bidirectional')
          manifest.merge('path' => relative,
                         'ruby_class' => embedded_identity_class(:project_security, id,
                                                                 'ApplicationSecurity'))
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

        def project_access_container_manifest(container)
          return nil unless container.is_a?(Hash)

          native_rules = native_items(container['AccessRules'])
          return nil unless native_rules.all? do |rule|
            rule.is_a?(Hash) && rule['$Type'] == 'DomainModels$AccessRule' &&
            native_items(rule['AllowedModuleRoles'] || rule['ModuleRoles']).any?
          end

          rules = native_rules.map do |rule|
            Model::Entity.parse_access_rule(rule)
          end
          {
            'id' => native_identifier(container['$ID']),
            'rules' => access_rules_with_source_identity(runtime_value(rules))
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
          relative = embedded_identity_path(:scheduled_event, id) || embedded_scheduled_event_path(id, qualified) ||
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
            'path' => relative,
            'ruby_class' => embedded_identity_class(:scheduled_event, id, "#{namespace}::#{ruby_constant(name)}")
          }
          write(relative, scheduled_event_source(namespace, ruby_constant(name), manifest))
          add_coverage(id, qualified, 'scheduled_event', relative, 'executable_bidirectional')
          manifest
        end
      end
      # rubocop:enable Metrics
    end
  end
end
