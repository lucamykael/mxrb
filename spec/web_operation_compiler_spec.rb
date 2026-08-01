# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Compiler::WebOperationCompiler do
  def unit(module_name:, document:)
    Struct.new(:module_name, :document, keyword_init: true).new(module_name:, document:)
  end

  def widget(source: true)
    data_source = if source
                    {
                      '$Type' => 'CustomWidgets$CustomWidgetXPathSource',
                      'EntityRef' => { 'Entity' => 'Demo.Item' }, 'XPathConstraint' => 'Active = true'
                    }
                  end
    {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'grid',
      'Object' => { 'DataSource' => data_source },
      'Columns' => [{ '$Type' => 'DomainModels$AttributeRef', 'Attribute' => 'Demo.Item.Name' },
                    { '$Type' => 'DomainModels$AttributeRef', 'Attribute' => 'Demo.Item.Name' }]
    }
  end

  it 'writes deterministic XPath retrieve operations with a deduplicated attribute inventory' do
    page = unit(module_name: 'Demo', document: {
      '$Type' => 'Forms$Page', 'Name' => 'Home', 'Widgets' => [widget, widget(source: false)]
    })
    source = instance_double(Mxrb::Compiler::SourceModel)
    allow(source).to receive(:units_of).with('Forms$Page').and_return([page])
    allow(source).to receive(:documents).with('Security$ProjectSecurity').and_return([])
    Dir.mktmpdir do |root|
      path = File.join(root, 'operations.json')
      operations = described_class.new(source).write(path)
      expect(JSON.parse(File.read(path))).to eq(operations)
      expect(operations.length).to eq(1)
      expect(operations.first).to include(
        'operationId' => described_class.operation_id('Demo.Home', 'grid'),
        'operationType' => 'retrieve'
      )
      expect(operations.first['constants']).to include(
        'XPath' => '//Demo.Item[Active = true]',
        'UsedAttributes' => ['Demo.Item.Name']
      )
    end
  end

  it 'renders an unconstrained XPath without brackets' do
    compiler = described_class.new(instance_double(Mxrb::Compiler::SourceModel))
    constants = compiler.send(
      :constants, 'Demo.Home', widget, { 'XPathConstraint' => '' }, 'Demo.Item'
    )
    expect(constants['XPath']).to eq('//Demo.Item')
  end

  it 'authorizes native save and cancel actions with deterministic operation ids' do
    actions = %w[Forms$SaveChangesClientAction Forms$CancelChangesClientAction].map.with_index do |type, index|
      { '$Type' => 'Forms$ActionButton', 'Name' => "button#{index}",
        'Action' => { '$Type' => type } }
    end
    actions << { '$Type' => 'Forms$ActionButton', 'Name' => 'ignored',
                 'Action' => { '$Type' => 'Forms$NoAction' } }
    page = unit(module_name: 'Demo', document: { 'Name' => 'Edit', 'Widgets' => actions })
    source = instance_double(Mxrb::Compiler::SourceModel)
    allow(source).to receive(:units_of).with('Forms$Page').and_return([page])
    allow(source).to receive(:documents).with('Security$ProjectSecurity').and_return([])

    operations = described_class.new(source).send(:page_operations, page)
    expect(operations.map { _1['operationType'] }).to eq(%w[commit rollback])
    expect(operations).to all(include(
                                'parameters' => { 'Objects' => ['AnyObjectList'] },
                                'constants' => {}, 'allowedUserRoleSets' => []
                              ))
  end

  it 'maps page module roles to the project user roles allowed by the Runtime' do
    page = unit(module_name: 'Demo', document: {
      'Name' => 'Edit', 'AllowedModuleRoles' => [1, 'Demo.Editor']
    })
    security = {
      'UserRoles' => [2,
                      { 'Name' => 'Administrator', 'ModuleRoles' => [1, 'Demo.Editor'] },
                      { 'Name' => 'Viewer', 'ModuleRoles' => [1, 'Demo.Viewer'] }]
    }
    source = instance_double(Mxrb::Compiler::SourceModel)
    allow(source).to receive(:documents).with('Security$ProjectSecurity').and_return([security])

    expect(described_class.new(source).send(:allowed_user_role_sets, page))
      .to eq([['Administrator']])
  end
