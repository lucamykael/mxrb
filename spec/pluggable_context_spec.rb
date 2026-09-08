# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/mpr_codec'

RSpec.describe 'Pluggable property context' do # rubocop:disable Metrics/BlockLength
  let(:codec) { Mxrb::Forms::MprCodec.new }
  let(:widget_id) { 'com.example.ContextBindings' }

  before do
    Mxrb::Pluggable.widget_type(widget_id) do
      properties do
        property 'label', :attribute
        property 'association', :association
        property 'datasource', :data_source
      end
    end
  end

  def without_ids(value)
    case value
    when Hash then value.reject { |key, _| key == '$ID' }.transform_values { without_ids(_1) }
    when Array then value.map { without_ids(_1) }
    else value
    end
  end

  def property_value(document, index = 1)
    document.dig('Object', 'Properties', index, 'Value')
  end

  it 'preserves a page-variable attribute binding through decode, source and encode' do
    node = Mxrb::Pluggable.widget(widget_id) do
      properties do
        label 'Sales.Customer.Name'
        source :label do
          page_parameter 'Customer'
          widget 'customer_details'
        end
      end
    end
    original = codec.encode(node)
    decoded = codec.decode(original)
    source = Mxrb::Forms::SourceEmitter.new.emit(decoded)
    rebuilt = codec.encode(eval(source)) # rubocop:disable Security/Eval

    expect(source).to include('source(:label) do', 'page_parameter "Customer"')
    expect(source).not_to include('$ID', 'TypePointer', '{', '}')
    expect(without_ids(property_value(rebuilt)['SourceVariable']))
      .to eq(without_ids(property_value(original)['SourceVariable']))
    expect(property_value(rebuilt).dig('AttributeRef', 'Attribute')).to eq('Sales.Customer.Name')
    decoded.object.set(:label, 'Sales.Customer.DisplayName')
    expect(decoded.object.source(:label).page_parameter.target).to eq('Customer')
  end

  it 'keeps association paths stored as entity references and their snippet source' do
    target = Mxrb::Forms::EntityReference.through(
      Mxrb::Forms::EntityPathStep.to('Sales.Order_Customer', 'Sales.Customer')
    )
    node = Mxrb::Pluggable.widget(widget_id)
    node.object.set(:association, Mxrb::Pluggable.reference(:association, target))
    node.object.source(:association) { snippet_parameter 'Order' }
    original = codec.encode(node)
    source = Mxrb::Forms::SourceEmitter.new.emit(codec.decode(original))
    rebuilt = codec.encode(eval(source)) # rubocop:disable Security/Eval

    expect(property_value(rebuilt)['AttributeRef']).to be_nil
    expect(without_ids(property_value(rebuilt)['EntityRef']))
      .to eq(without_ids(property_value(original)['EntityRef']))
    expect(property_value(rebuilt).dig('SourceVariable', 'SnippetParameter')).to eq('Order')
  end

  it 'keeps a direct entity association distinct from an attribute reference in source' do
    node = Mxrb::Pluggable.widget(widget_id)
    node.object.set(:association, Mxrb::Pluggable.reference(
                                    :association, Mxrb::Forms::EntityReference.direct('Sales.Customer')
                                  ))
    source = Mxrb::Forms::SourceEmitter.new.emit(node)
    rebuilt = codec.encode(eval(source)) # rubocop:disable Security/Eval

    expect(property_value(rebuilt).dig('EntityRef', '$Type')).to eq('DomainModels$DirectEntityRef')
    expect(property_value(rebuilt).dig('EntityRef', 'Entity')).to eq('Sales.Customer')
  end

  it 'retains data-source paths and does not inherit the previous property source' do
    node = Mxrb::Pluggable.widget(widget_id) do
      properties do
        label 'Sales.Customer.Name'
        source(:label) { page_parameter 'Customer' }
        datasource do
          entity Mxrb::Forms::EntityReference.through(
            Mxrb::Forms::EntityPathStep.to('Sales.Order_Customer', 'Sales.Customer')
          )
          source_variable { page_parameter 'Order' }
        end
      end
    end
    original = codec.encode(node)
    decoded = codec.decode(original)
    source = Mxrb::Forms::SourceEmitter.new.emit(decoded)
    rebuilt = codec.encode(eval(source)) # rubocop:disable Security/Eval

    expect(decoded.object.source(:datasource)).to be_nil
    expect(property_value(rebuilt, 2)['SourceVariable']).to be_nil
    expect(without_ids(property_value(rebuilt, 2)['DataSource']))
      .to eq(without_ids(property_value(original, 2)['DataSource']))
  end

  it 'rejects invalid source values without losing the assigned value' do
    node = Mxrb::Pluggable.widget(widget_id)
    node.object.set(:label, 'Sales.Customer.Name')

    expect { node.object.set(:label, 'changed', source: 'untyped') }.to raise_error(TypeError, /PageVariable/)
    expect(node.object.fetch(:label).to_s).to eq('Sales.Customer.Name')
  end
end
