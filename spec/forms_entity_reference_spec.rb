# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/mpr_codec'

RSpec.describe Mxrb::Forms::EntityReference do # rubocop:disable Metrics/BlockLength
  let(:codec) { Mxrb::Forms::MprCodec.new }

  it 'distinguishes an empty contextual path from an unselected direct entity' do
    contextual = described_class.through
    direct = described_class.direct('')

    expect(contextual).to be_indirect
    expect(direct).not_to be_indirect
    expect(contextual).not_to eq(direct)
    expect(contextual.steps).to eq([])
    expect(described_class.new('', [])).to eq(direct)
  end

  it 'preserves an empty indirect entity path through storage and editable Ruby' do
    document = {
      '$Type' => 'Forms$TextBox', 'Name' => 'customer_name',
      'AttributeRef' => {
        '$Type' => 'DomainModels$AttributeRef', 'Attribute' => 'Sales.Customer.Name',
        'EntityRef' => { '$Type' => 'DomainModels$IndirectEntityRef', 'Steps' => [2] }
      }
    }

    node = codec.decode(document)
    source = Mxrb::Forms::SourceEmitter.new.emit(node)
    restored = eval(source) # rubocop:disable Security/Eval
    rebuilt = codec.encode(restored)

    expect(source).to include('Mxrb::Forms::EntityReference.through()')
    expect(rebuilt.dig('AttributeRef', 'EntityRef', '$Type')).to eq('DomainModels$IndirectEntityRef')
    expect(rebuilt.dig('AttributeRef', 'EntityRef', 'Steps')).to eq([2])
    expect(rebuilt.dig('AttributeRef', 'Attribute')).to eq('Sales.Customer.Name')
  end

  it 'preserves direct and multi-step references independently of empty paths' do
    references = [
      described_class.direct('Sales.Customer'),
      described_class.through(
        Mxrb::Forms::EntityPathStep.to('Sales.Order_Customer', 'Sales.Customer'),
        Mxrb::Forms::EntityPathStep.to('Sales.Customer_Address', 'Sales.Address')
      )
    ]

    references.each do |reference|
      encoded = codec.encode_entity_reference_value(reference)
      expect(codec.decode_entity_reference_value(encoded)).to eq(reference)
    end
  end
end
