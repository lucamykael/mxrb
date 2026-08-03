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

  def schema # rubocop:disable Metrics/MethodLength
    types = [
      property_type('source', 'source', 'Enumeration'),
      property_type('options-type', 'optionsSourceType', 'Enumeration'),
      property_type('caption-type', 'optionsSourceAssociationCaptionType', 'Enumeration'),
      property_type('association-caption', 'optionsSourceAssociationCaptionAttribute', 'Attribute'),
      property_type('association', 'attributeAssociation', 'Association'),
      property_type('association-source', 'optionsSourceAssociationDataSource', 'DataSource'),
      property_type('database-target', 'databaseAttributeString', 'Attribute'),
      property_type('database-caption', 'optionsSourceDatabaseCaptionAttribute', 'Attribute'),
      property_type('database-value', 'optionsSourceDatabaseValueAttribute', 'Attribute'),
      property_type('database-source', 'optionsSourceDatabaseDataSource', 'DataSource'),
      property_type('database-selection', 'optionsSourceDatabaseItemSelection', 'Selection'),
      property_type('clearable', 'clearable', 'Boolean'),
      property_type('empty', 'emptyOptionText', 'TextTemplate')
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
end
# rubocop:enable Metrics/BlockLength
