# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'native page container rendering' do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'Containers.mpr')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          entity(:Item) { string :Name }
          page :Home
        end
      end
      @source = Mxrb::Compiler::SourceModel.read(@mpr)
      @unit = @source.units_of('Forms$Page').first
      example.run
    end
  end

  def page_widgets=(widgets)
    argument = @unit.document.dig('FormCall', 'Arguments').find { _1.is_a?(Hash) }
    argument['Widgets'] = [2, *widgets]
  end

  def table
    {
      '$Type' => 'Forms$Table', 'Name' => 'details', 'Appearance' => { 'Class' => 'details' },
      'Rows' => [2, { '$Type' => 'Forms$TableRow', 'Appearance' => { 'Class' => 'record' } }],
      'Cells' => [2,
                  {
                    '$Type' => 'Forms$DbTableCell', 'Name' => 'header', 'IsHeader' => true,
                    'TopRowIndex' => 0, 'LeftColumnIndex' => 0, 'Width' => 2, 'Height' => 1,
                    'Appearance' => { 'Class' => 'heading' }, 'Widgets' => [2]
                  },
                  {
                    '$Type' => 'Forms$DbTableCell', 'Name' => 'value', 'IsHeader' => false,
                    'TopRowIndex' => 0, 'LeftColumnIndex' => 2, 'Width' => 'bad', 'Height' => nil,
                    'Widgets' => [2, {
                      '$Type' => 'Forms$DynamicText', 'Name' => 'name', 'RenderMode' => 'Text',
                      'Content' => { 'Template' => { 'Items' => [2, { 'Text' => 'Name' }] } }
                    }]
                  }]
    }
  end

  def list_view
    {
      '$Type' => 'Forms$ListView', 'Name' => 'items', 'PageSize' => 10,
      'DataSource' => {
        '$Type' => 'Forms$ListViewXPathSource',
        'EntityRef' => { 'Entity' => 'Demo.Item' }, 'XPathConstraint' => ''
      },
      'Widgets' => [2, {
        '$Type' => 'Forms$DynamicText', 'Name' => 'itemName', 'RenderMode' => 'Text',
        'Content' => {
          'Template' => { 'Items' => [2, { 'Text' => '{1}' }] },
          'Parameters' => [2, { 'AttributeRef' => { 'Attribute' => 'Demo.Item.Name' } }]
        }
      }]
    }
  end

  it 'renders tables, XPath list views, and a DataView listening to list selection' do
    listener = {
      '$Type' => 'Forms$DataView', 'Name' => 'selected', 'ShowFooter' => false,
      'DataSource' => { '$Type' => 'Forms$ListenTargetSource', 'ListenTarget' => 'items' },
      'NoEntityMessage' => { 'Items' => [2] }, 'Widgets' => [2, table], 'FooterWidgets' => [2]
    }
    self.page_widgets = [list_view, listener]

    bundle = Mxrb::Compiler::PageBundleCompiler.new(@source).compile(@unit)

    expect(bundle).to have_attributes(unsupported_widgets: [], unsupported_custom_widgets: [])
    expect(bundle.source).to include(
      'React.createElement("table"', 'React.createElement("tbody"', 'React.createElement("tr"',
      'React.createElement("th"', 'React.createElement("td"', '"colSpan": 2', '"colSpan": 1',
      '$ListView', 'ListenObjectProperty',
      '"listenTo": "p.Demo.Home.items"', '"entity": "Demo.Item"'
    )
  end

  it 'fails closed for invalid listeners and resolves every structured microflow variable scope' do
    self.page_widgets = [list_view]
    compiler = Mxrb::Compiler::PageBundleCompiler.new(@source)
    compiler.send(:prepare_compile, @unit, 'p')
    compiler.instance_variable_set(
      :@snippet_scopes, [{ 'SnippetItem' => { scope: 'p.Demo.Home.items', entity: 'Demo.Item' } }]
    )

    expect(compiler.send(:listen_object_property, { 'ListenTarget' => 'missing' }, { 'Name' => 'view' }))
      .to be_nil
    expect(compiler.send(:data_view_entity, {
      'DataSource' => { '$Type' => 'Forms$ListenTargetSource', 'ListenTarget' => 'missing' }
    })).to eq('')
    expect(compiler.send(:integer_or, nil, 7)).to eq(7)
    expect(compiler.send(:all_page_widgets, 'scalar')).to eq([])

    scopes = {
      { 'SnippetParameter' => 'SnippetItem' } => 'p.Demo.Home.items',
      { 'PageParameter' => 'PageItem' } => '$PageItem',
      { 'Widget' => 'items' } => 'p.Demo.Home.items',
      { 'LocalVariable' => 'LocalItem' } => '$LocalItem'
    }
    scopes.each do |variable, expected|
      expect(compiler.send(:microflow_variable_scope, variable)).to eq(expected)
    end
    expect(compiler.send(:microflow_argument, {
      'Parameter' => 'Demo.Action.Item', 'Expression' => '',
      'Variable' => { 'SnippetParameter' => 'SnippetItem' }
    })).to eq([:Item, { widget: 'p.Demo.Home.items', source: 'object' }])
    expect(compiler.send(:microflow_variable_scope, nil)).to be_nil
    expect(compiler.send(:microflow_variable_scope, 'SnippetParameter' => 'Missing')).to be_nil
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
