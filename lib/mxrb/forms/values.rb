# frozen_string_literal: true

module Mxrb
  module Forms # rubocop:disable Metrics/ModuleLength
    Translation = Data.define(:language, :text) do
      def initialize(language:, text:)
        super(language: language&.dup&.freeze, text: text&.dup&.freeze)
      end
    end

    # Binary form resources stay outside editable Ruby source. Exported
    # documents refer to a normal file and the storage codec materializes its
    # bytes only at the MPR boundary.
    BinaryAsset = Data.define(:data, :subtype, :source_path) do
      def initialize(data:, subtype:, source_path:)
        super(data: data&.dup&.freeze, subtype:, source_path: source_path&.dup&.freeze)
      end

      def self.from_bytes(data, subtype: :generic)
        new(data.to_s.b.freeze, subtype.to_sym, nil)
      end

      def self.read(path, subtype: :generic)
        new(nil, subtype.to_sym, File.expand_path(path.to_s).freeze)
      end

      def self.empty(subtype: :generic)
        from_bytes(''.b, subtype:)
      end

      def bytes
        source_path ? File.binread(source_path) : data
      end

      def at(path)
        self.class.new(nil, subtype, path.to_s)
      end
    end

    Text = Data.define(:translations) do
      def initialize(translations:)
        super(translations: translations.dup.freeze)
      end

      def self.coerce(value, language: nil)
        return value if value.is_a?(self)

        entries = case value
                  when String then [Translation.new(language&.to_s, value)]
                  when Translation then [value]
                  else Array(value)
                  end
        raise TypeError, 'Text translations must be Translation values' unless entries.all? { _1.is_a?(Translation) }

        new(entries)
      end

      def to_s = translations.first&.text.to_s
    end

    Expression = Data.define(:source) do
      def initialize(source:)
        super(source: source.to_s.dup.freeze)
      end

      def self.coerce(value) = value.is_a?(self) ? value : new(value)
      alias_method :to_s, :source
    end

    EntityPathStep = Data.define(:association, :destination_entity) do
      def initialize(association:, destination_entity:)
        super(association: association.to_s.dup.freeze, destination_entity: destination_entity.to_s.dup.freeze)
      end

      def self.to(association, destination_entity)
        new(association, destination_entity)
      end
    end

    EntityReference = Data.define(:entity, :steps, :indirect) do
      def initialize(entity:, steps:, indirect: !steps.empty?)
        super(entity: entity.to_s.dup.freeze, steps: steps.dup.freeze, indirect:)
      end

      def self.coerce(value)
        return value if value.is_a?(self)

        direct(value)
      end

      def self.direct(entity)
        new(entity, [])
      end

      def self.through(*steps)
        unless steps.all? { _1.is_a?(EntityPathStep) }
          raise TypeError, 'entity path steps must be EntityPathStep values'
        end

        new(steps.last&.destination_entity, steps, true)
      end

      # An empty path refers to the surrounding entity context. It is distinct
      # from a direct reference whose entity has not been selected.
      def indirect? = indirect
      def path = entity
      alias_method :to_s, :entity
    end

    AttributeReference = Data.define(:attribute, :entity_reference) do
      def initialize(attribute:, entity_reference:)
        super(attribute: attribute.to_s.dup.freeze, entity_reference:)
      end

      def self.coerce(value)
        return value if value.is_a?(self)

        new(value, nil)
      end

      def self.through(attribute, via:)
        new(attribute, EntityReference.coerce(via))
      end

      def path = attribute
      alias_method :to_s, :attribute
    end

    DataType = Data.define(:name, :target) do
      def initialize(name:, target:)
        super(name: name.to_s.dup.freeze, target: target&.to_s&.dup&.freeze)
      end

      def self.build(name, target = nil)
        new(name, target)
      end

      def self.coerce(value) = value.is_a?(self) ? value : build(value)
      def self.object(entity) = build('Object', entity)
      def self.list(entity) = build('List', entity)
      def self.enumeration(enumeration) = build('Enumeration', enumeration)

      alias_method :to_s, :name
    end

    Condition = Data.define(:attribute_value, :editable_visible) do
      def initialize(attribute_value:, editable_visible:)
        super(attribute_value: attribute_value.to_s.dup.freeze, editable_visible:)
      end

      def self.coerce(value)
        return value if value.is_a?(self)

        when_value(value)
      end

      def self.when_value(value, visible: false)
        new(value, visible == true)
      end

      def expression = Expression.coerce(attribute_value)
      def to_s = attribute_value
    end

    TemplateParameter = Data.define(:expression) do
      def initialize(expression:)
        super(expression: Expression.coerce(expression))
      end

      def self.coerce(value) = value.is_a?(self) ? value : new(Expression.coerce(value))
    end

    TextTemplate = Data.define(:text, :parameters) do
      def initialize(text:, parameters:)
        super(text: Text.coerce(text), parameters: parameters.map { TemplateParameter.coerce(_1) }.freeze)
      end

      def self.build(text, parameters: [])
        new(text, parameters)
      end

      def self.coerce(value) = value.is_a?(self) ? value : build(value)
    end

    XPathConstraint = Data.define(:clauses) do
      def initialize(clauses:)
        super(clauses: clauses.map { _1.to_s.dup.freeze }.freeze)
      end

      def self.coerce(value)
        return value if value.is_a?(self)

        clauses = value.is_a?(Array) ? value.dup : [value]
        clauses.shift if clauses.first.is_a?(Integer)
        new(clauses)
      end

      def source = clauses.join
      alias_method :to_s, :source
    end

    Reference = Data.define(:target, :kind) do
      def initialize(target:, kind:)
        super(target: target.to_s.dup.freeze, kind:)
      end

      def self.to(target, kind: :by_name)
        kind = kind.to_sym
        unless %i[by_name by_id reference].include?(kind)
          raise ArgumentError, "unsupported reference kind #{kind.inspect}"
        end

        new(target, kind)
      end
    end

    EnumValue = Data.define(:type, :value) do
      def initialize(type:, value:)
        super(type:, value: value.to_s.dup.freeze)
      end

      def to_sym = Naming.ruby_name(value).to_sym
      def to_s = value
    end
  end
end
