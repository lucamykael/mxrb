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
end
# rubocop:enable Metrics/BlockLength
