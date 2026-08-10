# frozen_string_literal: true

require_relative '../io/bson_codec'

# Public authorization calls intentionally accept complete security contexts,
# and the XPath interpreter is clearer as small decision-oriented methods.
# rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
# rubocop:disable Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity

module Mxrb
  module Runtime
    class AuthorizationError < StandardError; end

    # Explicit security context used by the pure-Ruby runtime. User roles are
    # expanded to module roles by AccessControl; callers may also supply module
    # roles directly for system-to-system execution.
    class SecurityContext
      attr_reader :user, :user_roles, :module_roles, :attributes, :variables

      def initialize(user: nil, roles: [], user_roles: nil, module_roles: [],
                     attributes: {}, variables: {})
        @user = user
        @user_roles = strings(user_roles || roles)
        @module_roles = strings(module_roles)
        @attributes = attributes.to_h.freeze
        @variables = variables.to_h.freeze
      end

      def roles = @user_roles

      private

      def strings(values) = Array(values).map(&:to_s).reject(&:empty?).uniq.freeze
    end

    # Enforces Mendix project, document, entity, and member access rules.
    # Unsupported XPath constructs are never treated as a successful match.
    class AccessControl # rubocop:disable Metrics/ClassLength
      RIGHTS = {
        'none' => :none,
        'readonly' => :read,
        'readwrite' => :write
      }.freeze
      attr_reader :project, :security_level

      def initialize(project)
        @project = project
        @security = project_security
        @security_level = value(@security, 'SecurityLevel').to_s
        @role_map, @admin_roles = build_role_map
      end

      def security_enabled?
        !@security.nil? && !%w[CheckNothing Off None].include?(@security_level)
      end

      def context(user: nil, roles: [], user_roles: nil, module_roles: [],
                  attributes: {}, variables: {})
        supplied = SecurityContext.new(
          user:, roles:, user_roles:, module_roles:, attributes:, variables:
        )
        expanded = supplied.user_roles.flat_map { @role_map.fetch(_1, []) }
        SecurityContext.new(
          user: supplied.user, user_roles: supplied.user_roles,
          module_roles: supplied.module_roles + expanded,
          attributes: supplied.attributes, variables: supplied.variables
        )
      end

      def admin?(context)
        !(normalized_context(context).user_roles & @admin_roles).empty?
      end

      def microflow_allowed?(microflow, context:)
        document_allowed?(:microflow, microflow, context:)
      end

      def page_allowed?(page, context:)
        document_allowed?(:page, page, context:)
      end

      def entity_allowed?(entity, action:, context:, member: nil, record: nil)
        entity = resolve(:entity, entity)
        return false unless entity

        ctx = normalized_context(context)
        return true unless security_enabled?
        return true if admin?(ctx)

        rules = applicable_rules(entity, ctx, record:)
        return false if rules.empty?

        entity_action_allowed?(rules, action, member)
      end

      def member_allowed?(entity, member, action:, context:, record: nil)
        entity_allowed?(entity, action:, context:, member:, record:)
      end

      def authorized?(resource, action:, context:, kind: nil, member: nil, record: nil)
        inferred_kind = kind || resource_kind(resource)
        case inferred_kind&.to_sym
        when :microflow then microflow_allowed?(resource, context:)
        when :page then page_allowed?(resource, context:)
        when :entity
          entity_allowed?(resource, action:, context:, member:, record:)
        else
          false
        end
      end

      def authorize!(resource, action:, context:, kind: nil, member: nil, record: nil)
        return true if authorized?(resource, action:, context:, kind:, member:, record:)

        name = resource.respond_to?(:name) ? resource.name : resource
        raise AuthorizationError, "not authorized to #{action} #{name}"
      end

      # Returns the constraints contributed by roles in the context. An empty
      # string is a valid unconstrained rule and therefore remains in the list.
      def xpath_constraints(entity, context:)
        entity = resolve(:entity, entity)
        return [] unless entity

        applicable_rules(entity, normalized_context(context), evaluate_xpath: false)
          .map { value(_1, :xpath, 'XPathConstraint').to_s }.uniq.freeze
      end

      def filter_readable(entity, records, context:)
        Array(records).select do |record|
          entity_allowed?(entity, action: :read, context:, record:)
        end
      end

      # Evaluates the deliberately small, safe XPath subset understood by the
      # runtime. nil means that the expression is unsupported.
      def evaluate_xpath(expression, record:, context:)
        source = expression.to_s.strip
        return true if source.empty?

        source = source[1...-1].strip if source.start_with?('[') && source.end_with?(']')
        evaluate_boolean(source, record, normalized_context(context))
      end

      private

      def normalized_context(context)
        if context.is_a?(Hash)
          keys = context.to_h { |key, item| [key.to_sym, item] }
          return self.context(**keys)
        end
        return context unless context.is_a?(SecurityContext)

        expanded = context.user_roles.flat_map { @role_map.fetch(_1, []) }
        return context if (expanded - context.module_roles).empty?

        SecurityContext.new(
          user: context.user, user_roles: context.user_roles,
          module_roles: context.module_roles + expanded,
          attributes: context.attributes, variables: context.variables
        )
      end

      def project_security
        raw = @project.all_units.find do |unit|
          value(@project.parse_bson(unit), '$Type') == 'Security$ProjectSecurity'
        rescue StandardError
          false
        end
        raw && @project.parse_bson(raw)
      rescue NoMethodError
        nil
      end

      def build_role_map
        roles = parse_array(value(@security, 'UserRoles'))
        map = roles.to_h do |role|
          [value(role, 'Name').to_s, parse_array(value(role, 'ModuleRoles')).map(&:to_s)]
        end
        admins = roles.filter_map do |role|
          name = value(role, 'Name').to_s
          configured = name == value(@security, 'AdminUserRole').to_s
          name if configured || value(role, 'ManageAllRoles') == true
        end
        [map.freeze, admins.freeze]
      end

      def document_allowed?(kind, resource, context:)
        artifact = resolve(kind, resource)
        return false unless artifact

        ctx = normalized_context(context)
        return true unless security_enabled?
        return true if admin?(ctx)

        allowed = Array(artifact.allowed_module_roles).map(&:to_s)
        !allowed.empty? && !(allowed & ctx.module_roles).empty?
      end

      def applicable_rules(entity, context, record: nil, evaluate_xpath: true)
        Array(entity.access_rules).select do |rule|
          roles = Array(value(rule, :roles, 'AllowedModuleRoles', 'ModuleRoles')).map(&:to_s)
          next false if roles.empty? || (roles & context.module_roles).empty?
          next true unless evaluate_xpath && record

          evaluate_xpath(value(rule, :xpath, 'XPathConstraint'), record:, context:) == true
        end
      end

      def entity_action_allowed?(rules, action, member)
        case action.to_sym
        when :create then rules.any? { value(_1, :create, 'AllowCreate') == true }
        when :delete then rules.any? { value(_1, :delete, 'AllowDelete') == true }
        when :read, :retrieve
          member ? rules.any? { member_right(_1, member) != :none } : true
        when :write, :update
          if member
            rules.any? { member_right(_1, member) == :write }
          else
            rules.any? { writable_rule?(_1) }
          end
        else false
        end
      end

      def writable_rule?(rule)
        return true if right(value(rule, :default_rights, 'DefaultMemberAccessRights')) == :write

        Array(value(rule, :members, 'MemberAccesses')).any? do |member|
          right(value(member, :rights, 'AccessRights')) == :write
        end
      end

      def member_right(rule, member_name)
        name = member_name.respond_to?(:name) ? member_name.name.to_s : member_name.to_s
        override = Array(value(rule, :members, 'MemberAccesses')).find do |entry|
          reference = value(entry, :name, :reference, 'Attribute', 'Association').to_s
          reference == name || reference.split(%r{[/.]}).last == name
        end
        right(override ? value(override, :rights,
                               'AccessRights') : value(rule, :default_rights, 'DefaultMemberAccessRights'))
      end

      def right(raw) = RIGHTS.fetch(raw.to_s.downcase, :none)

      def resource_kind(resource)
        name = resource.class.name.to_s
        return :microflow if name.end_with?('Microflow')
        return :page if name.end_with?('Page')
        return :entity if name.end_with?('Entity')

        nil
      end

      def resolve(kind, resource)
        return resource unless resource.is_a?(String) || resource.is_a?(Symbol)

        name = resource.to_s
        matches = resource_catalog(kind).select do |qualified, artifact|
          qualified == name || artifact.name.to_s == name
        end
        matches.size == 1 ? matches.first.last : nil
      end

      def resource_catalog(kind)
        @resource_catalog ||= {}
        @resource_catalog[kind] ||= @project.modules.flat_map do |mod|
          collection = kind == :entity ? mod.entities : mod.public_send("#{kind}s")
          collection.map do |artifact|
            qualified = if artifact.respond_to?(:qualified_name) && artifact.qualified_name
                          artifact.qualified_name.to_s
                        else
                          "#{mod.name}.#{artifact.name}"
                        end
            [qualified, artifact]
          end
        end
      end

      def evaluate_boolean(source, record, context)
        expression = strip_parentheses(source.strip)
        parts = split_logical(expression, 'or')
        return combine(parts, record, context, :or) if parts.size > 1

        parts = split_logical(expression, 'and')
        return combine(parts, record, context, :and) if parts.size > 1

        return true if expression.match?(/\Atrue\(\)\z/i)
        return false if expression.match?(/\Afalse\(\)\z/i)

        if (match = expression.match(/\Anot\s*\((.*)\)\z/im))
          result = evaluate_boolean(match[1], record, context)
          return result.nil? ? nil : !result
        end

        comparison(expression, record, context)
      end

      def combine(parts, record, context, operator)
        values = parts.map { evaluate_boolean(_1, record, context) }
        return values.any?(true) if operator == :or && values.none?(&:nil?)
        return values.all?(true) if operator == :and && values.none?(&:nil?)

        nil
      end

      def comparison(expression, record, context)
        match = expression.match(/\A(.+?)\s*(>=|<=|!=|=|>|<)\s*(.+)\z/m)
        return nil unless match

        left = operand(match[1], record, context, record_side: true)
        right = operand(match[3], record, context, record_side: false)
        return nil if left.equal?(:unsupported) || right.equal?(:unsupported)

        case match[2]
        when '=' then left == right
        when '!=' then left != right
        when '>' then left && right && left > right
        when '<' then left && right && left < right
        when '>=' then left && right && left >= right
        when '<=' then left && right && left <= right
        end
      rescue ArgumentError
        false
      end

      def operand(source, record, context, record_side:)
        token = source.strip
        return token[1...-1].gsub("''", "'") if token.start_with?("'") && token.end_with?("'")
        return true if token.match?(/\Atrue\(\)\z/i)
        return false if token.match?(/\Afalse\(\)\z/i)
        return nil if token.match?(/\A(empty|null)\z/i)
        return token.to_f if token.match?(/\A-?\d+\.\d+\z/)
        return token.to_i if token.match?(/\A-?\d+\z/)
        return user_identity(context.user) if token == '[%CurrentUser%]'
        return variable(token.delete_prefix('$'), context) if token.start_with?('$')
        return lookup(record, token) if record_side

        :unsupported
      end

      def variable(name, context)
        return user_identity(context.user) if name.match?(/\Acurrentuser\z/i)

        found, result = lookup_with_presence(context.variables, name)
        found ? result : :unsupported
      end

      def user_identity(user)
        return nil if user.nil?

        if user.respond_to?(:key?)
          return user['id'] if user.key?('id')
          return user[:id] if user.key?(:id)
          return user['name'] if user.key?('name')
          return user[:name] if user.key?(:name)
        end
        return user.id if user.respond_to?(:id)

        user
      end

      def lookup(record, path)
        found, result = lookup_with_presence(record, path)
        found ? result : :unsupported
      end

      def lookup_with_presence(object, path)
        object = object.members if object.respond_to?(:members)
        candidates = [path, path.split(%r{[/.]}).last].uniq
        candidates.each do |candidate|
          if object.respond_to?(:key?)
            return [true, object[candidate]] if object.key?(candidate)

            symbol = candidate.to_sym
            return [true, object[symbol]] if object.key?(symbol)
          end
          return [true, object.public_send(candidate)] if object.respond_to?(candidate)
        end
        [false, nil]
      end

      def split_logical(source, operator)
        source.split(/\s+#{operator}\s+/i)
      end

      def strip_parentheses(source)
        source = source[1...-1].strip while source.start_with?('(') && source.end_with?(')')
        source
      end

      def parse_array(raw)
        Mxrb::IO::BsonCodec.parse_array(raw)[:items]
      rescue TypeError
        Array(raw)
      end

      def value(hash, *keys)
        return nil unless hash.respond_to?(:key?)

        keys.each { return hash[_1] if hash.key?(_1) }
        nil
      end
    end
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
# rubocop:enable Metrics/MethodLength, Metrics/ParameterLists, Metrics/PerceivedComplexity
