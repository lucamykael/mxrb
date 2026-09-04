# frozen_string_literal: true

module Mxrb
  module Forms
    Translation = Data.define(:language, :text)

    # Binary form resources stay outside editable Ruby source. Exported
    # documents refer to a normal file and the storage codec materializes its
    # bytes only at the MPR boundary.
    BinaryAsset = Data.define(:data, :subtype, :source_path) do
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
        self.class.new(nil, subtype, path.to_s.freeze)
      end
    end

    Text = Data.define(:translations) do
      def self.coerce(value, language: nil)
        return value if value.is_a?(self)

        entries = case value
                  when String then [Translation.new(language&.to_s, value)]
                  when Translation then [value]
                  else Array(value)
                  end
        raise TypeError, 'Text translations must be Translation values' unless entries.all? { _1.is_a?(Translation) }

        new(entries.freeze)
      end

      def to_s = translations.first&.text.to_s
    end

    Expression = Data.define(:source) do
      def self.coerce(value) = value.is_a?(self) ? value : new(value.to_s.freeze)
      alias_method :to_s, :source
    end

    EntityPathStep = Data.define(:association, :destination_entity) do
      def self.to(association, destination_entity)
        new(association.to_s.freeze, destination_entity.to_s.freeze)
      end
    end

    EntityReference = Data.define(:entity, :steps) do
      def self.coerce(value)
        return value if value.is_a?(self)

        direct(value)
      end

      def self.direct(entity)
        new(entity.to_s.freeze, [].freeze)
      end

      def self.through(*steps)
        unless steps.all? { _1.is_a?(EntityPathStep) }
          raise TypeError, 'entity path steps must be EntityPathStep values'
        end

        new(steps.last&.destination_entity.to_s.freeze, steps.freeze)
      end

      def indirect? = !steps.empty?
      def path = entity
      alias_method :to_s, :entity
    end

    AttributeReference = Data.define(:attribute, :entity_reference) do
      def self.coerce(value)
        return value if value.is_a?(self)

        new(value.to_s.freeze, nil)
      end

      def self.through(attribute, via:)
        new(attribute.to_s.freeze, EntityReference.coerce(via))
      end

      def path = attribute
      alias_method :to_s, :attribute
    end

    DataType = Data.define(:name, :target) do
      def self.build(name, target = nil)
        new(name.to_s.freeze, target&.to_s&.freeze)
      end

      def self.coerce(value) = value.is_a?(self) ? value : build(value)
      def self.object(entity) = build('Object', entity)
      def self.list(entity) = build('List', entity)
      def self.enumeration(enumeration) = build('Enumeration', enumeration)

      alias_method :to_s, :name
    end

    Condition = Data.define(:attribute_value, :editable_visible) do
      def self.coerce(value)
        return value if value.is_a?(self)

        when_value(value)
      end

      def self.when_value(value, visible: false)
        new(value.to_s.freeze, visible == true)
      end

      def expression = Expression.coerce(attribute_value)
      def to_s = attribute_value
    end

    TemplateParameter = Data.define(:expression) do
      def self.coerce(value) = value.is_a?(self) ? value : new(Expression.coerce(value))
    end

    TextTemplate = Data.define(:text, :parameters) do
      def self.build(text, parameters: [])
        parameters = parameters.map do |parameter|
          TemplateParameter.coerce(parameter)
        end
        new(Text.coerce(text), parameters.freeze)
      end

      def self.coerce(value) = value.is_a?(self) ? value : build(value)
    end

    XPathConstraint = Data.define(:clauses) do
      def self.coerce(value)
        return value if value.is_a?(self)

        clauses = value.is_a?(Array) ? value.dup : [value]
        clauses.shift if clauses.first.is_a?(Integer)
        new(clauses.map { _1.to_s.freeze }.freeze)
      end

      def source = clauses.join
      alias_method :to_s, :source
    end

    Reference = Data.define(:target, :kind) do
      def self.to(target, kind: :by_name)
        kind = kind.to_sym
        unless %i[by_name by_id reference].include?(kind)
          raise ArgumentError, "unsupported reference kind #{kind.inspect}"
        end

        new(target.to_s.freeze, kind)
      end
    end

    EnumValue = Data.define(:type, :value) do
      def to_sym = Naming.ruby_name(value).to_sym
      def to_s = value
    end
  end
end
