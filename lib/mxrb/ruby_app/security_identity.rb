# frozen_string_literal: true

require_relative 'member_identity'

module Mxrb
  module RubyApp
    # Security declarations remain authoritative. The private manifest supplies
    # identities only: never permissions, passwords, settings or collection order.
    # Call after loading the complete declarations, before assigning any result.
    class SecurityIdentity
      def initialize(manifest)
        @modules = manifest.modules
        @project = manifest.data['security']
      end

      def module_security(definition, removed_roles: [])
        previous = module_baseline(definition)
        roles = members(previous, 'roles', definition.fetch(:roles), removed_roles)
        definition.merge(
          id: identity(definition[:id], previous && previous['id'], 'module security'),
          roles:
        )
      end

      def project_security(definition, removed_user_roles: [], removed_demo_users: [])
        previous = @project
        identifier = identity(definition[:id], previous && previous.fetch('id'), 'project security')
        roles = members(previous, 'user_roles', definition.fetch(:user_roles), removed_user_roles)
        users = members(previous, 'demo_users', definition.fetch(:demo_users), removed_demo_users)
        roles = resolve_role_guids(roles, previous)
        result = definition.merge(id: identifier, user_roles: roles, demo_users: users)
        return result unless definition.key?(:password_policy) && definition[:password_policy]

        # Nil still means an explicit removal, and an absent declaration stays
        # absent. Resolve only the identity of a policy actually declared.
        if previous && !previous.key?('password_policy')
          raise ValidationError, 'existing project security requires its password policy identity baseline'
        end

        prior_policy = previous && previous['password_policy']
        policy = definition.fetch(:password_policy)
        result.merge(password_policy: policy.merge(
          id: identity(policy[:id], prior_policy && prior_policy.fetch('id'), 'password policy')
        ))
      end

      private

      def module_baseline(definition)
        identifier = definition[:id].to_s
        name = definition.fetch(:module_name).to_s
        by_id = if identifier.empty?
                  []
                else
                  @modules.select { _1['module_security'].to_h['id'].to_s == identifier }
                end
        matches = by_id.empty? ? @modules.select { _1.fetch('name').to_s == name } : by_id
        raise ValidationError, 'ambiguous private module security identity' if matches.size > 1
        return nil if matches.empty?

        mod = matches.first
        previous = mod['module_security']
        unless previous.is_a?(Hash)
          raise ValidationError, "existing module #{mod.fetch('name')} requires its security identity baseline"
        end

        # A supplied ID must not turn an existing same-name artifact into a new
        # artifact. SourceIdentity handles moved/renamed documents by their ID.
        identity(identifier, previous.fetch('id'), 'module security')
        previous
      end

      def members(previous, collection, declarations, removed)
        baseline = if previous
                     value = previous[collection]
                     unless value.is_a?(Array)
                       raise ValidationError, "existing security requires its #{collection} identity baseline"
                     end

                     value
                   else
                     []
                   end
        MemberIdentity.resolve(previous: baseline, declarations:, removed:)
      rescue ValidationError => e
        # MemberIdentity is shared with enumerations; name the corresponding
        # security removal operation without changing its matching rules.
        removal = { 'roles' => 'remove_module_role', 'user_roles' => 'remove_user_role',
                    'demo_users' => 'remove_demo_user' }.fetch(collection)
        raise ValidationError, e.message.sub('remove_value', removal)
      end

      def resolve_role_guids(roles, previous)
        return roles unless previous

        by_id = previous.fetch('user_roles').to_h { [_1.fetch('id').to_s, _1] }
        roles.map do |role|
          prior = by_id[role[:id].to_s]
          next role unless prior

          role.merge(guid: identity(role[:guid], prior.fetch('guid', ''), 'project role GUID'))
        end
      end

      def identity(supplied, previous, label)
        explicit = supplied.to_s
        baseline = previous.to_s
        if !explicit.empty? && !baseline.empty? && explicit != baseline
          raise ValidationError, "native identity mismatch for #{label}: expected #{baseline}, received #{explicit}"
        end

        explicit.empty? ? baseline : explicit
      end
    end
  end
end
