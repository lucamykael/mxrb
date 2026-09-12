# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Widget scenarios are intentionally kept together to share their synthetic schema helpers.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'modern page widgets' do
  def writer
    definition = {
      version: '11.12.1',
      modules: [{
        name: 'Ui', entities: [{
          name: 'Item', associations: [{ name: 'Item_Owner', target: 'Ui.Owner' }]
        }]
      }]
    }
    Mxrb::Writer.new('/tmp/unused.mpr', definition)
  end

  def schema_widget(id, specs, name: 'Widget') # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    descriptor = { id: id, name: name, studio_category: 'Custom', studio_pro_category: 'Custom' }
    widget = writer.send(
      :pluggable_widget_doc,
      { type: :pluggable_widget, name: name, options: {}, events: [] }, descriptor
    )
    property_types = specs.map.with_index do |(key, spec), index|
      value_type = {
        '$ID' => "value-type-#{index}", '$Type' => 'CustomWidgets$WidgetValueType',
        'Type' => spec.fetch(:type), 'DefaultValue' => spec.fetch(:default, '')
      }
      value_type['ObjectType'] = spec[:object_type] if spec[:object_type]
      value_type['Required'] = spec[:required] if spec.key?(:required)
      {
        '$ID' => "property-type-#{index}", '$Type' => 'CustomWidgets$WidgetPropertyType',
        'PropertyKey' => key.to_s, 'ValueType' => value_type
      }
    end
    object_type = widget.dig('Type', 'ObjectType')
    object_type['PropertyTypes'] = Mxrb::IO::BsonCodec.build_array(property_types, marker: 2)
    widget['Object'] = writer.send(:custom_widget_object_doc, object_type)
    widget
  end # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def nested_objects_widget(id) # rubocop:disable Metrics/MethodLength
    nested_object_type = {
      '$ID' => "#{id}-object-type", '$Type' => 'CustomWidgets$WidgetObjectType',
      'PropertyTypes' => Mxrb::IO::BsonCodec.build_array(%w[name amount].map.with_index do |key, index|
        {
          '$ID' => "#{id}-property-#{index}", '$Type' => 'CustomWidgets$WidgetPropertyType',
          'PropertyKey' => key,
          'ValueType' => {
            '$ID' => "#{id}-value-#{index}", '$Type' => 'CustomWidgets$WidgetValueType',
            'Type' => 'String', 'DefaultValue' => ''
          }
        }
      end, marker: 2)
    }
    schema_widget(id, { series: { type: 'Object', object_type: nested_object_type } })
  end # rubocop:enable Metrics/MethodLength

  def nested_object_state(current_writer, widget)
    property = current_writer.send(:custom_widget_properties, widget).fetch('series')
    current_writer.send(:array_items, property.dig('Value', 'Objects')).map do |object|
      properties = current_writer.send(
        :widget_object_properties, property.dig('ValueType', 'ObjectType'), object
      )
      {
        ids: [object['$ID'], *properties.values.flat_map { [_1['$ID'], _1.dig('Value', '$ID')] }],
        values: properties.transform_values { _1.dig('Value', 'PrimitiveValue') }
      }
    end
  end

  it 'writes a modern text area and widgets nested in tab pages' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'widgets.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module :Ui do
          page :Editor do
            text_area :Notes, attribute: 'Ui.Item.Notes', caption: 'Notes', lines: 7
            tab_control :Details do
              tab_page :General, caption: 'General' do
                text :Help, caption: 'Complete the fields'
              end
            end
            pluggable_widget :Map, widget_id: 'example.Map'
          end
        end
      end

      Mxrb.open(path) do |project|
        page = project.pages.find { _1.name == 'Editor' }
        area = page.widgets.find { _1[:type] == :text_area }
        tabs = page.widgets.find { _1[:type] == :tab_control }
        expect(area[:options]).to include(attribute: 'Ui.Item.Notes', lines: 7)
        expect(tabs.dig(:options, :tabs, 0, :widgets, 0, :type)).to eq(:text)
      end
    end
  end

  it 'hydrates arbitrary pluggable widget properties from the synchronized schema' do
    widget = {
      type: :pluggable_widget, name: 'Map', events: [],
      options: {
        widget_id: 'example.Map', widget_name: 'Map', properties: {
          mode: 'satellite', config: { PrimitiveValue: 'compact', Rules: [{ Enabled: true }] },
          ignored: nil
        }
      }
    }
    generated_widget = writer.send(
      :pluggable_widget_doc, widget,
      id: 'example.Map', name: 'Map', studio_category: 'Custom',
      studio_pro_category: 'Custom'
    )
    existing_widget = Marshal.load(Marshal.dump(generated_widget))
    object_type = existing_widget.dig('Type', 'ObjectType')
    property_types = %w[mode config ignored].map.with_index do |key, index|
      {
        '$ID' => "property-type-#{index}", '$Type' => 'CustomWidgets$WidgetPropertyType',
        'PropertyKey' => key,
        'ValueType' => {
          '$ID' => "value-type-#{index}", '$Type' => 'CustomWidgets$WidgetValueType',
          'Type' => 'Enumeration', 'DefaultValue' => 'default'
        }
      }
    end
    object_type['PropertyTypes'] = Mxrb::IO::BsonCodec.build_array(property_types, marker: 2)
    existing_widget['Object'] = writer.send(:custom_widget_object_doc, object_type)

    generated = { 'Widgets' => [generated_widget] }
    writer.send(:hydrate_pluggable_widgets!, generated, 'Widgets' => [existing_widget])
    values = writer.send(:custom_widget_properties, generated_widget)
    expect(values.dig('mode', 'Value', 'PrimitiveValue')).to eq('satellite')
    expect(values.dig('config', 'Value', 'PrimitiveValue')).to eq('compact')
    expect(values.dig('config', 'Value', 'Rules', 0, 'Enabled')).to be(true)
  end

  it 'hydrates semantic datasource, attribute, selection, children, and object values' do
    nested_types = %w[name amount].map.with_index do |key, index|
      {
        '$ID' => "nested-property-#{index}", 'PropertyKey' => key,
        'ValueType' => {
          '$ID' => "nested-value-#{index}", 'Type' => index.zero? ? 'String' : 'Attribute',
          'DefaultValue' => ''
        }
      }
    end
    nested_object_type = {
      '$ID' => 'nested-object',
      'PropertyTypes' => Mxrb::IO::BsonCodec.build_array(nested_types, marker: 2)
    }
    widget = schema_widget('example.Semantic', {
      source: { type: 'DataSource' }, label: { type: 'Attribute' }, selected: { type: 'Selection' },
      content: { type: 'Widgets' }, series: { type: 'Object', object_type: nested_object_type }
    })
    options = {
      properties: {
        source: { data_source: { entity: 'Ui.Item', xpath: '[Active = true]' } },
        label: { attribute: 'Ui.Item.Name' }, selected: { selection: 'Single' },
        content: { widgets: [{ type: :text, name: 'Nested', options: { caption: 'Child' }, events: [] }] },
        series: { objects: [{ name: { primitive: 'Primary' }, amount: { attribute: 'Ui.Item.Amount' } }] }
      }
    }

    writer.send(:configure_pluggable_widget!, widget, options)
    values = writer.send(:custom_widget_properties, widget)

    expect(values.dig('source', 'Value', 'DataSource')).to include(
      '$Type' => 'CustomWidgets$CustomWidgetXPathSource', 'XPathConstraint' => '[Active = true]'
    )
    expect(values.dig('label', 'Value', 'AttributeRef', 'Attribute')).to eq('Ui.Item.Name')
    expect(values.dig('selected', 'Value', 'Selection')).to eq('Single')
    expect(writer.send(:array_items, values.dig('content', 'Value', 'Widgets')).first).to include(
      '$Type' => 'Forms$DynamicText', 'Name' => 'Nested'
    )
    object = writer.send(:array_items, values.dig('series', 'Value', 'Objects')).first
    nested = writer.send(:widget_object_properties, nested_object_type, object)
    expect(nested.dig('name', 'Value', 'PrimitiveValue')).to eq('Primary')
    expect(nested.dig('amount', 'Value', 'AttributeRef', 'Attribute')).to eq('Ui.Item.Amount')
  end

  it 'hydrates every semantic scalar and normalizes singular data and widget values' do
    widget = schema_widget('example.Semantics', {
      expression: { type: 'Expression' }, text: { type: 'TextTemplate' },
      association: { type: 'Association' }, source: { type: 'DataSource' },
      content: { type: 'Widgets' }
    })
    writer.send(:configure_pluggable_widget!, widget, properties: {
      expression: { expression: '$currentObject/Name' }, text: { text: 'Hello' },
      association: { association: 'Ui.Item_Owner' }, source: { data_source: 'Ui.Item' },
      content: { widgets: { type: :text, name: 'OnlyChild', options: { caption: 'Child' }, events: [] } }
    })
    values = writer.send(:custom_widget_properties, widget)

    expect(values.dig('expression', 'Value', 'Expression')).to eq('$currentObject/Name')
    expect(values.dig('text', 'Value', 'TextTemplate', '$Type')).to eq('Forms$ClientTemplate')
    expect(values.dig('association', 'Value', 'EntityRef', '$Type')).to eq('DomainModels$IndirectEntityRef')
    expect(values.dig('source', 'Value', 'DataSource', 'EntityRef', 'Entity')).to eq('Ui.Item')
    expect(writer.send(:array_items, values.dig('content', 'Value', 'Widgets')).length).to eq(1)
    expect(writer.send(:widget_object_properties, nil, nil)).to eq({})
    expect(writer.send(:widget_object_properties, widget.dig('Type', 'ObjectType'), nil)).to eq({})
  end

  it 'clears explicitly nil pluggable widget values according to their value types' do
    primitive_types = %w[String Boolean Integer Decimal Number Enumeration]
    specs = primitive_types.to_h do |type|
      [type.downcase.to_sym, { type:, default: "#{type} default" }]
    end.merge(
      expression: { type: 'Expression', default: '$currentObject/Name' },
      text: { type: 'TextTemplate', default: 'Default text' },
      optional_text: { type: 'TextTemplate' },
      required_text: { type: 'TextTemplate', required: true },
      attribute: { type: 'Attribute' }, association: { type: 'Association' },
      data_source: { type: 'DataSource' }, action: { type: 'Action' },
      widgets: { type: 'Widgets' }, object: { type: 'Object' },
      selection: { type: 'Selection' }, omitted: { type: 'String', default: 'omitted default' }
    )
    widget = schema_widget('example.Clearable', specs)
    values = writer.send(:custom_widget_properties, widget)
    values.each_value do |property|
      property['Value']['XPathConstraint'] = 'preserved'
      property['Value']['PrimitiveValue'] = 'configured'
      property['Value']['Expression'] = 'configured'
      property['Value']['TextTemplate'] = { 'configured' => true }
      property['Value']['AttributeRef'] = { 'configured' => true }
      property['Value']['EntityRef'] = { 'configured' => true }
      property['Value']['DataSource'] = { 'configured' => true }
      property['Value']['Action'] = { 'configured' => true }
      property['Value']['Widgets'] = [2, { 'configured' => true }]
      property['Value']['Objects'] = [2, { 'configured' => true }]
      property['Value']['Selection'] = 'Single'
    end
    cleared = specs.keys - [:omitted]

    writer.send(:configure_pluggable_widget!, widget, properties: cleared.to_h { [_1, nil] })

    primitive_types.each do |type|
      expect(values.dig(type.downcase, 'Value', 'PrimitiveValue')).to eq("#{type} default")
    end
    expect(values.dig('expression', 'Value', 'Expression')).to eq('$currentObject/Name')
    expect(Mxrb::Model::Page.allocate.send(
             :extract_text, values.dig('text', 'Value', 'TextTemplate')
           )).to eq('Default text')
    expect(values.dig('optional_text', 'Value', 'TextTemplate')).to be_nil
    expect(values.dig('required_text', 'Value', 'TextTemplate')).to include(
      '$Type' => 'Forms$ClientTemplate'
    )
    expect(values.dig('attribute', 'Value', 'AttributeRef')).to be_nil
    expect(values.dig('association', 'Value', 'EntityRef')).to be_nil
    expect(values.dig('data_source', 'Value', 'DataSource')).to be_nil
    expect(values.dig('action', 'Value', 'Action')).to include(
      '$Type' => 'Forms$NoAction', 'DisabledDuringExecution' => true
    )
    expect(values.dig('widgets', 'Value', 'Widgets')).to eq([2])
    expect(values.dig('object', 'Value', 'Objects')).to eq([2])
    expect(values.dig('selection', 'Value', 'Selection')).to eq('None')
    expect(values.dig('omitted', 'Value', 'PrimitiveValue')).to eq('configured')
    expect(values.values).to all(satisfy { _1.dig('Value', 'XPathConstraint') == 'preserved' })
  end

  it 'fails closed when nil cannot be safely mapped to a pluggable widget field' do
    %w[Icon Image System Future].each do |type|
      widget = schema_widget("example.#{type}", { value: { type: } })

      expect do
        writer.send(:configure_pluggable_widget!, widget, properties: { value: nil })
      end.to raise_error(Mxrb::ValidationError, /cannot clear.*#{type}/)
    end
  end

  it 'reuses nested widget object identities and creates identities only for appends' do
    nested_object_type = {
      '$ID' => 'nested-object', '$Type' => 'CustomWidgets$WidgetObjectType',
      'PropertyTypes' => Mxrb::IO::BsonCodec.build_array(%w[name amount].map.with_index do |key, index|
        {
          '$ID' => "nested-property-#{index}", '$Type' => 'CustomWidgets$WidgetPropertyType',
          'PropertyKey' => key,
          'ValueType' => {
            '$ID' => "nested-value-#{index}", '$Type' => 'CustomWidgets$WidgetValueType',
            'Type' => 'String', 'DefaultValue' => ''
          }
        }
      end, marker: 2)
    }
    widget = schema_widget('example.Objects', {
      series: { type: 'Object', object_type: nested_object_type }
    })
    configurations = [
      { name: 'First', amount: '1' }, { name: 'Second', amount: '2' }
    ]
    identities = lambda do
      objects = writer.send(:array_items, writer.send(:custom_widget_properties, widget)
                                              .dig('series', 'Value', 'Objects'))
      objects.map do |object|
        {
          object: object['$ID'],
          properties: writer.send(:array_items, object['Properties']).map do |property|
            [property['$ID'], property.dig('Value', '$ID')]
          end
        }
      end
    end

    writer.send(:configure_pluggable_widget!, widget, properties: { series: { objects: configurations } })
    first_write = identities.call
    writer.send(:configure_pluggable_widget!, widget, properties: { series: { objects: configurations } })
    second_write = identities.call
    expect(second_write).to eq(first_write)

    appended = configurations + [{ name: 'Third', amount: '3' }]
    writer.send(:configure_pluggable_widget!, widget, properties: { series: { objects: appended } })
    third_write = identities.call
    expect(third_write.first(2)).to eq(second_write)
    expect(third_write.length).to eq(3)
    existing_ids = second_write.flat_map do |identity|
      [identity[:object], *identity[:properties].flatten]
    end
    appended_ids = [third_write.last[:object], *third_write.last[:properties].flatten]
    expect(appended_ids & existing_ids).to be_empty
  end

  it 'fails closed when nested widget object configurations shrink' do
    current_writer = writer
    widget = nested_objects_widget('example.ShrinkingObjects')
    original = [
      { name: 'First', amount: '1' },
      { name: 'Second', amount: '2' },
      { name: 'Third', amount: '3' }
    ]
    current_writer.send(
      :configure_pluggable_widget!, widget, properties: { series: { objects: original } }
    )

    expect do
      current_writer.send(
        :configure_pluggable_widget!, widget,
        properties: { series: { objects: original.first(2) } }
      )
    end.to raise_error(
      Mxrb::ValidationError,
      /configuration count 2 is smaller than baseline count 3/
    )
  end

  it 'preserves nested object identities for a single positional edit' do
    current_writer = writer
    widget = nested_objects_widget('example.EditedObjects')
    original = [{ name: 'First', amount: '1' }, { name: 'Second', amount: '2' }]
    current_writer.send(
      :configure_pluggable_widget!, widget, properties: { series: { objects: original } }
    )
    before = nested_object_state(current_writer, widget)

    edited = [{ name: 'First', amount: '1' }, { name: 'Second', amount: '20' }]
    current_writer.send(
      :configure_pluggable_widget!, widget, properties: { series: { objects: edited } }
    )
    after = nested_object_state(current_writer, widget)

    expect(after.map { _1[:ids] }).to eq(before.map { _1[:ids] })
    expected_values = [
      { 'name' => 'First', 'amount' => '1' },
      { 'name' => 'Second', 'amount' => '20' }
    ]
    expect(after.map { _1[:values] }).to eq(expected_values)
  end

  it 'preserves positional identities for legitimate duplicate object configurations' do
    current_writer = writer
    widget = nested_objects_widget('example.DuplicateObjects')
    duplicates = [{ name: 'Same', amount: '1' }, { name: 'Same', amount: '1' }]
    current_writer.send(
      :configure_pluggable_widget!, widget, properties: { series: { objects: duplicates } }
    )
    before = nested_object_state(current_writer, widget)

    current_writer.send(
      :configure_pluggable_widget!, widget, properties: { series: { objects: duplicates } }
    )
    after = nested_object_state(current_writer, widget)

    expect(after.map { _1[:ids] }).to eq(before.map { _1[:ids] })
    expect(after[0][:ids]).not_to eq(after[1][:ids])
  end

  it 'allows an undetectable same-length reorder and keeps identities by position' do
    current_writer = writer
    widget = nested_objects_widget('example.ReorderedObjects')
    original = [{ name: 'First', amount: '1' }, { name: 'Second', amount: '2' }]
    current_writer.send(
      :configure_pluggable_widget!, widget, properties: { series: { objects: original } }
    )
    before = nested_object_state(current_writer, widget)

    expect do
      current_writer.send(
        :configure_pluggable_widget!, widget,
        properties: { series: { objects: original.reverse } }
      )
    end.not_to raise_error
    after = nested_object_state(current_writer, widget)

    expect(after.map { _1[:ids] }).to eq(before.map { _1[:ids] })
    expect(after.map { _1.dig(:values, 'name') }).to eq(%w[Second First])
  end

  it 'fails closed when a nested widget object baseline has corrupt pointers' do
    nested_object_type = {
      '$ID' => 'nested-object', '$Type' => 'CustomWidgets$WidgetObjectType',
      'PropertyTypes' => Mxrb::IO::BsonCodec.build_array([{
        '$ID' => 'nested-property', '$Type' => 'CustomWidgets$WidgetPropertyType',
        'PropertyKey' => 'name',
        'ValueType' => {
          '$ID' => 'nested-value', '$Type' => 'CustomWidgets$WidgetValueType',
          'Type' => 'String', 'DefaultValue' => ''
        }
      }], marker: 2)
    }
    widget = schema_widget('example.CorruptObjects', {
      series: { type: 'Object', object_type: nested_object_type }
    })
    configuration = { series: { objects: [{ name: 'First' }] } }
    writer.send(:configure_pluggable_widget!, widget, properties: configuration)
    object = writer.send(:array_items, writer.send(:custom_widget_properties, widget)
                                        .dig('series', 'Value', 'Objects')).first
    original_pointer = object['TypePointer']
    object['TypePointer'] = 'corrupt-object-type'
    expect do
      writer.send(:configure_pluggable_widget!, widget, properties: configuration)
    end.to raise_error(Mxrb::ValidationError, %r{invalid ObjectType/WidgetObject pointer})

    object['TypePointer'] = original_pointer
    property = writer.send(:array_items, object['Properties']).first
    property['Value']['TypePointer'] = 'corrupt-value-type'
    expect do
      writer.send(:configure_pluggable_widget!, widget, properties: configuration)
    end.to raise_error(Mxrb::ValidationError, %r{invalid WidgetValue/ValueType pointer})
  end

  it 'covers optional synchronization paths without inventing widget values' do
    current_writer = writer
    empty = schema_widget('example.Empty', {}, name: 'Empty')
    other = schema_widget('example.Other', { source: { type: 'Enumeration' } }, name: 'Empty')
    generated = current_writer.send(:widget_doc, {
      type: :pluggable_widget, name: 'Empty', events: [],
      options: { widget_id: 'example.Empty', widget_name: 'Empty', properties: {} }
    })
    expect(current_writer.send(:compatible_widget_baseline?, generated, nil)).to be(false)
    expect(current_writer.send(:compatible_widget_baseline?, generated, other)).to be(false)
    expect(current_writer.send(:compatible_widget_baseline?, generated, empty)).to be(false)

    current_writer.send(:configure_data_grid2!, empty, entity: 'Ui.Item', columns: [])
    grid = schema_widget(
      'grid', { datasource: { type: 'DataSource' }, columns: { type: 'Object' } }, name: 'Grid'
    )
    current_writer.send(:configure_data_grid2!, grid, {})
    combo = schema_widget(
      'combo', { source: { type: 'Enumeration' }, optionsSourceType: { type: 'Enumeration' } },
      name: 'Combo'
    )
    current_writer.send(:configure_combo_box!, combo, __kind: :drop_down, caption: nil)
    current_writer.send(:configure_combo_box!, combo, __kind: :reference_selector, caption: nil)
    current_writer.send(:set_widget_primitive, {}, 'missing', 'value')
    expect(current_writer.send(:association_destination, 'Item_Owner')).to eq('Ui.Owner')
    expect(current_writer.send(:association_destination, 'Missing')).to eq('')
    expression = current_writer.send(
      :custom_widget_value_doc,
      '$ID' => 'expression', 'Type' => 'Expression', 'DefaultValue' => '$currentObject/Name'
    )
    expect(expression['Expression']).to eq('$currentObject/Name')
    expect(current_writer.send(:widget_doc, type: :tab_control, name: 'EmptyTabs', options: {}, events: [])[
      'DefaultPagePointer'
    ]).to be_nil
    expect(current_writer.send(:modern_widget_properties, :future_widget, {})).to eq({})
  end

  it 'hydrates Data Grid 2 datasource and column objects' do
    column_properties = [
      {
        '$ID' => 'show', 'PropertyKey' => 'showContentAs',
        'ValueType' => {
          '$ID' => 'show-value', 'Type' => 'Enumeration', 'DefaultValue' => 'custom'
        }
      },
      {
        '$ID' => 'attribute', 'PropertyKey' => 'attribute',
        'ValueType' => {
          '$ID' => 'attribute-value', 'Type' => 'Attribute', 'DefaultValue' => ''
        }
      },
      {
        '$ID' => 'header', 'PropertyKey' => 'header',
        'ValueType' => {
          '$ID' => 'header-value', 'Type' => 'TextTemplate', 'DefaultValue' => ''
        }
      }
    ]
    column_type = {
      '$ID' => 'column-type', '$Type' => 'CustomWidgets$WidgetObjectType',
      'PropertyTypes' => Mxrb::IO::BsonCodec.build_array(column_properties, marker: 2)
    }
    baseline = schema_widget(
      'com.mendix.widget.web.datagrid.Datagrid',
      { datasource: { type: 'DataSource' },
        columns: { type: 'Object', object_type: column_type },
        loadMoreButtonCaption: { type: 'TextTemplate' },
        singleSelectionColumnLabel: { type: 'TextTemplate' },
        clearSelectionButtonLabel: { type: 'TextTemplate' },
        filterSectionTitle: { type: 'TextTemplate' } },
      name: 'Grid'
    )
    generated = writer.send(:pluggable_widget_doc, {
      type: :data_grid, name: 'Grid', events: [],
      options: { entity: 'Ui.Item', columns: [{ name: 'Name', attribute: 'Name' }] }
    }, writer.send(:data_grid2_descriptor))

    writer.send(:hydrate_pluggable_widgets!, { 'Widgets' => [generated] }, 'Widgets' => [baseline])
    properties = writer.send(:custom_widget_properties, generated)
    expect(properties.dig('datasource', 'Value', 'DataSource', 'EntityRef', 'Entity')).to eq('Ui.Item')
    expect(Mxrb::IO::BsonCodec.parse_array(properties.dig('columns', 'Value', 'Objects'))[:items].size).to eq(1)
    parsed = Mxrb::Model::Page.allocate.send(:data_grid2_widget, generated)
    expect(parsed.dig(:options, :columns, 0, :attribute)).to eq('Ui.Item.Name')
    expect(properties.dig('loadMoreButtonCaption', 'Value', 'TextTemplate')).to be_nil
    expect(properties.dig('filterSectionTitle', 'Value', 'TextTemplate', '$Type'))
      .to eq('Forms$ClientTemplate')
    qualified = writer.send(
      :data_grid2_column_doc, column_type,
      { name: 'Name', attribute: 'Ui.Item.Name' }, entity: 'Ui.Item'
    )
    column_values = Mxrb::IO::BsonCodec.parse_array(qualified['Properties'])[:items]
    attribute_value = column_values.find { _1['TypePointer'] == 'attribute' }
    expect(attribute_value.dig('Value', 'AttributeRef', 'Attribute')).to eq('Ui.Item.Name')
    text_value = writer.send(
      :custom_widget_value_doc,
      '$ID' => 'required-text', 'Type' => 'TextTemplate', 'DefaultValue' => '', 'Required' => true
    )
    expect(text_value.dig('TextTemplate', '$Type')).to eq('Forms$ClientTemplate')
  end

  it 'hydrates Data Grid 2 selection, filter slots, and multiple column filters' do
    filter_type = {
      '$ID' => 'filter', 'PropertyKey' => 'filter',
      'ValueType' => { '$ID' => 'filter-value', 'Type' => 'Widgets', 'DefaultValue' => '' }
    }
    column_type = {
      '$ID' => 'column-type', '$Type' => 'CustomWidgets$WidgetObjectType',
      'PropertyTypes' => Mxrb::IO::BsonCodec.build_array([filter_type], marker: 2)
    }
    grid = schema_widget('grid', {
      itemSelection: { type: 'Selection' }, filtersPlaceholder: { type: 'Widgets' },
      columns: { type: 'Object', object_type: column_type }
    })
    filter = { type: :text, name: 'Filter', options: { caption: 'Filter' }, events: [] }
    writer.send(:configure_data_grid2!, grid, selection: :Multi, filters: filter, columns: [{
      name: 'Name', filter: [filter, filter]
    }])
    values = writer.send(:custom_widget_properties, grid)

    expect(values.dig('itemSelection', 'Value', 'Selection')).to eq('Multi')
    expect(writer.send(:array_items, values.dig('filtersPlaceholder', 'Value', 'Widgets')).length).to eq(1)
    writer.send(:configure_data_grid2!, grid, filters: [filter])
    expect(writer.send(:array_items, values.dig('filtersPlaceholder', 'Value', 'Widgets')).length).to eq(1)
    expect { writer.send(:configure_data_grid2!, grid, selection: :invalid) }
      .to raise_error(Mxrb::ValidationError, /selection must be none, single, or multi/)
    column = writer.send(:array_items, values.dig('columns', 'Value', 'Objects')).first
    column_values = writer.send(:widget_object_properties, column_type, column)
    expect(writer.send(:array_items, column_values.dig('filter', 'Value', 'Widgets')).length).to eq(2)

    event_grid = schema_widget('grid-events', {
      itemSelection: { type: 'Selection' }, onSelectionChange: { type: 'Action' }
    })
    event_properties = writer.send(:custom_widget_properties, event_grid)
    event_properties['itemSelection']['Value']['Selection'] = 'Single'
    event_properties['onSelectionChange']['Value']['Action'] = {
      '$Type' => 'Forms$SaveChangesClientAction'
    }
    parsed = Mxrb::Model::Page.allocate.send(:data_grid2_widget, event_grid)
    expect(parsed.dig(:options, :selection)).to eq(:single)
    expect(parsed.fetch(:events)).to include(include(kind: :action, event: :on_change))
  end

  it 'fails before emitting unsupported official Data Grid 2 toolbar and selection events' do
    descriptor = writer.send(:data_grid2_descriptor)
    toolbar = {
      type: :data_grid, name: 'Grid', events: [],
      options: { toolbar: { buttons: [{ type: :new }] } }
    }
    selection_event = {
      type: :data_grid, name: 'Grid', options: {},
      events: [{ event: :on_change, kind: :nanoflow, handler: 'Ui.Refresh' }]
    }

    expect do
      writer.send(:validate_official_data_grid2_contract!, toolbar, descriptor, Object.new)
    end.to raise_error(Mxrb::ValidationError, /toolbar buttons are not portable/)
    expect do
      writer.send(:validate_official_data_grid2_contract!, selection_event, descriptor, Object.new)
    end.to raise_error(Mxrb::ValidationError, /on_change is not certified/)
    expect do
      writer.send(:validate_official_data_grid2_contract!, selection_event, descriptor, nil)
    end.not_to raise_error
    expect do
      writer.send(:validate_official_data_grid2_contract!, toolbar.merge(options: {}), descriptor, Object.new)
    end.not_to raise_error
  end

  it 'writes a hydrated official Data Grid 2 selection action property' do
    current_writer = writer
    template = schema_widget('grid-template', { onSelectionChange: { type: 'Action' } })
    allow(Mxrb::WidgetPackage).to receive(:find).and_return(Object.new)
    allow(Mxrb::WidgetPackage).to receive(:template)
      .and_return([template.fetch('Type'), template.fetch('Object')])
    allow(current_writer).to receive(:validate_official_data_grid2_contract!)

    generated = current_writer.send(:pluggable_widget_doc, {
      type: :data_grid, name: 'Grid', options: {},
      events: [{ event: :on_change, kind: :nanoflow, handler: 'Ui.Refresh' }]
    }, current_writer.send(:data_grid2_descriptor))
    action = current_writer.send(:custom_widget_properties, generated)
                           .dig('onSelectionChange', 'Value', 'Action')

    expect(action.fetch('$Type')).to eq('Forms$CallNanoflowClientAction')
  end

  it 'hydrates Combo Box enumeration and association modes' do
    specs = {
      source: { type: 'Enumeration' }, optionsSourceType: { type: 'Enumeration' },
      attributeEnumeration: { type: 'Attribute' }, attributeAssociation: { type: 'Association' },
      optionsSourceAssociationDataSource: { type: 'DataSource' },
      optionsSourceAssociationCaptionAttribute: { type: 'Attribute' }
    }
    descriptor = writer.send(:combo_box_descriptor)
    baseline = schema_widget(descriptor[:id], specs, name: 'Choice')
    enumeration = writer.send(:pluggable_widget_doc, {
      type: :drop_down, name: 'Choice', events: [],
      options: { attribute: 'Ui.Item.Status', caption: 'Status' }
    }, descriptor)
    writer.send(:hydrate_pluggable_widgets!, { 'Widgets' => [enumeration] }, 'Widgets' => [baseline])
    enum_values = writer.send(:custom_widget_properties, enumeration)
    expect(enum_values.dig('optionsSourceType', 'Value', 'PrimitiveValue')).to eq('enumeration')
    expect(Mxrb::Model::Page.allocate.send(:combo_box_widget, enumeration)[:type]).to eq(:drop_down)

    association = writer.send(:pluggable_widget_doc, {
      type: :reference_selector, name: 'Choice', events: [],
      options: {
        attribute: 'Ui.Item_Owner', display_attribute: 'Ui.Owner.Name', caption: 'Owner'
      }
    }, descriptor)
    writer.send(:hydrate_pluggable_widgets!, { 'Widgets' => [association] }, 'Widgets' => [baseline])
    assoc_values = writer.send(:custom_widget_properties, association)
    expect(assoc_values.dig(
             'optionsSourceAssociationDataSource', 'Value', 'DataSource', 'EntityRef', 'Entity'
           )).to eq('Ui.Owner')
    parsed = Mxrb::Model::Page.allocate.send(:combo_box_widget, association)
    expect(parsed[:type]).to eq(:reference_selector)
    expect(parsed.dig(:options, :display_attribute)).to eq('Ui.Owner.Name')
  end

  it 'preserves an unknown native widget as deep structure' do
    raw = {
      '$ID' => 'old-id', '$Type' => 'Vendor$ModernWidget', 'Name' => 'VendorMap',
      'Type' => 'LegacyWidgetKind', 'Mode' => '3d',
      'Settings' => { 'Zoom' => 12 }, 'Layers' => %w[roads labels]
    }
    page = Mxrb::Model::Page.allocate
    native = page.send(:native_widget, raw)
    parsed = []
    page.send(:parse_widgets, [raw], parsed)
    expect(parsed.first[:type]).to eq(:native_widget)
    rebuilt = writer.send(:widget_doc, native)
    expect(rebuilt).to include(
      '$Type' => 'Vendor$ModernWidget', 'Name' => 'VendorMap', 'Mode' => '3d'
    )
    expect(rebuilt.dig('Settings', 'Zoom')).to eq(12)
    expect(rebuilt['$ID']).not_to eq('old-id')
    expect { Mxrb::Dsl::PageBuilder.new(:P).native_widget(:Bad, type: 'X', deep_structure: []) }
      .to raise_error(ArgumentError, /requires a Hash/)
  end

  it 'projects canonical title, radio, and static image widgets as typed Ruby' do
    raw = [
      {
        '$Type' => 'Forms$Title', 'Name' => 'PageTitle',
        'ConditionalVisibilitySettings' => nil, 'TabIndex' => 0
      },
      {
        '$Type' => 'Forms$RadioButtonGroup', 'Name' => 'Status',
        'AttributeRef' => { 'Attribute' => 'Ui.Order.Status' },
        'LabelTemplate' => 'Status', 'RenderHorizontal' => true
      },
      {
        '$Type' => 'Forms$StaticImageViewer', 'Name' => 'Logo',
        'Image' => 'Ui.Images.Logo', 'AlternativeText' => 'Logo',
        'Width' => 80, 'Height' => 50, 'WidthUnit' => 'Pixels',
        'HeightUnit' => 'Pixels', 'Responsive' => true,
        'ClickAction' => {
          '$Type' => 'Forms$CallNanoflowClientAction',
          'NanoflowSettings' => { 'Nanoflow' => 'Ui.Toggle', 'ParameterMappings' => [2] }
        }
      }
    ]
    parsed = []
    page = Mxrb::Model::Page.allocate
    page.send(:parse_widgets, raw, parsed)

    expect(parsed.map { _1.fetch(:type) }).to eq(%i[page_title radio_button_group static_image])
    expect(parsed[1].fetch(:options)).to include(
      attribute: 'Ui.Order.Status', caption: 'Status', horizontal: true
    )
    expect(parsed[2].fetch(:options)).to include(
      image: 'Ui.Images.Logo', alternative_text: 'Logo', width: 80, height: 50
    )
    source = parsed.flat_map { Mxrb::Exporter.allocate.send(:render_widget, _1, 2) }.join("\n")
    expect(source).to include(
      'page_title :PageTitle', 'radio_button_group :Status', 'horizontal: true',
      'static_image :Logo', 'image: "Ui.Images.Logo"', 'on_click nanoflow: :Toggle'
    )
    expect(source).not_to include('native_widget', 'deep_structure:')

    rebuilt = parsed.map { writer.send(:widget_doc, _1) }
    expect(rebuilt.map { _1.fetch('$Type') }).to eq(
      %w[Forms$Title Forms$RadioButtonGroup Forms$StaticImageViewer]
    )
  end

  it 'reconstructs BSON values in native widgets nested inside containers and tabs' do
    encoded = Base64.strict_encode64("\x01\x02".b)
    page = Mxrb::Dsl::PageBuilder.new(:P)
    page.instance_eval do
      container :Outer do
        native_widget :Nested, type: 'Vendor$Nested', deep_structure: {
          '$ID' => bson_binary(encoded, subtype: :uuid)
        }
      end
      tab_control :Tabs do
        tab_page :General do
          native_widget :Tabbed, type: 'Vendor$Tabbed', deep_structure: {
            '$ID' => bson_binary(encoded, subtype: :uuid)
          }
        end
      end
    end

    widgets = page.to_h.fetch(:widgets)
    nested = widgets.first.fetch(:children).first.dig(:options, :deep_structure, '$ID')
    tabbed = widgets.last.dig(:options, :tabs, 0, :widgets, 0, :options, :deep_structure, '$ID')
    expect(nested).to be_a(BSON::Binary)
    expect(tabbed).to be_a(BSON::Binary)
    expect(nested.type).to eq(:uuid)
    expect(tabbed.type).to eq(:uuid)
  end

  it 'projects legacy file, reference-set, navigation, and scroll controls semantically' do
    raw = [
      { '$Type' => 'Forms$FileManager', 'Name' => 'Files', 'MaxFileSize' => 10,
        'Editable' => 'Always', 'Type' => 'Both' },
      { '$Type' => 'Forms$ReferenceSetSelector', 'Name' => 'Members',
        'SelectionMode' => 'Multi', 'NumberOfRows' => 25 },
      { '$Type' => 'Forms$NavigationList', 'Name' => 'Links', 'TabIndex' => 0 },
      { '$Type' => 'Forms$ScrollContainer', 'Name' => 'Shell',
        'Alignment' => 'Center', 'LayoutMode' => 'Headline',
        'ScrollBehavior' => 'PerRegion', 'WidthMode' => 'Auto' }
    ]
    parsed = []
    Mxrb::Model::Page.allocate.send(:parse_widgets, raw, parsed)

    expect(parsed.map { _1.fetch(:type) }).to eq(
      %i[file_manager reference_set_selector navigation_list scroll_container]
    )
    source = parsed.flat_map { Mxrb::Exporter.allocate.send(:render_widget, _1, 2) }.join("\n")
    expect(source).to include(
      'file_manager :Files', 'reference_set_selector :Members',
      'navigation_list :Links', 'scroll_container :Shell'
    )
    expect(source).not_to include('native_widget', 'deep_structure:', 'bson_binary(')
    expect(parsed.map { writer.send(:widget_doc, _1).fetch('$Type') }).to eq(
      raw.map { _1.fetch('$Type') }
    )

    ruby_exporter = Mxrb::RubyApp::Exporter.allocate
    runtime_source = parsed.map do |widget|
      manifest = ruby_exporter.send(:widget_manifest, widget)
      ruby_exporter.send(:runtime_widget_call_source, manifest, 2)
    end.join("\n")
    expect(runtime_source).to match(/file_manager(?:\s|\()/)
    expect(runtime_source).to match(/reference_set_selector(?:\s|\()/)
    expect(runtime_source).to match(/navigation_list(?:\s|\()/)
    expect(runtime_source).to match(/scroll_container(?:\s|\()/)
    expect(runtime_source).not_to include('native_widget')

    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.file_manager(:Files)
    tree.reference_set_selector(:Members)
    tree.navigation_list(:Links)
    tree.scroll_container(:Shell)
    expect(tree.widgets.map { _1.fetch('type') }).to eq(
      %w[file_manager reference_set_selector navigation_list scroll_container]
    )
  end

  it 'projects legacy image and menu controls as editable typed Ruby' do
    raw = [
      {
        '$Type' => 'Forms$ImageViewer', 'Name' => 'Preview',
        'DataSource' => {
          '$Type' => 'Forms$ImageViewerSource',
          'EntityRef' => { '$Type' => 'DomainModels$DirectEntityRef', 'Entity' => 'Ui.Picture' },
          'ForceFullObjects' => false
        },
        'AlternativeText' => { '$Type' => 'Forms$ClientTemplate', 'Template' => 'Preview' },
        'ClickAction' => {
          '$Type' => 'Forms$MicroflowAction',
          'MicroflowSettings' => { 'Microflow' => 'Ui.Download', 'ParameterMappings' => [2] }
        },
        'DefaultImage' => 'Ui.Images.Empty', 'Width' => 120, 'Height' => 100,
        'WidthUnit' => 'Pixels', 'HeightUnit' => 'Auto', 'Responsive' => true,
        'ShowAsThumbnail' => true, 'OnClickEnlarge' => false, 'TabIndex' => 1
      },
      {
        '$Type' => 'Forms$ImageUploader', 'Name' => 'Upload',
        'AllowedExtensions' => 'png;jpg', 'Editable' => 'Always',
        'LabelTemplate' => { '$Type' => 'Forms$ClientTemplate', 'Template' => 'Upload image' },
        'MaxFileSize' => 8, 'ThumbnailSize' => '48;32', 'TabIndex' => 2
      },
      {
        '$Type' => 'Forms$MenuBar', 'Name' => 'Menu',
        'MenuSource' => { '$Type' => 'Forms$MenuDocumentSource', 'Menu' => 'Ui.MainMenu' },
        'TabIndex' => 3
      },
      {
        '$Type' => 'Forms$NavigationTree', 'Name' => 'Tree',
        'MenuSource' => { '$Type' => 'Forms$MenuDocumentSource', 'Menu' => 'Ui.MainMenu' },
        'TabIndex' => 4
      }
    ]
    parsed = []
    Mxrb::Model::Page.allocate.send(:parse_widgets, raw, parsed)

    expect(parsed.map { _1.fetch(:type) }).to eq(
      %i[image_viewer image_uploader menu_bar navigation_tree]
    )
    expect(parsed[0].fetch(:options)).to include(
      entity: 'Ui.Picture', alternative_text: 'Preview', default_image: 'Ui.Images.Empty',
      width: 120, width_unit: :pixels, show_as_thumbnail: true
    )
    expect(parsed[0].fetch(:events)).to contain_exactly(
      include(event: :on_click, kind: :microflow, handler: 'Download')
    )
    expect(parsed[1].fetch(:options)).to include(
      caption: 'Upload image', allowed_extensions: 'png;jpg',
      thumbnail_width: 48, thumbnail_height: 32
    )
    expect(parsed[2].fetch(:options)).to include(menu: 'Ui.MainMenu', tab_index: 3)

    source = parsed.flat_map { Mxrb::Exporter.allocate.send(:render_widget, _1, 2) }.join("\n")
    expect(source).to include(
      'image_viewer :Preview', 'entity: "Ui.Picture"', 'on_click microflow: :Download',
      'image_uploader :Upload', 'thumbnail_width: 48',
      'menu_bar :Menu', 'navigation_tree :Tree', 'menu: "Ui.MainMenu"'
    )
    expect(source).not_to include('native_widget', 'deep_structure:', 'bson_binary(')

    rebuilt = parsed.map { writer.send(:widget_doc, _1) }
    expect(rebuilt.map { _1.fetch('$Type') }).to eq(raw.map { _1.fetch('$Type') })
    expect(rebuilt[0].dig('DataSource', 'EntityRef', 'Entity')).to eq('Ui.Picture')
    expect(rebuilt[0].dig('ClickAction', '$Type')).to eq('Forms$MicroflowAction')
    expect(rebuilt[1]['ThumbnailSize']).to eq('48;32')
    expect(rebuilt[2].dig('MenuSource', 'Menu')).to eq('Ui.MainMenu')

    ruby_exporter = Mxrb::RubyApp::Exporter.allocate
    runtime_source = parsed.map do |widget|
      manifest = ruby_exporter.send(:widget_manifest, widget)
      ruby_exporter.send(:runtime_widget_call_source, manifest, 2)
    end.join("\n")
    expect(runtime_source).to include('image_viewer', 'image_uploader', 'menu_bar', 'navigation_tree')
    expect(runtime_source).not_to include('native_widget')

    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.image_viewer(:Preview, entity: 'Ui.Picture')
    tree.image_uploader(:Upload)
    tree.menu_bar(:Menu, menu: 'Ui.MainMenu')
    tree.navigation_tree(:Tree, menu: 'Ui.MainMenu')
    expect(tree.widgets.map { _1.fetch('type') }).to eq(
      %w[image_viewer image_uploader menu_bar navigation_tree]
    )
  end

  it 'evaluates exported tab pages through the runtime page tree' do
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.tab_control(:Tabs) do
      tab_page :General, caption: 'General' do
        text :Greeting, caption: 'Hello'
      end
    end

    expect(tree.widgets.dig(0, 'options', 'tabs', 0)).to include(
      'name' => 'General', 'caption' => 'General',
      'widgets' => include(include('type' => 'text', 'name' => 'Greeting'))
    )
  end

  it 'retains children nested directly in a generic widget builder' do
    empty = Mxrb::Dsl::WidgetBuilder.new(:layout_grid, :Empty)
    expect(empty.to_h).not_to have_key(:children)

    nested = Mxrb::Dsl::WidgetBuilder.new(:layout_grid, :Grid)
    nested.instance_eval { text :Caption, caption: 'Nested content' }
    expect(nested.to_h.fetch(:children)).to contain_exactly(
      include(type: :text, name: 'Caption', options: include(caption: 'Nested content'))
    )

    filtered = Mxrb::Dsl::WidgetBuilder.new(:data_grid, :Filtered)
    filtered.filter(type: :text, name: 'Search', options: { caption: 'Search' }, events: [])
    expect(filtered.to_h.dig(:options, :filters).length).to eq(1)
  end

  it 'normalizes every pluggable widget property shape for the React projection' do
    page = Mxrb::Model::Page.allocate
    expect(page.send(:data_view_editability, true)).to eq(:always)
    expect(page.send(:data_view_editability, 'False')).to eq(:never)
    allow(page).to receive(:parse_widgets) do |_widgets, target|
      target << { type: :text, name: 'Slot', options: {}, events: [] }
    end

    expect(page.send(:pluggable_properties, nil, nil)).to eq({})
    expect(page.send(:pluggable_value, 'invalid', nil)).to be_nil
    expect(page.send(:pluggable_value, { 'Selection' => 'None' }, nil)).to be_nil
    slot = page.send(:pluggable_value, { 'Widgets' => [2, { '$Type' => 'Forms$DynamicText' }] }, {})
    expect(slot).to include(widgets: include(include(type: :text, name: 'Slot')))

    object_type = {
      'PropertyTypes' => [2, {
        '$ID' => 'value-type', 'PropertyKey' => 'value',
        'ValueType' => { 'Type' => 'String' }
      }]
    }
    object = {
      'Properties' => [2, {
        'TypePointer' => 'value-type', 'Value' => { 'PrimitiveValue' => 'nested' }
      }, {
        'TypePointer' => 'missing', 'Value' => { 'PrimitiveValue' => 'ignored' }
      }]
    }
    objects = page.send(
      :pluggable_value, { 'Objects' => [2, object] }, { 'ObjectType' => object_type }
    )
    expect(objects).to eq(objects: [{ 'value' => 'nested' }])
    expect(page.send(:pluggable_value, { 'Objects' => [2, object] }, nil)).to eq(objects: [{}])

    text = { 'TextTemplate' => { 'Template' => { 'Items' => [3, { 'Text' => 'Caption' }] } } }
    allow(page).to receive(:extract_text).with(text['TextTemplate']).and_return('Caption')
    expect(page.send(:pluggable_value, text, {})).to eq('Caption')
    expect(page.send(:pluggable_value, { 'AttributeRef' => { 'Attribute' => 'M.E.Name' } }, {}))
      .to eq('M.E.Name')
    data_source = {
      'DataSource' => {
        'EntityRef' => { 'Entity' => 'M.E' }, 'XPathConstraint' => '[Active]',
        'SortBar' => { 'SortItems' => [2, {
          'AttributeRef' => { 'Attribute' => 'M.E.Name' }, 'SortDirection' => 'Ascending'
        }] }
      }
    }
    expect(page.send(:pluggable_value, data_source, {})).to eq(
      data_source: 'M.E', xpath: '[Active]',
      sort: [{ attribute: 'M.E.Name', direction: 'Ascending' }]
    )
    expect(page.send(:pluggable_data_source, 'Entity' => 'Fallback')).to include(data_source: 'Fallback')

    %w[Expression Image Form].each do |key|
      expect(page.send(:pluggable_value, { key => 'value' }, {})).to eq('value')
    end
    expect(page.send(:pluggable_value, { 'PrimitiveValue' => 'true' }, { 'Type' => 'Boolean' })).to be(true)
    expect(page.send(:pluggable_value, { 'PrimitiveValue' => false }, { 'Type' => 'Boolean' })).to be(false)
    expect(page.send(:pluggable_value, { 'PrimitiveValue' => '4' }, { 'Type' => 'Integer' })).to eq(4)
    expect(page.send(:pluggable_value, { 'PrimitiveValue' => '1.5' }, { 'Type' => 'Decimal' })).to eq(1.5)
    expect(page.send(:pluggable_value, { 'PrimitiveValue' => '2.5' }, { 'Type' => 'Number' })).to eq(2.5)
    expect(page.send(:pluggable_value, { 'PrimitiveValue' => 'plain' }, {})).to eq('plain')

    actions = {
      'nanoflow' => { 'Nanoflow' => 'M.N', '$Type' => 'Action' },
      'microflow' => { 'Microflow' => 'M.M', '$Type' => 'Action' },
      'page' => { 'Form' => 'M.P', '$Type' => 'Action' },
      'action' => { '$Type' => 'Forms$SaveChangesClientAction' }
    }
    actions.each do |kind, action|
      value = page.send(:pluggable_value, { 'Action' => action }, {})
      expect(value.fetch(:kind)).to eq(kind)
    end
    expect(page.send(:pluggable_value, { 'Selection' => 'Single' }, {})).to eq('Single')
    expect(page.send(:pluggable_value, { 'Selection' => 'None' }, {})).to be_nil

    widget = { type: :text, name: 'Slot' }
    nested = { section: [{ widgets: [widget, widget] }] }
    expect(page.send(:nested_pluggable_widgets, nested)).to eq([widget])
    expect(page.send(:strip_pluggable_widgets, nested)).to eq(section: [{}])
    expect(page.send(:strip_pluggable_widgets, 'value')).to eq('value')
    events = page.send(:pluggable_events, {
      'onChange' => { kind: 'microflow', handler: 'M.Change' },
      'onClick' => { kind: 'nanoflow', handler: 'M.Click' },
      'ignored' => nil
    })
    expect(events).to contain_exactly(include(event: :on_change), include(event: :on_click))
    native = page.send(:native_widget, {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'Native',
      'Type' => { 'WidgetId' => 'example.Native', 'SupportedPlatform' => 'Web' }
    })
    expect(native[:options]).to include(widget_id: 'example.Native', platform: 'Web')
  end

  it 'preserves a nil pluggable value when its package omits the property type' do
    value = { 'PrimitiveValue' => 'package-owned-default' }
    property = { 'Value' => value, 'ValueType' => {} }

    expect(writer.send(:configure_custom_widget_value!, property, nil)).to equal(value)
    expect(value).to eq('PrimitiveValue' => 'package-owned-default')
  end

  it 'omits empty unsupported pluggable properties from the editable projection' do
    widget = schema_widget('example.UnsupportedNil', {
      icon: { type: 'Icon' }, title: { type: 'String' }
    })
    properties = Mxrb::Model::Page.allocate.send(
      :pluggable_properties, widget['Object'], widget.dig('Type', 'ObjectType')
    )

    expect(properties).not_to have_key('icon')
    expect(properties).to have_key('title')
    expect(properties['title']).to be_nil
  end

  it 'retains explicit association storage and exact member access overrides' do
    entity = Mxrb::Dsl::EntityBuilder.new(:Account)
    entity.association 'System.User', name: :Account_User, storage_format: :Table
    entity.access_rule 'M.User', default_rights: 'ReadWrite', members: [
      { name: 'Secret', rights: 'None', kind: :attribute }
    ]
    definition = entity.to_h

    expect(definition.dig(:associations, 0, :storage_format)).to eq(:Table)
    expect(definition.dig(:access_rules, 0, :default_rights)).to eq('ReadWrite')
    expect(definition.dig(:access_rules, 0, :members, 0)).to include(
      name: 'Secret', rights: 'None', kind: :attribute
    )

    project = Mxrb::Dsl::Builder.new('/tmp/platform-reference.mpr')
    project.instance_eval do
      self.module(:M) { entity(:Token) { association 'System.User' } }
    end
    expect(project.validate!).to be_valid
  end

  it 'exports BSON date-time values as executable Ruby with nanosecond precision' do
    value = Time.at(1_541_030_400, 123_000_000, :nanosecond).utc
    source = Mxrb::Exporter.allocate.send(:native_ruby, value)

    expect(source).to eq('Time.at(1541030400, 123000000, :nanosecond).utc')
    expect(eval(source)).to eq(value) # rubocop:disable Security/Eval
  end

  it 'exports native parameter types and expression-based list operations as executable DSL' do
    exporter = Mxrb::Exporter.allocate
    action = {
      'Action' => {
        '$Type' => 'Microflows$ListOperationsAction', 'ResultVariableName' => 'Found',
        'NewOperation' => {
          '$Type' => 'Microflows$FindByExpression', 'ListName' => 'Items',
          'Expression' => '$currentObject/Name = $Name'
        }
      }
    }
    line = exporter.send(:action_dsl_line, action, 2)
    expect(line).to include(
      'list_operation :find_by_expression, :Items',
      'expression: "$currentObject/Name = $Name"', 'as: :Found'
    )

    flow = Mxrb::Dsl::FlowBuilder.new(:Find, runtime: nil, kind: :microflow, public: false)
    type = { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'System.HttpMessage' }
    flow.parameter :Message, type: type
    expect(flow.to_h.dig(:parameters, 0, :type)).to eq(type)
  end

  it 'handles legacy and malformed widget metadata defensively' do
    page = Mxrb::Model::Page.allocate
    expect(page.send(:widget_type, 'Forms$DropDown')).to eq(:drop_down)
    expect(page.send(:widget_type, 'Future$Widget')).to be_nil
    expect(page.send(:custom_property_map, nil, nil)).to eq({})
    expect(page.send(:parse_search_bar, 'invalid')).to be_nil
    expect(page.send(:parse_search_bar, 'SearchFields' => [{ 'Name' => 'missing' }])).to be_nil
    search = page.send(:parse_search_bar, 'SearchFields' => [{
      'AttributePath' => 'Ui.Item/Name', 'Caption' => 'Name'
    }])
    expect(search.dig(:fields, 0, :attribute)).to eq('Name')
    expect(page.send(:parse_toolbar, 'invalid')).to be_nil
    expect(page.send(:parse_toolbar, 'Buttons' => [{ '$Type' => 'Unknown' }])).to be_nil
    toolbar = page.send(:parse_toolbar, 'Buttons' => [{
      '$Type' => 'Forms$GridSearchButton', 'Caption' => 'Search'
    }])
    expect(toolbar.dig(:buttons, 0, :type)).to eq(:search)
    expect(page.send(:parse_source, '$Type' => 'Forms$MicroflowSource')).to be_nil
  end
  it 'exports generic, native, reference and nested tab widget declarations' do
    exporter = Mxrb::Exporter.allocate
    pluggable = exporter.send(:render_widget, {
      type: :pluggable_widget, name: 'Map', events: [],
      options: {
        widget_id: 'example.Map', widget_name: 'Map widget', properties: { zoom: 12 },
        class: 'map'
      }
    }, 2).join("\n")
    minimal_pluggable = exporter.send(:render_widget, {
      type: :pluggable_widget, name: 'Basic', events: [], options: { widget_id: 'example.Basic' }
    }, 2).join("\n")
    native = exporter.send(:render_widget, {
      type: 'native_widget', name: 'Raw', events: [],
      options: { native_type: 'Vendor$Raw', deep_structure: { 'Mode' => '3d' } }
    }, 2).join("\n")
    reference = exporter.send(:render_widget, {
      type: :reference_selector, name: 'Owner', events: [],
      options: { display_attribute: 'Ui.Owner.Name' }
    }, 2).join("\n")
    text_area = exporter.send(:render_widget, {
      type: :text_area, name: 'Notes', events: [], options: { lines: 4 }
    }, 2).join("\n")
    tabs = exporter.send(:render_widget, {
      type: :tab_control, name: 'Tabs', events: [],
      options: { tabs: [
        { name: 'Empty', caption: 'Empty' },
        { name: 'Full', widgets: [{ type: :text, name: 'Help', options: {}, events: [] }] }
      ] }
    }, 2).join("\n")
    expect(pluggable).to include('pluggable_widget', 'widget_name:', 'properties:', 'class_name:')
    expect(minimal_pluggable).to eq('  pluggable_widget :Basic, widget_id: "example.Basic"')
    expect(native).to include('native_widget', 'deep_structure:')
    expect(reference).to include('display_attribute:')
    expect(text_area).to include('lines: 4')
    expect(tabs).to include('tab_page :Empty', 'tab_page :Full do', 'text :Help')
    page_builder = Mxrb::Dsl::PageBuilder.new(:Page)
    page_builder.container(:Empty)
    expect(page_builder.to_h.fetch(:widgets).last).to include(type: :container, children: [])
  end

  it 'hydrates incomplete generated widgets from each compatible native baseline' do
    descriptors = [writer.send(:data_grid2_descriptor), writer.send(:combo_box_descriptor)]
    baselines = descriptors.map do |descriptor|
      schema_widget(descriptor[:id], { value: { type: 'String' } }, name: descriptor[:name])
    end
    custom_baseline = schema_widget('example.Widget', { value: { type: 'String' } }, name: 'Custom')
    baselines << custom_baseline
    generated = [
      {
        '$Type' => 'CustomWidgets$CustomWidget', 'Name' => descriptors[0][:name],
        'Type' => { 'WidgetId' => descriptors[0][:id] },
        '__mxrb_widget_options' => { __kind: :data_grid }
      },
      {
        '$Type' => 'CustomWidgets$CustomWidget', 'Name' => descriptors[1][:name],
        'Type' => { 'WidgetId' => descriptors[1][:id] },
        '__mxrb_widget_options' => { __kind: :drop_down }
      },
      {
        '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'Custom',
        'Type' => { 'WidgetId' => 'example.Widget' },
        '__mxrb_widget_options' => { __kind: :pluggable_widget, properties: { value: 'ready' } }
      }
    ]

    writer.send(:hydrate_pluggable_widgets!, { 'Widgets' => generated }, 'Widgets' => baselines)

    expect(generated.map { _1.dig('Type', 'WidgetId') }).to eq(
      [descriptors[0][:id], descriptors[1][:id], 'example.Widget']
    )
    expect(writer.send(:custom_widget_properties, generated.last).dig('value', 'Value', 'PrimitiveValue'))
      .to eq('ready')
    parsed = Mxrb::Model::Page.allocate.send(:pluggable_widget, generated.last)
    expect(parsed).to include(
      type: :pluggable_widget, name: 'Custom',
      options: include(widget_id: 'example.Widget', widget_name: 'Custom', properties: include('value' => 'ready'))
    )
    expect(parsed[:children]).to be_empty
  end

  it 'runs the native MPK-backed generator twice to settle widget schemas' do
    Dir.mktmpdir do |dir|
      definition = File.join(dir, 'project.rb')
      File.write(definition, "# test\n")
      synchronizer = Mxrb::WidgetSynchronizer.new(definition, File.join(dir, 'app.mpr'))
      allow(synchronizer).to receive(:generate)

      result = synchronizer.sync!
      expect(synchronizer).to have_received(:generate).twice
      expect(result.project).to eq(File.join(dir, 'app.mpr'))
      expect(result.mx_path).to eq('native MPK schemas')
    end
  end
  it 'restores output paths and reports synchronizer failures' do
    Dir.mktmpdir do |dir|
      definition = File.join(dir, 'project.rb')
      marker = File.join(dir, 'marker')
      File.write(definition, "File.write(#{marker.inspect}, ENV.fetch('MXRB_OUTPUT_PATH'))\n")
      synchronizer = Mxrb::WidgetSynchronizer.new(definition, File.join(dir, 'app.mpr'))

      ENV['MXRB_OUTPUT_PATH'] = 'original'
      synchronizer.send(:generate)
      expect(File.read(marker)).to eq(File.join(dir, 'app.mpr'))
      expect(ENV.fetch('MXRB_OUTPUT_PATH')).to eq('original')
      ENV.delete('MXRB_OUTPUT_PATH')
      synchronizer.send(:generate)
      expect(ENV).not_to have_key('MXRB_OUTPUT_PATH')

      expect { Mxrb::WidgetSynchronizer.new('missing.rb', 'missing.mpr').sync! }
        .to raise_error(ArgumentError, /definition not found/)
    ensure
      ENV.delete('MXRB_OUTPUT_PATH')
    end
  end
end
# rubocop:enable Metrics/BlockLength
