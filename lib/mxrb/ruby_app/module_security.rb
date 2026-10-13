# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Authoritative module-role collection with stable Mendix identities.
    class ModuleSecurity
      class << self
        attr_reader :mendix_id, :roles

        def inherited(child)
          super
          child.instance_variable_set(:@roles, [])
          child.instance_variable_set(:@removed_roles, [])
        end

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :module_security, @mendix_name, id:)
          Registry.register(:module_security, @mendix_name, self)
        end

        def module_role(name, id: nil, description: '', renamed_from: nil)
          @roles ||= []
          declaration = { name: name.to_s, id: id.to_s, description: description.to_s }
          declaration[:renamed_from] = renamed_from.to_s unless renamed_from.nil?
          @roles << declaration
        end

        def clear_module_roles! = (@roles = [])

        def remove_module_role(name)
          raise ArgumentError, 'remove_module_role requires a role name' if name.to_s.empty?

          (@removed_roles ||= []) << name.to_s
        end

        def resolve_security_identities!(identities)
          definition = identities.module_security(native_definition, removed_roles: Array(@removed_roles))
          @mendix_id = definition.fetch(:id)
          @roles = definition.fetch(:roles)
        end

        def native_definition
          { module_name: @mendix_name.to_s, id: @mendix_id.to_s, roles: Array(@roles) }
        end
      end
    end
  end
end
