# frozen_string_literal: true

require 'json'
require 'rexml/document'
require 'tmpdir'
require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::LegacyDataGridCompiler do
  def text(value)
    { 'Items' => [3, { '$Type' => 'Texts$Translation', 'LanguageCode' => 'en_US', 'Text' => value }] }
  end

  def button(type, name)
    {
      '$ID' => SecureRandom.uuid, '$Type' => type, 'Name' => name, 'ButtonStyle' => 'Default',
      'CaptionTemplate' => { 'Template' => text(name) }, 'Tooltip' => text(''),
      'FormSettings' => { 'Form' => 'Demo.Edit', 'Location' => 'ModalPopup' },
      'Action' => { '$Type' => 'Forms$MicroflowAction',
                    'MicroflowSettings' => { 'Microflow' => 'Demo.Run' } }
    }
  end

  def grid(source_type) # rubocop:disable Metrics/MethodLength
    search = button('Forms$GridSearchButton', 'search')
    actions = %w[GridNewButton GridEditButton GridDeleteButton GridActionButton].map do |type|
      button("Forms$#{type}", type)
    end
    {
      '$ID' => '11111111-2222-4333-8444-555555555555', '$Type' => 'Forms$DataGrid',
      'Name' => 'grid', 'NumberOfRows' => 20, 'IsControlBarVisible' => true,
      'IsPagingEnabled' => true, 'SelectionMode' => 'Single', 'DefaultButtonTrigger' => 'Double',
      'Columns' => [2, { '$Type' => 'Forms$DataGridColumn', 'Name' => 'name',
                         'AttributePath' => 'Demo.Item.Name', 'WidthValue' => 100,
                         'Caption' => text('Name'), 'FormattingInfo' => { 'EnumFormat' => 'Text' } }],
      'DataSource' => {
        '$Type' => source_type, 'EntityPath' => 'Demo.Item', 'XPathConstraint' => '[Active]',
        'MicroflowSettings' => { 'Microflow' => 'Demo.Load' },
        'SearchBar' => { 'Type' => 'FoldableClosed', 'NewButtons' => [3, {
          '$Type' => 'Forms$ComparisonSearchField', 'Name' => 'find',
          'AttributePath' => 'Demo.Item.Name', 'Operator' => 'Contains', 'Caption' => text('Name')
        }] },
        'SortBar' => { 'SortItems' => [2, { 'AttributePath' => 'Demo.Item.Name',
                                            'SortOrder' => 'Ascending' }] }
      },
      'ControlBar' => { 'SearchButton' => search, 'NewButtons' => [3, *actions],
                        'DefaultButtonPointer' => actions[1]['$ID'] }
    }
  end # rubocop:enable Metrics/MethodLength

  it 'compiles every audited Data Grid 1 source and control-bar family' do
    page = Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil,
      document: { '$Type' => 'Forms$Page', 'Name' => 'Edit', 'PopupResizable' => true },
      module_name: 'Demo'
    )
    source = instance_double(Mxrb::Compiler::SourceModel, units_of: [page])
    types = %w[
      Forms$GridDatabaseSource Forms$NewGridDatabaseSource
      Forms$GridXPathSource Forms$MicroflowSource
    ]
    types.each_with_index do |type, index|
      compiler = described_class.new(source, 'Demo.Home', grid(type), language: 'en_US', sequence: index)
      document = REXML::Document.new(compiler.html)
      element = document.root
      props = JSON.parse("{#{element.attributes['data-mendix-props']}}")
      expect(props).to include('entity' => 'Demo.Item', 'schema' => '11111111-2222-4333-8444-555555555555')
      expect(props.dig('config', 'datasource', 'type')).to eq(described_class::SOURCE_TYPES.fetch(type))
      expect(props.dig('config', 'controlBar', 'gridActions').map { _1['gridFunction'] }).to eq(
        %w[ToggleSearch InsertNew EditSelection DeleteSelection InvokeAction]
      )
      expect(compiler.unsupported).to be_empty
    end
  end

  it 'reports unsupported contracts and covers every legacy client-action branch' do # rubocop:disable Metrics/BlockLength
    source = instance_double(Mxrb::Compiler::SourceModel, units_of: [])
    value = grid('Forms$UnknownSource')
    value['DataSource'].delete('EntityPath')
    value['DataSource']['SearchBar']['NewButtons'] << { '$Type' => 'Forms$UnknownSearch' }
    value['Columns'][1]['AttributePath'] = nil
    value['Columns'][1]['AttributeRef'] = { 'Attribute' => 'Demo.Item.Picture' }
    value['Columns'][1]['FormattingInfo']['EnumFormat'] = 'Image'
    value['ControlBar']['NewButtons'] << button('Forms$UnknownButton', 'unknown')
    value['ControlBar']['DefaultButtonPointer'] = SecureRandom.uuid
    compiler = described_class.new(source, 'Demo.Home', value, language: 'de_DE', sequence: 3)

    props = JSON.parse("{#{REXML::Document.new(compiler.html).root.attributes['data-mendix-props']}}")
    expect(props.dig('config', 'datasource', 'type')).to eq('unsupported')
    expect(props.dig('config', 'defaultButton')).to be_nil
    expect(props.dig('config', 'griddata', 0)).to include('tag' => 'Picture', 'render' => 'EnumImage')
    expect(compiler.unsupported).to include('Forms$UnknownSource', 'Forms$UnknownSearch', 'Forms$UnknownButton')

    actions = [
      [{ '$Type' => 'Forms$FormAction', 'FormSettings' => nil }, 'openPage'],
      [{ '$Type' => 'Forms$DeleteClientAction' }, 'deleteObject'],
      [{ '$Type' => 'Forms$NoAction' }, 'noAction'],
      [nil, 'noAction'],
      [{ '$Type' => 'Forms$UnknownAction' }, 'unsupported']
    ]
    expect(actions.map { |action, _type| compiler.send(:client_action, action)['type'] })
      .to eq(actions.map(&:last))
    expect(compiler.unsupported).to include('Forms$UnknownAction')
    expect(compiler.send(:translated, { 'Items' => [2, { 'LanguageCode' => 'pt_BR', 'Text' => 'Primeiro' }] }))
      .to eq('Primeiro')
    expect(compiler.send(:translated, nil)).to eq('')
    expect(compiler.send(:default_search_value, 'DefaultValue' => '')).to be_nil
    expect(compiler.send(:default_search_value, 'DefaultValue' => 'x')).to eq('x')
  end
