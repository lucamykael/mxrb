# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::GenericWidgetBundleCompiler do
  def property_type(id, key, type)
    { '$ID' => id, 'PropertyKey' => key, 'ValueType' => { 'Type' => type } }
  end

  def property(id, value)
    { 'TypePointer' => id, 'Value' => value }
  end

  it 'compiles schema-backed primitive, data, text, action and content properties' do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'widgets', 'example'))
      File.write(File.join(root, 'widgets', 'example', 'LanguageSelector.mjs'), 'export default {};')
      types = [
        property_type('enabled', 'enabled', 'Boolean'),
        property_type('options', 'options', 'DataSource'),
        property_type('caption', 'caption', 'TextTemplate'),
        property_type('action', 'onClick', 'Action'),
        property_type('content', 'content', 'Widgets')
      ]
      index = types.to_h { [_1['$ID'], _1] }
      index['widget'] = {
        'WidgetId' => 'example.LanguageSelector', 'ObjectType' => { '$ID' => 'widget-object' }
      }
      source = instance_double(
        Mxrb::Compiler::SourceModel,
        path: File.join(root, 'App.mpr'), document_index: index
      )
      allow(source).to receive(:units_of).and_return([])
      widget = {
        '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'language',
        'Appearance' => { 'Class' => 'language-picker' },
        'Object' => { 'TypePointer' => 'widget-object', 'Properties' => [
          2,
          property('enabled', 'PrimitiveValue' => 'true'),
          property('options', 'DataSource' => {
            '$Type' => 'CustomWidgets$CustomWidgetXPathSource',
            'EntityRef' => { 'Entity' => 'System.Language' },
            'SortBar' => { 'SortItems' => [2, {
              'AttributeRef' => { 'Attribute' => 'System.Language.Description' },
              'SortOrder' => 'Ascending'
            }] }
          }),
          property('caption', 'TextTemplate' => {
            'Template' => { 'Items' => [3, {
              'LanguageCode' => 'en_US', 'Text' => 'Choose language'
            }] }
          }),
          property('action', 'Action' => { '$Type' => 'Forms$SignOutClientAction' }),
          property('content', 'Widgets' => [3, { '$Type' => 'Forms$DynamicText' }])
        ] }
      }
      compiler = described_class.new(
        source, 'Demo.Home', widget, scope: nil, entity: nil,
                                     render_widgets: ->(_widgets) { { '$raw' => '[content]' } },
                                     action_property: ->(_action) { 'ActionProperty({ action: { type: "signOut" } })' }
      )

      expect(compiler).to be_supported
      expect(compiler.render).to include(
        'React.createElement($LanguageSelector', '"enabled": true',
        'DatabaseObjectListProperty', 'System.Language', 'Description',
        'ExpressionProperty', 'Choose language', 'ActionProperty',
        '"content": [content]', 'mx-name-language language-picker'
      )
    end
  end

  it 'fails closed for missing package modules and unsupported object properties' do
    type = property_type('config', 'config', 'Object')
    source = instance_double(
      Mxrb::Compiler::SourceModel,
      path: '/tmp/Missing.mpr',
      document_index: {
        'config' => type,
        'widget' => { 'WidgetId' => 'example.Missing', 'ObjectType' => { '$ID' => 'widget-object' } }
      }
    )
    allow(source).to receive(:units_of).and_return([])
    widget = {
      'Name' => 'missing', 'Object' => {
        'TypePointer' => 'widget-object',
        'Properties' => [2, property('config', 'Objects' => [3, {}])]
      }
    }

    expect(described_class.new(source, 'Demo.Home', widget, scope: nil, entity: nil))
      .not_to be_supported
  end

  it 'does not bind expressions to an unconfigured list datasource' do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, 'widgets', 'example'))
      File.write(File.join(root, 'widgets', 'example', 'Chart.mjs'), 'export default {};')
      index = {
        'items' => property_type('items', 'items', 'DataSource'),
        'label' => property_type('label', 'label', 'Expression'),
        'widget' => { 'WidgetId' => 'example.Chart', 'ObjectType' => { '$ID' => 'widget-object' } }
      }
      source = instance_double(
        Mxrb::Compiler::SourceModel,
        path: File.join(root, 'App.mpr'), document_index: index
      )
      allow(source).to receive(:units_of).and_return([])
      properties = [
        2, property('items', 'DataSource' => nil),
        property('label', 'Expression' => '$Item/Name')
      ]
      widget = {
        'Name' => 'chart', 'Object' => {
          'TypePointer' => 'widget-object', 'Properties' => properties
        }
      }

      compiler = described_class.new(source, 'Demo.Home', widget, scope: 'scope', entity: 'Demo.Item')

      expect(compiler).to be_supported
      expect(compiler.render).to include('ExpressionProperty')
      expect(compiler.render).not_to include('ListExpressionProperty')
    end
  end

  it 'covers every schema-property, expression, template, and package fallback' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir do |root|
      index = {}
      source = instance_double(
        Mxrb::Compiler::SourceModel,
        path: File.join(root, 'App.mpr'), document_index: index
      )
      allow(source).to receive(:units_of).and_return([])
      compiler = described_class.allocate
      compiler.instance_variable_set(:@source, source)
      compiler.instance_variable_set(:@page_name, 'Demo.Home')
      compiler.instance_variable_set(:@widget, { 'Name' => 'all', 'Appearance' => {} })
      compiler.instance_variable_set(:@scope, 'p.Demo.Home.context')
      compiler.instance_variable_set(:@entity, 'Demo.Item')
      compiler.instance_variable_set(:@render_widgets, ->(widgets) { "rendered-#{widgets.length}" })
      compiler.instance_variable_set(:@key_prefix, 'p')
      compiler.instance_variable_set(:@action_property, ->(_action) { 'ActionProperty({})' })
      compiler.instance_variable_set(:@index, index)
      compiler.instance_variable_set(:@values, {})
      compiler.instance_variable_set(:@list_data_source, nil)
      compiler.instance_variable_set(:@component_name, 'All')
      compiler.instance_variable_set(:@module_path, 'example/All')

      expect(compiler.send(:widget_id)).to be_nil
      expect(compiler.send(:property_values, nil)).to eq({})
      expect(compiler.send(:property_values, 'Properties' => [2, { 'TypePointer' => 'missing' }])).to eq({})

      primitive_types = %w[Boolean Integer Decimal Enumeration String System]
      primitive_types.each { expect(compiler.send(:supported_property?, [_1, {}])).to be(true) }
      expect(compiler.send(:supported_property?, ['Association', {}])).to be(true)
      expect(compiler.send(:supported_property?, ['Selection', {}])).to be(true)
      expect(compiler.send(:supported_property?, ['Icon', { 'Icon' => nil }])).to be(true)
      expect(compiler.send(:supported_property?, ['Icon', { 'Icon' => {} }])).to be(false)
      expect(compiler.send(:supported_property?, ['Image', { 'Image' => '' }])).to be(true)
      expect(compiler.send(:supported_property?, ['Image', { 'Image' => 'Demo.Logo' }])).to be(false)
      expect(compiler.send(:supported_property?, ['Attribute', { 'AttributeRef' => nil }])).to be(true)
      expect(compiler.send(:supported_property?, ['DataSource', { 'DataSource' => nil }])).to be(true)
      expect(compiler.send(:supported_property?, ['DataSource', { 'DataSource' => { '$Type' => 'Bad' } }]))
        .to be(false)
      expect(compiler.send(:supported_property?, ['Object', { 'Objects' => [2] }])).to be(true)
      expect(compiler.send(:supported_property?, ['Object', { 'Objects' => [2, {}] }])).to be(false)
      expect(compiler.send(:supported_property?, ['Unknown', {}])).to be(false)

      values = {
        'Boolean' => { 'PrimitiveValue' => 'false' }, 'Integer' => { 'PrimitiveValue' => '12' },
        'Decimal' => { 'PrimitiveValue' => '1.5' }, 'Enumeration' => { 'PrimitiveValue' => 'One' },
        'String' => { 'PrimitiveValue' => 'value' }, 'Association' => {}, 'Object' => {},
        'Selection' => { 'Selection' => 'Multi' }, 'Icon' => {}, 'Image' => {}
      }
      values.each { |type, value| expect { compiler.send(:compile_property, [type, value]) }.not_to raise_error }
      expect(compiler.send(:compile_property, ['Selection', { 'Selection' => 'Multi' }]))
        .to include('$raw' => include('SelectionProperty', '"selectionType": "Multi"'))
      expect(compiler.send(:compile_property, ['Unknown', {}])).to eq(:undefined)
      expect(compiler.send(:compile_property, ['DataSource', { 'DataSource' => { '$Type' => 'Bad' } }]))
        .to eq(:undefined)
      expect(compiler.send(:compile_property, ['Action', {
        'Action' => { '$Type' => 'Forms$NoAction' }
      }])).to eq(:undefined)
      expect(compiler.send(:compile_widgets, 'Widgets' => [2])).to eq([])
      expect(compiler.send(:compile_widgets, 'Widgets' => [2, {}])).to eq('rendered-1')

      index['nested-name'] = property_type('nested-name', 'name', 'String')
      index['nested-source'] = property_type('nested-source', 'source', 'DataSource')
      nested = {
        'Properties' => [2,
                         property('nested-name', 'PrimitiveValue' => 'Series'),
                         property('nested-source', 'DataSource' => nil)]
      }
      object_value = { 'Objects' => [2, nested] }
      expect(compiler.send(:supported_property?, ['Object', object_value])).to be(true)
      expect(compiler.send(:compile_property, ['Object', object_value])).to eq([{ name: 'Series' }])

      expressions = ['', 'empty', '$Item', '$Item/Name', '12', '-1.5', 'true', 'false', "'text'", 'invalid +']
      compiled = expressions.map { compiler.send(:compile_expression, _1) }
      expect(compiled).to include(nil, { type: 'variable', variable: 'currentObject' },
                                  { type: 'literalNumeric', value: '-1.5' })
      expect(compiler.send(:variable_expression, '$Item/Name')).to include(path: 'Name')

      literal = { 'TextTemplate' => { 'Template' => { 'Items' => [2] }, 'Parameters' => [2] } }
      expect(compiler.send(:compile_template, literal)).to eq(type: 'literal', value: '')
      invalid = { 'TextTemplate' => { 'Template' => { 'Items' => [2] },
                                      'Parameters' => [2, { 'Expression' => 'bad +' }] } }
      expect(compiler.send(:compile_template, invalid)).to be_nil
      expect(compiler.send(:compile_template, 'TextTemplate' => nil)).to eq(type: 'literal', value: '')
      single = { 'TextTemplate' => { 'Template' => { 'Items' => [2, { 'Text' => '{1}' }] },
                                     'Parameters' => [2, { 'Expression' => '$Item' }] } }
      expect(compiler.send(:compile_template, single)).to include(type: 'variable')
      formatted = single.dup
      formatted['TextTemplate'] = Marshal.load(Marshal.dump(single['TextTemplate']))
      formatted.dig('TextTemplate', 'Template', 'Items', 1)['Text'] = 'Item {1}'
      expect(compiler.send(:compile_template, formatted)).to include(type: 'function', name: '+')

      expect(compiler.send(:attribute_property, 'AttributeRef' => { 'Attribute' => 'Demo.Item.Name' }))
        .to include('AttributeProperty')
      expect(compiler.send(:supported_property?, ['Attribute', {
        'AttributeRef' => { 'Attribute' => 'Demo.Item.Name' }
      }])).to be(true)
      expect(compiler.send(:compile_property, ['Attribute', {
        'AttributeRef' => { 'Attribute' => 'Demo.Item.Name' }
      }])).to include('$raw' => include('AttributeProperty'))
      compiler.instance_variable_set(:@scope, nil)
      expect(compiler.send(:compile_property, ['Attribute', {
        'AttributeRef' => { 'Attribute' => 'Demo.Item.Name' }
      }])).to eq(:undefined)
      expect(compiler.send(:attribute_property, 'AttributeRef' => { 'Attribute' => 'Demo.Item.Name' })).to be_nil
      expect(compiler.send(:attribute_property, 'AttributeRef' => { 'Attribute' => 'Name' })).to be_nil
      compiler.instance_variable_set(:@scope, 'scope')

      nested_expression = { type: 'function', parameters: [{ type: 'variable', variable: 'currentObject' }] }
      expect(compiler.send(:expression_variables, nested_expression)).to eq(['currentObject'])
      expect(compiler.send(:expression_variables, [nested_expression, nil])).to eq(['currentObject'])
      expect(compiler.send(:expression_variables, 'literal')).to eq([])

      xpath = { 'DataSource' => { '$Type' => 'CustomWidgets$CustomWidgetXPathSource',
                                  'EntityRef' => { 'Entity' => 'Demo.Item' }, 'SortBar' => {
                                    'SortItems' => [2, { 'AttributeRef' => { 'Attribute' => '' } }, {
                                      'AttributeRef' => { 'Attribute' => 'Demo.Item.Name' },
                                      'SortOrder' => 'Descending'
                                    }]
                                  } } }
      expect(compiler.send(:database_list_property, xpath)).to include('"desc"')
      compiler.send(:with_list_data_source, 'items' => ['DataSource', xpath, { 'DataSourceProperty' => 'items' }]) do
        expect(compiler.instance_variable_get(:@list_data_source)).to eq('DataSourceProperty' => 'items')
      end
      expect(compiler.send(:database_list_property, 'DataSource' => {
        '$Type' => 'CustomWidgets$CustomWidgetXPathSource', 'EntityRef' => { 'Entity' => 'Bad' }
      })).to be_nil
      compiler.instance_variable_set(:@list_data_source, xpath)
      bound = { 'DataSourceProperty' => 'items' }
      expect(compiler.send(:expression_property, 'Expression', { 'Expression' => '$Item' }, bound))
        .to include('ListExpressionProperty', 'dataSourceId')
      expect(compiler.send(:attribute_property, {
        'AttributeRef' => { 'Attribute' => 'Demo.Item.Name' }
      }, bound)).to include('ListAttributeProperty', 'dataSourceId')
      expect(compiler.send(:compile_widgets, { 'Widgets' => [2, {}] }, bound).fetch('$raw'))
        .to include('TemplatedWidgetProperty', 'dataSourceId')
      expect(compiler.send(:expression_property, 'Expression', 'Expression' => 'bad +')).to be_nil
      compiler.instance_variable_set(:@list_data_source, nil)
      expect(compiler.send(:expression_property, 'Expression', 'Expression' => '$Item'))
        .to include('ExpressionProperty')

      expect(compiler.send(:compiled_action, 'Action' => { '$Type' => 'Forms$NoAction' })).to be_nil
      expect(compiler.send(:compiled_action, 'Action' => { '$Type' => 'Forms$MicroflowAction' }))
        .to include('ActionProperty')
      compiler.instance_variable_set(:@action_property, nil)
      expect(compiler.send(:compiled_action, 'Action' => { '$Type' => 'Forms$MicroflowAction' })).to be_nil
      expect(compiler.send(:no_action?, {})).to be(true)
      expect(compiler.send(:no_action?, 'Action' => { '$Type' => 'Forms$NoAction' })).to be(true)
      expect(compiler.send(:no_action?, 'Action' => { '$Type' => 'Other' })).to be(false)

      expect(compiler.send(:enumeration_name, 'Missing.Entity.Member')).to be_nil
      enumeration_domain = Struct.new(:module_name, :document).new('Demo', {
        'Entities' => [2, { 'Name' => 'Item', 'Attributes' => [2, {
          'Name' => 'State', 'NewType' => { 'Enumeration' => 'Demo.State' }
        }, { 'Name' => 'Name', 'NewType' => {} }] }]
      })
      allow(source).to receive(:units_of).with('DomainModels$DomainModel').and_return([enumeration_domain])
      expect(compiler.send(:enumeration_name, 'Demo.Item.State')).to eq('Demo.State')
      expect(compiler.send(:enumeration_name, 'Demo.Item.Name')).to be_nil
      expect(compiler.send(:template_parameter, 'AttributeRef' => {
        'Attribute' => 'Demo.Item.State'
      })).to include(type: 'function', name: 'getCaption')
      expect(compiler.send(:template_parameter, 'AttributeRef' => {
        'Attribute' => 'Demo.Item.Name'
      })).to include(type: 'variable')
      expect(compiler.send(:format_expression, '{1} suffix', [{ type: 'literal', value: 'x' }]))
        .to include(type: 'function')
      expect(compiler.send(:translated_text, nil)).to eq('')
      expect(compiler.send(:present_qualified_name?, 'Demo.Item')).to be(true)
      expect(compiler.send(:present_qualified_name?, 'Bad')).to be(false)
      expect(compiler.send(:quoted?, '"yes"')).to be(true)
      expect(compiler.send(:quoted?, "'no\"")).to be(false)

      FileUtils.mkdir_p(File.join(root, 'widgets', 'example'))
      File.write(File.join(root, 'widgets', 'example', 'All.mjs'), '')
      expect(compiler.send(:package_module?)).to be(true)

      compiler.instance_variable_set(:@values, 'association' => ['Association', {}])
      expect(compiler.render).not_to include('"association"')
      FileUtils.rm_f(File.join(root, 'widgets', 'example', 'All.mjs'))
      FileUtils.mkdir_p(File.join(root, 'widgets'))
      File.write(File.join(root, 'widgets', 'broken.mpk'), 'broken')
      expect(compiler.send(:package_module?)).to be(false)
      Zip::File.open(File.join(root, 'widgets', 'good.mpk'), create: true) do |zip|
        zip.get_output_stream('example/All.mjs') { _1.write('') }
      end
      expect(compiler.send(:package_module?)).to be(true)
    end
  end
end
# rubocop:enable Metrics/BlockLength
