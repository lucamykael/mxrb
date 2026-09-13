# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Writer::PageOverlay do
  def writer
    Mxrb::Writer.new('/tmp/unused.mpr', version: '11.12.1', modules: [])
  end

  def data_view(message)
    page = Mxrb::Dsl::PageBuilder.new(:Page)
    page.data_view(
      :Details, from: { kind: :context, entity: 'Ui.Item' }, no_entity_message: message
    )
    page.to_h.fetch(:widgets).first
  end

  def overlay(original:, current:, metadata:)
    encoded_original = writer.send(:widget_doc, original)
    encoded_current = writer.send(:widget_doc, current)
    baseline = {
      '$Type' => 'Forms$Page',
      'Widgets' => Mxrb::IO::BsonCodec.build_array([encoded_original], marker: 2)
    }

    described_class.new(
      baseline:, target: Marshal.load(Marshal.dump(baseline)), widgets: [current],
      encoded_widgets: [encoded_current], metadata:
    )
  end

  it 'applies a declared data view no-entity message without structural drift' do
    original = data_view('No item selected')
    edited = data_view('Choose an item')
    encoded_original = writer.send(:widget_doc, original)
    encoded_edited = writer.send(:widget_doc, edited)
    baseline = {
      '$Type' => 'Forms$Page',
      'Widgets' => Mxrb::IO::BsonCodec.build_array([encoded_original], marker: 2)
    }
    target = Marshal.load(Marshal.dump(baseline))
    metadata = described_class.metadata([original])

    result = described_class.new(
      baseline:, target:, widgets: [edited], encoded_widgets: [encoded_edited], metadata:
    ).apply
    native = Mxrb::IO::BsonCodec.parse_array(result.fetch('Widgets'))[:items].first

    expect(Mxrb::Model::Page.allocate.send(:extract_text, native.fetch('NoEntityMessage')))
      .to eq('Choose an item')
    expect(described_class.metadata([edited])).to eq(metadata)
  end

  it 'accepts an unchanged data view captured with legacy version 1 metadata' do
    original = data_view('No item selected')
    current = data_view('No item selected')
    metadata = {
      'version' => 1,
      'page_unit_id' => nil,
      'module_unit_id' => nil,
      'widgets' => [{
        'type' => original.fetch(:type).to_s,
        'name' => original.fetch(:name).to_s,
        'fingerprint' => described_class.send(:structural_fingerprint, original, 1)
      }]
    }

    expect { overlay(original:, current:, metadata:).apply }.not_to raise_error
  end

  it 'rejects a no-entity-message edit against legacy version 1 metadata' do
    original = data_view('No item selected')
    edited = data_view('Choose an item')
    metadata = described_class.metadata([original], version: 1)

    expect { overlay(original:, current: edited, metadata:).apply }
      .to raise_error(
        Mxrb::ValidationError,
        /unsupported structural or property edit at data_view "Details"/
      )
  end

  it 'rejects an unknown structural baseline metadata version' do
    original = data_view('No item selected')
    metadata = described_class.metadata([original], version: 1).merge('version' => 99)

    expect { overlay(original:, current: original, metadata:).apply }
      .to raise_error(Mxrb::ValidationError, /unknown structural baseline version 99/)
  end

  it 'applies an overlay using only a content digest and the native target' do
    original = data_view('No item selected')
    edited = data_view('Choose an item')
    encoded_original = writer.send(:widget_doc, original)
    encoded_edited = writer.send(:widget_doc, edited)
    target = {
      '$Type' => 'Forms$Page',
      'Widgets' => Mxrb::IO::BsonCodec.build_array([encoded_original], marker: 2)
    }
    metadata = described_class.metadata([original])
    metadata['baseline_digest'] = described_class.baseline_digest(target, metadata)

    result = described_class.new(
      baseline: nil, target:, widgets: [edited], encoded_widgets: [encoded_edited], metadata:
    ).apply
    native = Mxrb::IO::BsonCodec.parse_array(result.fetch('Widgets'))[:items].first

    expect(Mxrb::Model::Page.allocate.send(:extract_text, native.fetch('NoEntityMessage')))
      .to eq('Choose an item')
  end

  it 'rejects a digest-backed overlay when an unsupported native field changed' do
    original = data_view('No item selected')
    encoded = writer.send(:widget_doc, original)
    target = {
      '$Type' => 'Forms$Page', 'Documentation' => 'original',
      'Widgets' => Mxrb::IO::BsonCodec.build_array([encoded], marker: 2)
    }
    metadata = described_class.metadata([original])
    metadata['baseline_digest'] = described_class.baseline_digest(target, metadata)
    target['Documentation'] = 'changed elsewhere'

    overlay = described_class.new(
      baseline: nil, target:, widgets: [original], encoded_widgets: [encoded], metadata:
    )
    expect { overlay.apply }
      .to raise_error(Mxrb::ValidationError, /page changed outside the Ruby overlay/)
  end
end
# rubocop:enable Metrics/BlockLength
