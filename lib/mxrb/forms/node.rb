# frozen_string_literal: true

require_relative 'catalog'
require_relative 'values'

module Mxrb
  # Typed construction API for canonical Mendix Forms values.
  module Forms
    Assignment = Data.define(:property, :value)

    # Schema-checked Ruby object for any Forms element. Values remain typed;
    # BSON hashes are strictly a codec concern outside this public model.
    class Node # rubocop:disable Metrics/ClassLength
      EXTERNAL_VALUES = {
        'AttributeReference' => AttributeReference,
        'Condition' => Condition,
        'DataType' => DataType,
        'EntityReference' => EntityReference,
        'Expression' => Expression,
        'Text' => Text,
        'TextTemplate' => TextTemplate,
        'XPathConstraint' => XPathConstraint
      }.freeze

      attr_reader :schema_type, :catalog

      def self.build(type, catalog: Catalog.for('11.12.1'), &block)
        new(type, catalog:).tap { _1.evaluate(&block) if block }
      end

      def self.representable?(property, catalog: Catalog.for('11.12.1'))
        catalog.type(property.type_name) || EXTERNAL_VALUES.key?(property.type_name) ||
          property.reference? || %w[string integer boolean size blob].include?(property.type_name)
      end

      def initialize(type, catalog: Catalog.for('11.12.1'))
        @catalog = catalog
        @schema_type = catalog.fetch_type(type)
        raise ArgumentError, "#{@schema_type.name} is an enum, not an element" if @schema_type.enum?

        @assignments = []
      end

      def evaluate(&block)
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      end

      def each(&block) = assignments.each(&block)
      def assignments = @assignments.dup.freeze

      def assigned?(property)
        !assignment(property).nil?
      end

      def fetch(property)
        assignment(property)&.value
      end

      def set(property, value)
        property = schema_type.fetch_property(property)
        normalized = normalize(property, value)
        @assignments.reject! { _1.property.name == property.name }
        @assignments << Assignment.new(property, normalized)
        self
      end

      def append(property, value = nil, type: nil, &block)
        property = schema_type.fetch_property(property)
        raise ArgumentError, "#{schema_type.name}.#{property.name} is not a collection" unless property.many?

        value = nested_value(property, value, type, &block) if block
        current = fetch(property) || [].freeze
        set(property.name, [*current, value])
      end

      def unset(property)
        property = schema_type.fetch_property(property)
        @assignments.reject! { _1.property.name == property.name }
        self
      end

      def method_missing(name, *arguments, &block) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
        property = schema_type.property(name)
        return super unless property

        return fetch(property.name) if arguments.empty? && !block
        return append(property.name, type: arguments.first, &block) if property.many? && block

        if block
          unless arguments.size <= 1
            raise ArgumentError,
                  "#{schema_type.name}.#{property.name} accepts at most one type with a block"
          end

          return set(property.name, Node.build(arguments.first || property.type_name, catalog:, &block))
        end
        unless arguments.length == 1
          raise ArgumentError, "#{schema_type.name}.#{property.name} expects exactly one value"
        end

        set(property.name, arguments.first)
      end

      def respond_to_missing?(name, include_private = false)
        !schema_type.property(name).nil? || super
      end

      def inspect
        values = assignments.map { "#{_1.property.ruby_name}=#{_1.value.inspect}" }.join(', ')
        "#<#{self.class.name} #{schema_type.name} #{values}>"
      end

      private

      def assignment(property)
        property = schema_type.fetch_property(property)
        @assignments.find { _1.property.name == property.name }
      end

      def nested_value(property, value, explicit_type, &block)
        nested_type = explicit_type || value || property.type_name
        if property.type_name == 'Widget' && catalog.type(nested_type).nil? &&
           defined?(Mxrb::Pluggable::Node)
          return Mxrb::Pluggable::Node.build(nested_type, &block)
        end

        Node.build(nested_type, catalog:, &block)
      end

      def normalize(property, value) # rubocop:disable Metrics/AbcSize
        return nil if value.nil? && property.optional?
        raise TypeError, "#{schema_type.name}.#{property.name} cannot be nil" if value.nil?

        if property.many?
          raise TypeError, "#{schema_type.name}.#{property.name} requires an Array" unless value.is_a?(Array)

          return value.map { normalize_one(property, _1) }.freeze
        end
        normalize_one(property, value)
      end

      def normalize_one(property, value) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
        return normalize_reference(property, value) if property.reference?

        target = catalog.type(property.type_name)
        return normalize_enum(target, value) if target&.enum?
        return normalize_node(property, target, value) if target&.element?
        return normalize_external(property, value) if EXTERNAL_VALUES.key?(property.type_name)

        valid = case property.type_name
                when 'string' then value.is_a?(String)
                when 'integer' then value.is_a?(Integer)
                when 'size' then value.is_a?(Size)
                when 'boolean' then value.equal?(true) || value.equal?(false)
                when 'blob' then value.is_a?(String) || value.is_a?(BinaryAsset)
                else false
                end
        return value.dup.freeze if valid && value.is_a?(String)
        return value if valid

        raise TypeError, "#{schema_type.name}.#{property.name} expects #{property.type_name}, got #{value.class}"
      end

      def normalize_enum(enum_type, value)
        candidate = value.is_a?(EnumValue) ? value.value : value.to_s
        exact = enum_type.values.find do |allowed|
          allowed == candidate || Naming.ruby_name(allowed) == Naming.ruby_name(candidate)
        end
        raise ArgumentError, "invalid #{enum_type.name} value #{value.inspect}" unless exact

        EnumValue.new(enum_type, exact)
      end

      def normalize_node(property, target, value)
        if target.name == 'Widget' && defined?(Mxrb::Pluggable::Node) && value.is_a?(Mxrb::Pluggable::Node)
          return value
        end

        allowed = [target.name, *property.targets]
        compatible = value.is_a?(Node) && allowed.any? do |candidate|
          value.schema_type.name == candidate || catalog.descendant?(value.schema_type.name, candidate)
        end
        raise TypeError, "#{schema_type.name}.#{property.name} expects #{target.name} element" unless compatible

        value
      end

      def normalize_external(property, value)
        expected = EXTERNAL_VALUES.fetch(property.type_name)
        return value if value.is_a?(expected)

        expected.coerce(value)
      rescue TypeError, ArgumentError => e
        raise TypeError, "#{schema_type.name}.#{property.name} expects #{property.type_name}: #{e.message}"
      end

      def normalize_reference(property, value)
        return value if value.is_a?(Reference) && value.kind == property.reference

        Reference.to(value, kind: property.reference)
      end
    end

    def self.build(type, version: '11.12.1', &block)
      Node.build(type, catalog: Catalog.for(version), &block)
    end

    Catalog.for('11.12.1').types.reject(&:enum?).each do |schema_type|
      define_singleton_method(schema_type.ruby_name) do |version: '11.12.1', &block|
        build(schema_type.name, version:, &block)
      end
    end
  end
end
