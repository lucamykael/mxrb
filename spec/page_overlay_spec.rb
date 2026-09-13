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

  def page_with(*widgets)
    {
      '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Page', 'Name' => 'Page',
      'Widgets' => Mxrb::IO::BsonCodec.build_array(widgets, marker: 2)
    }
  end

  def projected_widget(type, name, declared_fields: [], options: {})
    { type:, name:, declared_fields:, options: }
  end

  def encoded_widget(type, name, fields = {})
    {
      '$ID' => SecureRandom.uuid, '$Type' => "Forms$#{type}", 'Name' => name,
      'Appearance' => {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$Appearance',
        'Class' => '', 'DynamicClasses' => '', 'Style' => ''
      }
    }.merge(fields)
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

  it 'locates form-call widget slots and rejects absent or multiple root slots' do
    instance = described_class.allocate
    nested = encoded_widget('DataView', 'Nested')
    argument_slots = {
      'FormCall' => {
        'Arguments' => [3, nil, { 'Widgets' => [2, nested] }, { 'Widget' => nested }, 'ignored']
      }
    }

    expect(instance.send(:root_slots, argument_slots)).to eq([[nested], [nested]])
    expect(instance.send(:root_slots, 'FormCall' => 'invalid')).to be_empty
    expect { instance.send(:sole_root_slot, {}) }
      .to raise_error(Mxrb::ValidationError, /exactly one root widget slot \(found 0\)/)
    expect { instance.send(:sole_root_slot, argument_slots) }
      .to raise_error(Mxrb::ValidationError, /found 2/)
  end

  it 'applies scalar and appearance fields while retaining unsupported native content' do
    original = projected_widget(
      :data_view, 'Details', declared_fields: %i[editable class style],
                             options: { editable: 'Never', class: 'old', style: 'color:red' }
    )
    edited = projected_widget(
      :data_view, 'Details', declared_fields: %i[editable class style],
                             options: { editable: 'Always', class: 'new', style: 'color:blue' }
    )
    native = encoded_widget(
      'DataView', 'Details', 'Editability' => 'Never', 'Unknown' => 'retained'
    )
    generated = Marshal.load(Marshal.dump(native))
    generated['Editability'] = 'Always'
    generated['Appearance']['Class'] = 'new'
    generated['Appearance']['Style'] = 'color:blue'
    native['Appearance']['Class'] = 'old'
    native['Appearance']['Style'] = 'color:red'
    baseline = page_with(native)

    result = described_class.new(
      baseline:, target: Marshal.load(Marshal.dump(baseline)), widgets: [edited],
      encoded_widgets: [generated], metadata: described_class.metadata([original])
    ).apply
    rebuilt = result.fetch('Widgets').last

    expect(rebuilt).to include('Editability' => 'Always', 'Unknown' => 'retained')
    expect(rebuilt.fetch('Appearance')).to include('Class' => 'new', 'Style' => 'color:blue')
  end

  it 'rejects missing appearance, missing matches, ambiguous matches, and duplicate projections' do
    source = projected_widget(:table, 'Grid', declared_fields: [:class], options: { class: 'old' })
    edited = projected_widget(:table, 'Grid', declared_fields: [:class], options: { class: 'new' })
    native = encoded_widget('Table', 'Grid')
    generated = Marshal.load(Marshal.dump(native))
    generated['Appearance']['Class'] = 'new'
    metadata = described_class.metadata([source])

    missing_appearance = page_with(native.reject { _1 == 'Appearance' })
    expect do
      described_class.new(
        baseline: missing_appearance, target: missing_appearance, widgets: [edited],
        encoded_widgets: [generated], metadata:
      ).apply
    end.to raise_error(Mxrb::ValidationError, /missing Appearance/)

    missing = page_with(encoded_widget('Table', 'Other'))
    expect do
      described_class.new(
        baseline: missing, target: missing, widgets: [edited], encoded_widgets: [generated], metadata:
      ).apply
    end.to raise_error(Mxrb::ValidationError, /missing widget/)

    ambiguous = page_with(native, Marshal.load(Marshal.dump(native)))
    expect do
      described_class.new(
        baseline: ambiguous, target: ambiguous, widgets: [edited],
        encoded_widgets: [generated], metadata:
      ).apply
    end.to raise_error(Mxrb::ValidationError, /ambiguous widget/)

    duplicate_metadata = described_class.metadata([source, source])
    expect do
      described_class.new(
        baseline: page_with(native), target: page_with(native), widgets: [edited, edited],
        encoded_widgets: [generated, generated], metadata: duplicate_metadata
      ).apply
    end.to raise_error(Mxrb::ValidationError, /multiple Ruby widgets/)
  end

  it 'merges explicit structural edits while preserving native identities and array markers' do
    original = projected_widget(:layout_grid, 'Grid', options: { children: [] })
    edited = projected_widget(:layout_grid, 'Grid', options: { children: [{ type: :text, name: 'Title' }] })
    child_id = SecureRandom.uuid
    native = encoded_widget(
      'LayoutGrid', 'Grid',
      'Rows' => [3, { '$ID' => child_id, '$Type' => 'Forms$LayoutGridRow', 'Name' => 'Row',
                      'Legacy' => true }]
    )
    generated = encoded_widget(
      'LayoutGrid', 'Grid',
      'Rows' => [2, { '$ID' => SecureRandom.uuid, '$Type' => 'Forms$LayoutGridRow', 'Name' => 'Row',
                      'Weight' => 12 },
                 { '$ID' => SecureRandom.uuid, '$Type' => 'Forms$LayoutGridRow', 'Name' => 'Added' }]
    )
    metadata = described_class.metadata([original]).merge('apply_fields' => false)
    baseline = page_with(native)

    result = described_class.new(
      baseline:, target: Marshal.load(Marshal.dump(baseline)), widgets: [edited],
      encoded_widgets: [generated], metadata:
    ).apply
    merged = result.fetch('Widgets').last

    expect(merged.fetch('$ID')).to eq(native.fetch('$ID'))
    expect(merged.fetch('Rows').first).to eq(3)
    expect(merged.fetch('Rows')[1]).to include('$ID' => child_id, 'Legacy' => true, 'Weight' => 12)
    expect(merged.fetch('Rows')[2]).to include('Name' => 'Added')
  end

  it 'rejects unsafe structural matching and target drift' do
    original = projected_widget(:layout_grid, 'Grid')
    edited = projected_widget(:layout_grid, 'Renamed')
    native = encoded_widget('LayoutGrid', 'Grid')
    generated = encoded_widget('LayoutGrid', 'Renamed')
    metadata = described_class.metadata([original]).merge('apply_fields' => false)
    baseline = page_with(native)

    expect do
      described_class.new(
        baseline:, target: baseline, widgets: [edited], encoded_widgets: [generated], metadata:
      ).apply
    end.to raise_error(Mxrb::ValidationError, /cannot safely match edited widget/)

    target = Marshal.load(Marshal.dump(baseline)).merge('Documentation' => 'changed')
    expect do
      described_class.new(
        baseline:, target:, widgets: [original], encoded_widgets: [native],
        metadata: described_class.metadata([original])
      ).apply
    end.to raise_error(Mxrb::ValidationError, /page changed outside/)
  end

  it 'normalizes table placement and redundant pluggable slot projections in fingerprints' do
    implicit = projected_widget(
      :table, 'Grid',
      options: {
        rows: [
          { cells: [{ rowspan: 2 }, { colspan: 2 }] },
          { cells: [{}] }
        ]
      }
    )
    explicit = Marshal.load(Marshal.dump(implicit))
    explicit[:options][:rows][0][:cells][0][:column] = 0
    explicit[:options][:rows][0][:cells][1][:column] = 1
    explicit[:options][:rows][1][:cells][0][:column] = 1
    expect(described_class.metadata([implicit])).to eq(described_class.metadata([explicit]))

    child = { type: :text, name: 'Child' }
    slotted = {
      type: :pluggable_widget, name: 'Custom', arguments: {},
      children: [child], slots: [{ widgets: [child] }]
    }
    without_children = slotted.reject { _1 == :children }
    expect(described_class.metadata([slotted])).to eq(described_class.metadata([without_children]))
  end

  it 'returns the target unchanged for disabled field application and non-actionable widgets' do
    unsupported = projected_widget(:text, 'Label', declared_fields: [:caption])
    target = page_with(encoded_widget('Text', 'Label'))
    metadata = described_class.metadata([unsupported])
    result = described_class.new(
      baseline: target, target:, widgets: [unsupported], encoded_widgets: [target['Widgets'].last], metadata:
    ).apply
    expect(result).to eq(target)

    no_fields = projected_widget(:table, 'Grid', declared_fields: [:class])
    native = encoded_widget('Table', 'Grid')
    disabled = described_class.metadata([no_fields]).merge('apply_fields' => false)
    expect(described_class.new(
      baseline: page_with(native), target: page_with(native), widgets: [no_fields],
      encoded_widgets: [native], metadata: disabled
    ).apply.fetch('Widgets').last).to include('Name' => 'Grid')
  end

  it 'normalizes all supported redundant slot projections and rejects malformed ones' do
    child = { 'type' => 'text', 'name' => 'Child' }
    nested = { 'type' => 'container', 'name' => 'Root', 'children' => [child] }
    slots = [{ 'widgets' => [nested] }]
    preorder = [nested, child]

    expect(described_class.send(:slotted_widget_preorder, slots)).to eq(preorder)
    expect(described_class.send(:nested_slotted_widgets, slots)).to eq([nested])
    expect(described_class.send(:redundant_slotted_projection?, preorder, slots)).to be true
    expect(described_class.send(
             :redundant_widget_children?, 'type' => 'pluggable_widget', 'children' => [], 'slots' => nil
           )).to be true
    expect(described_class.send(
             :redundant_widget_children?, 'type' => 'text', 'children' => [], 'slots' => slots
           )).to be false
    expect(described_class.send(
             :redundant_widget_children?, 'type' => 'pluggable_widget', 'children' => 'bad', 'slots' => slots
           )).to be false
    expect(described_class.send(
             :redundant_widget_children?, 'type' => 'pluggable_widget', 'children' => [child],
                                          'slots' => [{}]
           )).to be false

    nested_slots = [{ 'widgets' => [child, child] }, { 'widgets' => [nested] }]
    expect(described_class.send(:nested_slotted_widgets, nested_slots)).to eq([child, nested])
    expect(described_class.send(:collect_widget_preorder, 'scalar', [])).to be_nil
    expect(described_class.send(:collect_widget_preorder, {}, [])).to be_empty
  end

  it 'covers marker-free semantic arrays and defensive matching fallbacks' do
    instance = described_class.allocate
    previous = [
      { '$ID' => 'kept', '$Type' => 'Forms$Row', 'Name' => '', 'Legacy' => true },
      'old scalar'
    ]
    current = [
      { '$ID' => 'new', '$Type' => 'Forms$Row', 'Name' => '', 'Weight' => 6 },
      'new scalar', 'added'
    ]
    merged = instance.send(:merge_semantic_array, previous, current)

    expect(merged.first).to include('$ID' => 'kept', 'Legacy' => true, 'Weight' => 6)
    expect(merged.drop(1)).to eq(['new scalar', 'added'])
    expect(instance.send(:semantic_array_match, previous, 'scalar')).to be_nil
    expect(instance.send(:root_slots, 'FormCall' => {})).to be_empty
    expect(instance.send(:collection_items, %w[one two])).to eq(%w[one two])
    expect(instance.send(:merge_semantic_value, {}, 'replacement')).to eq('replacement')
    instance.instance_variable_set(:@metadata, { 'widgets' => [] })
    expect(instance.send(:scrub_supported_fields!, {})).to be_nil
  end

  it 'rejects missing structural metadata and accepts symbol-key metadata' do
    native = encoded_widget('Table', 'Grid')
    projected = projected_widget(:table, 'Grid')
    target = page_with(native)
    expect do
      described_class.new(
        baseline: target, target:, widgets: [projected], encoded_widgets: [native], metadata: nil
      ).apply
    end.to raise_error(Mxrb::ValidationError, /no structural baseline/)

    string_metadata = described_class.metadata([projected])
    symbol_metadata = string_metadata.transform_keys(&:to_sym)
    expect(described_class.new(
      baseline: target, target:, widgets: [projected], encoded_widgets: [native],
      metadata: symbol_metadata
    ).apply).to eq(target)
  end
end
# rubocop:enable Metrics/BlockLength
