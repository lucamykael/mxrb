# frozen_string_literal: true

require 'spec_helper'
require 'zip'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Frontend::Migrator do
  subject(:migrator) { described_class.new('/tmp/App.mpr') }

  def array(items = [], marker: 2)
    Mxrb::IO::BsonCodec.build_array(items, marker:)
  end

  def value_type(type, default: '', required: false, object_type: nil, selections: [])
    {
      '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetValueType',
      'Type' => type, 'DefaultValue' => default, 'Required' => required,
      'Translations' => array, 'SelectionTypes' => array(selections, marker: 1),
      'ObjectType' => object_type
    }
  end

  def property_type(key, value_type)
    {
      '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetPropertyType',
      'PropertyKey' => key, 'ValueType' => value_type
    }
  end

  def object_type(types)
    {
      '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetObjectType',
      'PropertyTypes' => array(types)
    }
  end

  def property(type, value)
    {
      '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetProperty',
      'TypePointer' => type['$ID'], 'Value' => value
    }
  end

  def object(type, properties)
    {
      '$ID' => SecureRandom.uuid, '$Type' => 'CustomWidgets$WidgetObject',
      'Properties' => array(properties), 'TypePointer' => type['$ID']
    }
  end

  def default_value(type)
    migrator.send(:default_value, type)
  end

  it 'covers fail-closed envelopes and schema rebinding edge contracts' do
    issues = []
    expect(migrator.send(:safe_envelope?, {}, {}, {}, 'u', '$', issues)).to be(false)

    widget = { 'Type' => { 'Mystery' => true }, 'Object' => {} }
    expect(migrator.send(:safe_envelope?, widget, {}, {}, 'u', '$', issues)).to be(false)
    widget = { 'Type' => {}, 'Object' => { 'Mystery' => true } }
    expect(migrator.send(:safe_envelope?, widget, {}, {}, 'u', '$', issues)).to be(false)
    expect(migrator.send(:safe_envelope?, { 'Type' => {}, 'Object' => {} }, {}, {},
                         'u', '$', issues)).to be(true)

    old_vt = value_type('String')
    old_pt = property_type('legacy', old_vt)
    old_type = object_type([old_pt])
    new_type = object_type([])
    old_value = default_value(old_vt)
    old_object = object(old_type, [property(old_pt, old_value)])
    new_object = object(new_type, [])
    expect(migrator.send(:rebind_object, old_object, old_type, new_object, new_type,
                         'u', '$', issues)).to be_a(Hash)

    old_object['Properties'] = array([{ 'TypePointer' => SecureRandom.uuid, 'Value' => old_value }])
    expect(migrator.send(:rebind_object, old_object, old_type, new_object, new_type,
                         'u', '$', issues)).to be(false)
    expect(issues.map(&:kind)).to include(:malformed_widget, :unknown_widget_schema,
                                          :unknown_widget_object, :unknown_property_pointer)
  end

  it 'covers widget values, conversions, objects and inactive captions' do
    issues = []
    string = value_type('String')
    expect(migrator.send(:rebind_value, nil, string, string, 'u', '$', issues)).to be(false)

    nested_old = value_type('Object', object_type: nil)
    nested_new = value_type('Object', object_type: nil)
    empty = default_value(nested_old)
    rebound = migrator.send(:rebind_value, empty, nested_old, nested_new, 'u', '$', issues)
    expect(Mxrb::IO::BsonCodec.parse_array(rebound['Objects'])[:items]).to be_empty

    empty['Objects'] = array([{ '$Type' => 'CustomWidgets$WidgetObject' }])
    expect(migrator.send(:rebind_value, empty, nested_old, nested_new, 'u', '$', issues)).to be(false)

    boolean = value_type('Boolean', default: 'false')
    expression = value_type('Expression')
    optional_text = value_type('TextTemplate')
    expect(default_value(optional_text)['TextTemplate']).to be_nil
    explicit_selection = value_type('Selection', default: 'Multi', selections: %w[Single Multi])
    expect(default_value(explicit_selection)['Selection']).to eq('Multi')
    invalid = default_value(boolean).merge('PrimitiveValue' => 'maybe')
    expect(migrator.send(:convert_value, invalid, boolean, expression, 'u', '$', issues)).to be(false)
    configured = default_value(boolean).merge('PrimitiveValue' => 'true', 'Image' => 'configured')
    expect(migrator.send(:convert_value, configured, boolean, expression,
                         'u', '$', issues)).to be(false)

    caption_type = property_type('selectCaption', value_type('TextTemplate', required: true))
    controller_type = property_type('select', value_type('Boolean', default: 'false'))
    caption = property(caption_type, default_value(caption_type['ValueType']))
    controller = property(controller_type, default_value(controller_type['ValueType']))
    properties = { 'selectCaption' => caption, 'select' => controller }
    migrator.send(:clear_inactive_default_captions!, properties,
                  'selectCaption' => caption_type, 'select' => controller_type)
    expect(caption.dig('Value', 'TextTemplate')).to be_nil

    custom = property(caption_type, default_value(caption_type['ValueType']))
    custom['Value']['PrimitiveValue'] = 'custom'
    migrator.send(:clear_inactive_default_captions!, { 'selectCaption' => custom },
                  'selectCaption' => caption_type)
    expect(custom.dig('Value', 'TextTemplate')).not_to be_nil
  end

  it 'covers weight normalization and design-property helpers' do
    expect(migrator.send(:normalize_weights, [1, 11])).to be_nil
    expect(migrator.send(:normalize_weights, ['x', -1])).to be_nil
    expect(migrator.send(:normalize_weights, [12, -1])).to be_nil
    expect(migrator.send(:normalize_weights, [13])).to be_nil
    expect(migrator.send(:normalize_weights, [10, -1, -1, -1])).to be_nil
    expect(migrator.send(:normalize_weights, [-1, -1])).to eq([6, 6])

    mappings = {}
    migrator.send(:collect_design_aliases, nil, mappings)
    property = {
      'name' => 'New', 'type' => 'Dropdown', 'oldNames' => ['Old'],
      'options' => [{ 'name' => 'On', 'oldNames' => ['Yes'] }]
    }
    migrator.send(:collect_design_aliases, property, mappings)
    migrator.send(:add_design_alias, mappings, ['Old', nil], key: 'Conflict')
    expect(mappings.values).to include(:conflict)

    spacing = {
      'name' => 'Spacing', 'type' => 'Spacing',
      'margin' => [{ 'name' => 'M', 'top' => { 'oldNames' => ['Old top'] } }]
    }
    spacing_mappings = {}
    migrator.send(:collect_spacing_mappings, nil, spacing_mappings)
    migrator.send(:collect_spacing_mappings, spacing, spacing_mappings)
    migrator.send(:collect_spacing_mappings, spacing, spacing_mappings)
    expect(spacing_mappings['Old top']).to include(key: 'Spacing', child: 'margin-top')
    expect(migrator.send(:design_property_name, nil)).to be_nil
    expect(migrator.send(:compound_design_property?, nil)).to be(false)
  end

  it 'covers audited package visibility and model evolution normalization' do
    boolean = value_type('Boolean')
    enum = value_type('Enumeration')
    selection = value_type('Selection', selections: %w[Single Multi])
    text = value_type('TextTemplate', required: true)
    nested_types = %w[showContentAs dynamicText exportValue tooltip].map do |key|
      property_type(key, key == 'showContentAs' ? enum : text)
    end
    nested_object_type = object_type(nested_types)
    columns_type = property_type('columns', value_type('Object', object_type: nested_object_type))
    top_types = [
      columns_type, property_type('pagination', enum), property_type('itemSelection', selection),
      property_type('loadMoreButtonCaption', text),
      property_type('clearSelectionButtonLabel', text),
      property_type('singleSelectionColumnLabel', text), property_type('orphan', boolean)
    ]
    top_type = object_type(top_types)
    column_values = nested_types.map do |type|
      value = default_value(type['ValueType'])
      value['PrimitiveValue'] = 'attribute' if type['PropertyKey'] == 'showContentAs'
      property(type, value)
    end
    column_values << { 'TypePointer' => SecureRandom.uuid, 'Value' => {} }
    column = object(nested_object_type, column_values)
    properties = top_types.map do |type|
      value = default_value(type['ValueType'])
      value['Objects'] = array([column]) if type['PropertyKey'] == 'columns'
      property(type, value)
    end
    properties << { 'TypePointer' => SecureRandom.uuid, 'Value' => {} }
    top_object = object(top_type, properties)

    migrator.send(:apply_audited_package_migration!, top_object,
                  { 'ObjectType' => top_type }, 'other')
    migrator.send(:apply_audited_package_migration!, top_object,
                  { 'ObjectType' => top_type }, described_class::AUDITED_DATA_GRID_PACKAGE_SHA256)
    expect(properties[3].dig('Value', 'TextTemplate')).to be_nil

    migrator.send(:clear_audited_data_grid_column_texts!, nil, nil)
    page_variable = {
      '$Type' => 'Forms$PageVariable', 'SnippetParameter' => 'P', 'Other' => [{}]
    }
    expect(migrator.send(:normalize_source_variable, page_variable)['SubKey']).to eq('')
    nanoflow = { '$Type' => 'Forms$CallNanoflowClientAction', 'Nanoflow' => 'N' }
    microflow = { '$Type' => 'Forms$MicroflowSettings', 'Microflow' => 'M' }
    expect(migrator.send(:normalize_source_variable, nanoflow)).to have_key('OutputMappings')
    expect(migrator.send(:normalize_source_variable, microflow)).to have_key('OutputMappings')
    expect(migrator.send(:normalize_source_variable, [1, 'x'])).to eq([1, 'x'])
  end

  it 'covers id preservation and canonical copying across nonmatching shapes' do
    target = { '$ID' => 'new', 'Child' => [{ '$ID' => 'new-child' }], 'Only' => true }
    source = { '$ID' => 'old', 'Child' => [{ '$ID' => 'old-child' }] }
    expect(migrator.send(:preserve_ids!, target, source).dig('Child', 0, '$ID')).to eq('old-child')
    expect(migrator.send(:preserve_ids!, {}, [])).to eq({})
    expect(migrator.send(:preserve_ids!, [], {})).to eq([])
    expect(migrator.send(:canonical_schema, [{ '$ID' => 'x', 'Value' => 1 }]))
      .to eq([{ 'Value' => 1 }])
    expect(migrator.send(:deep_copy, 1)).to eq(1)
  end

  it 'covers migration-plan concurrency guards and widget early exits' do
    plan = Mxrb::Frontend::MigrationPlan.new(path: '/tmp/missing.mpr', version: '11',
                                             changes: [], issues: [])
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise(Errno::ENOENT)
    expect { plan.apply! }.to raise_error(Errno::ENOENT)

    fake_mpr = instance_double(Mxrb::IO::MprFile, close: nil)
    allow(Mxrb::IO::MprFile).to receive(:open).and_return(fake_mpr)
    allow(fake_mpr).to receive(:transaction).and_yield
    allow(fake_mpr).to receive(:unit).and_return(nil)
    change = Mxrb::Frontend::MigrationChange.new('gone', 'hash', {}, {}, 0, 0, 0)
    gone = Mxrb::Frontend::MigrationPlan.new(path: '/tmp/x.mpr', version: '11',
                                             changes: [change], issues: [])
    expect { gone.apply! }.to raise_error(Mxrb::SerializationError, /disappeared/)
    allow(fake_mpr).to receive(:unit).and_return('ContentsHash' => 'other')
    expect { gone.apply! }.to raise_error(Mxrb::SerializationError, /changed after preview/)

    counts = { widgets: 0 }
    issues = []
    migrator.send(:migrate_widget!, { 'Type' => {} }, 'u', '$', issues, counts)
    allow(migrator).to receive(:definition).and_return(nil)
    migrator.send(:migrate_widget!, { 'Type' => { 'WidgetId' => 'missing' } },
                  'u', '$', issues, counts)
    allow(migrator).to receive(:definition).and_call_original
  end

  it 'covers nested object success and value rejection branches' do
    old_child_value = value_type('String')
    old_child_property = property_type('name', old_child_value)
    old_child_type = object_type([old_child_property])
    new_child_value = value_type('String')
    new_child_property = property_type('name', new_child_value)
    new_child_type = object_type([new_child_property])
    old_outer = value_type('Object', object_type: old_child_type)
    new_outer = value_type('Object', object_type: new_child_type)
    child = object(old_child_type, [property(old_child_property, default_value(old_child_value))])
    outer = default_value(old_outer)
    outer['Objects'] = array([child])
    issues = []
    result = migrator.send(:rebind_value, outer, old_outer, new_outer, 'u', '$', issues)
    expect(Mxrb::IO::BsonCodec.parse_array(result['Objects'])[:items].size).to eq(1)

    incompatible = value_type('Integer')
    old_pt = property_type('name', old_child_value)
    new_pt = property_type('name', incompatible)
    expect(migrator.send(:rebind_object,
                         object(old_child_type, [property(old_pt, default_value(old_child_value))]),
                         object_type([old_pt]), object(object_type([new_pt]), []),
                         object_type([new_pt]), 'u', '$', issues)).to be_nil

    no_id = object(object_type([]), [])
    no_id.delete('$ID')
    expect(migrator.send(:rebind_object, no_id, object_type([]), object(object_type([]), []),
                         object_type([]), 'u', '$', issues)).to be_a(Hash)
    expect(migrator.send(:object_template, new_child_type)).to include('$Type' => 'CustomWidgets$WidgetObject')
  end

  it 'covers layout and design no-op, conflict, cache and malformed-file paths' do
    counts = { layout_rows: 0, design_properties: 0 }
    issues = []
    migrator.send(:migrate_layout_row!, { 'Columns' => array }, 'u', '$', issues, counts)
    valid_columns = array([{ 'Weight' => 12 }])
    migrator.send(:migrate_layout_row!, { 'Columns' => valid_columns }, 'u', '$', issues, counts)
    expect(counts[:layout_rows]).to eq(0)

    migrator.instance_variable_set(:@spacing_mappings, {})
    migrator.instance_variable_set(:@design_alias_mappings, {})
    migrator.send(:migrate_design_properties!, { 'DesignProperties' => array },
                  'u', '$', issues, counts)
    plain = {
      '$Type' => 'Forms$DesignPropertyValue', 'Key' => 'Plain',
      'Value' => { '$Type' => 'Forms$OptionDesignPropertyValue', 'Option' => 'On' }
    }
    owner = { 'DesignProperties' => array([plain]) }
    migrator.send(:migrate_design_properties!, owner, 'u', '$', issues, counts)
    expect(counts[:design_properties]).to eq(0)

    migrator.instance_variable_set(:@spacing_mappings, 'Old::M' => {
      key: 'Spacing', child: 'margin-top', option: 'M'
    })
    existing = migrator.send(:compound_design_property, 'Spacing')
    existing['Value']['Properties'] = array([
                                              migrator.send(:option_design_property, 'margin-top', 'L')
                                            ])
    legacy = Marshal.load(Marshal.dump(plain)).merge('Key' => 'Old')
    legacy['Value']['Option'] = 'M'
    owner = { 'DesignProperties' => array([existing, legacy]) }
    migrator.send(:migrate_design_properties!, owner, 'u', '$', issues, counts)
    expect(issues.map(&:kind)).to include(:conflicting_design_property)
    expect(migrator.send(:spacing_mappings)).to be_a(Hash)
    expect(migrator.send(:design_alias_mappings)).to be_a(Hash)
  end

  it 'covers definition cache, nil-safe accessors and all audited visibility outcomes' do
    migrator.instance_variable_set(:@definitions, 'cached' => :definition)
    expect(migrator.send(:definition, 'cached')).to eq(:definition)
    expect(migrator.send(:definition, 'missing')).to be_nil
    expect(migrator.send(:definition, 'missing')).to be_nil
    expect(migrator.send(:package_digest, 'missing')).to be_nil
    expect(migrator.send(:property_types, nil)).to eq([])
    expect(migrator.send(:property_values, nil)).to eq([])

    enum = value_type('Enumeration')
    selection = value_type('Selection', selections: %w[Single Multi])
    text = value_type('TextTemplate', required: true)
    nested_types = %w[showContentAs dynamicText exportValue tooltip].map do |key|
      property_type(key, key == 'showContentAs' ? enum : text)
    end
    nested_schema = object_type(nested_types)
    columns = property_type('columns', value_type('Object', object_type: nested_schema))
    top_types = [columns, property_type('pagination', enum),
                 property_type('itemSelection', selection),
                 property_type('loadMoreButtonCaption', text),
                 property_type('clearSelectionButtonLabel', text),
                 property_type('singleSelectionColumnLabel', text)]
    top_schema = object_type(top_types)
    column_objects = %w[dynamicText customContent].map do |content|
      props = nested_types.map do |type|
        value = default_value(type['ValueType'])
        value['PrimitiveValue'] = content if type['PropertyKey'] == 'showContentAs'
        property(type, value)
      end
      object(nested_schema, props)
    end
    top_properties = top_types.map do |type|
      value = default_value(type['ValueType'])
      case type['PropertyKey']
      when 'columns' then value['Objects'] = array(column_objects)
      when 'pagination' then value['PrimitiveValue'] = 'loadMore'
      when 'itemSelection' then value['Selection'] = 'Multi'
      end
      property(type, value)
    end
    top_object = object(top_schema, top_properties)
    migrator.send(:apply_audited_package_migration!, top_object, { 'ObjectType' => top_schema },
                  described_class::AUDITED_DATA_GRID_PACKAGE_SHA256)
    expect(top_object).to be_a(Hash)
    migrator.send(:clear_text_template!, nil)
  end

  it 'closes the remaining guards, design merges and malformed package branches' do
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise(Errno::ENOENT)
    expect { described_class.new('/tmp/absent.mpr').plan }.to raise_error(Errno::ENOENT)

    fake_mpr = instance_double(Mxrb::IO::MprFile, close: nil)
    allow(Mxrb::IO::MprFile).to receive(:open).and_return(fake_mpr)
    allow(fake_mpr).to receive(:transaction).and_yield
    settled = Mxrb::Frontend::MigrationPlan.new(path: '/tmp/x.mpr', version: '11',
                                                changes: [], issues: [])
    expect(settled.apply!).to equal(settled)
    expect { settled.apply! }.to raise_error(Mxrb::SerializationError, /already applied/)

    issues = []
    counts = { widgets: 0 }
    definition = instance_double(Mxrb::WidgetPackage::Definition)
    allow(migrator).to receive(:definition).and_return(definition)
    empty_type = object_type([])
    template = [{ 'WidgetId' => 'x', 'ObjectType' => empty_type }, object(empty_type, [])]
    allow(Mxrb::WidgetPackage).to receive(:template).and_return(template)
    malformed = { '$Type' => 'CustomWidgets$CustomWidget', 'Type' => { 'WidgetId' => 'x' } }
    migrator.send(:migrate_widget!, malformed, 'u', '$', issues, counts)
    expect(issues.map(&:kind)).to include(:malformed_widget)

    string = value_type('String')
    string['Translations'] = array([{ 'LanguageCode' => 'en_US', 'Text' => 'Default' }])
    expect(default_value(string)).to be_a(Hash)
    expect(migrator.send(:normalized_value, {}, string)).to include('PrimitiveValue' => '')
    boolean = value_type('Boolean')
    expression = value_type('Expression')
    expect(migrator.send(:convert_value, nil, boolean, expression, 'u', '$', issues)).to be(false)

    old_nested_property = property_type('changed', string)
    new_nested_property = property_type('changed', value_type('Integer'))
    old_nested_type = object_type([old_nested_property])
    new_nested_type = object_type([new_nested_property])
    old_outer = value_type('Object', object_type: old_nested_type)
    new_outer = value_type('Object', object_type: new_nested_type)
    configured = default_value(string)
    configured['PrimitiveValue'] = 'kept'
    nested = object(old_nested_type, [property(old_nested_property, configured)])
    old_outer_value = default_value(old_outer)
    old_outer_value['Objects'] = array([nested])
    expect(migrator.send(:rebind_value, old_outer_value, old_outer, new_outer,
                         'u', '$', issues)).to be_nil

    caption_type = property_type('goCaption', value_type('TextTemplate', required: true))
    controller_type = property_type('go', value_type('Boolean', default: 'false'))
    caption = property(caption_type, default_value(caption_type['ValueType']))
    caption['Value']['PrimitiveValue'] = 'configured'
    controller = property(controller_type, default_value(controller_type['ValueType']))
    migrator.send(:clear_inactive_default_captions!,
                  { 'goCaption' => caption, 'go' => controller },
                  'goCaption' => caption_type, 'go' => controller_type)
    expect(caption['Value']['PrimitiveValue']).to eq('configured')

    mappings = {
      ['Old', nil] => { key: 'New' },
      %w[OldOption Yes] => { key: 'NewOption', option: 'On' }
    }
    migrator.instance_variable_set(:@design_alias_mappings, mappings)
    items = [
      { 'Key' => 'Old', 'Value' => { 'Option' => nil } },
      { 'Key' => 'OldOption', 'Value' => { 'Option' => 'Yes' } },
      { 'Key' => 'Untouched', 'Value' => { 'Option' => 'No' } }
    ]
    expect(migrator.send(:migrate_simple_design_aliases!, items)).to eq(2)
    expect(items[0]['Key']).to eq('New')
    expect(items[1]['Value']['Option']).to eq('On')

    spacing_target = { key: 'Spacing', child: 'margin-top', option: 'M' }
    migrator.instance_variable_set(:@spacing_mappings, 'Old::M' => spacing_target)
    compound = migrator.send(:compound_design_property, 'Spacing')
    compound['Value']['Properties'] = array([
                                              migrator.send(:option_design_property, 'margin-top', 'M')
                                            ])
    legacy = {
      '$Type' => 'Forms$DesignPropertyValue', 'Key' => 'Old',
      'Value' => { '$Type' => 'Forms$OptionDesignPropertyValue', 'Option' => 'M' }
    }
    owner = { 'DesignProperties' => array([compound, legacy, Marshal.load(Marshal.dump(legacy))]) }
    design_counts = { design_properties: 0 }
    migrator.send(:migrate_design_properties!, owner, 'u', '$', issues, design_counts)
    expect(design_counts[:design_properties]).to eq(2)

    conflicts = {}
    first = { 'name' => 'One', 'type' => 'Spacing',
              'margin' => [{ 'name' => 'M', 'top' => { 'oldNames' => ['same'] } }] }
    second = { 'name' => 'Two', 'type' => 'Spacing',
               'margin' => [{ 'name' => 'L', 'top' => { 'oldNames' => ['same'] } }] }
    migrator.send(:collect_spacing_mappings, first, conflicts)
    migrator.send(:collect_spacing_mappings, second, conflicts)
    expect(conflicts['same'][:key]).to eq('One')

    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, 'widgets'))
      File.write(File.join(dir, 'widgets', 'broken.mpk'), 'not a zip')
      Zip::File.open(File.join(dir, 'widgets', 'other.mpk'), create: true) do |zip|
        zip.get_output_stream('Widget.xml') do |stream|
          stream.write('<widget id="other.Widget"><name>Other</name></widget>')
        end
      end
      design = File.join(dir, 'themesource', 'theme', 'web')
      FileUtils.mkdir_p(design)
      File.write(File.join(design, 'design-properties.json'), '{broken')
      fresh = described_class.new(File.join(dir, 'App.mpr'))
      expect(fresh.send(:definition, 'absent')).to be_nil
      expect(fresh.send(:spacing_mappings)).to eq({})
      expect(fresh.send(:design_property_documents)).to eq([])
      expect(described_class.new('/tmp/x.mpr').send(:package_digest, 'x')).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
