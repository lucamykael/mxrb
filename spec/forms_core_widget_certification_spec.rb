# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/mpr_codec'

RSpec.describe 'Mendix 11.12.1 core Forms widget certification' do # rubocop:disable Metrics/BlockLength
  def sample_value(property, catalog) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
    target = catalog.type(property.type_name)
    value = if property.reference?
              'Certification.Target'
            elsif target&.enum?
              target.values.first
            elsif target&.element?
              concrete = catalog.types.find do |candidate|
                candidate.element? && candidate.concrete? &&
                  (candidate == target || catalog.descendant?(candidate.name, target.name))
              end
              element_sample(concrete, catalog)
            else
              external_or_primitive(property.type_name)
            end
    property.many? ? [value] : value
  end

  def element_sample(type, catalog)
    node = Mxrb::Forms::Node.new(type.name, catalog:)
    return node unless type.name == 'ClientTemplate'

    node.template Mxrb::Forms::Text.coerce(
      [Mxrb::Forms::Translation.new('en_US', 'Certification')]
    )
    node.fallback Mxrb::Forms::Text.coerce([])
    node.set(:parameters, [])
    node
  end

  def external_or_primitive(type) # rubocop:disable Metrics/MethodLength
    {
      'string' => 'certification-value',
      'integer' => 17,
      'boolean' => true,
      'size' => Mxrb::Forms::Size.new(320, 180),
      'Text' => Mxrb::Forms::Text.coerce([Mxrb::Forms::Translation.new('en_US', 'Certification')]),
      'Expression' => '$currentObject/Name',
      'AttributeReference' => 'Certification.Entity.Name',
      'EntityReference' => 'Certification.Entity',
      'DataType' => 'String',
      'Condition' => Mxrb::Forms::Condition.when_value('Active', visible: true),
      'TextTemplate' => Mxrb::Forms::TextTemplate.build(
        Mxrb::Forms::Text.coerce([Mxrb::Forms::Translation.new('en_US', 'Hello {1}')]),
        parameters: ['$currentObject/Name']
      ),
      'XPathConstraint' => Mxrb::Forms::XPathConstraint.coerce(['[Active = true()]'])
    }.fetch(type)
  end

  def sample_values(property, catalog)
    values = [sample_value(property, catalog)]
    target = catalog.type(property.type_name)
    values.concat(target.values) if target&.enum?
    values << false if property.type_name == 'boolean'
    values << [] if property.many?
    values << nil if property.optional?
    values.uniq
  end

  def signature(value) # rubocop:disable Metrics/MethodLength
    case value
    when Mxrb::Forms::Node
      [value.schema_type.name,
       value.assignments.map { [_1.property.name, signature(_1.value)] }.sort_by(&:first)]
    when Mxrb::Forms::EnumValue
      [value.type.name, value.value]
    when Mxrb::Forms::Reference
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

  def certify(widget, property, value, environment) # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    catalog, emitter, codec = environment
    node = Mxrb::Forms::Node.new(widget.name, catalog:)
    node.set(property.name, value)
    source = emitter.emit(node)
    expected = signature(node)
    failures = []
    failures << 'opaque Ruby source' if opaque_source?(source)
    failures << 'Ruby source changed semantics' if signature(eval(source)) != expected # rubocop:disable Security/Eval
    failures << 'storage changed semantics' if signature(codec.decode(codec.encode(node))) != expected
    [[widget.name, property.name], failures.map { "#{widget.name}.#{property.name} (#{value.inspect}): #{_1}" }]
  rescue StandardError, ScriptError => e
    [[widget.name, property.name], ["#{widget.name}.#{property.name} (#{value.inspect}): #{e.class}: #{e.message}"]]
  end

  it 'losslessly certifies every inherited property occurrence through clean Ruby and typed storage' do
    catalog = Mxrb::Forms::Catalog.for('11.12.1')
    emitter = Mxrb::Forms::SourceEmitter.new
    codec = Mxrb::Forms::MprCodec.new(
      reference_decoder: ->(value, _path) { value.to_s },
      reference_encoder: ->(target, _path) { target.to_s }
    )
    environment = [catalog, emitter, codec]
    results = catalog.concrete_widgets.flat_map do |widget|
      widget.all_properties.flat_map do |property|
        sample_values(property, catalog).map do |value|
          certify(widget, property, value, environment)
        end
      end
    end
    certified = results.map(&:first)
    failures = results.flat_map(&:last)

    expect(certified.map(&:first).uniq.size).to eq(41)
    expect(certified.size).to eq(825)
    expect(certified.uniq.size).to eq(455)
    expect(failures).to be_empty, -> { failures.join("\n") }
  end
end
