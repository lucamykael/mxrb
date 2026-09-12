# frozen_string_literal: true

require 'spec_helper'

# Keep the synthetic schema and its atomicity scenarios together.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'pluggable property fail-closed guards' do
  let(:writer) { Mxrb::Writer.new('/tmp/unused-property-guard.mpr', version: '11.12.1', modules: []) }

  def schema_widget(name = 'Map') # rubocop:disable Metrics/MethodLength
    property_type = {
      '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetPropertyType', 'PropertyKey' => 'mode',
      'ValueType' => {
        '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetValueType',
        'Type' => 'String', 'DefaultValue' => 'original'
      }
    }
    object_type = {
      '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetObjectType',
      'PropertyTypes' => Mxrb::IO::BsonCodec.build_array([property_type], marker: 2)
    }
    {
      '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$CustomWidget', 'Name' => name,
      'Type' => { 'WidgetId' => 'example.Map', 'ObjectType' => object_type },
      'Object' => writer.send(:custom_widget_object_doc, object_type)
    }
  end

  def pending_widget(options, name = 'Map')
    {
      '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$CustomWidget', 'Name' => name,
      'Type' => { 'WidgetId' => 'example.Map' }, '__mxrb_widget_options' => options
    }
  end

  def bytes(document) = Mxrb::IO::BsonCodec.serialize(document)

  it 'rejects all unknown keys before updating a known value or touching slots' do
    widget = schema_widget
    options = { properties: { mode: 'edited', mdoe: 'discarded' }, __slots: [{ path: ['missing'] }] }
    previous_widget = bytes(widget)
    previous_options = Marshal.dump(options)

    expect { writer.send(:configure_pluggable_widget!, widget, options) }
      .to raise_error(Mxrb::ValidationError, /unknown properties: :mdoe/)

    expect(bytes(widget)).to eq(previous_widget)
    expect(Marshal.dump(options)).to eq(previous_options)
  end

  it 'rejects unknown properties even when explicitly nil' do
    widget = schema_widget
    previous = bytes(widget)
    expect { writer.send(:configure_pluggable_widget!, widget, properties: { 'mdoe' => nil }) }
      .to raise_error(Mxrb::ValidationError, /unknown properties/)
    expect(bytes(widget)).to eq(previous)
  end

  it 'preflights the whole hydration batch before changing baselines or removing metadata' do
    options = { __kind: :pluggable_widget, properties: { mode: 'edited' } }
    invalid = { __kind: :pluggable_widget, properties: { mode: 'edited', mdoe: 'discarded' } }
    generated = { 'Widgets' => [pending_widget(options, 'First'), pending_widget(invalid)] }
    baseline = { 'Widgets' => [schema_widget('First'), schema_widget] }
    previous = [bytes(generated), bytes(baseline), Marshal.dump([options, invalid])]

    expect { writer.send(:hydrate_pluggable_widgets!, generated, baseline) }
      .to raise_error(Mxrb::ValidationError, /unknown properties/)

    expect([bytes(generated), bytes(baseline), Marshal.dump([options, invalid])]).to eq(previous)
  end

  it 'validates complete generated schemas before deleting their pending options' do
    widget = schema_widget
    widget['__mxrb_widget_options'] = { __kind: :pluggable_widget, properties: { mdoe: 'discarded' } }
    generated = { 'Widgets' => [widget] }
    previous = bytes(generated)

    expect { writer.send(:hydrate_pluggable_widgets!, generated, {}) }
      .to raise_error(Mxrb::ValidationError, /unknown properties/)

    expect(bytes(generated)).to eq(previous)
  end

  it 'rejects nonempty properties without a schema before mutating any widget or options' do
    [nil, false, ''].each do |value|
      options = { __kind: :pluggable_widget, properties: { mode: value }, __slots: [] }
      valid = { __kind: :pluggable_widget, properties: { mode: 'edited' } }
      generated = { 'Widgets' => [pending_widget(valid, 'First'), pending_widget(options)] }
      baseline = { 'Widgets' => [schema_widget('First')] }
      previous = [bytes(generated), bytes(baseline), Marshal.dump(options)]

      expect { writer.send(:hydrate_pluggable_widgets!, generated, baseline) }
        .to raise_error(Mxrb::ValidationError, /declared properties.*definition is unavailable/)

      expect([bytes(generated), bytes(baseline), Marshal.dump(options)]).to eq(previous)
    end
  end

  it 'keeps absent or empty properties valid when no schema is available' do
    [{ __kind: :pluggable_widget }, { __kind: :pluggable_widget, properties: {} }].each do |options|
      widget = pending_widget(options)
      previous_options = Marshal.dump(options)
      expect { writer.send(:hydrate_pluggable_widgets!, { 'Widgets' => [widget] }, {}) }.not_to raise_error
      expect(widget).not_to have_key('__mxrb_widget_options')
      expect(Marshal.dump(options)).to eq(previous_options)
    end
  end

  it 'preserves known string and symbol keys, explicit nil and caller-owned values' do
    widget = schema_widget
    [{ 'mode' => 'edited' }, { mode: nil }].each do |properties|
      options = { properties: }
      previous_options = Marshal.dump(options)
      writer.send(:configure_pluggable_widget!, widget, options)
      expected = properties.values.first || 'original'
      expect(writer.send(:custom_widget_properties, widget).dig('mode', 'Value', 'PrimitiveValue')).to eq(expected)
      expect(Marshal.dump(options)).to eq(previous_options)
    end
    previous = bytes(widget)
    writer.send(:configure_pluggable_widget!, widget, properties: {})
    expect(bytes(widget)).to eq(previous)
  end

  it 'rejects typos supplied through the legacy public widget DSL' do
    builder = Mxrb::Dsl::WidgetSlotBuilder.new
    builder.pluggable_widget :Map, widget_id: 'example.Map', properties: { mode: 'edited', mdoe: 'discarded' }
    declaration = builder.widgets.fetch(0)
    widget = schema_widget
    previous = bytes(widget)

    expect { writer.send(:configure_pluggable_widget!, widget, declaration.fetch(:options)) }
      .to raise_error(Mxrb::ValidationError, /unknown properties/)

    expect(bytes(widget)).to eq(previous)
  end
end
# rubocop:enable Metrics/BlockLength
