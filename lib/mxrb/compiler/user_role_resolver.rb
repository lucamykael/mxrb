# frozen_string_literal: true

module Mxrb
  module Compiler
    # The project's user roles that hold given module roles, in the order the
    # project security lists them, which is the order MxBuild writes allowed
    # user roles in.
    class UserRoleResolver
      include ModelValues

      # The user roles of the project the System module seed was built from, by
      # the System module role each one held.
      SEED_ROLES = { 'Administrator' => 'System.Administrator', 'User' => 'System.User' }.freeze

      def initialize(source)
        security = source.respond_to?(:documents) ? source.documents('Security$ProjectSecurity').first : nil
        @roles = array(security&.fetch('UserRoles', nil)).map do |role|
          [role['Name'].to_s, array(role['ModuleRoles']).map(&:to_s)]
        end
      end

      def resolve(module_roles)
        wanted = Array(module_roles).map(&:to_s)
        @roles.filter_map { |name, held| name if held.intersect?(wanted) }
      end

      # The project's user roles for the roles a seeded System document names.
      def resolve_seed(seed_roles)
        resolve(Array(seed_roles).map { SEED_ROLES.fetch(_1.to_s, _1.to_s) })
      end
    end
  end
end
