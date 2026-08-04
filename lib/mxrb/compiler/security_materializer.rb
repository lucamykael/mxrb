# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    SecurityMaterialization = Data.define(:model_path, :metadata_path, :roles)

    # Compiles project-security units into the flattened Runtime model shape.
    class SecurityMaterializer
      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        model_path = File.join(@deployment, 'model', 'model.mdp')
        metadata_path = File.join(@deployment, 'model', 'metadata.json')
        source = source_security
        compiled, role_metadata = compile(source)
        ModelPackage.read(model_path).upsert(compiled).write(model_path)
        write_metadata(metadata_path, source, role_metadata)
        SecurityMaterialization.new(model_path:, metadata_path:, roles: role_metadata.freeze)
      end

      private

      def source_security
        mpr = IO::MprFile.open(@mpr_path, readonly: true)
        document = mpr.all_units.lazy.map { mpr.parse_contents(_1) }
                      .find { _1['$Type'] == 'Security$ProjectSecurity' }
        raise CompilationError, 'MPR has no project security document' unless document

        document
      ensure
        mpr&.close
      end

      def compile(source)
        source_roles = array(source['UserRoles'])
        names = source_roles.map { _1['Name'].to_s }
        roles = source_roles.map { compile_role(_1, names) }
        [compiled_document(source, roles), role_metadata(source_roles, names)]
      end

      def compiled_document(source, roles)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'], 'UserRoles' => roles,
          'DemoUsers' => array(source['DemoUsers']).map { compile_demo_user(_1) },
          'PasswordPolicySettings' => source['PasswordPolicySettings'],
          'SecurityLevel' => source['SecurityLevel'], 'AdminUserName' => source['AdminUserName'],
          'AdminUserRole' => source['AdminUserRole'],
          'EnableDemoUsers' => source['EnableDemoUsers'] == true,
          'EnableGuestAccess' => source['EnableGuestAccess'] == true,
          'GuestUserRole' => source['GuestUserRole'].to_s, 'StrictMode' => source['StrictMode'] == true
        }
      end

      def compile_demo_user(user)
        user.merge('UserRoles' => array(user['UserRoles']).map(&:to_s))
      end

      def compile_role(role, names)
        manageable = role['ManageAllRoles'] == true ? names : array(role['ManageableRoles']).map(&:to_s)
        {
          '$ID' => role['$ID'], '$Type' => role['$Type'], 'GUID' => role['GUID'],
          'Name' => role['Name'], 'Description' => role['Description'].to_s,
          'IsSystemAdministrator' => array(role['ModuleRoles']).include?('System.Administrator'),
          'ManageableRoles' => manageable,
          'ManageUsersWithoutRoles' => role['ManageUsersWithoutRoles'] == true,
          'CheckSecurity' => role['CheckSecurity'] != false
        }
      end

      def role_metadata(roles, names)
        ids = roles.to_h { [_1['Name'].to_s, id(_1['GUID'])] }
        roles.to_h do |role|
          [ids.fetch(role['Name'].to_s), metadata_role(role, names, ids)]
        end
      end

      def metadata_role(role, names, ids)
        manageable = role['ManageAllRoles'] == true ? names : array(role['ManageableRoles']).map(&:to_s)
        resolved = manageable.filter_map { ids[_1] }
        { 'Name' => role['Name'].to_s }.tap do |value|
          value['ManageableRoles'] = resolved unless resolved.empty?
        end
      end

      def write_metadata(path, source, roles)
        metadata = JSON.parse(File.read(path))
        metadata['Roles'] = roles
        admin = roles.find { |_role_id, value| value['Name'] == source['AdminUserRole'] }
        raise CompilationError, "admin role #{source['AdminUserRole'].inspect} is not defined" unless admin

        metadata['AdminRole'] = admin.first
        File.write(path, JSON.pretty_generate(metadata))
      end

      def array(value) = IO::BsonCodec.parse_array(value)[:items]
      def id(value) = IO::BsonCodec.extract_id(value)
    end
  end
end