end

RSpec.describe Mxrb::Compiler::DataGridBundleCompiler do
  def unit(module_name:, document:)
    Struct.new(:module_name, :document, keyword_init: true).new(module_name:, document:)
  end

  def property_type(id, key, type)
    { '$ID' => id, '$Type' => 'CustomWidgets$WidgetPropertyType', 'PropertyKey' => key,
      'ValueType' => { '$Type' => 'CustomWidgets$WidgetValueType', 'Type' => type } }
  end

  def value(type_id, primitive: '', **extra)
    { '$Type' => 'CustomWidgets$WidgetValue', 'TypePointer' => type_id,
      'PrimitiveValue' => primitive, 'Widgets' => [2], 'Objects' => [2] }
      .merge(extra.transform_keys(&:to_s))
  end

  def property(type_id, contents)
    { '$Type' => 'CustomWidgets$WidgetProperty', 'TypePointer' => type_id, 'Value' => contents }
  end

  def text(value)
    { '$Type' => 'Forms$ClientTemplate', 'Template' => {
      '$Type' => 'Texts$Text', 'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => value }]
    } }
  end

  def schema
    @top_types = [
      property_type('datasource', 'datasource', 'DataSource'),
      property_type('columns', 'columns', 'Object'),
      property_type('refresh', 'refreshInterval', 'Integer'),
      property_type('enabled', 'refreshIndicator', 'Boolean'),
      property_type('pagination', 'pagination', 'Enumeration'),
      property_type('caption', 'loadMoreButtonCaption', 'TextTemplate'),
      property_type('widgets', 'filtersPlaceholder', 'Widgets'),
      property_type('ignored', 'onClick', 'Action')
    ]
    @column_types = [
      property_type('show', 'showContentAs', 'Enumeration'),
      property_type('attribute', 'attribute', 'Attribute'),
      property_type('header', 'header', 'TextTemplate'),
      property_type('sortable', 'sortable', 'Boolean')
    ]
    {
      '$ID' => 'widget-type', '$Type' => 'CustomWidgets$CustomWidgetType',
      'WidgetId' => described_class::WIDGET_ID,
      'ObjectType' => {
        '$ID' => 'object-type', '$Type' => 'CustomWidgets$WidgetObjectType',
        'PropertyTypes' => [2, *@top_types]
      },
      'ColumnSchema' => { 'PropertyTypes' => [2, *@column_types] }
    }
  end

  def grid
    column = {
      '$Type' => 'CustomWidgets$WidgetObject',
      'Properties' => [
        2,
        property('show', value('show-value', primitive: 'attribute')),
        property('attribute', value('attribute-value', AttributeRef: { 'Attribute' => 'Demo.Item.Name' })),
        property('header', value('header-value', TextTemplate: text('Name'))),
        property('sortable', value('sortable-value', primitive: 'true'))
      ]
    }
    {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'grid',
      'Appearance' => { 'Class' => 'table' }, 'Object' => {
        '$Type' => 'CustomWidgets$WidgetObject', 'TypePointer' => 'object-type',
        'Properties' => [
          2,
          property('datasource', value('source-value', DataSource: {
            '$Type' => 'CustomWidgets$CustomWidgetXPathSource',
            'EntityRef' => { 'Entity' => 'Demo.Item' }
          })),
          property('columns', value('columns-value', Objects: [2, column])),
          property('refresh', value('refresh-value', primitive: '20')),
          property('enabled', value('enabled-value', primitive: 'false')),
          property('pagination', value('pagination-value', primitive: 'buttons')),
          property('caption', value('caption-value', TextTemplate: text('Load More'))),
          property('widgets', value('widgets-value')),
          property('ignored', value('ignored-value')),
          property('unknown-type', value('unknown-value'))
        ]
      }
    }
  end

  def source(widget_schema = schema)
    domain = unit(module_name: 'Demo', document: {
      'Entities' => [2, { 'Name' => 'Item', 'Attributes' => [
        2, { 'Name' => 'Name', 'NewType' => { '$Type' => 'DomainModels$StringAttributeType' } }
      ] }]
    })
    instance_double(Mxrb::Compiler::SourceModel, documents: [widget_schema]).tap do |model|
      allow(model).to receive(:units_of).and_return([])
      allow(model).to receive(:units_of).with('DomainModels$DomainModel').and_return([domain])
    end
  end

  it 'compiles an XPath Data Grid 2 and its attribute columns' do
    compiler = described_class.new(source, 'Demo.Home', grid)
    expect(compiler).to be_supported
    output = compiler.render
    expect(output).to include(
      'React.createElement($Datagrid', 'DatabaseObjectListProperty',
      'AttributeProperty', 'ExpressionProperty', '"attributeType": "String"',
      '"refreshIndicator": false', 'mx-name-grid table'
    )
  end

  it 'rejects another widget type and a column without an attribute' do
    other = schema.merge('WidgetId' => 'example.Other')
    expect(described_class.new(source(other), 'Demo.Home', grid)).not_to be_supported
    broken = grid
    column = broken.dig('Object', 'Properties', 2, 'Value', 'Objects', 1)
    column['Properties'][2]['Value']['AttributeRef'] = nil
    expect(described_class.new(source, 'Demo.Home', broken)).not_to be_supported
  end

  it 'generates the complete page module for a supported data grid' do
    model = source
    page = unit(module_name: 'Demo', document: {
      '$Type' => 'Forms$Page', 'Name' => 'Home', 'Title' => text('Items')['Template'],
      'FormCall' => { 'Arguments' => [
        2, { 'Parameter' => 'Demo.Shell.Main', 'Widgets' => [2, grid] }
      ] }
    })
    bundle = Mxrb::Compiler::PageBundleCompiler.new(model).compile(page)
    expect(bundle.unsupported_widgets).to be_empty
    expect(bundle.source).to include('asPluginWidgets', 'DatabaseObjectListProperty', '$Datagrid')
  end

  it 'covers optional grid metadata and schema fallbacks' do
    compiler = described_class.new(source, 'Demo.Home', grid)
    expect(compiler.send(:primitive, 'Widgets', 'Widgets' => [2, {}])).to eq(:undefined)
    expect(compiler.send(:property_values, nil)).to eq({})
    plain = described_class.new(source, 'Demo.Home', 'Name' => 'plain')
    expect(plain.send(:css_class)).to eq('mx-name-plain')
    expect(compiler.send(:translated_text, nil)).to eq('')
    expect(compiler.send(:translated_text, 'Template' => {
      'Items' => [3, { 'LanguageCode' => 'de_DE', 'Text' => 'Name' }]
    })).to eq('Name')
    expect(compiler.send(:translated_text, 'Template' => { 'Items' => [3] })).to eq('')
    expect(compiler.send(:text_value, nil)).to eq('')
    expect(compiler.send(:attribute_type_name, nil)).to eq('String')

    without_source = grid
    without_source.dig('Object', 'Properties')[1]['Value']['DataSource'] = nil
    expect(described_class.new(source, 'Demo.Home', without_source)).not_to be_supported

    missing_source = grid
    missing_source.dig('Object', 'Properties').reject! do |item|
      item.is_a?(Hash) && item['TypePointer'] == 'datasource'
    end
    expect(described_class.new(source, 'Demo.Home', missing_source)).not_to be_supported

    nil_source = grid
    nil_source.dig('Object', 'Properties').find do |item|
      item.is_a?(Hash) && item['TypePointer'] == 'datasource'
    end['Value'] = nil
    expect(described_class.new(source, 'Demo.Home', nil_source)).not_to be_supported

    missing_attribute = grid
    column = missing_attribute.dig('Object', 'Properties', 2, 'Value', 'Objects', 1)
    column['Properties'].reject! { _1.is_a?(Hash) && _1['TypePointer'] == 'attribute' }
    expect(described_class.new(source, 'Demo.Home', missing_attribute)).not_to be_supported

    missing_header = grid
    column = missing_header.dig('Object', 'Properties', 2, 'Value', 'Objects', 1)
    column['Properties'].reject! { _1.is_a?(Hash) && _1['TypePointer'] == 'header' }
    expect(described_class.new(source, 'Demo.Home', missing_header).render).to include(
      '"value": ""'
    )
    expect(compiler.send(:attribute_type, 'Other.Item', 'Name')).to eq('String')
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
