# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Compiler::GalleryBundleCompiler do
  def unit(module_name:, document:)
    Struct.new(:module_name, :document, keyword_init: true).new(module_name:, document:)
  end

  def property_type(id, key, type)
    { '$ID' => id, '$Type' => 'CustomWidgets$WidgetPropertyType', 'PropertyKey' => key,
      'ValueType' => { '$Type' => 'CustomWidgets$WidgetValueType', 'Type' => type } }
  end

  def property(id, value)
    { '$Type' => 'CustomWidgets$WidgetProperty', 'TypePointer' => id, 'Value' => value }
  end

  def value(primitive: '', **extra)
    { '$Type' => 'CustomWidgets$WidgetValue', 'PrimitiveValue' => primitive,
      'Widgets' => [2], 'Selection' => 'None' }.merge(extra.transform_keys(&:to_s))
  end

  def schema
    types = [
      property_type('datasource', 'datasource', 'DataSource'),
      property_type('content', 'content', 'Widgets'),
      property_type('page-size', 'pageSize', 'Integer'),
      property_type('pagination', 'pagination', 'Enumeration'),
      property_type('caption', 'loadMoreButtonCaption', 'TextTemplate'),
      property_type('selection', 'itemSelection', 'Selection')
    ]
    {
      '$ID' => 'gallery-type', '$Type' => 'CustomWidgets$CustomWidgetType',
      'WidgetId' => described_class::WIDGET_ID,
      'ObjectType' => { '$ID' => 'gallery-object', 'PropertyTypes' => [2, *types] }
    }
  end

  def gallery(data_source)
    {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'gallery1',
      'Appearance' => { 'Class' => 'cards' }, 'Object' => {
        '$Type' => 'CustomWidgets$WidgetObject', 'TypePointer' => 'gallery-object',
        'Properties' => [
          2,
          property('datasource', value(DataSource: data_source)),
          property('content', value(Widgets: [2, { '$Type' => 'Forms$DivContainer' }])),
          property('page-size', value(primitive: '20')),
          property('pagination', value(primitive: 'buttons')),
          property('caption', value(TextTemplate: {
            'Template' => { 'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => 'More' }] }
          })),
          property('selection', value)
        ]
      }
    }
  end

  def source(*units, widget_schema: schema)
    instance_double(Mxrb::Compiler::SourceModel, documents: [widget_schema]).tap do |model|
      allow(model).to receive(:units_of) do |type|
        units.select { _1.document['$Type'] == type || (type == 'Microflows$Microflow' && !_1.document['$Type']) }
      end
    end
  end

  it 'compiles XPath data, selection and templated content through the official Gallery' do
    widget = gallery('$Type' => 'CustomWidgets$CustomWidgetXPathSource',
                     'EntityRef' => { 'Entity' => 'Demo.Item' })
    compiler = described_class.new(source, 'Demo.Home', widget)

    expect(compiler).to be_supported
    expect(compiler.entity_name).to eq('Demo.Item')
    expect(compiler.content_widgets.length).to eq(1)
    expect(compiler.render('[card]')).to include(
      'React.createElement($Gallery', 'DatabaseObjectListProperty',
      'TemplatedWidgetProperty({ children: () => [card]', 'SelectionProperty',
      'ExpressionProperty', 'mx-name-gallery1 cards'
    )
    expect(compiler.send(:primitive, 'Boolean', 'PrimitiveValue' => 'true')).to be(true)
    expect(compiler.send(:primitive, 'Boolean', 'PrimitiveValue' => 'false')).to be(false)
  end

  it 'compiles microflow list data and rejects unknown or incomplete sources' do
    flow = unit(module_name: 'Demo', document: {
      'Name' => 'LoadItems', 'MicroflowReturnType' => {
        '$Type' => 'DataTypes$ListType', 'Entity' => 'Demo.Item'
      }
    })
    widget = gallery('$Type' => 'Forms$MicroflowSource',
                     'MicroflowSettings' => { 'Microflow' => 'Demo.LoadItems' })
    compiler = described_class.new(source(flow), 'Demo.Home', widget)
    expect(compiler).to be_supported
    expect(compiler.render('[]')).to include('MicroflowObjectListProperty', 'fetchOnlyWithAllParams')

    unknown = schema.merge('WidgetId' => 'example.Other')
    expect(described_class.new(source(flow, widget_schema: unknown), 'Demo.Home', widget))
      .not_to be_supported
    missing = gallery('$Type' => 'Forms$MicroflowSource',
                      'MicroflowSettings' => { 'Microflow' => 'Demo.Missing' })
    expect(described_class.new(source(flow), 'Demo.Home', missing)).not_to be_supported
  end

  it 'compiles a nanoflow list as a client-side data source without a Runtime operation' do
    flow = unit(module_name: 'Demo', document: {
      '$Type' => 'Microflows$Nanoflow', 'Name' => 'LoadItems',
      'MicroflowReturnType' => { '$Type' => 'DataTypes$ListType', 'Entity' => 'Demo.Item' }
    })
    widget = gallery('$Type' => 'Forms$NanoflowSource', 'Nanoflow' => 'Demo.LoadItems')
    compiler = described_class.new(source(flow), 'Demo.Home', widget)

    expect(compiler).to be_supported
    expect(compiler.render('[]', nanoflow_reference: '() => DemoLoadItems')).to include(
      'NanoflowObjectListProperty', '"source": { "nanoflow": () => DemoLoadItems }',
      'fetchOnlyWithAllParams'
    )
  end

  it 'covers absent schema pointers and optional property values' do
    widget = gallery('$Type' => 'CustomWidgets$CustomWidgetXPathSource',
                     'EntityRef' => { 'Entity' => 'Demo.Item' })
    widget['Object'].delete('TypePointer')
    compiler = described_class.new(source, 'Demo.Home', widget)
    expect(compiler).not_to be_supported
    expect(compiler.send(:property_values, nil)).to eq({})
    expect(compiler.send(:primitive, 'Widgets', 'Widgets' => [2, {}])).to eq(:undefined)
    expect(compiler.send(:translated_text, nil)).to eq('')
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