end

RSpec.describe Mxrb::Compiler::LegacyPageBuilder do
  it 'writes localized, parseable Dojo pages and an explicit client-profile manifest' do
    Dir.mktmpdir do |root|
      page = Mxrb::Compiler::SourceModel::Unit.new(
        id: '11111111-2222-4333-8444-555555555555', container_id: nil, containment: nil,
        module_name: 'Demo', document: {
          '$Type' => 'Forms$Page', 'Name' => 'Home',
          'Title' => { 'Items' => [3,
                                   { '$Type' => 'Texts$Translation', 'LanguageCode' => 'en_US', 'Text' => 'Home' },
                                   { '$Type' => 'Texts$Translation', 'LanguageCode' => 'de_DE', 'Text' => 'Start' }] },
          'FormCall' => { 'Form' => 'Demo.Shell', 'Arguments' => [2, { 'Parameter' => 'Main',
                                                                       'Widgets' => [3] }] }
        }
      )
      source = instance_double(Mxrb::Compiler::SourceModel, documents: [page.document])
      allow(source).to receive(:units_of).with('Forms$Page').and_return([page])
      allow(source).to receive(:units_of).with('Forms$Layout').and_return([])
      result = described_class.new(source, root, profiles: %i[dojo react_wrapper]).build
      expect(result.files).to eq(2)
      expect(result.unsupported_widgets).to be_empty
      Dir[File.join(root, 'pages', '**', '*.xml')].each do |path|
        expect { REXML::Document.new(File.binread(path).force_encoding('UTF-8')) }.not_to raise_error
      end
      manifest = JSON.parse(File.read(File.join(root, 'mxrb-legacy-pages.json')))
      expect(manifest).to include('profiles' => %w[dojo react_wrapper], 'unsupportedWidgets' => {})
    end
  end

  it 'renders Data Grid 1 and records every other visible legacy widget instead of dropping it silently' do
    Dir.mktmpdir do |root|
      grid = {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DataGrid', 'Name' => 'items',
        'Columns' => [2, { '$Type' => 'Forms$DataGridColumn', 'Name' => 'name',
                           'AttributePath' => 'Demo.Item.Name', 'Caption' => { 'Items' => [2] } }],
        'DataSource' => { '$Type' => 'Forms$GridXPathSource', 'EntityPath' => 'Demo.Item' },
        'ControlBar' => {}, 'IsPagingEnabled' => false
      }
      page = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: {
          '$Type' => 'Forms$Page', 'Name' => 'Home',
          'Title' => { 'Items' => [2, { '$Type' => 'Texts$Translation',
                                        'LanguageCode' => 'pt_BR', 'Text' => 'Início' }] },
          'Widgets' => [3, grid, { '$Type' => 'Forms$TextBox', 'Name' => 'name' }]
        }
      )
      source = instance_double(Mxrb::Compiler::SourceModel, documents: [page.document])
      allow(source).to receive(:units_of).with('Forms$Page').and_return([page])
      allow(source).to receive(:units_of).with('Forms$Layout').and_return([])
      result = described_class.new(source, root).build
      xml = File.binread("#{result.directory}/pt_BR/Demo/Home.page.xml").force_encoding('UTF-8')

      expect(xml).to include('mxui.widget.DataGrid', "title='Início'", '<m:layouts></m:layouts>')
      expect(result.unsupported_widgets).to eq('Demo.Home' => ['Forms$TextBox'])
      expect(JSON.parse(File.read(File.join(root, 'mxrb-legacy-pages.json')))
        .dig('unsupportedWidgets', 'Demo.Home')).to eq(['Forms$TextBox'])
    end
  end

  it 'audits pages without writing files and includes custom widgets' do
    grid = {
      '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DataGrid', 'Name' => 'items',
      'Columns' => [2], 'DataSource' => {
        '$Type' => 'Forms$GridXPathSource', 'EntityPath' => 'Demo.Item'
      }, 'ControlBar' => {}, 'IsPagingEnabled' => false
    }
    dynamic = {
      '$Type' => 'Forms$DynamicText', 'Content' => {
        'Parameters' => [2, { 'Expression' => '$Item/Name' }]
      }
    }
    page = Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
      document: { '$Type' => 'Forms$Page', 'Name' => 'Home',
                  'Widgets' => [3, { '$Type' => 'Forms$TextBox' },
                                { '$Type' => 'CustomWidgets$CustomWidget' }, grid, dynamic] }
    )
    source = instance_double(Mxrb::Compiler::SourceModel, documents: [page.document])
    allow(source).to receive(:units_of).with('Forms$Page').and_return([page])
    allow(source).to receive(:units_of).with('Forms$Layout').and_return([])

    expect(described_class.new(source, '/not-used').audit).to eq(
      'Demo.Home' => ['CustomWidgets$CustomWidget', 'Forms$DynamicText(parameters)', 'Forms$TextBox']
    )
  end

  it 'renders layouts, placeholders, containers and literal dynamic text natively' do
    Dir.mktmpdir do |root|
      placeholder_id = SecureRandom.uuid
      layout = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: {
          '$Type' => 'Forms$Layout', 'Name' => 'Shell',
          'Widget' => { '$ID' => placeholder_id, '$Type' => 'Forms$Placeholder', 'Name' => 'Main' }
        }
      )
      text = {
        '$Type' => 'Forms$DynamicText', 'Name' => 'heading', 'RenderMode' => 'Text',
        'Content' => {
          'Parameters' => [2],
          'Template' => { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Hello & welcome' }] }
        }
      }
      page = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: {
          '$Type' => 'Forms$Page', 'Name' => 'Home', 'Class' => 'app-page',
          'Title' => { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Home' }] },
          'FormCall' => {
            'Form' => 'Demo.Shell',
            'Arguments' => [2, { 'Parameter' => 'Demo.Shell.Main',
                                 'Widget' => {
                                   '$Type' => 'Forms$VerticalFlow', 'Widgets' => [2, {
                                     '$Type' => 'Forms$DivContainer', 'Name' => 'card',
                                     'Class' => 'panel', 'Widget' => text
                                   }]
                                 } }]
          }
        }
      )
      source = instance_double(Mxrb::Compiler::SourceModel, documents: [layout.document, page.document])
      allow(source).to receive(:units_of).with('Forms$Page').and_return([page])
      allow(source).to receive(:units_of).with('Forms$Layout').and_return([layout])

      result = described_class.new(source, root).build
      page_xml = File.binread(File.join(root, 'pages/en_US/Demo/Home.page.xml')).force_encoding('UTF-8')
      layout_xml = File.binread(File.join(root, 'pages/en_US/Demo/Shell.layout.xml')).force_encoding('UTF-8')

      expect(result).to have_attributes(files: 2, unsupported_widgets: {})
      expect(page_xml).to include(
        "parameterName='#{placeholder_id}'", "class='mx-name-card panel'",
        "class='mx-text mx-name-heading'", 'Hello &amp; welcome'
      )
      expect(layout_xml).to include("data-mx-placeholder='#{placeholder_id}'")
      expect { REXML::Document.new(page_xml) }.not_to raise_error
      expect { REXML::Document.new(layout_xml) }.not_to raise_error
    end
  end

  it 'covers defensive legacy rendering fallbacks and interactive-container auditing' do
    layout = Mxrb::Compiler::SourceModel::Unit.new(
      id: 'layout', container_id: nil, containment: nil, module_name: 'Demo',
      document: { '$Type' => 'Forms$Layout', 'Name' => 'Shell', 'Widgets' => [2] }
    )
    source = instance_double(Mxrb::Compiler::SourceModel, documents: [])
    allow(source).to receive(:units_of).with('Forms$Layout').and_return([layout])
    allow(source).to receive(:units_of).with('Forms$Page').and_return([])
    builder = described_class.new(source, '/not-used')
    builder.instance_variable_set(:@widget_sequence, 0)

    interactive = {
      '$Type' => 'Forms$DivContainer',
      'OnClickAction' => { '$Type' => 'Forms$MicroflowAction' }
    }
    builder.send(:audit_unsupported_widgets, interactive, 'Demo.Home')
    expect(builder.instance_variable_get(:@unsupported)['Demo.Home'])
      .to include('Forms$DivContainer(onClick)')
    expect(builder.send(:render_widget, nil, 'Demo.Home', 'en_US')).to eq('')

    span = { '$Type' => 'Forms$DivContainer', 'RenderMode' => 'Span', 'Style' => 'color:red' }
    expect(builder.send(:render_widget, span, 'Demo.Home', 'en_US'))
      .to include('<span', "style='color:red'")
    paragraph = {
      '$Type' => 'Forms$DynamicText', 'RenderMode' => 'Paragraph',
      'Content' => {
        'Template' => { 'Items' => [2] },
        'Fallback' => { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Fallback' }] }
      }
    }
    expect(builder.send(:render_widget, paragraph, 'Demo.Home', 'en_US'))
      .to include('<p', 'Fallback')
    expect(builder.send(:html_attributes, {}, base: nil)).to eq('')
    expect(builder.send(:html_attributes, { 'Appearance' => { 'Style' => 'display:block' } }, base: nil))
      .to eq(" style='display:block'")
    expect(builder.send(:css_classes, { 'Name' => '' }, base: nil)).to eq('')
    expect(builder.send(:widget_children, nil)).to eq([])
    expect(builder.send(:layout_argument_id, 'Demo.Missing.Main')).to eq('Demo.Missing.Main')
    expect(builder.send(:layout_argument_id, 'Demo.Shell.Missing')).to eq('Demo.Shell.Missing')
  end
end
# rubocop:enable Metrics/BlockLength
