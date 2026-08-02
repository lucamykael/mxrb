# frozen_string_literal: true

module Mxrb
  module Compiler
    # Resolves project roles and association security into Runtime fields.
    class DomainSecurityCompiler
      include ModelValues

      def initialize(source)
        @role_map = project_role_map(source)
      end

      def access_rule(source)
        module_roles = array(source['AllowedModuleRoles']).map(&:to_s)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'MemberAccesses' => array(source['MemberAccesses']).map { member_access(_1) },
          'AllowedUserRoles' => module_roles.flat_map { @role_map.fetch(_1, []) }.uniq,
          'AllowCreate' => source['AllowCreate'] == true, 'AllowDelete' => source['AllowDelete'] == true,
          'XPathConstraint' => source['XPathConstraint'].to_s
        }
      end

      def association(source, module_name)
        name = source['Name'].to_s
        result = association_fields(source).merge(
          'QualifiedName' => "#{module_name}.#{name}",
          'UnqualifiedName' => name, 'Navigability' => 'BothDirections'
        )
        child_key = source['$Type'] == 'DomainModels$CrossAssociation' ? 'Child' : 'ChildPointer'
        result.merge(child_key => source[child_key])
      end

      private

      def member_access(source)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Attribute' => source['Attribute'].to_s, 'Association' => source['Association'].to_s,
          'AccessRights' => source['AccessRights']
        }
      end

      def association_fields(source)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'DeleteBehavior' => delete_behavior(source['DeleteBehavior']),
          'Source' => source['Source'], 'GUID' => source['GUID'], 'Type' => source['Type'],
          'Owner' => source['Owner'], 'StorageFormat' => source['StorageFormat'],
          'ParentPointer' => source['ParentPointer']
        }
      end

      def delete_behavior(source)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'ParentErrorMessage' => text_reference(source['ParentErrorMessage']),
          'ChildErrorMessage' => text_reference(source['ChildErrorMessage']),
          'ParentDeleteBehavior' => runtime_delete_behavior(source['ParentDeleteBehavior']),
          'ChildDeleteBehavior' => runtime_delete_behavior(source['ChildDeleteBehavior'])
        }
      end

      def text_reference(source)
        source&.slice('$ID', '$Type')
      end

      def runtime_delete_behavior(value)
        value == 'NoAction' ? 'DeleteMeAndReferences' : value
      end

      def project_role_map(source)
        security = source.documents('Security$ProjectSecurity').first
        return {} unless security

        array(security['UserRoles']).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |role, map|
          array(role['ModuleRoles']).each { |module_role| map[module_role.to_s] << role['Name'].to_s }
        end
      end
    end
  end
end
