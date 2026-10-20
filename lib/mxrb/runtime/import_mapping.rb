# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'decimal_values'

module Mxrb
  module Runtime
    # Applies a JSON import mapping as the Mendix Runtime does: each object
    # element finds or creates one object per JSON node its path reaches, value
    # elements set attributes, and every object is linked to the object of its
    # parent element over the element's association, on whichever side owns it.
    class ImportMapping # rubocop:disable Metrics/ClassLength
      SEGMENTS = %w[(Object) (Array) (Wrapper) (Value)].freeze

      # The mapping tree of an ImportMappings$ImportMapping document, in the
      # plain form the manifest of a Ruby application also stores.
      def self.definition(document)
        { 'elements' => items(document['Elements']).map { element(_1) } }
      end

      def self.element(raw) # rubocop:disable Metrics/AbcSize
        object = raw['$Type'].to_s.end_with?('ObjectMappingElement')
        {
          'kind' => object ? 'object' : 'value', 'element_type' => raw['ElementType'].to_s,
          'path' => raw['JsonPath'].to_s.split('|'), 'entity' => raw['Entity'].to_s,
          'association' => raw['Association'].to_s, 'attribute' => raw['Attribute'].to_s.split('.').last.to_s,
          'type' => raw.dig('Type', '$Type').to_s.delete_prefix('DataTypes$').delete_suffix('Type'),
          'key' => raw['IsKey'] == true, 'handling' => raw['ObjectHandling'].to_s,
          'backup' => raw['ObjectHandlingBackup'].to_s, 'converter' => raw['Converter'].to_s,
          'children' => items(raw['Children']).map { element(_1) }
        }
      end

      def self.items(value)
        return [] if value.nil?

        IO::BsonCodec.parse_array(value).fetch(:items).select { _1.is_a?(Hash) }
      end

      # associations: { 'Module.Association' => { type:, from: } }; converter:
      # ->(microflow, value) { converted } runs the converter microflow of a value.
      def initialize(definition, store:, associations:, converter: nil)
        @definition = definition
        @store = store
        @associations = associations
        @converter = converter
        @objects = []
      end

      attr_reader :objects

      # The objects of the root element, one per JSON node its path reaches; for
      # a root without an entity, such as a JSON array, those of its children.
      def import(json)
        document = json.is_a?(String) ? JSON.parse(json) : json
        @definition.fetch('elements').flat_map do |root|
          resolve(document, root.fetch('path')).flat_map { build(root, _1, nil) }
        end
      end

      private

      # The objects an element makes of one JSON node.
      def build(element, node, parent)
        return [] if node.nil?
        return children(element, node, parent) if element.fetch('entity').empty?

        object = obtain(element, node)
        return [] unless object

        link(element.fetch('association'), object, parent) if parent
        children(element, node, object)
        [object]
      end

      # An object element without an entity carries its children to its parent.
      def children(element, node, object)
        element.fetch('children').flat_map do |child|
          nodes = resolve(node, relative(child, element))
          next nodes.flat_map { build(child, _1, object) } unless child.fetch('kind') == 'value'

          object.members[child.fetch('attribute')] = value(child, nodes.first) if object
          []
        end
      end

      def obtain(element, node)
        found = find(element, node) if element.fetch('handling') == 'Find'
        return found if found
        return create(element) unless element.fetch('handling') == 'Find'

        case element.fetch('backup')
        when 'Ignore' then nil
        when 'Error' then raise NativeRuntimeError, "import mapping found no #{element.fetch('entity')} object"
        else create(element)
        end
      end

      def create(element)
        @store.create(element.fetch('entity')).tap { @objects << _1 }
      end

      # The object whose key attributes hold the values of the node.
      def find(element, node) # rubocop:disable Metrics/AbcSize
        keys = element.fetch('children').select { _1.fetch('kind') == 'value' && _1.fetch('key') }
        raise NativeRuntimeError, "import mapping finds #{element.fetch('entity')} without a key" if keys.empty?

        wanted = keys.to_h { [_1.fetch('attribute'), value(_1, resolve(node, relative(_1, element)).first)] }
        found = @store.retrieve(element.fetch('entity')).find do |object|
          wanted.all? { |name, expected| object.members[name] == expected }
        end
        @objects << found if found
        found
      end

      def link(association, object, parent)
        return if association.empty?

        definition = @associations.fetch(association) do
          raise NativeRuntimeError, "import mapping uses unknown association #{association}"
        end
        name = association.split('.').last
        owner, target = owned_by?(definition, object) ? [object, parent] : [parent, object]
        set = definition.fetch(:type).to_s == 'ReferenceSet'
        owner.members[name] = set ? Array(owner.members[name]) | [target] : target
      end

      def owned_by?(definition, object)
        from = definition.fetch(:from).to_s
        return true if from == object.entity
        return false unless @store.respond_to?(:schema)

        @store.schema.assignable?(object.entity, from)
      end

      def relative(child, element)
        child.fetch('path').drop(element.fetch('path').length)
      end

      # The JSON nodes a path reaches from a node; arrays fan out into their items.
      def resolve(node, segments)
        segments.reduce([node]) do |nodes, segment|
          nodes.flat_map { step(_1, segment) }
        end
      end

      def step(node, segment) # rubocop:disable Metrics/CyclomaticComplexity
        case segment
        when '(Object)' then json_objects(node)
        when '(Wrapper)' then node.is_a?(Array) ? node : [node]
        when '(Array)' then node.is_a?(Array) ? [node] : []
        when '(Value)' then [node]
        else node.is_a?(Hash) && node.key?(segment) ? [node[segment]] : []
        end
      end

      def json_objects(node)
        return node.grep(Hash) if node.is_a?(Array)

        node.is_a?(Hash) ? [node] : []
      end

      def value(element, raw)
        raw = @converter.call(element.fetch('converter'), raw) if @converter && !element.fetch('converter').empty?
        return nil if raw.nil?

        convert(element.fetch('type'), raw)
      end

      def convert(type, raw) # rubocop:disable Metrics/CyclomaticComplexity
        case type
        when 'Integer', 'Long' then raw.is_a?(Numeric) ? raw.to_i : Integer(raw.to_s, 10)
        when 'Decimal', 'Float' then DecimalValues.parse(raw.to_s)
        when 'Boolean' then raw == true || raw.to_s.casecmp?('true')
        when 'DateTime' then date_time(raw)
        when 'String', 'Enumeration' then raw.is_a?(String) ? raw : JSON.generate(raw)
        else raw
        end
      end

      def date_time(raw)
        return Time.at(raw / 1000.0).utc if raw.is_a?(Numeric)

        Time.iso8601(raw.to_s).utc
      rescue ArgumentError
        Time.parse(raw.to_s).utc
      end
    end
  end
end
