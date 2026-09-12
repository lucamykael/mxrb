# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/node'
require 'mxrb/forms/mpr_codec'

RSpec.describe 'Forms value ownership' do # rubocop:disable Metrics/BlockLength
  forms = Mxrb::Forms

  {
    expression: ->(value) { forms::Expression.coerce(value).source },
    entity: ->(value) { forms::EntityReference.direct(value).entity },
    association: ->(value) { forms::EntityPathStep.to(value, 'App.Target').association },
    destination: ->(value) { forms::EntityPathStep.to('App.Link', value).destination_entity },
    attribute: ->(value) { forms::AttributeReference.coerce(value).attribute },
    attribute_path: ->(value) { forms::AttributeReference.through(value, via: 'App.Item').attribute },
    data_type: ->(value) { forms::DataType.build(value).name },
    type_target: ->(value) { forms::DataType.object(value).target },
    condition: ->(value) { forms::Condition.when_value(value).attribute_value },
    reference: ->(value) { forms::Reference.to(value).target },
    xpath: ->(value) { forms::XPathConstraint.coerce([3, value]).clauses.first },
    template_parameter: ->(value) { forms::TemplateParameter.coerce(value).expression.source },
    asset_path: ->(value) { forms::BinaryAsset.empty.at(value).source_path },
    enum_value: ->(value) { forms::EnumValue.new(:example, value).value }
  }.each do |name, build|
    it "owns its #{name} string without freezing the caller" do
      original = +'before'
      stored = build.call(original)

      expect(original).not_to be_frozen
      original.replace('after')
      expect(stored).to eq('before')
      expect(stored).to be_frozen
    end
  end

  it 'copies directly constructed collections and their typed components' do
    expression = +'$Item/Name'
    parameters = [forms::TemplateParameter.new(expression)]
    template = forms::TextTemplate.new('Name: {1}', parameters)
    association = +'App.Item_Owner'
    destination = +'Administration.Account'
    steps = [forms::EntityPathStep.new(association, destination)]
    reference = forms::EntityReference.new(destination, steps)
    clause = +'[Name != empty]'
    clauses = [clause]
    xpath = forms::XPathConstraint.new(clauses)

    parameters.clear
    steps.clear
    clauses.clear
    [expression, association, destination, clause].each { _1.replace('changed') }

    expect(template.parameters.first.expression.source).to eq('$Item/Name')
    expect(template.parameters).to be_frozen
    expect(reference.steps.first.association).to eq('App.Item_Owner')
    expect(reference.steps.first.destination_entity).to eq('Administration.Account')
    expect(reference.entity).to eq('Administration.Account')
    expect(reference.steps).to be_frozen
    expect(reference).to be_indirect
    expect(xpath.clauses).to eq(['[Name != empty]'])
    expect(xpath.clauses).to be_frozen
  end

  it 'owns binary buffers without changing their encoding or subtype' do
    bytes = +"\x00\xFF".b
    asset = forms::BinaryAsset.new(bytes, :user, nil)
    bytes.clear

    expect(asset.bytes).to eq("\x00\xFF".b)
    expect(asset.bytes.encoding).to eq(Encoding::BINARY)
    expect(asset.bytes).to be_frozen
    expect(asset.subtype).to eq(:user)
  end

  it 'retains immutable values through coercion and preserves empty indirect references' do
    reference = forms::EntityReference.through
    expression = forms::Expression.new('')
    template = forms::TextTemplate.new('', [])

    expect(forms::EntityReference.coerce(reference)).to equal(reference)
    expect(reference).to be_indirect
    expect(reference.entity).to eq('')
    expect(forms::Expression.coerce(expression)).to equal(expression)
    expect(forms::TextTemplate.coerce(template)).to equal(template)
  end

  it 'does not freeze or retain native attribute strings when decoding a document' do
    attribute = +'App.Item.Name'
    entity = +'App.Item'
    document = {
      '$Type' => 'Forms$TextBox', 'Name' => 'name',
      'AttributeRef' => {
        '$Type' => 'DomainModels$AttributeRef', 'Attribute' => attribute,
        'EntityRef' => { '$Type' => 'DomainModels$DirectEntityRef', 'Entity' => entity }
      }
    }
    node = forms::MprCodec.new.decode(document)
    attribute.replace('App.Item.Changed')
    entity.replace('App.Other')

    expect(node.attribute_ref.attribute).to eq('App.Item.Name')
    expect(node.attribute_ref.entity_reference.entity).to eq('App.Item')
  end
end
