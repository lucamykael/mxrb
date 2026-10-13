# frozen_string_literal: true

module Mxrb
  module Dsl
    class FlowBuilder # rubocop:disable Metrics/ClassLength
      include FlowBodyDsl
      attr_reader :expected_body_fingerprint

      def initialize(name, runtime:, kind:, public:, unit_id: nil, metadata: nil)
        @metadata             = metadata || {}
        @name                 = name.to_s
        @unit_id              = (unit_id || @metadata['unit_id'])&.to_s
        @runtime              = runtime
        @kind                 = kind
        @public               = public
        @parameters           = []
        @return_type          = nil
        @doc                  = ''
        @calls                = []
        @repositories         = []
        @allowed_roles        = nil
        @body                 = nil
        @return_variable_name = nil
        @return_expression    = nil
        @expected_body_fingerprint = @metadata['body_fingerprint']&.to_s
        @allow_concurrent_execution = nil
        @apply_entity_access = nil
        @mark_as_used = nil
        @excluded = nil
        @annotations_authoritative = false
        @return_node_ref = nil
      end

      def parameter(name, type:, id: nil, relative_middle_point: nil, size: nil)
        metadata = Array(@metadata['parameters']).find { _1['name'].to_s == name.to_s } || {}
        type = type.merge('$ID' => metadata['type_id']) \
          if type.is_a?(Hash) && metadata['type_id'].to_s != ''
        @parameters << {
          name: name.to_s, type: type.is_a?(Hash) ? type : type.to_s,
          id: (id || metadata['id'])&.to_s,
          relative_middle_point: (relative_middle_point || metadata['relative_middle_point'])&.to_s,
          size: (size || metadata['size'])&.to_s
        }.compact
      end

      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype.to_sym)
      end

      def flow_type(value)
        spec = value.to_h.transform_keys(&:to_sym)
        kind = spec.fetch(:kind).to_sym
        kind = :datetime if %i[DateTime date_time].include?(kind)
        native = {
          void: 'Void', boolean: 'Boolean', string: 'String', integer: 'Integer',
          long: 'Integer', decimal: 'Decimal', float: 'Float', datetime: 'DateTime',
          object: 'Object', list: 'List', enumeration: 'Enumeration'
        }.fetch(kind) { raise ArgumentError, "unsupported flow data type #{kind.inspect}" }
        document = {
          '$ID' => spec[:id].to_s.empty? ? SecureRandom.uuid : spec[:id].to_s,
          '$Type' => "DataTypes$#{native}Type"
        }
        document['Entity'] = spec.fetch(:entity, '').to_s if %i[object list].include?(kind)
        document['Enumeration'] = spec.fetch(:enumeration).to_s if kind == :enumeration
        document
      end

      def object_of(entity, id: nil)
        flow_type({ kind: :object, entity:, id: })
      end

      def list_of(entity, id: nil)
        flow_type({ kind: :list, entity:, id: })
      end

      def enum_of(enumeration, id: nil)
        flow_type({ kind: :enumeration, enumeration:, id: })
      end

      def return_type(type)
        if type.is_a?(Hash) && @metadata['return_type_id'].to_s != ''
          type = type.merge('$ID' => @metadata['return_type_id'])
        end
        @return_type = type.is_a?(Hash) ? type : type.to_s
      end

      def documentation(d) = (@doc = d)
      def allow_concurrent_execution(value = true) = (@allow_concurrent_execution = !!value)
      def apply_entity_access(value = true) = (@apply_entity_access = !!value)
      def mark_as_used(value = true) = (@mark_as_used = !!value)
      def excluded(value = true) = (@excluded = !!value)

      def annotations_authoritative(value = true)
        @annotations_authoritative = value == true
        @body ||= []
      end

      def allowed_roles(*roles)
        @allowed_roles = roles.map(&:to_s)
      end

      def call(microflow: nil, nanoflow: nil)
        choices = { microflow: microflow, nanoflow: nanoflow }.compact
        raise ArgumentError, 'call requires exactly one target' unless choices.size == 1

        @calls << { kind: choices.keys.first, name: choices.values.first.to_s }
      end

      def uses_repository(name)
        @repositories << name.to_s
      end

      def rescue_all(&block)
        rb = RescueBuilder.new(allow_break: false)
        rb.instance_eval(&block) if block
        _acts << { type: :rescue_all, activities: rb.activities }
      end

      def return_value(var)
        if var.is_a?(Symbol)
          @return_variable_name = var.to_s
          @return_expression = "$#{var}"
        else
          @return_expression = var.to_s
        end
      end

      def return_node(reference)
        value = reference.to_s
        raise ArgumentError, 'return node reference cannot be empty' if value.empty?

        @return_node_ref = value
      end

      def body_fingerprint(value)
        @expected_body_fingerprint = value.to_s
      end

      def self.body_digest(body, return_expression)
        payload = canonical_body_value([body, return_expression])
        Digest::SHA256.hexdigest(JSON.generate(payload))
      end

      def self.canonical_body_value(value)
        case value
        when Hash
          value.keys.sort_by(&:to_s).to_h do |key|
            [key.to_s, canonical_body_value(value[key])]
          end
        when Array
          value.map { canonical_body_value(_1) }
        when Symbol
          { '__symbol__' => value.to_s }
        else
          value
        end
      end

      def to_h
        current_fingerprint = self.class.body_digest(@body, @return_expression)
        {
          name: @name, runtime: @runtime, kind: @kind, public: @public,
          parameters: @parameters, return_type: @return_type, documentation: @doc,
          calls: @calls, repositories: @repositories, allowed_roles: @allowed_roles,
          body: @body, return_variable_name: @return_variable_name,
          return_expression: @return_expression, return_node_ref: @return_node_ref,
          allow_concurrent_execution: @allow_concurrent_execution,
          apply_entity_access: @apply_entity_access,
          mark_as_used: @mark_as_used, excluded: @excluded,
          annotations_authoritative: @annotations_authoritative || body_contains_annotation?(@body),
          annotation_flows_authoritative: body_contains_annotation_flow?(@body),
          preserve_native_body: !@expected_body_fingerprint.nil? &&
            @expected_body_fingerprint == current_fingerprint
        }.tap { _1[:unit_id] = @unit_id unless @unit_id.nil? }
      end

      private

      def body_contains_annotation?(activities)
        Array(activities).any? do |activity|
          activity[:type] == :annotation ||
            body_contains_annotation?(activity[:activities]) ||
            body_contains_annotation?(activity[:true_branch]) ||
            body_contains_annotation?(activity[:false_branch]) ||
            activity.fetch(:branches, {}).values.any? { body_contains_annotation?(_1) }
        end
      end

      def body_contains_annotation_flow?(activities)
        Array(activities).any? do |activity|
          activity[:type] == :annotation_flow ||
            body_contains_annotation_flow?(activity[:activities]) ||
            body_contains_annotation_flow?(activity[:true_branch]) ||
            body_contains_annotation_flow?(activity[:false_branch]) ||
            activity.fetch(:branches, {}).values.any? { body_contains_annotation_flow?(_1) }
        end
      end

      def _acts = (@body ||= [])
    end

    class DecisionBuilder
      def initialize(condition, allow_break: false)
        @condition      = condition
        @allow_break    = allow_break
        @true_branch    = []
        @false_branch   = []
        @branches       = {}
      end

      def on(value, &block)
        bb = BranchBuilder.new(allow_break: @allow_break)
        bb.instance_eval(&block) if block
        case value
        when true  then @true_branch  = bb.activities
        when false then @false_branch = bb.activities
        end
        @branches[value] = bb.activities
      end

      def to_h
        { type: :decision, condition: @condition,
          true_branch: @true_branch, false_branch: @false_branch,
          branches: @branches }
      end
    end

    # Rule conditions share the ordinary branch DSL and preserve ordered
    # argument mappings, including repeated parameter names from native flows.
    class RuleDecisionBuilder < DecisionBuilder
      def initialize(rule, allow_break: false)
        super({ rule: rule.to_s.dup.freeze, pass: {} }, allow_break:)
        @arguments = []
      end

      def argument(parameter, value)
        value = value.dup.freeze if value.is_a?(String)
        @arguments << [parameter.to_s.dup.freeze, value].freeze
      end

      def to_h
        mappings = if @arguments.map(&:first).uniq.size == @arguments.size
                     @arguments.to_h.freeze
                   else
                     @arguments.dup.freeze
                   end
        snapshot(super.merge(condition: @condition.merge(pass: mappings)))
      end

      private

      def snapshot(value)
        case value
        when Hash then value.to_h { |key, child| [snapshot(key), snapshot(child)] }.freeze
        when Array then value.map { snapshot(_1) }.freeze
        when String then value.dup.freeze
        else value
        end
      end
    end

    class BranchBuilder
      include FlowBodyDsl
      attr_reader :activities

      def initialize(allow_break: false)
        @allow_break = allow_break
        @activities = []
      end

      private

      def _acts = @activities
      def _break_allowed? = @allow_break
    end

    class TypeDecisionBuilder
      def initialize(variable, allow_break: false)
        @variable = variable
        @allow_break = allow_break
        @branches = {}
      end

      def on_type(type, &block)
        add_branch(type.to_s, &block)
      end

      def otherwise(&block)
        add_branch('', &block)
      end

      def to_h
        { type: :inheritance_decision, variable: @variable, branches: @branches }
      end

      private

      def add_branch(value, &block)
        branch = BranchBuilder.new(allow_break: @allow_break)
        branch.instance_eval(&block) if block
        @branches[value] = branch.activities
      end
    end

    class LoopBuilder
      include FlowBodyDsl

      def initialize(variable, as:)
        @variable   = variable
        @iterator   = as
        @activities = []
      end

      def to_h
        { type: :loop_over, variable: @variable, iterator: @iterator, activities: @activities }
      end

      private

      def _acts = @activities
      def _break_allowed? = true
    end

    class RescueBuilder
      include FlowBodyDsl
      attr_reader :activities

      def initialize(allow_break: false)
        @allow_break = allow_break
        @activities = []
      end

      private

      def _acts = @activities
      def _break_allowed? = @allow_break
    end

    class SetBuilder
      attr_reader :members

      def initialize
        @members = []
      end

      def set(attribute, to:)
        @members << { attribute: attribute.to_s, value: to }
      end

      def set_association(association, to:, operation: :set)
        @members << {
          association: association.to_s, value: to,
          operation: operation.to_s
        }
      end
    end

    MicroflowBuilder = FlowBuilder
  end
end
