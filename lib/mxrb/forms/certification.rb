# frozen_string_literal: true

require_relative 'mpr_codec'

module Mxrb
  module Forms
    # Deterministic values used to exercise every versioned core Forms
    # property. These values are deliberately semantic: no BSON-shaped hashes,
    # generated IDs, or native fragments are accepted as certification input.
    module Certification
      module_function

      def sample_value(property, catalog: Catalog.for('11.12.1'), suffix: nil) # rubocop:disable Metrics/MethodLength
        target = catalog.type(property.type_name)
        value = if property.reference?
                  reference_sample(property, suffix)
                elsif target&.enum?
                  target.values.first
                elsif target&.element?
                  element_sample(concrete_element(target, catalog), catalog, suffix:)
                else
                  external_or_primitive(property.type_name)
                end
        property.many? ? [value] : value
      end

      def sample_values(property, catalog: Catalog.for('11.12.1'))
        values = [sample_value(property, catalog:)]
        target = catalog.type(property.type_name)
        values.concat(target.values) if target&.enum?
        values << false if property.type_name == 'boolean'
        values << [] if property.many?
        values << nil if property.optional?
        values.uniq.freeze
      end

      def signature(value) # rubocop:disable Metrics/MethodLength
        case value
        when Node
          [value.schema_type.name,
           value.assignments.map { [_1.property.name, signature(_1.value)] }.sort_by(&:first)]
        when EnumValue
          [value.type.name, value.value]
        when Reference
          [value.kind, value.target]
        when Array
          value.map { signature(_1) }
        else
          value
        end
      end

      def opaque_source?(source)
        transport = /\$ID|TypePointer|native_widget|deep_structure|native_fragment|form_structure|\bHash\b|=>|[{}]/
        uuid = /\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b/i
        source.match?(transport) || source.match?(uuid)
      end

      def element_sample(type, catalog, suffix: nil)
        node = Node.new(type.name, catalog:)
        node.name "certificationNested#{suffix}" if suffix && type.property(:name)
        configure_element(node)
        return node unless type.name == 'ClientTemplate'

        node.template Text.coerce([Translation.new('en_US', 'Certification')])
        node.fallback Text.coerce([])
        node.set(:parameters, [])
        node
      end

      def configure_element(node)
        return unless node.schema_type.name == 'ListViewTemplate'

        node.specialization 'Certification.Entity'
        node.set(:widgets, [])
      end

      def concrete_element(target, catalog)
        catalog.types.find do |candidate|
          candidate.element? && candidate.concrete? &&
            (candidate == target || catalog.descendant?(candidate.name, target.name))
        end
      end

      def reference_sample(property, suffix)
        return "certificationTab#{suffix}" if property.reference == :by_id
        return 'Certification.AllCoreProperties' if property.type_name == 'Page'
        return 'Certification.Images.Target' if property.type_name == 'by_name'

        'Certification.Target'
      end

      def external_or_primitive(type) # rubocop:disable Metrics/MethodLength
        {
          'string' => 'certification-value',
          'integer' => 17,
          'boolean' => true,
          'blob' => BinaryAsset.from_bytes('mxrb-certification'),
          'size' => Size.new(320, 180),
          'Text' => Text.coerce([Translation.new('en_US', 'Certification')]),
          'Expression' => '$currentObject/Name',
          'AttributeReference' => 'Certification.Entity.Name',
          'EntityReference' => 'Certification.Entity',
          'DataType' => 'String',
          'Condition' => Condition.when_value('Active', visible: true),
          'TextTemplate' => TextTemplate.build(
            Text.coerce([Translation.new('en_US', 'Hello {1}')]),
            parameters: ['$currentObject/Name']
          ),
          'XPathConstraint' => XPathConstraint.coerce(['[Active = true()]'])
        }.fetch(type)
      end
    end
  end
end
