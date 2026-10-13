# frozen_string_literal: true

module Mxrb
  module Dsl
    # Validates project-security references that cross DSL builders.
    class SecurityValidator
      def initialize(modules, security)
        @modules = modules
        @security = security
      end

      def validate!
        return unless @security

        errors = demo_users.flat_map { reference_errors(_1) }
        duplicates = demo_users.group_by { _1.fetch(:name) }.select { |_name, users| users.size > 1 }
        errors << "duplicate demo user name(s): #{duplicates.keys.join(', ')}" unless duplicates.empty?
        return if errors.empty?

        raise ValidationError, "security validation failed:\n- #{errors.join("\n- ")}"
      end

      private

      def demo_users = Array(@security[:demo_users])

      def reference_errors(user)
        errors = []
        missing_roles = user.fetch(:roles) - user_roles
        errors << "demo user #{user[:name]} references missing user role(s): #{missing_roles.join(', ')}" unless
          missing_roles.empty?
        entity = user.fetch(:entity)
        errors << "demo user #{user[:name]} references missing user entity #{entity}" unless
          entity == 'System.User' || entities.include?(entity)
        errors
      end

      def user_roles = @security.fetch(:user_roles, []).map { _1.fetch(:name) }

      def entities
        @modules.flat_map do |mod|
          definition = mod.to_h
          definition.fetch(:entities, []).map { "#{definition.fetch(:name)}.#{_1.fetch(:name)}" }
        end
      end
    end

    class SecurityBuilder # rubocop:disable Metrics/ClassLength
      def initialize
        @user_roles = []
        @demo_users = []
        @demo_users_declared = false
        @security_level = nil
        @check_security = nil
        @strict_page_url_check = nil
        @admin_user_name = nil
        @admin_password = nil
        @admin_user_role = nil
        @demo_users_enabled = nil
        @guest_access_enabled = nil
        @guest_user_role = nil
        @sign_in_microflow = nil
        @strict_mode = nil
        @password_policy = nil
        @password_policy_id = nil
        @file_document_access = nil
        @image_access = nil
        @id = nil
      end

      def mendix_id(value) = (@id = value.to_s)

      # Mendix stores the project security mode as an enum-like string such as
      # "CheckNothing" or "CheckEverything". Keep the native value explicit so
      # export/import does not silently weaken project security.
      def security_level(value)
        @security_level = value.to_s
      end

      def check_security(value = true) = (@check_security = value == true)
      def strict_page_url_check(value = true) = (@strict_page_url_check = value == true)
      def strict_mode(value = true) = (@strict_mode = value == true)

      # The administrative password is write-only. Exporters emit the user
      # name but leave the secret in the private native baseline.
      def admin_user(name, password: nil)
        @admin_user_name = name.to_s
        @admin_password = password.to_s unless password.nil?
      end

      def user_role(name, module_roles: [], exact_module_roles: false, admin: false, id: nil, guid: nil,
                    description: '', check_security: true, manageable_roles: [],
                    manage_users_without_roles: false)
        native_roles = Array(module_roles).map(&:to_s)
        unless exact_module_roles || native_roles.any? { _1.start_with?('System.') }
          native_roles << (admin ? 'System.Administrator' : 'System.User')
        end
        @user_roles << {
          name: name.to_s, module_roles: native_roles,
          exact_module_roles: exact_module_roles == true,
          admin: admin, id: id.to_s, guid: guid.to_s,
          description: description.to_s, check_security: check_security == true,
          manageable_roles: Array(manageable_roles).map(&:to_s),
          manage_users_without_roles: manage_users_without_roles == true
        }
      end

      def admin_user_role(name)
        @admin_user_role = name.to_s
      end

      def demo_users(enabled = true)
        @demo_users_enabled = enabled == true
      end

      def demo_user(name, entity:, roles:, password:, id: nil)
        user_name = name.to_s
        entity_name = entity.to_s
        role_names = Array(roles).map(&:to_s).uniq
        secret = password.to_s
        raise ArgumentError, 'demo user name must not be empty' if user_name.empty?
        raise ArgumentError, 'demo user name must not contain whitespace' unless user_name.match?(/\A[^\s]+\z/)
        unless entity_name.match?(/\A[A-Za-z][A-Za-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*\z/)
          raise ArgumentError, 'demo user entity must be qualified as Module.Entity'
        end
        raise ArgumentError, 'demo user requires at least one role' if role_names.empty?
        raise ArgumentError, 'demo user password must not be empty' if secret.empty?

        @demo_users << {
          name: user_name, id: id.to_s, entity: entity_name, roles: role_names, password: secret
        }
        @demo_users_declared = true
        # Declaring a demo user enables demo users unless demo_users false said otherwise.
        @demo_users_enabled = true if @demo_users_enabled.nil?
      end

      def evaluate(path)
        instance_eval(File.read(path), path, 1)
      end

      def evaluate_dir(dir)
        return unless File.directory?(dir)

        Dir[File.join(dir, '*.rb')].sort.each { |path| evaluate(path) }
      end

      def guest_access(enabled = true, role: nil)
        @guest_access_enabled = enabled == true
        @guest_user_role = role&.to_s
      end

      def sign_in_microflow(name)
        @sign_in_microflow = name&.to_s
      end

      def password_policy(id: nil, **options)
        @password_policy_id = id.to_s
        @password_policy = options.transform_keys(&:to_sym)
      end

      def file_document_access_rule(*roles, **options)
        @file_document_access ||= []
        @file_document_access << project_access_rule(roles, options)
      end

      def image_access_rule(*roles, **options)
        @image_access ||= []
        @image_access << project_access_rule(roles, options)
      end

      def clear_file_document_access_rules! = (@file_document_access = [])
      def clear_image_access_rules! = (@image_access = [])

      def to_h
        {
          user_roles: @user_roles,
          demo_users: @demo_users_declared ? @demo_users : nil,
          security_level: @security_level,
          check_security: @check_security,
          strict_page_url_check: @strict_page_url_check,
          admin_user_name: @admin_user_name,
          admin_password: @admin_password,
          admin_user_role: @admin_user_role,
          demo_users_enabled: @demo_users_enabled,
          guest_access_enabled: @guest_access_enabled,
          guest_user_role: @guest_user_role,
          sign_in_microflow: @sign_in_microflow,
          strict_mode: @strict_mode,
          password_policy: @password_policy,
          password_policy_id: @password_policy_id,
          file_document_access: @file_document_access,
          image_access: @image_access,
          id: @id
        }
      end

      private

      def project_access_rule(roles, options)
        values = options.transform_keys(&:to_sym)
        {
          id: values[:id]&.to_s,
          documentation: values.fetch(:documentation, '').to_s,
          roles: roles.map(&:to_s),
          create: values.fetch(:create, false) == true,
          delete: values.fetch(:delete, false) == true,
          default_rights: values.fetch(:default_rights, :None).to_s,
          members: Array(values[:members]).map { _1.to_h.transform_keys(&:to_sym) },
          xpath: values.fetch(:xpath, '').to_s,
          xpath_caption: values[:xpath_caption]&.to_s
        }
      end
    end
  end
end
