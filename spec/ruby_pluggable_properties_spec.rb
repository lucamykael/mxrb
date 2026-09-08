# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/ruby_app/pluggable_properties'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::PluggableProperties do
  let(:widget_id) { 'com.example.bridge.Widget' }
  let(:catalog) { Mxrb::Pluggable::Catalog.new }
  let!(:schema) do
    Mxrb::Pluggable.widget_type(widget_id, catalog:) do
      properties do
        property :title, :string
        property :showLabel, :boolean
        property :count, :integer
        property :price, :decimal
        property(:display, :enumeration) { choice 'table', 'Table' }
        property :selection, :selection
        property :computed, :expression
        property :attribute, :attribute
        property :action, :action
        property :source, :data_source
        property :label, :text_template
        property :image, :image
        property(:objects, :object) { list! }
        property :content, :widgets
      end
    end
  end

  let(:projection) do
    { 'title' => 'Hello', 'showLabel' => false, 'count' => 7, 'price' => 1.25,
      'display' => 'table', 'selection' => 'Single', 'computed' => '$currentObject/Name',
      'attribute' => 'App.Item.Name' }
  end

  def native_widget(values)
    node = Mxrb::Pluggable::Node.new(schema, catalog:)
    values.each { |key, value| node.object.set(key, value) }
    forms = Mxrb::Forms::MprCodec.new(pluggable_catalog: catalog)
    Mxrb::Pluggable::MprCodec.new(forms_codec: forms, catalog:).encode(node)
  end

  def runtime_properties(document)
    Mxrb::Model::Page.allocate.send(:pluggable_properties, document.fetch('Object'), document.dig('Type', 'ObjectType'))
  end

  it 'uses real typed values and reproduces the existing native page projection exactly' do
    oracle = runtime_properties(native_widget(projection))
    expect(oracle).to eq(projection)
    bridge = described_class.try_from_projection(widget_id, oracle, catalog:)
    expect(bridge).to be_a(described_class)
    expect(bridge.to_projection.to_a).to eql(oracle.to_a)
    expect(bridge.typed_value(:computed)).to be_a(Mxrb::Forms::Expression)
    expect(bridge.typed_value(:attribute)).to be_a(Mxrb::Forms::AttributeReference)
    expect(bridge.typed_value(:price)).to be_a(Mxrb::Pluggable::Decimal)
    expect(bridge.to_projection).to be_frozen
  end

  it 'supports an ordered property block without retaining an input Hash' do
    bridge = described_class.build(widget_id, catalog:) do
      set :count, 2
      set :show_label, false
      set :title, nil
      set :computed, Mxrb::Forms::Expression.coerce('$x')
    end
    expect(bridge.to_projection.to_a).to eq([['count', 2], ['showLabel', false], ['title', nil], ['computed', '$x']])
    expect(bridge.to_projection).not_to have_key('price')
  end

  it 'preserves nil separately from absence and does not freeze caller strings' do
    title = +'Original'
    input = { 'title' => title, 'showLabel' => nil }
    bridge = described_class.try_from_projection(widget_id, input, catalog:)
    expect(title).not_to be_frozen
    title.replace('Changed')
    expect(bridge.to_projection).to eq('title' => 'Original', 'showLabel' => nil)
    expect(bridge.typed_value(:title)).to be_frozen
  end

  it 'rejects unknown keys instead of disguising a typo as a successful fallback' do
    expect { described_class.try_from_projection(widget_id, { 'typo' => true }, catalog:) }.to raise_error(KeyError)
    expect do
      described_class.try_from_projection(widget_id, { 'show_label' => false }, catalog:)
    end.to raise_error(KeyError)
    expect { described_class.try_from_projection(widget_id, { 'action' => nil, 'typo' => true }, catalog:) }
      .to raise_error(KeyError)
    expect { described_class.new(widget_id, catalog:).set(:missing, 1) }.to raise_error(KeyError)
  end

  it 'falls back for unsupported shapes, invalid scalar types and lossy normalization' do
    [{ 'action' => { 'kind' => 'microflow', 'handler' => 'App.Flow' } },
     { 'objects' => { 'objects' => [] } }, { 'source' => { 'entity' => 'App.Item' } },
     { 'content' => [] }, { 'count' => '7' }, { 'showLabel' => 'false' },
     { 'price' => 1 }, { 'display' => 'unknown' }, { 'computed' => { 'expression' => '$x' } }].each do |values|
      expect(described_class.try_from_projection(widget_id, values, catalog:)).to be_nil
    end
    expect(described_class.try_from_projection('unavailable', {}, catalog:)).to be_nil
  end

  it 'rejects decimal precision loss and attributed contexts without publishing a partial update' do
    bridge = described_class.build(widget_id, catalog:) { set :title, 'Original' }
    expect { bridge.set(:price, '0.123456789012345678901') }.to raise_error(described_class::UnsupportedProjection)
    attributed = Mxrb::Forms::AttributeReference.through('App.Item.Name', via: 'App.Item')
    expect { bridge.set(:attribute, attributed) }.to raise_error(described_class::UnsupportedProjection)
    expect do
      bridge.evaluate do
        set :title, 'Changed'
        set :count, 'invalid'
      end
    end.to raise_error(TypeError)
    expect(bridge.to_projection).to eq('title' => 'Original')
  end

  it 'bridges scalar captions and image references using real Forms and Pluggable values' do
    template = Mxrb::Forms::Node.build('ClientTemplate') { template 'Caption' }
    reference = Mxrb::Pluggable.reference(:image, 'App.Images.Photo')
    oracle = runtime_properties(native_widget('label' => template, 'image' => reference, 'source' => nil,
                                              'action' => nil))
    expect(oracle).to eq('label' => 'Caption', 'image' => 'App.Images.Photo', 'source' => nil, 'action' => nil)
    bridge = described_class.try_from_projection(widget_id, oracle, catalog:)
    expect(bridge.to_projection.to_a).to eql(oracle.to_a)
    expect(bridge.typed_value(:label)).to be_a(Mxrb::Forms::Node)
    expect(bridge.typed_value(:label).fetch(:template)).to be_a(Mxrb::Forms::Text)
    expect(bridge.typed_value(:image)).to be_a(Mxrb::Pluggable::Reference)
    expect(bridge.typed_value(:image).kind).to eq('Image')
    expect(bridge.to_projection).not_to have_key('objects')
    expect(described_class.try_from_projection(widget_id, { 'objects' => nil }, catalog:)).to be_nil
    expect(described_class.try_from_projection(widget_id, { 'content' => nil }, catalog:)).to be_nil
  end

  it 'refuses caption parameters, translation metadata and mismatched image reference types' do
    bridge = described_class.new(widget_id, catalog:)
    template = Mxrb::Forms::TextTemplate.build('Value {1}', parameters: ['$value'])
    expect { bridge.set(:label, template) }.to raise_error(described_class::UnsupportedProjection)
    localized = Mxrb::Forms::Text.coerce('Localized', language: 'pt_BR')
    expect { bridge.set(:label, localized) }.to raise_error(described_class::UnsupportedProjection)
    foreign = Mxrb::Pluggable.reference(:microflow, 'App.Flow')
    expect { bridge.set(:image, foreign) }.to raise_error(TypeError)
    expect(bridge.to_projection).to eq({})
    image = +'App.Images.Photo'
    bridge.set(:image, image)
    image.replace('changed')
    expect(bridge.to_projection).to eq('image' => 'App.Images.Photo')
  end

  it 'loads schemas from native documents without evaluating source or changing the global catalog' do
    document = native_widget(projection)
    before = Mxrb::Pluggable::Catalog.default.schema_definitions
    mpr = double(all_units: [:unit])
    allow(mpr).to receive(:parse_contents).with(:unit).and_return(document)
    snapshot = described_class.catalog_from_mpr(mpr)
    expect(snapshot.unsupported_widget_ids).to be_empty
    expect(snapshot.catalog).not_to equal(catalog)
    keys = snapshot.catalog.fetch(widget_id).object_type.properties.map(&:key)
    expect(keys).to eq(schema.object_type.properties.map(&:key))
    expect(Mxrb::Pluggable::Catalog.default.schema_definitions).to eq(before)
    expect(described_class.try_from_projection(widget_id, projection, catalog: snapshot.catalog).to_projection)
      .to eq(projection)
  end

  it 'does not expose a partially supported widget when another embedded schema revision is unknown' do
    document = native_widget(projection)
    unsupported = Marshal.load(Marshal.dump(document))
    unsupported.fetch('Type')['FutureSchemaField'] = 'uninterpreted'
    mpr = double(all_units: [:unit])
    allow(mpr).to receive(:parse_contents).with(:unit).and_return([document, unsupported])
    snapshot = described_class.catalog_from_mpr(mpr)
    expect(snapshot.unsupported_widget_ids).to eq([widget_id])
    expect(snapshot.catalog.type(widget_id)).to be_nil
    expect(described_class.try_from_projection(widget_id, projection, catalog: snapshot.catalog)).to be_nil
  end

  it 'reads a real MPR without executing neighboring schema source or mutating native bytes' do
    Dir.mktmpdir('mxrb-pluggable-properties-') do |directory|
      path = File.join(directory, 'ReadOnly.mpr')
      widget = native_widget(projection)
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:App) do
          page(:Home) do
            native_widget 'example', type: 'CustomWidgets$CustomWidget', deep_structure: widget
          end
        end
      end
      FileUtils.mkdir_p(File.join(directory, '.mxrb'))
      File.write(File.join(directory, '.mxrb', 'widget_types.rb'), "raise 'must not execute schema Ruby'\n")
      before = File.binread(path)
      mpr = Mxrb::IO::MprFile.open(path, readonly: true)
      begin
        snapshot = described_class.catalog_from_mpr(mpr)
        expect(snapshot.unsupported_widget_ids).to be_empty
        bridge = described_class.try_from_projection(widget_id, projection, catalog: snapshot.catalog)
        expect(bridge.to_projection.to_a).to eql(projection.to_a)
      ensure
        mpr.close
      end
      expect(File.binread(path)).to eq(before)
    end
  end
end
# rubocop:enable Metrics/BlockLength
