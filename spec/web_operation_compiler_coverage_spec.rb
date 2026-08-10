# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength
RSpec.describe Mxrb::Compiler::WebOperationCompiler, 'complete operation paths' do
  def unit(module_name, document)
    Struct.new(:module_name, :document).new(module_name, document)
  end

  def source_model(units: {}, documents: [], index: {})
    Mxrb::Compiler::SourceModel.allocate.tap do |source|
      allow(source).to receive(:units_of) { |type| units.fetch(type, []) }
      allow(source).to receive(:documents) { |type = nil| type ? documents.select { _1['$Type'] == type } : documents }
      allow(source).to receive(:document_index).and_return(index)
      allow(source).to receive(:web_page?).and_return(true)
      allow(source).to receive(:web_layout?).and_return(true)
    end
  end

  def flow(name = 'Run')
    unit('Demo', {
      '$Type' => 'Microflows$Microflow', 'Name' => name,
      'ObjectCollection' => { 'Objects' => [2] }
    })
  end

  it 'writes page and layout catalogs for a real SourceModel instance' do
    page = unit('Demo', { '$Type' => 'Forms$Page', 'Name' => 'Home' })
    layout = unit('Demo', { '$Type' => 'Forms$Layout', 'Name' => 'Shell' })
    source = source_model(units: { 'Forms$Page' => [page], 'Forms$Layout' => [layout] })
    compiler = described_class.new(source)

    Dir.mktmpdir do |directory|
      path = File.join(directory, 'operations.json')
      expect(compiler.write(path)).to eq([])
      expect(JSON.parse(File.read(path))).to eq([])
    end
    expect(compiler.send(:web_page?, page)).to be(true)
    expect(compiler.send(:web_layout?, layout)).to be(true)
  end

  it 'adds popup rollback and compiles Data Grid filter operations' do
    layout = unit('Demo', { '$Type' => 'Forms$Layout', 'Name' => 'DialogPopup' })
    page = unit('Demo', {
      '$Type' => 'Forms$Page', 'Name' => 'Dialog',
      'FormCall' => { 'Form' => 'Demo.DialogPopup' }
    })
    source = source_model(units: { 'Forms$Layout' => [layout] })
    compiler = described_class.new(source)
    expect(compiler.send(:page_operations, page)).to contain_exactly(
      include('operationType' => 'rollback', 'parameters' => { 'Objects' => ['AnyObjectList'] })
    )

    grid = { 'Name' => 'grid' }
    other = { 'Name' => 'other' }
    filter = { 'Name' => 'category' }
    allow(compiler).to receive(:custom_widgets).and_return([other, grid])
    allow(compiler).to receive(:custom_widget_id) do |widget|
      widget.equal?(grid) ? Mxrb::Compiler::DataGridBundleCompiler::WIDGET_ID : 'Other.Widget'
    end
    allow(compiler).to receive(:grid_filter_specs).with(grid)
                                                  .and_return([[filter, 'Demo.Category', 'Name']])
    expect(compiler.send(:data_grid_filter_operations, 'Demo.Dialog', {}, [['User']]))
      .to contain_exactly(include(
                            'operationType' => 'retrieve',
                            'constants' => include('XPath' => '//Demo.Category'),
                            'allowedUserRoleSets' => [['User']]
                          ))
  end

  it 'resolves custom widget schemas and all incomplete grid filter shapes' do
    widget_type = {
      'ObjectType' => { '$ID' => 'widget-object' }, 'WidgetId' => 'com.mendix.widget.grid'
    }
    property_type = {
      'PropertyKey' => 'columns', 'ValueType' => { 'Type' => 'Object' }
    }
    source = source_model(index: { 'property-type' => property_type, 'widget' => widget_type })
    compiler = described_class.new(source)
    widget = {
      'Object' => {
        'TypePointer' => 'widget-object',
        'Properties' => [2, { 'TypePointer' => 'property-type', 'Value' => 'contents' }]
      }
    }
    expect(compiler.send(:custom_widget_id, widget)).to eq('com.mendix.widget.grid')
    expect(compiler.send(:custom_property_values, widget['Object']))
      .to eq('columns' => %w[Object contents])

    grid = { 'Object' => { 'shape' => 'grid' } }
    column = { 'shape' => 'column' }
    allow(compiler).to receive(:custom_property_values) do |object|
      if object['shape'] == 'grid'
        { 'columns' => ['Object', { 'Objects' => [2, column] }] }
      else
        {
          'attribute' => ['Attribute', { 'AttributeRef' => { 'EntityRef' => { 'Steps' => [2] } } }],
          'filter' => ['Widgets', { 'Widgets' => [2] }]
        }
      end
    end
    expect(compiler.send(:grid_filter_specs, grid)).to eq([])
  end

  it 'resolves menu documents, navigation profiles, and nested non-action items' do
    action = {
      '$ID' => 'action', '$Type' => 'Forms$MicroflowAction',
      'MicroflowSettings' => { 'Microflow' => 'Demo.Run' }
    }
    child = { 'Action' => action }
    item = { 'Action' => { '$Type' => 'Forms$NoAction' }, 'Items' => [2, child] }
    menu = unit('Demo', {
      '$Type' => 'Menus$MenuDocument', 'Name' => 'Main',
      'ItemCollection' => { 'Items' => [2, item] }
    })
    navigation = unit('System', {
      '$Type' => 'Navigation$NavigationDocument',
      'Profiles' => [2, { 'Name' => 'Responsive', 'Menu' => { 'Items' => [2, item] } }]
    })
    source = source_model(units: {
      'Menus$MenuDocument' => [menu], 'Navigation$NavigationDocument' => [navigation],
      'Microflows$Microflow' => [flow]
    })
    compiler = described_class.new(source)
    document_source = { '$Type' => 'Forms$MenuDocumentSource', 'Menu' => 'Demo.Main' }
    navigation_source = { '$Type' => 'Forms$NavigationSource', 'NavigationProfile' => 'Responsive' }
    expect(compiler.send(:resolved_menu_items, document_source)).to eq([item])
    expect(compiler.send(:resolved_menu_items, navigation_source)).to eq([item])
    expect(compiler.send(:menu_item_operations, item)).to contain_exactly(
      include('operationType' => 'callMicroflow')
    )
    allow(compiler).to receive(:menu_widgets).and_return([{ 'MenuSource' => document_source }])
    expect(compiler.send(:menu_action_operations, {})).to contain_exactly(
      include('constants' => { 'MicroflowName' => 'Demo.Run' })
    )
  end

  it 'walks unique recursive snippets and inherits a typed delete scope' do
    snippet = unit('Demo', {
      '$Type' => 'Forms$Snippet', 'Name' => 'Shared',
      'Nested' => { '$Type' => 'Forms$SnippetCallWidget', 'FormCall' => { 'Form' => 'Demo.Shared' } }
    })
    source = source_model(units: { 'Forms$Snippet' => [snippet] })
    compiler = described_class.new(source)
    page = {
      'First' => { '$Type' => 'Forms$SnippetCallWidget', 'FormCall' => { 'Form' => 'Demo.Shared' } },
      'Second' => { '$Type' => 'Forms$SnippetCallWidget', 'FormCall' => { 'Form' => 'Demo.Shared' } }
    }
    expect(compiler.send(:page_related_documents, page)).to contain_exactly(page, snippet.document)

    delete_page = {
      'Parameters' => [2, { 'ParameterType' => { 'Entity' => 'Demo.Item' } }],
      'Button' => {
        '$Type' => 'Forms$ActionButton', 'Name' => 'delete',
        'Action' => { '$Type' => 'Forms$DeleteClientAction' }
      }
    }
    expect(compiler.send(:data_action_operations, 'Demo.Edit', delete_page, []).first)
      .to include('parameters' => { 'Objects' => ['[Demo.Item]'] })
  end

  it 'extracts actionable custom widget values and association DataView paths' do
    microflow_action = {
      '$Type' => 'Forms$MicroflowAction', 'MicroflowSettings' => { 'Microflow' => 'Demo.Run' }
    }
    custom = {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'custom', 'Object' => {
        'Empty' => { '$Type' => 'CustomWidgets$WidgetValue', 'Action' => {} },
        'None' => { '$Type' => 'CustomWidgets$WidgetValue', 'Action' => { '$Type' => 'Forms$NoAction' } },
        'Run' => { '$Type' => 'CustomWidgets$WidgetValue', 'Action' => microflow_action }
      }
    }
    source = source_model(units: { 'Microflows$Microflow' => [flow] })
    compiler = described_class.new(source)
    expect(compiler.send(:action_widgets, custom)).to contain_exactly([custom, microflow_action])

    data_view = {
      '$Type' => 'Forms$DataView', 'Name' => 'child', 'DataSource' => {
        'EntityRef' => { 'Steps' => [2, {
          'Association' => 'Demo.Parent_Child', 'DestinationEntity' => 'Demo.Child'
        }] }
      }
    }
    operation = compiler.send(:data_view_operation, 'Demo.Home', data_view, [], 'Demo.Parent')
    expect(operation).to include(
      'operationType' => 'retrieve',
      'constants' => include('EntityPath' => 'Demo.Parent_Child/Demo.Child')
    )
    expect(compiler.send(:widget_scope_entity, data_view)).to eq('Demo.Child')
    expect(compiler.send(:data_view_operation, 'Demo.Home', {
      '$Type' => 'Forms$DataView', 'Name' => 'empty', 'DataSource' => { 'EntityRef' => nil }
    }, [])).to be_nil
  end

  it 'compiles nanoflow server calls and commit variants while ignoring client actions' do
    server_flow = flow('ServerAction')
    nanoflow = unit('Demo', {
      '$Type' => 'Microflows$Nanoflow', 'Name' => 'ClientAction',
      'ObjectCollection' => { 'Objects' => [
        2,
        { '$Type' => 'Microflows$MicroflowParameter', 'Name' => 'Input',
          'VariableType' => { 'Entity' => 'Demo.Item' } },
        { '$Type' => 'Microflows$MicroflowParameter', 'Name' => 'Empty', 'VariableType' => {} },
        { '$Type' => 'Microflows$ActionActivity', '$ID' => 'call', 'Action' => {
          '$Type' => 'Microflows$MicroflowCallAction',
          'MicroflowCall' => { 'Microflow' => 'Demo.ServerAction' }
        } },
        { '$Type' => 'Microflows$ActionActivity', '$ID' => 'commit',
          'Action' => { '$Type' => 'Microflows$CommitAction', 'CommitVariableName' => 'Input' } },
        { '$Type' => 'Microflows$ActionActivity', '$ID' => 'change', 'Action' => {
          '$Type' => 'Microflows$ChangeAction', 'Commit' => 'Yes',
          'ChangeVariableName' => 'Created'
        } },
        { '$Type' => 'Microflows$ActionActivity', '$ID' => 'create', 'Action' => {
          '$Type' => 'Microflows$CreateChangeAction', 'Commit' => 'Yes',
          'VariableName' => 'Created', 'Entity' => 'Demo.Item'
        } },
        { '$Type' => 'Microflows$ActionActivity', '$ID' => 'client',
          'Action' => { '$Type' => 'Microflows$ShowMessageAction' } }
      ] }
    })
    source = source_model(units: {
      'Microflows$Nanoflow' => [nanoflow], 'Microflows$Microflow' => [server_flow]
    })
    operations = described_class.new(source).send(:nanoflow_operations)
    expect(operations.map { _1['operationType'] }).to eq(
      %w[callMicroflow commit commit commit]
    )
    expect(operations).to include(include('allowedUserRoleSets' => []))
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength
