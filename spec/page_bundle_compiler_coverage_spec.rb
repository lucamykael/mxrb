# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::PageBundleCompiler, 'complete branch coverage' do
  around do |example|
    Dir.mktmpdir do |root|
      path = File.join(root, 'Coverage.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          layout :Shell
          microflow :ServerAction
          nanoflow :ClientAction
          page(:Home) do
            layout 'Demo.Shell'
            title 'Home'
            container(:body) { text :caption, caption: 'Body' }
          end
        end
      end
      @source = Mxrb::Compiler::SourceModel.read(path)
      @unit = @source.units_of('Forms$Page').first
      @compiler = described_class.new(@source)
      @compiler.send(:prepare_compile, @unit, 'p')
      example.run
    end
  end

  def text(name, value = name)
    {
      '$Type' => 'Forms$DynamicText', 'Name' => name,
      'Content' => { 'Template' => { 'Items' => [2, { 'Text' => value }] } }
    }
  end

  it 'compiles layouts and renders every native layout/table dispatch path' do
    layout = @source.units_of('Forms$Layout').first
    layout.document['Content']['Widgets'] = [2, text('layoutText', 'Layout')]
    bundle = described_class.new(@source).compile_layout(layout)
    expect(bundle.source).to include('Object.assign', 'Layout')

    table = {
      '$Type' => 'Forms$Table', 'Name' => 'table', 'Rows' => [2, { 'Name' => 'row' }],
      'Cells' => [2,
                  { 'Name' => 'heading', 'IsHeader' => true, 'TopRowIndex' => 0,
                    'LeftColumnIndex' => 0, 'Width' => 2, 'Height' => 1, 'Widgets' => [2, text('h')] },
                  { 'Name' => 'value', 'IsHeader' => false, 'TopRowIndex' => 'bad',
                    'LeftColumnIndex' => 'bad', 'Width' => 0, 'Height' => nil, 'Widgets' => [2] }]
    }
    expect(@compiler.send(:render_widget, table)).to include(
      'React.createElement("table"', 'React.createElement("th"', 'React.createElement("td"'
    )

    scroll = {
      '$Type' => 'Forms$ScrollContainer', 'Name' => 'scroll', 'ScrollBehavior' => 'PerRegion',
      'LayoutMode' => 'Headline', 'Top' => nil,
      'CenterRegion' => {
        'ToggleMode' => 'PushContentInitiallyClosed', 'SizeMode' => 'Pixels', 'Size' => 200,
        'Appearance' => { 'Class' => 'center' }, 'Widgets' => [2, text('center')]
      }
    }
    expect(@compiler.send(:render_widget, scroll)).to include(
      '$ScrollContainer', '"enabled": false', '"enabled": true', '"toggleMode": "push"'
    )
    expect(@compiler.send(:render_widget, '$Type' => 'Forms$Placeholder', 'Name' => 'main'))
      .to include('$Placeholder', 'Demo.Home.main')
    expect(@compiler.send(:render_widget, '$Type' => 'Forms$SidebarToggleButton', 'Name' => 'toggle'))
      .to include('$SidebarToggle')
    expect(@compiler.send(:render_widget, {
      '$Type' => 'Forms$Header', 'Name' => 'header',
      'LeftWidgets' => [2, text('left')], 'RightWidgets' => [2, text('right')]
    })).to include('$Header', 'leftWidgets', 'rightWidgets')

    allow(@compiler).to receive(:menu_items).and_return([])
    %w[NavigationTree MenuBar SimpleMenuBar].each do |kind|
      output = @compiler.send(
        :render_widget,
        '$Type' => "Forms$#{kind}", 'Name' => kind, 'Orientation' => 'Horizontal', 'MenuSource' => {}
      )
      expect(output).to include("$#{kind}")
    end
  end

  it 'resolves real menu/navigation sources and compiles nested item contracts' do
    item = {
      'Caption' => { 'Items' => [2, { 'Text' => 'Parent' }] },
      'Icon' => { 'Image' => 'Demo.MenuIcon' },
      'Action' => {
        '$Type' => 'Forms$MicroflowAction',
        'MicroflowSettings' => { 'Microflow' => 'Demo.ServerAction', 'ParameterMappings' => [2] }
      },
      'Items' => [2, { 'Caption' => { 'Items' => [2, { 'Text' => 'Child' }] } }]
    }
    menu = Struct.new(:module_name, :document).new('Demo', {
      'Name' => 'Main', 'ItemCollection' => { 'Items' => [2, item] }
    })
    navigation = Struct.new(:document).new({
      'Profiles' => [2, { 'Name' => 'Responsive', 'Menu' => { 'Items' => [2, item] } }]
    })
    allow(@source).to receive(:units_of).and_call_original
    allow(@source).to receive(:units_of).with('Menus$MenuDocument').and_return([menu])
    allow(@source).to receive(:units_of).with('Navigation$NavigationDocument').and_return([navigation])

    expect(@compiler.send(:menu_items, '$Type' => 'Forms$MenuDocumentSource',
                                       'Menu' => 'Demo.Main')).to eq([item])
    expect(@compiler.send(:menu_items, '$Type' => 'Forms$NavigationSource',
                                       'NavigationProfile' => 'Responsive')).to eq([item])
    expect(@compiler.send(:render_menu, {
      '$Type' => 'Forms$MenuBar', 'Name' => 'resolvedMenu',
      'MenuSource' => { '$Type' => 'Forms$MenuDocumentSource', 'Menu' => 'Demo.Main' }
    }, 'MenuBar')).to include('$MenuBar', 'Parent')
    compiled = @compiler.send(:compile_menu_item, item, { 'Name' => 'menu' }, [0])
    expect(compiled).to include(:action, :icon, :items)
    expect(@compiler.send(:menu_action_config, {})).to be_nil
  end

  it 'renders snippets successfully and always unwinds scoped widget rendering' do
    snippet_document = {
      'Name' => 'Detail', 'Parameters' => [2],
      'Widgets' => [2, text('snippetText', 'Snippet')]
    }
    snippet = Struct.new(:module_name, :document).new('Demo', snippet_document)
    allow(@source).to receive(:units_of).and_call_original
    allow(@source).to receive(:units_of).with('Forms$Snippet').and_return([snippet])

    expect(@compiler.send(:snippet_index)).to include('Demo.Detail' => snippet)
    rendered = @compiler.send(
      :render_widget,
      '$Type' => 'Forms$SnippetCallWidget', 'Name' => 'detail',
      'FormCall' => { 'Form' => 'Demo.Detail' }
    )
    expect(rendered).to include('React.Fragment', 'Snippet')
    expect(@compiler.instance_variable_get(:@snippet_stack)).to be_empty

    expect(@compiler.send(:render_scoped_widgets, [text('scoped')], 'list', 'Demo.Item'))
      .to include('scoped')
    expect(@compiler.instance_variable_get(:@list_scopes)).to be_empty
  end

  it 'covers supported grid and object-scoped generic widget callbacks' do
    allow(Mxrb::Compiler::DataGridBundleCompiler).to receive(:new) do |*, render_widgets:, **|
      nested = render_widgets.call([text('gridChild')], 'gridScope', 'Demo.Item')
      instance_double(Mxrb::Compiler::DataGridBundleCompiler, supported?: true, render: nested)
    end
    expect(@compiler.send(:render_custom_widget, 'Name' => 'grid')).to include('gridChild')

    allow(Mxrb::Compiler::DataGridBundleCompiler).to receive(:new)
      .and_return(instance_double(Mxrb::Compiler::DataGridBundleCompiler, supported?: false))
    allow(Mxrb::Compiler::GalleryBundleCompiler).to receive(:new)
      .and_return(instance_double(Mxrb::Compiler::GalleryBundleCompiler, supported?: false))
    allow(Mxrb::Compiler::ImageBundleCompiler).to receive(:new)
      .and_return(instance_double(Mxrb::Compiler::ImageBundleCompiler, supported?: false))
    allow(Mxrb::Compiler::ComboBoxBundleCompiler).to receive(:new)
      .and_return(instance_double(Mxrb::Compiler::ComboBoxBundleCompiler, supported?: false))
    @compiler.instance_variable_set(:@list_scopes, [{ scope: 'objectScope', entity: 'Demo.Item' }])
    allow(Mxrb::Compiler::GenericWidgetBundleCompiler).to receive(:new) do |*, scope:, entity:, **|
      expect([scope, entity]).to eq(['objectScope', 'Demo.Item'])
      instance_double(
        Mxrb::Compiler::GenericWidgetBundleCompiler, supported?: true,
                                                     component_name: 'Generic', module_path: 'demo/Generic',
                                                     render: 'generic-render'
      )
    end
    expect(@compiler.send(:render_custom_widget, 'Name' => 'generic')).to eq('generic-render')
  end

  it 'covers close actions, empty-expression mappings, and every variable scope' do
    expect(@compiler.send(:close_page_config, '$Type' => 'Forms$ClosePageClientAction'))
      .to include(type: 'closePage')
    expect(@compiler.send(:close_page_config, {})).to be_nil

    @compiler.instance_variable_set(:@list_scopes, [{ scope: 'current', entity: 'Demo.Item' }])
    @compiler.instance_variable_set(:@snippet_scopes, [{ 'SnippetItem' => { scope: 'snippet' } }])
    @unit.document['Parameters'] = [2, { 'Name' => 'PageItem' }]
    argument = @compiler.send(:array, @unit.document.dig('FormCall', 'Arguments')).first
    body = @compiler.send(:array, argument['Widgets']).find { _1.is_a?(Hash) }
    expect(body['Name']).to eq('body')

    expect(@compiler.send(:microflow_variable_scope, nil)).to be_nil
    expect(@compiler.send(:microflow_variable_scope, 'SnippetParameter' => 'SnippetItem')).to eq('snippet')
    expect(@compiler.send(:microflow_variable_scope, 'SnippetParameter' => 'Missing')).to be_nil
    expect(@compiler.send(:microflow_variable_scope, 'PageParameter' => 'PageItem')).to eq('$PageItem')
    expect(@compiler.send(:microflow_variable_scope, 'Widget' => 'body')).to include('body')
    expect(@compiler.send(:microflow_variable_scope, 'Widget' => 'missing')).to be_nil
    expect(@compiler.send(:microflow_variable_scope, 'LocalVariable' => 'Local')).to eq('$Local')
    expect(@compiler.send(:microflow_variable_scope, 'LocalVariable' => 'bad value')).to be_nil

    mapping = {
      'Parameter' => 'Demo.ServerAction.Item', 'Expression' => '',
      'Variable' => { 'PageParameter' => 'PageItem' }
    }
    expect(@compiler.send(:microflow_argument, mapping)).to eq(
      [:Item, { widget: '$PageItem', source: 'object' }]
    )
  end

  it 'finds listen targets, page widgets, recursive values, and data-view entities' do
    listen_source = { '$Type' => 'Forms$ListenTargetSource', 'ListenTarget' => 'body' }
    listen_widget = { 'Name' => 'listener', 'DataSource' => listen_source }
    expect(@compiler.send(:listen_object_property, listen_source, listen_widget))
      .to include('ListenObjectProperty', 'body')
    expect(@compiler.send(:data_view_object_property, listen_widget, 'listener'))
      .to include('ListenObjectProperty')
    expect(@compiler.send(:listen_object_property, { 'ListenTarget' => 'missing' }, listen_widget)).to be_nil
    expect(@compiler.send(:page_widget, 'body')).to be_a(Hash)
    expect(@compiler.send(:page_widget, 'missing')).to be_nil

    recursive = { '$Type' => 'Forms$DivContainer', 'Children' => [{ '$Type' => 'Other', 'Items' => [] }] }
    expect(@compiler.send(:all_page_widgets, recursive).size).to eq(1)
    expect(@compiler.send(:all_page_widgets, [recursive, 'ignored']).size).to eq(1)
    expect(@compiler.send(:all_page_widgets, 'ignored')).to eq([])

    data_source = instance_double(Mxrb::Compiler::WebListDataSource, entity: 'Demo.Item')
    allow(Mxrb::Compiler::WebListDataSource).to receive(:new).and_return(data_source)
    expect(@compiler.send(:data_view_entity, 'DataSource' => listen_source)).to eq('Demo.Item')
    expect(@compiler.send(:data_view_entity, 'DataSource' => listen_source.merge('ListenTarget' => 'missing')))
      .to eq('')
    expect(@compiler.send(:data_view_entity, 'DataSource' => {
      'EntityRef' => { 'Entity' => 'Demo.Direct' }
    })).to eq('Demo.Direct')
  end

  it 'renders valid text areas, popup exports, and listen-object imports' do
    @compiler.instance_variable_set(:@data_view_scopes, [{ scope: 'object', entity: 'Demo.Item' }])
    base = {
      '$Type' => 'Forms$TextArea', 'Name' => 'notes',
      'AttributeRef' => { 'Attribute' => 'Demo.Item.Notes' },
      'NumberOfLines' => 4, 'SubmitBehaviour' => 'WhileEditing'
    }
    expect(@compiler.send(:render_widget, base.merge(
                                            'AutoGrow' => true, 'MaxLengthCode' => 200, 'Autocomplete' => false
                                          ))).to include('$TextArea', '"autoGrow": true', '"maxLength": 200',
                                                         '"autocomplete": "off"')
    expect(@compiler.send(:render_text_area, base.merge(
                                               'AutoGrow' => false, 'MaxLengthCode' => 0, 'Autocomplete' => true
                                             ))).to include('"autoGrow": false', '"maxLength": null',
                                                            '"autocomplete": "on"')

    allow(@compiler).to receive(:popup_page?).and_return(true)
    expect(@compiler.send(:cancel_changes_export)).to include('cancelChangesOperationId')
    expect(@compiler.send(:cancel_changes_operation_id)).to be_a(String).and(satisfy { !_1.empty? })

    @compiler.instance_variable_set(:@uses_form_widgets, true)
    @compiler.instance_variable_set(:@uses_listen_object, true)
    expect(@compiler.send(:widget_imports)).to include('ListenObjectProperty')
  end
end
# rubocop:enable Metrics/BlockLength
