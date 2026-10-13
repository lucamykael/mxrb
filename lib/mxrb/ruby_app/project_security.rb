# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Authoritative project-security declaration. Passwords remain private and
    # are only replaced when explicitly supplied by application code.
    class ProjectSecurity
      OPTION_UNSET = Object.new.freeze

      class << self
        attr_reader :user_roles, :demo_user_definitions

        def inherited(child)
          super
          child.instance_variable_set(:@mendix_id, '')
          child.instance_variable_set(:@user_roles, [])
          child.instance_variable_set(:@demo_user_definitions, [])
          child.instance_variable_set(:@settings, {})
          child.instance_variable_set(:@password_policy, nil)
          child.instance_variable_set(:@removed_user_roles, [])
          child.instance_variable_set(:@removed_demo_users, [])
        end

        def mendix_id(value = OPTION_UNSET)
          return @mendix_id.to_s if value.equal?(OPTION_UNSET)

          project_security(id: value)
        end

        def mendix_name = 'project'

        def project_security(id: nil)
          @mendix_id = SourceIdentity.resolve(self, :project_security, 'project', id:)
          Registry.register(:project_security, 'project', self)
        end

        def security_level(value) = (@settings[:security_level] = value.to_s)
        # rubocop:disable Style/OptionalBooleanParameter
        # Positional booleans keep the class DSL parallel with the regular DSL.
        def check_security(value = true) = (@settings[:check_security] = value == true)
        def strict_page_url_check(value = true) = (@settings[:strict_page_url_check] = value == true)
        def strict_mode(value = true) = (@settings[:strict_mode] = value == true)
        # rubocop:enable Style/OptionalBooleanParameter
        def admin_user_role(value) = (@settings[:admin_user_role] = value.to_s)
        def demo_users(enabled: true) = (@settings[:demo_users_enabled] = enabled == true)
        def sign_in_microflow(value) = (@settings[:sign_in_microflow] = value.to_s)

        # Passwords are deliberately write-only and are absent from exported
        # source. Omitting one preserves the value in the native baseline.
        def admin_user(name, password: nil)
          @settings[:admin_user_name] = name.to_s
          @settings[:admin_password] = password.to_s unless password.nil?
        end

        def guest_access(enabled: true, role: nil)
          @settings[:guest_access_enabled] = enabled == true
          @settings[:guest_user_role] = role.to_s
        end

        def file_document_access_rule(*roles, **options, &block)
          project_access_rule(:file_document_access, roles, options, &block)
        end

        def image_access_rule(*roles, **options, &block)
          project_access_rule(:image_access, roles, options, &block)
        end

        def clear_file_document_access_rules! = (@settings[:file_document_access] = [])
        def clear_image_access_rules! = (@settings[:image_access] = [])

        def user_role(name, id: nil, guid: nil, description: '', check_security: true,
                      manageable_roles: [], manage_all_roles: false,
                      manage_users_without_roles: false, module_roles: [], exact_module_roles: false,
                      renamed_from: nil)
          @user_roles ||= []
          native_roles = Array(module_roles).map(&:to_s)
          unless exact_module_roles || native_roles.any? { _1.start_with?('System.') }
            native_roles << (manage_all_roles ? 'System.Administrator' : 'System.User')
          end
          declaration = {
            name: name.to_s, id: id.to_s, guid: guid.to_s,
            description: description.to_s, check_security: check_security == true,
            manageable_roles: Array(manageable_roles).map(&:to_s),
            manage_all_roles: manage_all_roles == true,
            manage_users_without_roles: manage_users_without_roles == true,
            module_roles: native_roles, exact_module_roles: exact_module_roles == true
          }
          declaration[:renamed_from] = renamed_from.to_s unless renamed_from.nil?
          @user_roles << declaration
        end

        def clear_user_roles! = (@user_roles = [])

        def demo_user(name, entity:, roles:, id: nil, password: nil, renamed_from: nil)
          @demo_user_definitions ||= []
          declaration = {
            name: name.to_s, id: id.to_s, entity: entity.to_s,
            roles: Array(roles).map(&:to_s), password: password
          }
          declaration[:renamed_from] = renamed_from.to_s unless renamed_from.nil?
          @demo_user_definitions << declaration
        end

        def clear_demo_users! = (@demo_user_definitions = [])

        def remove_user_role(name)
          raise ArgumentError, 'remove_user_role requires a role name' if name.to_s.empty?

          (@removed_user_roles ||= []) << name.to_s
        end

        def remove_demo_user(name)
          raise ArgumentError, 'remove_demo_user requires a user name' if name.to_s.empty?

          (@removed_demo_users ||= []) << name.to_s
        end

        def resolve_security_identities!(identities)
          definition = identities.project_security(
            native_definition, removed_user_roles: Array(@removed_user_roles),
                               removed_demo_users: Array(@removed_demo_users)
          )
          @mendix_id = definition.fetch(:id)
          @user_roles = definition.fetch(:user_roles)
          @demo_user_definitions = definition.fetch(:demo_users)
          @password_policy = definition[:password_policy]
          %i[file_document_access image_access].each do |key|
            @settings[key] = definition[key] if definition.key?(key)
          end
        end

        def password_policy(id: nil, properties: {}, **options, &block)
          values = properties.to_h.merge(options)
          if block
            builder = PasswordPolicyBuilder.new(values)
            builder.evaluate(&block)
            values = builder.properties
          end
          @password_policy = {
            id: id.to_s,
            properties: values.transform_keys(&:to_s)
          }
        end

        def native_definition
          @settings.to_h.merge(
            id: @mendix_id.to_s, user_roles: Array(@user_roles),
            demo_users: Array(@demo_user_definitions), password_policy: @password_policy
          )
        end

        private

        def project_access_rule(kind, roles, options, &block)
          raise ArgumentError, 'project access rule requires at least one module role' if roles.empty?

          values = options.transform_keys(&:to_sym)
          declarations = AccessRuleBuilder.new(values.fetch(:members, []))
          declarations.evaluate(&block) if block
          rule = {
            id: values[:id].to_s, roles: roles.map(&:to_s),
            documentation: values.fetch(:documentation, '').to_s,
            create: values.fetch(:create, false) == true,
            delete: values.fetch(:delete, false) == true,
            default_rights: project_access_right(values.fetch(:default_rights, :None)),
            xpath: values.fetch(:xpath, '').to_s,
            xpath_caption: values[:xpath_caption]&.to_s,
            members: declarations.members.map { project_access_member(_1) }
          }
          rule[:source_identity] = values[:identity].to_s unless values[:identity].nil?
          (@settings[kind] ||= []) << rule
        end

        def project_access_member(member)
          declaration = member.to_h.transform_keys(&:to_sym)
          kind = declaration.fetch(:kind, :attribute).to_sym
          unless %i[attribute association].include?(kind)
            raise ArgumentError, 'access member kind must be attribute or association'
          end

          {
            id: declaration[:id].to_s, name: declaration.fetch(:name).to_s,
            reference: declaration[:reference].to_s,
            rights: project_access_right(declaration.fetch(:rights)), kind:
          }
        end

        def project_access_right(value)
          right = { none: :None, read_only: :ReadOnly, read_write: :ReadWrite }
                  .fetch(value.to_sym, value.to_sym)
          return right if %i[None ReadOnly ReadWrite].include?(right)

          raise ArgumentError, 'access rights must be one of None, ReadOnly, ReadWrite'
        end
      end
    end
    # rubocop:enable Metrics
  end
end
