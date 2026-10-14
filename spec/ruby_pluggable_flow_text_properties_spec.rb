# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/ruby_app/pluggable_properties'

# Microflow, nanoflow and translatable string properties, as legacy widgets such as
# timers and HTML snippets use them, are projected to Ruby and written back losslessly.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::PluggableProperties do
  let(:widget_id) { 'com.example.legacy.Timer' }
  let(:catalog) { Mxrb::Pluggable::Catalog.new }
  let!(:schema) do
    Mxrb::Pluggable.widget_type(widget_id, catalog:) do
      properties do
        property :microflow, :microflow
        property :nanoflow, :nanoflow
        property :contents, :translatable_string
      end
    end
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

  let(:text) do
    Mxrb::Forms::Text.new(translations: [Mxrb::Forms::Translation.new('en_US', 'Hello'),
                                         Mxrb::Forms::Translation.new('nl_NL', 'Hallo')])
  end

  it 'imports, projects and emits flow references and translations' do
    document = native_widget('microflow' => Mxrb::Pluggable.reference(:microflow, 'App.Tick'),
                             'nanoflow' => Mxrb::Pluggable.reference(:nanoflow, 'App.ClientTick'),
                             'contents' => text)
    oracle = runtime_properties(document)
    expect(oracle).to eq('microflow' => 'App.Tick', 'nanoflow' => 'App.ClientTick',
                         'contents' => { 'en_US' => 'Hello', 'nl_NL' => 'Hallo' })

    bridge = described_class.try_from_projection(widget_id, oracle, catalog:)
    expect(bridge.to_projection).to eq(oracle)
    expect(bridge.typed_value(:microflow)).to eq(Mxrb::Pluggable.reference(:microflow, 'App.Tick'))
    expect(bridge.source_expression(:contents)).to eq('translatable_text([["en_US", "Hello"], ["nl_NL", "Hallo"]])')
    expect(bridge.source_expression(:microflow)).to be_nil

    empty = runtime_properties(native_widget('microflow' => nil, 'nanoflow' => nil,
                                             'contents' => Mxrb::Forms::Text.new(translations: [])))
    expect(empty).to eq('microflow' => nil, 'nanoflow' => nil, 'contents' => nil)
  end

  it 'selects translation maps from a page projection and ignores absent texts' do
    bridge = described_class.new(widget_id, catalog:).populate_supported_subset(
      'contents' => { 'en_US' => 'Hi', 'pt_BR' => 'Oi' }, 'nanoflow' => 'App.ClientTick'
    )
    expect(bridge.to_projection).to eq('contents' => { 'en_US' => 'Hi', 'pt_BR' => 'Oi' },
                                       'nanoflow' => 'App.ClientTick')
    expect(Mxrb::Model::Page.allocate.send(:pluggable_translatable, nil)).to be_nil
  end

  it 'accepts plain text and rejects malformed values' do
    bridge = described_class.build(widget_id, catalog:) do
      set 'contents', 'Plain'
      set 'microflow', Mxrb::Pluggable.reference(:microflow, 'App.Tick')
    end
    expect(bridge.to_projection).to eq('contents' => { 'en_US' => 'Plain' }, 'microflow' => 'App.Tick')
    expect(described_class.build(widget_id, catalog:) { set 'contents', translatable_text([%w[de_DE Hallo]]) }
             .to_projection).to eq('contents' => { 'de_DE' => 'Hallo' })
    expect { described_class.build(widget_id, catalog:) { set 'contents', translatable_text([['en_US']]) } }
      .to raise_error(ArgumentError, /language, text/)
    expect { described_class.build(widget_id, catalog:) { set 'microflow', 7 } }
      .to raise_error(TypeError, /qualified name/)
    expect { described_class.build(widget_id, catalog:) { set 'nanoflow', Mxrb::Pluggable.reference(:image, 'A.B') } }
      .to raise_error(TypeError, /qualified name/)
  end
end

RSpec.describe Mxrb::Writer do
  let(:writer) { described_class.allocate }

  def property(kind, value)
    { 'ValueType' => { 'Type' => kind }, 'Value' => value }
  end

  it 'writes flow names and keeps translation ids per language' do
    flow = property('Nanoflow', { 'Nanoflow' => 'App.Old', 'Microflow' => '' })
    expect(writer.send(:configure_custom_widget_value!, flow, 'App.New')).to include('Nanoflow' => 'App.New')
    expect(writer.send(:configure_custom_widget_value!, flow, nil)).to include('Nanoflow' => '')

    existing = {
      '$ID' => 'text-id', '$Type' => 'Texts$Text',
      'Items' => Mxrb::IO::BsonCodec.build_array([{ '$ID' => 'en-id', '$Type' => 'Texts$Translation',
                                                    'LanguageCode' => 'en_US', 'Text' => 'Old' }])
    }
    text = property('TranslatableString', { 'TranslatableValue' => existing })
    written = writer.send(:configure_custom_widget_value!, text, { 'en_US' => 'New', 'nl_NL' => 'Nieuw' })
    value = written.fetch('TranslatableValue')
    items = Mxrb::IO::BsonCodec.parse_array(value.fetch('Items'))[:items]
    expect(value.fetch('$ID')).to eq('text-id')
    expect(items.map { _1.values_at('$ID', 'LanguageCode', 'Text') }.first).to eq(%w[en-id en_US New])
    expect(items.last.values_at('LanguageCode', 'Text')).to eq(%w[nl_NL Nieuw])

    plain = writer.send(:configure_custom_widget_value!, property('TranslatableString', {}), 'Text')
    expect(Mxrb::IO::BsonCodec.parse_array(plain.dig('TranslatableValue', 'Items'))[:items].first)
      .to include('LanguageCode' => 'en_US', 'Text' => 'Text')
    expect(writer.send(:configure_custom_widget_value!, property('TranslatableString', {}), nil)).to eq({})
    cleared = writer.send(:configure_custom_widget_value!,
                          property('TranslatableString', { 'TranslatableValue' => existing }), nil)
    expect(Mxrb::IO::BsonCodec.parse_array(cleared.dig('TranslatableValue', 'Items'))[:items]).to eq([])
  end
end
# rubocop:enable Metrics/BlockLength
