# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Writes the Ruby sources of entities, enumerations, constants, security, schedules and services.
      module ModelSources
        private

        def calculated_attribute(attribute)
          return '' unless attribute['calculated']

          pass = attribute['pass_entity'] == false ? ', pass_entity: false' : ''
          ", calculated: #{attribute['calculated'].inspect}#{pass}"
        end

        def entity_source(namespace, class_name, qualified, _id, attributes, associations = [],
                          dto:, persistable:,
                          access_rules: [], indexes: [], system_members: nil,
                          generalization: nil, oql_view: nil, lifecycle: [], validation_rules: [])
          access_rules = access_rules_with_source_identity(access_rules)
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
              "enumeration: #{attribute['enumeration'].inspect}#{calculated_attribute(attribute)}"
          end
          association_declarations = associations.map do |association|
            "    association #{association.fetch('to_entity').inspect}, " \
              "name: #{association.fetch('name').split('.', 2).last.inspect}, " \
              "type: :#{association.fetch('type')}, " \
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
          semantic_declarations << "    generalizes #{generalization.fetch('target').inspect}" if generalization
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
                mendix_name #{qualified.inspect}
                persistence #{persistable}
            #{(declarations + association_declarations + index_declarations + system_declarations + semantic_declarations + lifecycle_declarations + validation_declarations + access_declarations).join("\n")}
              end
            end
          RUBY
        end

        def index_source(index)
          members = index.fetch('members').map do |member|
            "      member #{member.fetch('name').inspect}, " \
              "ascending: #{member.fetch('ascending')}, type: #{underscore(member.fetch('type')).to_sym.inspect}"
          end
          declaration = "    index include_offline: #{index.fetch('include_offline')} do"
          [declaration, *members, '    end'].join("\n")
        end

        def oql_view_source(view)
          options = %w[source query].filter_map do |name|
            value = view[name]
            "#{name}: #{value.inspect}" unless value.nil?
          end
          "    oql_view #{options.join(', ')}"
        end

        def lifecycle_source(callback)
          "    #{callback.fetch('event')} microflow: #{callback.fetch('handler').inspect}, " \
            "pass_event_object: #{callback.fetch('pass_event_object')}, " \
            "raise_error_on_false: #{callback.fetch('raise_error_on_false')}"
        end

        def validation_rule_source(rule)
          kind = rule.fetch('kind')
          info = rule.fetch('rule_info')
          regular_expression = kind == 'DomainModels$RegExRuleInfo' && info['RegExIdentifier'].is_a?(String)
          kind = 'regular_expression' if regular_expression
          kind = %w[required unique regular_expression].include?(kind) ? ":#{kind}" : kind.inspect
          remaining = regular_expression ? info.reject { |key, _value| key == 'RegExIdentifier' } : info
          declaration = "    validation_rule #{rule.fetch('attribute').inspect}, kind: #{kind}"
          declaration += ", rule_info: #{remaining.inspect}" unless remaining.empty?
          translations = rule.fetch('translations').map do |translation|
            "      translation #{translation.fetch('language_code').inspect}, " \
              "#{translation.fetch('text').inspect}"
          end
          options = regular_expression ? ["      regular_expression #{info.fetch('RegExIdentifier').inspect}"] : []
          ["#{declaration} do", *translations, *options, '    end'].join("\n")
        end

        def access_rules_with_source_identity(rules)
          grouped = rules.group_by { RecordIdentity.access_signature(_1) }
          grouped.each_value do |matches|
            next unless matches.size > 1

            matches.sort_by { _1.fetch('id').to_s }.each_with_index do |rule, index|
              rule['source_identity'] = "rule_#{index + 1}"
            end
          end
          rules
        end

        def access_rule_source(rule)
          roles = rule.fetch('roles').map(&:inspect).join(', ')
          members = rule.fetch('members').map do |member|
            "      member #{member.fetch('name').inspect}, " \
              "reference: #{member.fetch('reference').inspect}, rights: :#{underscore(member.fetch('rights'))}, " \
              "kind: :#{member.fetch('kind')}"
          end
          identity = rule['source_identity'] ? "identity: #{rule.fetch('source_identity').inspect}, " : ''
          declaration = "    access_rule #{roles}, #{identity}" \
            "documentation: #{rule.fetch('documentation').inspect}, create: #{rule.fetch('create')}, " \
            "delete: #{rule.fetch('delete')}, default_rights: :#{underscore(rule.fetch('default_rights'))}, " \
            "xpath: #{rule.fetch('xpath').inspect}, " \
            "xpath_caption: #{rule.fetch('xpath_caption', nil).inspect}"
          return declaration if members.empty?

          ["#{declaration} do", *members, '    end'].join("\n")
        end

        def enumeration_source(namespace, class_name, enumeration)
          declarations = enumeration.fetch('values').map do |value|
            translations = value.fetch('captions').map do |language, text|
              "      translation #{language.inspect}, #{text.inspect}"
            end
            ["    value #{value.fetch('name').inspect} do",
             *translations, '    end'].join("\n")
          end
          <<~RUBY
            # frozen_string_literal: true

            module #{namespace}
              class #{class_name} < Mxrb::RubyApp::Enumeration
                mendix_name #{enumeration.fetch('name').inspect}
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
                mendix_name #{constant.fetch('name').inspect}
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
            "    module_role #{role.fetch('name').inspect}, " \
              "description: #{role.fetch('description').inspect}"
          end
          roles = ['    clear_module_roles!'] if roles.empty?
          <<~RUBY
            # frozen_string_literal: true

            module #{namespace}
              class Security < Mxrb::RubyApp::ModuleSecurity
                mendix_name #{module_name.inspect}
            #{roles.join("\n")}
              end
            end
          RUBY
        end

        def project_security_source(security)
          user_roles = security.fetch('user_roles').map do |role|
            "    user_role #{role.fetch('name').inspect}, description: #{role.fetch('description').inspect}, " \
              "check_security: #{role.fetch('check_security')}, " \
              "manageable_roles: #{role.fetch('manageable_roles').inspect}, " \
              "manage_all_roles: #{role.fetch('manage_all_roles')}, " \
              "manage_users_without_roles: #{role.fetch('manage_users_without_roles')}, " \
              "module_roles: #{role.fetch('module_roles').inspect}, exact_module_roles: true"
          end
          user_roles = ['    clear_user_roles!'] if user_roles.empty?
          demo_users = security.fetch('demo_users').map do |user|
            "    demo_user #{user.fetch('name').inspect}, " \
              "entity: #{user.fetch('entity').inspect}, roles: #{user.fetch('roles').inspect}, " \
              'password: nil'
          end
          demo_users = ['    clear_demo_users!'] if demo_users.empty?
          policy = security['password_policy']
          policy_source = password_policy_source(policy) if policy
          sign_in_source = if security['sign_in_microflow']
                             "    sign_in_microflow #{security.fetch('sign_in_microflow').inspect}"
                           end
          file_access = if security.key?('file_document_access')
                          project_access_source(
                            security.fetch('file_document_access').fetch('rules', []),
                            'file_document_access_rule', 'clear_file_document_access_rules!'
                          )
                        else
                          []
                        end
          image_access = if security.key?('image_access')
                           project_access_source(
                             security.fetch('image_access').fetch('rules', []),
                             'image_access_rule', 'clear_image_access_rules!'
                           )
                         else
                           []
                         end
          <<~RUBY
            # frozen_string_literal: true

            class ApplicationSecurity < Mxrb::RubyApp::ProjectSecurity
              project_security
              security_level #{security.fetch('security_level').inspect}
              check_security #{security.fetch('check_security', true)}
              strict_page_url_check #{security.fetch('strict_page_url_check', true)}
              admin_user #{security.fetch('admin_user_name', 'MxAdmin').inspect}
              admin_user_role #{security.fetch('admin_user_role').inspect}
              demo_users enabled: #{security.fetch('demo_users_enabled')}
              guest_access enabled: #{security.fetch('guest_access_enabled')}, role: #{security.fetch('guest_user_role').inspect}
              strict_mode #{security.fetch('strict_mode', false)}
            #{sign_in_source}
            #{user_roles.join("\n")}
            #{demo_users.join("\n")}
            #{policy_source}
            #{file_access.join("\n")}
            #{image_access.join("\n")}
            end
          RUBY
        end

        def project_access_source(rules, declaration, clear_declaration)
          return ["    #{clear_declaration}"] if rules.empty?

          access_rules_with_source_identity(rules).map do |rule|
            access_rule_source(rule).sub(/\A    access_rule/, "    #{declaration}")
          end
        end

        def password_policy_source(policy)
          typed = PasswordPolicyBuilder.new(policy.fetch('properties')).build
          declarations = typed.to_h.compact.map { |name, value| "      #{name} #{value.inspect}" }
          ['    password_policy do', *declarations, '    end'].join("\n")
        rescue ArgumentError, TypeError
          # Unknown extensions and explicit nulls retain the legacy contract.
          "    password_policy properties: #{policy.fetch('properties').inspect}"
        end

        def scheduled_event_source(namespace, class_name, event)
          schedule = event['schedule']
          binding = if event.fetch('unbound', false)
                      "    unbound\n"
                    else
                      "    microflow #{event.fetch('microflow').inspect}\n"
                    end
          schedule_source = schedule ? schedule_source(schedule) : ''
          <<~RUBY
            # frozen_string_literal: true

            module #{namespace}
              class #{class_name} < Mxrb::RubyApp::ScheduledEvent
                mendix_name #{event.fetch('name').inspect}
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

        def schedule_source(schedule)
          type = schedule.fetch('type')
          properties = schedule.fetch('properties')
          unless ScheduleBuilder.compatible?(type, properties)
            return "    schedule #{type.inspect}, properties: #{properties.inspect}\n"
          end

          declarations = properties.map do |name, value|
            "      #{ScheduleBuilder::PROPERTY_NAMES.fetch(name)} #{value.inspect}"
          end
          ["    schedule #{ScheduleBuilder.kind(type).inspect} do", *declarations, '    end'].join("\n")
        end

        def service_source(namespace, class_name, qualified, _id, native_source: nil,
                           native_kind: :microflow, export_level: 'Hidden', activity_captions: {})
          rule_options = native_kind == :rule ? ", export_level: #{export_level.inspect}" : ''
          native = if native_source
                     emitter = Mxrb::Exporter::MethodFlowSource.new(native_source, captions: activity_captions)
                     methods = service_method_source(emitter.source(indent: 4))
                     "\n#{methods}\n\n    flow :#{native_kind}#{rule_options}, main: :main_line\n"
                   else
                     ''
                   end
          fallback = native_source ? '' : "\n    def call(**arguments)\n      execute_flow(arguments)\n    end\n"
          <<~RUBY
            # frozen_string_literal: true

            module #{namespace}
              class #{class_name} < Mxrb::RubyApp::Service
                mendix_name #{qualified.inspect}
            #{native}

            #{fallback}
              end
            end
          RUBY
        end

        def service_method_source(source)
          entry = "    def call(**arguments)\n      execute_flow(arguments)\n    end"
          main_line, marker, helpers = source.partition("\n    private\n")
          "#{main_line}\n\n#{entry}\n#{marker}#{helpers}"
        end
      end
      # rubocop:enable Metrics
    end
  end
end
