# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/mpr_codec'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Pluggable nested properties with reserved Ruby names' do
  let(:widget_id) { 'com.example.ReservedProperties' }

  before do
    Mxrb::Pluggable.widget_type(widget_id) do
      properties do
        property 'source', :data_source
        property 'schema', :object do
          properties { property 'title', :string }
        end
        property 'assignments', :object do
          list!
          properties { property 'title', :string }
        end
        property 'fetch', :action
        property 'set', :widgets
      end
    end
  end

  it 'emits nested data sources and objects through explicit set and append blocks' do
    node = Mxrb::Pluggable.widget(widget_id) do
      properties do
        set(:source) { entity 'Sales.Order' }
        set(:schema) { title 'Selected order' }
        append(:assignments) { title 'First' }
        append(:assignments) { title 'Second' }
      end
    end
    restored, source = round_trip(node)

    expect(source).to include('set(:source) do', 'set(:schema) do', 'append(:assignments) do')
    expect(restored.object.fetch(:source).entity.to_s).to eq('Sales.Order')
    expect(restored.object.fetch(:schema).fetch(:title)).to eq('Selected order')
    expect(restored.object.fetch(:assignments).map { _1.fetch(:title) }).to eq(%w[First Second])
  end

  it 'preserves nested Forms types and both kinds of widget children' do
    Mxrb::Pluggable.widget_type('com.example.ReservedChild') { properties {} }
    node = Mxrb::Pluggable.widget(widget_id) do
      properties do
        set(:fetch, type: :no_client_action) {}
        append(:set, type: :text_box) { name 'order_number' }
        append(:set, type: 'com.example.ReservedChild') { identifier 'child' }
      end
    end
    restored, source = round_trip(node)

    expect(source).to include('set(:fetch, type: :no_client_action)', 'append(:set, type: :text_box)',
                              'append(:set, type: "com.example.ReservedChild")')
    expect(restored.object.fetch(:fetch).schema_type.name).to eq('NoClientAction')
    expect(restored.object.fetch(:set).first.name).to eq('order_number')
    expect(restored.object.fetch(:set).last.identifier).to eq('child')
  end

  it 'rejects ambiguous set calls and preserves an existing value when a block fails' do
    object = Mxrb::Pluggable.widget(widget_id).object
    object.set(:source) { entity 'Sales.Order' }
    original = object.fetch(:source)

    expect { object.set(:source, original) {} }.to raise_error(ArgumentError, /not both/)
    expect { object.set(:source) }.to raise_error(ArgumentError, /requires a value/)
    expect { object.set(:source, original, type: :page_variable) }.to raise_error(ArgumentError, /nested block/)
    expect { object.set(:source) { raise 'nested failure' } }.to raise_error('nested failure')
    expect(object.fetch(:source)).to equal(original)
  end

  def round_trip(node)
    codec = Mxrb::Forms::MprCodec.new
    document = codec.encode(node)
    source = Mxrb::Forms::SourceEmitter.new.emit(codec.decode(document))
    restored = eval(source) # rubocop:disable Security/Eval
    expect(without_ids(codec.encode(restored, baseline: document))).to eq(without_ids(document))
    [restored, source]
  end

  def without_ids(value)
    case value
    when Hash then value.reject { |key, _| %w[$ID TypePointer].include?(key) }.transform_values { without_ids(_1) }
    when Array then value.map { without_ids(_1) }
    else value
    end
  end
end
# rubocop:enable Metrics/BlockLength
