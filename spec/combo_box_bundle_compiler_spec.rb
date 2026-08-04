# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::ComboBoxBundleCompiler do
  def property_type(id, key, type)
    { '$ID' => id, 'PropertyKey' => key, 'ValueType' => { 'Type' => type } }
  end

  def property(id, primitive: '', **values)
    { 'TypePointer' => id, 'Value' => {
      'PrimitiveValue' => primitive, 'Widgets' => [2], 'Selection' => 'None'
    }.merge(values.transform_keys(&:to_s)) }
  end

  def schema # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    types = [
      property_type('source', 'source', 'Enumeration'),
      property_type('options-type', 'optionsSourceType', 'Enumeration'),
      property_type('caption-type', 'optionsSourceAssociationCaptionType', 'Enumeration'),
      property_type('association-caption', 'optionsSourceAssociationCaptionAttribute', 'Attribute'),
      property_type('association-caption-expression', 'optionsSourceAssociationCaptionExpression', 'Expression'),
      property_type('association', 'attributeAssociation', 'Association'),
      property_type('association-source', 'optionsSourceAssociationDataSource', 'DataSource'),
      property_type('database-target', 'databaseAttributeString', 'Attribute'),
      property_type('database-caption', 'optionsSourceDatabaseCaptionAttribute', 'Attribute'),
      property_type('database-value', 'optionsSourceDatabaseValueAttribute', 'Attribute'),
      property_type('database-source', 'optionsSourceDatabaseDataSource', 'DataSource'),
      property_type('database-selection', 'optionsSourceDatabaseItemSelection', 'Selection'),
      property_type('clearable', 'clearable', 'Boolean'),
      property_type('empty', 'emptyOptionText', 'TextTemplate'),
      property_type('interval', 'filterInputDebounceInterval', 'Integer'),
      property_type('footer', 'menuFooterContent', 'Widgets')
    ]
    {
      '$ID' => 'combo-type', 'WidgetId' => described_class::WIDGET_ID,
      'ObjectType' => { '$ID' => 'combo-object', 'PropertyTypes' => [2, *types] }
    }
  end

  def page
    Struct.new(:module_name, :document, keyword_init: true).new(module_name: 'Demo', document: {
      '$Type' => 'Forms$Page', 'Name' => 'Edit', 'Parameters' => [2, {
        'Name' => 'Order', 'ParameterType' => { 'Entity' => 'Demo.Order' }
      }]
    })
  end

  def source
    instance_double(Mxrb::Compiler::SourceModel, documents: [schema]).tap do |model|
      allow(model).to receive(:units_of) { |type| type == 'Forms$Page' ? [page] : [] }
    end
  end

  def widget(name, properties)
    {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => name,
      'LabelTemplate' => { 'Template' => { 'Items' => [
        3, { 'LanguageCode' => 'en_US', 'Text' => name.capitalize }
      ] } },
      'Appearance' => { 'Class' => 'selector' },
      'Object' => { 'TypePointer' => 'combo-object', 'Properties' => [2, *properties] }
    }
  end

  def xpath(entity)
    { '$Type' => 'CustomWidgets$CustomWidgetXPathSource',
      'EntityRef' => { 'Entity' => entity }, 'XPathConstraint' => '' }
  end

  it 'compiles a context association Combo box with its caption and selectable objects' do
    properties = [
      property('source', primitive: 'context'), property('options-type', primitive: 'association'),
      property('caption-type', primitive: 'attribute'),
      property('association-caption', AttributeRef: { 'Attribute' => 'Demo.Location.Name' }),
      property('association', EntityRef: { 'Steps' => [2, {
        'Association' => 'Demo.Order_Location', 'DestinationEntity' => 'Demo.Location'
      }] }),
      property('association-source', DataSource: xpath('Demo.Location')),
      property('clearable', primitive: 'true'), property('empty', TextTemplate: nil)
    ]
    compiler = described_class.new(
      source, 'Demo.Edit', widget('location', properties), scope: 'p.Demo.Edit.editor', entity: 'Demo.Order'
    )

    expect(compiler).to be_supported
    expect(compiler.render).to include(
      'React.createElement($Combobox', 'AssociationProperty', 'DatabaseObjectListProperty',
      'Demo.Order_Location', 'Demo.Location', 'ListAttributeProperty', 'Location',
      'React.createElement($FormGroup', 'mx-name-location selector'
    )
  end

  it 'compiles a database Combo box backed by an attribute reached through an association' do
    target = {
      'Attribute' => 'Demo.Course.Title', 'EntityRef' => { 'Steps' => [2, {
        'Association' => 'Demo.Order_Course', 'DestinationEntity' => 'Demo.Course'
      }] }
    }
    properties = [
      property('source', primitive: 'database'), property('options-type', primitive: 'association'),
      property('database-target', AttributeRef: target,
                                  SourceVariable: { 'PageParameter' => 'Order' }),
      property('database-caption', AttributeRef: { 'Attribute' => 'Demo.Course.Title' }),
      property('database-value', AttributeRef: { 'Attribute' => 'Demo.Course.Title' }),
      property('database-source', DataSource: xpath('Demo.Course')),
      property('database-selection', Selection: 'Single')
    ]
    compiler = described_class.new(
      source, 'Demo.Edit', widget('course', properties), scope: nil, entity: nil
    )

    expect(compiler).to be_supported
    expect(compiler.render).to include(
      '"source": "context"', 'AssociationProperty', '"scope": "$Order"',
      '"attribute": "Demo.Order_Course"', 'DatabaseObjectListProperty', 'Course'
    )
  end

  it 'compiles a direct database attribute and exercises optional primitive values' do
    target = { 'Attribute' => 'Demo.Order.Code', 'EntityRef' => { 'Steps' => [2] } }
    properties = [
      property('source', primitive: 'database'), property('options-type', primitive: 'database'),
      property('database-target', AttributeRef: target,
                                  SourceVariable: { 'PageParameter' => 'Order' }),
      property('database-caption', AttributeRef: { 'Attribute' => 'Demo.Order.Code' }),
      property('database-value', AttributeRef: { 'Attribute' => 'Demo.Order.Code' }),
      property('database-source', DataSource: xpath('Demo.Order')),
      property('interval', primitive: '250'), property('footer', Widgets: [2])
    ]
    compiler = described_class.new(source, 'Demo.Edit', widget('code', properties), scope: nil, entity: nil)

    expect(compiler).to be_supported
    expect(compiler.render).to include(
      'AttributeProperty', '"path": ""', 'SelectionProperty',
      '"selectionType": "Single"', '"filterInputDebounceInterval": 250',
      '"menuFooterContent": []'
    )
    expect(compiler.send(:compile_primitive, 'Widgets', 'Widgets' => [2, {}])).to be_nil
    expect(compiler.send(:translated_text, 'Template' => {
      'Items' => [3, { 'LanguageCode' => 'pt_BR', 'Text' => 'Curso' }]
    })).to eq('Curso')
    expect(compiler.send(:translated_text, nil)).to eq('')
  end

  it 'renders a microflow list source and rejects incomplete widget metadata' do
    properties = [
      property('source', primitive: 'context'), property('options-type', primitive: 'association'),
      property('caption-type', primitive: 'attribute'),
      property('association-caption', AttributeRef: { 'Attribute' => 'Demo.Location.Name' }),
      property('association', EntityRef: { 'Steps' => [2, {
        'Association' => 'Demo.Order_Location', 'DestinationEntity' => 'Demo.Location'
      }] }), property('association-source', DataSource: xpath('Demo.Location'))
    ]
    compiler = described_class.new(
      source, 'Demo.Edit', widget('location', properties), scope: 'p.Demo.Edit.editor', entity: 'Demo.Order'
    )
    compiler.instance_variable_set(
      :@data_source,
      instance_double(Mxrb::Compiler::WebListDataSource, xpath?: false, entity: 'Demo.Location')
    )
    expect(compiler.send(:list_property)).to include('MicroflowObjectListProperty')
    expect(compiler.send(:page_parameter_entity, 'Missing')).to eq('')
    expect(compiler.send(:page_parameter_entity, 'Order')).to eq('Demo.Order')

    blank_source = instance_double(Mxrb::Compiler::SourceModel, documents: [])
    allow(blank_source).to receive(:units_of).and_return([])
    incomplete = described_class.new(
      blank_source, 'Demo.Edit', widget('missing', []), scope: nil, entity: nil
    )
    expect(incomplete).not_to be_supported
    expect(incomplete.send(:property_values, 'Properties' => [2, { 'TypePointer' => 'missing' }])).to eq({})
    expect { incomplete.send(:split_attribute, 'invalid') }
      .to raise_error(Mxrb::CompilationError, /invalid Combo box attribute/)

    expect(incomplete.send(:selection_property)).to include('Single')
    expect(incomplete.send(:resolved_scope)).to be_nil
    expect(incomplete.send(:resolved_entity)).to eq('')
    expect(incomplete.send(:target_attribute)).to be_nil
    expect(incomplete.send(:database_caption_attribute)).to be_nil
    expect(incomplete.send(:database_value_attribute)).to be_nil
    expect(incomplete.send(:enumeration_attribute)).to be_nil
    expect(incomplete.send(:association_caption_attribute)).to be_nil
    expect(incomplete.send(:association_caption_expression)).to be_nil
    expect(incomplete.send(:list_expression_property)).to include('"path": null')
    expect(incomplete.send(:entity_steps, nil)).to eq([])
    expect(incomplete.send(:primitive, 'missing')).to be_nil
    expect(incomplete.send(:property_values, nil)).to eq({})

    stepped = { 'Attribute' => 'Demo.Course.Title', 'EntityRef' => { 'Steps' => [2, {
      'Association' => 'Demo.Order_Course', 'DestinationEntity' => 'Demo.Course'
    }] } }
    expect(compiler.send(:attribute_property, stepped))
      .to include('Demo.Order_Course/Demo.Course')
    compiler.instance_variable_get(:@values)['optionsSourceDatabaseItemSelection'] = [
      'Selection', { 'Selection' => 'Multiple' }
    ]
    expect(compiler.send(:selection_property)).to include('Multiple')
  end

  it 'compiles a context enumeration without requiring a list data source' do
    properties = [
      property('source', primitive: 'context'), property('options-type', primitive: 'enumeration'),
      property('database-target', AttributeRef: nil),
      property('association-caption', AttributeRef: nil),
      property('clearable', primitive: 'true'),
      {
        'TypePointer' => 'enum-target',
        'Value' => { 'AttributeRef' => { 'Attribute' => 'Demo.Order.Status' } }
      }
    ]
    model = source
    model.documents << property_type('enum-target', 'attributeEnumeration', 'Attribute')
    compiler = described_class.new(
      model, 'Demo.Edit', widget('status', properties),
      scope: 'p.Demo.Edit.editor', entity: 'Demo.Order'
    )

    expect(compiler).to be_supported
    expect(compiler.render).to include(
      'React.createElement($Combobox', '"optionsSourceType": "enumeration"',
      '"attributeEnumeration": AttributeProperty', '"entity": "Demo.Order"',
      '"attribute": "Status"'
    )
  end

  it 'compiles a context association caption expression' do
    properties = [
      property('source', primitive: 'context'), property('options-type', primitive: 'association'),
      property('caption-type', primitive: 'expression'),
      property('association-caption-expression', Expression: '$currentObject/Name'),
      property('association', EntityRef: { 'Steps' => [2, {
        'Association' => 'Demo.Order_Location', 'DestinationEntity' => 'Demo.Location'
      }] }),
      property('association-source', DataSource: xpath('Demo.Location'))
    ]
    compiler = described_class.new(
      source, 'Demo.Edit', widget('location', properties), scope: 'p.Demo.Edit.editor', entity: 'Demo.Order'
    )

    expect(compiler).to be_supported
    expect(compiler.render).to include(
      'optionsSourceAssociationCaptionExpression', 'ListExpressionProperty', '"path": "Name"'
    )
  end
end
# rubocop:enable Metrics/BlockLength
