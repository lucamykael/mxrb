# frozen_string_literal: true

require 'bigdecimal'
require_relative 'catalog'
require_relative '../forms/node'

module Mxrb
  module Pluggable
    Assignment = Data.define(:property, :value, :source_variable) do
      def initialize(property:, value:, source_variable: nil)
        super
      end
    end
    Reference = Data.define(:kind, :target)
    Decimal = Data.define(:value) do
      def self.coerce(value) = new(BigDecimal(value.to_s).to_s('F').freeze)
      def to_s = value
    end
    XPathSource = Data.define(
      :entity, :constraint, :sort_bar, :source_variable, :force_full_objects
    )

    class XPathSourceBuilder
      def initialize
        @force_full_objects = false
      end

      def entity(value = nil)
        return @entity if value.nil?

        @entity = Forms::EntityReference.coerce(value)
      end

      def constraint(value = nil)
        return @constraint if value.nil?

        @constraint = Forms::XPathConstraint.coerce(value)
      end

      def force_full_objects(value = nil)
        return @force_full_objects if value.nil?

        @force_full_objects = !!value
      end

      def sort_bar(type = 'GridSortBar', &block)
        return @sort_bar unless block

        @sort_bar = Forms::Node.build(type, &block)
      end

      def source_variable(type = 'PageVariable', &block)
        return @source_variable unless block

        @source_variable = Forms::Node.build(type, &block)
      end

      def build
        XPathSource.new(@entity, @constraint, @sort_bar, @source_variable, @force_full_objects)
      end
    end

    # Values for one WidgetObject, checked against its embedded MPK schema.
    class ObjectNode
      VALUE_UNSET = Object.new.freeze

      attr_reader :schema

      def initialize(schema)
        raise TypeError, 'expected Pluggable::ObjectType' unless schema.is_a?(ObjectType)

        @schema = schema
        @assignments = []
      end

      def assignments = @assignments.dup.freeze
      def fetch(identifier) = assignment(identifier)&.value

      def set(identifier, value = VALUE_UNSET, source: assignment(identifier)&.source_variable, type: nil, &block)
        property = schema.fetch_property(identifier)
        value = assignment_value(property, value, type, &block)
        normalized = normalize(property, value)
        validate_source!(source)
        @assignments.reject! { _1.property.key == property.key }
        @assignments << Assignment.new(property, normalized, source)
        self
      end

      def source(identifier, type = 'PageVariable', &block)
        current = assignment(identifier)
        raise ArgumentError, "assign #{identifier} before its source" unless current
        return current.source_variable unless block

        set(identifier, current.value, source: Forms::Node.build(type, &block))
      end

      def append(identifier, value = nil, type: nil, &block)
        property = schema.fetch_property(identifier)
        nested = block ? nested_value(property, type, &block) : value
        current = fetch(property.key)
        current = [] if current.nil?
        raise TypeError, "#{property.key} is not a collection" unless collection?(property)

        set(property.key, [*current, nested])
      end

      def evaluate(&block)
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      end

      def method_missing(name, *arguments, &block)
        property = schema.property(name)
        return super unless property
        return fetch(property.key) if arguments.empty? && !block

        if block
          return append(property.key, type: arguments.first, &block) if collection?(property)

          return set(property.key, nested_value(property, arguments.first, &block))
        end
        raise ArgumentError, "#{property.key} expects exactly one value" unless arguments.length == 1

        set(property.key, arguments.first)
      end

      def respond_to_missing?(name, include_private = false)
        !schema.property(name).nil? || super
      end

      private

      def assignment_value(property, value, type, &block)
        if block
          raise ArgumentError, 'set accepts a value or a nested block, not both' unless value.equal?(VALUE_UNSET)

          return nested_value(property, type, &block)
        end
        if value.equal?(VALUE_UNSET) || type
          raise ArgumentError, 'set requires a value, or a nested block with an optional type'
        end

        value
      end

      def validate_source!(source)
        return if source.nil?
        return if source.is_a?(Forms::Node) && source.schema_type.name == 'PageVariable'

        raise TypeError, 'property source must be a Forms::PageVariable'
      end

      def assignment(identifier)
        property = schema.fetch_property(identifier)
        @assignments.find { _1.property.key == property.key }
      end

      def collection?(property)
        property.value_type.widgets? ||
          (property.value_type.object? && property.value_type.list?)
      end

      def nested_value(property, explicit_type, &block)
        value_type = property.value_type
        if value_type.kind == 'DataSource'
          return Forms::Node.build(explicit_type, &block) if explicit_type

          builder = XPathSourceBuilder.new
          block.arity == 1 ? block.call(builder) : builder.instance_eval(&block)
          return builder.build
        end
        if %w[Action Icon TextTemplate].include?(value_type.kind)
          raise ArgumentError, "#{property.key} requires a Forms type" if explicit_type.nil?

          return Forms::Node.build(explicit_type, &block)
        end
        return ObjectNode.new(value_type.object_type).evaluate(&block) if value_type.object?
        return widget_node(explicit_type, &block) if value_type.widgets?

        raise ArgumentError, "#{property.key} does not accept a nested block"
      end

      def widget_node(type, &block)
        candidate = type.to_s
        if (forms_type = Forms::Catalog.for('11.12.1').type(candidate))
          return Forms::Node.build(forms_type.name, &block)
        end

        Node.build(candidate, &block)
      end

      def normalize(property, value)
        if collection?(property)
          raise TypeError, "#{property.key} requires an Array" unless value.is_a?(Array)

          return value.map { normalize_one(property, _1) }.freeze
        end
        normalize_one(property, value)
      end

      def normalize_one(property, value)
        kind = property.value_type.kind
        # MPK `Required` is an authoring/validation hint, not BSON nullability.
        # Studio stores nil for required values whose controlling property
        # selects another mode (for example a custom header instead of text).
        return nil if value.nil?

        value = coerce_semantic(kind, value)

        valid = case kind
                when 'Boolean' then value.equal?(true) || value.equal?(false)
                when 'Integer' then value.is_a?(Integer)
                when 'Decimal' then value.is_a?(Decimal)
                when 'String', 'Enumeration', 'Selection' then value.is_a?(String) || value.is_a?(Symbol)
                when 'Expression' then value.is_a?(Forms::Expression)
                when 'EntityConstraint' then value.is_a?(Forms::XPathConstraint)
                when 'Attribute' then value.is_a?(Forms::AttributeReference)
                when 'Entity' then value.is_a?(Forms::EntityReference)
                when 'TranslatableString' then value.is_a?(Forms::Text)
                when 'TextTemplate', 'Action', 'Icon' then value.is_a?(Forms::Node)
                when 'Object' then value.is_a?(ObjectNode)
                when 'Widgets' then value.is_a?(Forms::Node) || value.is_a?(Node)
                when 'DataSource' then value.is_a?(XPathSource) || value.is_a?(Forms::Node) || value.nil?
                when 'System' then true
                else value.is_a?(Reference) || value.nil?
                end
        return canonical_scalar(kind, value) if valid

        raise TypeError, "#{property.key} expects #{kind}, got #{value.class}"
      end

      def canonical_scalar(kind, value)
        case kind
        when 'String', 'Enumeration', 'Selection' then value.to_s.freeze
        else value
        end
      end

      def coerce_semantic(kind, value)
        case kind
        when 'Decimal' then Decimal.coerce(value)
        when 'Expression' then Forms::Expression.coerce(value)
        when 'EntityConstraint' then Forms::XPathConstraint.coerce(value)
        when 'Attribute' then Forms::AttributeReference.coerce(value)
        when 'Entity' then Forms::EntityReference.coerce(value)
        when 'TranslatableString' then Forms::Text.coerce(value)
        else value
        end
      end
    end

    # A complete custom-widget instance: standard Forms fields plus a typed
    # WidgetObject. Definition metadata is registry state, not source noise.
    class Node
      OUTER_FIELDS = %i[
        identifier appearance conditional_editability editable label_template
        conditional_visibility tab_index
      ].freeze

      attr_reader :widget_type, :object

      def self.build(widget_id, catalog: Catalog.default, &block)
        new(catalog.fetch(widget_id), catalog:).tap { _1.evaluate(&block) if block }
      end

      def initialize(widget_type, catalog: Catalog.default)
        raise TypeError, 'expected Pluggable::WidgetType' unless widget_type.is_a?(WidgetType)

        @widget_type = widget_type
        @catalog = catalog
        @object = ObjectNode.new(widget_type.object_type)
        @outer = {}
      end

      def evaluate(&block)
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      end

      def properties(&block)
        return object unless block

        object.evaluate(&block)
        self
      end

      OUTER_FIELDS.each do |field|
        define_method(field) do |*values, &block|
          return @outer[field] if values.empty? && !block
          raise ArgumentError, "#{field} expects one value" if values.size > 1

          value = if block
                    type = values.first || outer_forms_type(field)
                    Forms::Node.build(type, &block)
                  else
                    values.first
                  end
          @outer[field] = normalize_outer(field, value)
          self
        end
      end

      def assigned_outer = @outer.dup.freeze

      private

      def outer_forms_type(field)
        {
          appearance: 'Appearance', conditional_editability: 'ConditionalEditabilitySettings',
          label_template: 'ClientTemplate', conditional_visibility: 'ConditionalVisibilitySettings'
        }.fetch(field)
      end

      def normalize_outer(field, value)
        case field
        when :identifier then String(value).freeze
        when :editable then value.to_sym
        when :tab_index then Integer(value)
        when :appearance, :conditional_editability, :label_template, :conditional_visibility
          return nil if value.nil?
          raise TypeError, "#{field} expects a Forms node" unless value.is_a?(Forms::Node)

          value
        else value
        end
      end
    end

    def self.widget(widget_id, catalog: Catalog.default, &block)
      Node.build(widget_id, catalog:, &block)
    end

    def self.reference(kind, target)
      canonical_kind = kind.to_s.split('_').map(&:capitalize).join.freeze
      canonical_target = if canonical_kind == 'Association' && target.is_a?(Forms::EntityReference)
                           target
                         elsif canonical_kind == 'Association'
                           Forms::AttributeReference.coerce(target)
                         else
                           target.to_s.freeze
                         end
      Reference.new(canonical_kind, canonical_target)
    end

    def self.decimal(value) = Decimal.coerce(value)
  end
end
