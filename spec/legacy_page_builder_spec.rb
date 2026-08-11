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

  it 'compiles the legacy reference-set selector through its patched Data Grid contract' do
    value = grid('Forms$GridXPathSource')
    value['$Type'] = 'Forms$ReferenceSetSelector'
    value['SelectableXPathConstraint'] = '[Active]'
    value['DataSource'] = {
      '$Type' => 'Forms$ReferenceSetSource',
      'EntityPath' => 'Demo.Item_Tags/Demo.Tag',
      'SortBar' => { 'SortItems' => [2, { 'AttributePath' => 'Demo.Tag.Name',
                                          'SortOrder' => 'Ascending' }] }
    }
    value['Columns'][1]['AttributePath'] = 'Demo.Tag.Name'
    value['ControlBar']['NewButtons'] = [2,
                                         button('Forms$DataGridAddButton', 'add'),
                                         button('Forms$DataGridRemoveButton', 'remove')]
    source = instance_double(Mxrb::Compiler::SourceModel, units_of: [])
    compiler = described_class.new(source, 'Demo.Edit', value, language: 'en_US', sequence: 4)
    element = REXML::Document.new(compiler.html).root
    props = JSON.parse("{#{element.attributes['data-mendix-props']}}")

    expect(element.attributes['data-mendix-type']).to eq('mxui.widget.ReferenceSetSelector')
    expect(props).to include('entity' => 'Demo.Tag', 'xpathConstraint' => '[Active]')
    expect(props.dig('config', 'datasource')).to include(
      'entity' => 'Demo.Tag', 'path' => 'Demo.Tag', 'reference' => 'Demo.Item_Tags',
      'attributes' => ['Name']
    )
    expect(props.dig('config', 'controlBar', 'gridActions').map { _1['gridFunction'] })
      .to eq(%w[ToggleSearch AddRef DeleteRef])
    expect(compiler.unsupported).to be_empty
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

RSpec.describe Mxrb::Compiler::LegacyCustomWidgetCompiler do
  it 'compiles recursive object properties and legacy System image references' do
    object_type_id = SecureRandom.uuid
    image_type_id = SecureRandom.uuid
    caption_type_id = SecureRandom.uuid
    nested_type = {
      '$ID' => object_type_id,
      'PropertyKey' => 'columns',
      'ValueType' => {
        'Type' => 'Object',
        'ObjectType' => {
          'PropertyTypes' => [2,
                              { '$ID' => image_type_id, 'PropertyKey' => 'icon',
                                'ValueType' => { 'Type' => 'Image' } },
                              { '$ID' => caption_type_id, 'PropertyKey' => 'caption',
                                'ValueType' => { 'Type' => 'String' } }]
        }
      }
    }
    widget = {
      '$Type' => 'CustomWidgets$CustomWidget',
      'Type' => {
        'WidgetId' => 'TreeView.widget.TreeView',
        'ObjectType' => { 'PropertyTypes' => [2, nested_type] }
      },
      'Object' => {
        'Properties' => [2, {
          'TypePointer' => object_type_id,
          'Value' => {
            'Objects' => [2, {
              'Properties' => [2,
                               { 'TypePointer' => image_type_id,
                                 'Value' => { 'Image' => 'System.Images.Completed' } },
                               { 'TypePointer' => caption_type_id,
                                 'Value' => { 'PrimitiveValue' => 'Done' } }]
            }]
          }
        }]
      }
    }
    source = instance_double(Mxrb::Compiler::SourceModel)
    allow(source).to receive(:units_of).with('Images$ImageCollection').and_return([])

    compiler = described_class.new(source, widget, language: 'en_US')

    expect(compiler).to be_supported
    expect(compiler.properties_hash).to eq(
      'columns' => [{ 'icon' => 'img/System$Completed.gif', 'caption' => 'Done' }]
    )
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

  it 'renders responsive layout grids without reporting them as unsupported' do
    Dir.mktmpdir do |root|
      page = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: {
          '$Type' => 'Forms$Page', 'Name' => 'Dashboard',
          'Widgets' => [2, {
            '$Type' => 'Forms$LayoutGrid', 'Name' => 'dashboardGrid', 'Class' => 'outer',
            'Rows' => [2, {
              '$Type' => 'Forms$LayoutGridRow', 'Name' => 'mainRow', 'Style' => 'gap:1rem',
              'Columns' => [2, {
                '$Type' => 'Forms$LayoutGridColumn', 'Name' => 'summary',
                'Weight' => 6, 'TabletWeight' => 12, 'PhoneWeight' => 12,
                'Widgets' => [2, {
                  '$Type' => 'Forms$DynamicText', 'Name' => 'heading',
                  'Content' => { 'Parameters' => [2], 'Template' => {
                    'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Summary' }]
                  } }
                }]
              }]
            }]
          }]
        }
      )
      source = instance_double(Mxrb::Compiler::SourceModel, documents: [page.document])
      allow(source).to receive(:units_of).with('Forms$Page').and_return([page])
      allow(source).to receive(:units_of).with('Forms$Layout').and_return([])

      result = described_class.new(source, root).build
      xml = File.binread("#{result.directory}/en_US/Demo/Dashboard.page.xml").force_encoding('UTF-8')

      expect(result.unsupported_widgets).to be_empty
      expect(xml).to include(
        'mx-layoutgrid mx-layoutgrid-fluid mx-name-dashboardGrid outer',
        "class='row mx-name-mainRow' style='gap:1rem'",
        'col col-md-6 col-sm-12 col-xs-12 mx-name-summary', 'Summary'
      )
      expect { REXML::Document.new(xml) }.not_to raise_error
    end
  end

  it 'renders legacy scroll layouts, headers, toggles, and both navigation source generations' do
    navigation_id = SecureRandom.uuid
    menu_id = SecureRandom.uuid
    navigation = Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: nil,
      document: {
        '$Type' => 'Navigation$NavigationDocument',
        'DesktopProfile' => { '$Type' => 'Navigation$NavigationProfile',
                              'Menu' => { '$ID' => navigation_id } }
      }
    )
    menu = Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
      document: {
        '$Type' => 'Menus$MenuDocument', 'Name' => 'Secondary',
        'ItemCollection' => { '$ID' => menu_id, 'Items' => [2] }
      }
    )
    source = instance_double(Mxrb::Compiler::SourceModel, documents: [navigation.document, menu.document])
    allow(source).to receive(:units_of) do |type|
      { 'Navigation$NavigationDocument' => [navigation], 'Menus$MenuDocument' => [menu] }.fetch(type, [])
    end
    builder = described_class.new(source, '/not-used')
    builder.instance_variable_set(:@widget_sequence, 0)
    translated = { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Menu' }] }
    scroll = {
      '$Type' => 'Forms$ScrollContainer', 'ScrollBehavior' => 'PerRegion',
      'Left' => {
        '$Type' => 'Forms$ScrollContainerRegion', 'Class' => 'region-sidebar',
        'SizeMode' => 'Pixels', 'Size' => 240, 'ToggleMode' => 'PushContentAside',
        'Widgets' => [2, {
          '$Type' => 'Forms$NavigationTree', 'Name' => 'navigation',
          'MenuSource' => { '$Type' => 'Forms$NavigationSource', 'DeviceType' => 'Desktop' }
        }]
      },
      'CenterRegion' => {
        '$Type' => 'Forms$ScrollContainerRegion', 'Class' => 'region-content',
        'Widgets' => [2, { '$Type' => 'Forms$Placeholder', '$ID' => SecureRandom.uuid }]
      },
      'Top' => {
        '$Type' => 'Forms$ScrollContainerRegion', 'Class' => 'region-topbar',
        'Widgets' => [2, {
          '$Type' => 'Forms$Header', 'Name' => 'header',
          'LeftWidgets' => [2, {
            '$Type' => 'Forms$SidebarToggleButton', 'Name' => 'toggle',
            'ButtonStyle' => 'Inverse', 'RenderType' => 'Button',
            'Icon' => { '$Type' => 'Forms$GlyphIcon', 'Code' => 57_910 },
            'CaptionTemplate' => { 'Template' => translated }
          }],
          'RightWidgets' => [2, {
            '$Type' => 'Forms$MenuBar', 'Name' => 'secondary',
            'MenuSource' => { '$Type' => 'Forms$MenuDocumentSource', 'Menu' => 'Demo.Secondary' }
          }]
        }]
      }
    }

    document = REXML::Document.new(
      "<root>#{builder.send(:render_widget, scroll, 'Demo.Shell', 'en_US')}</root>"
    )
    contracts = REXML::XPath.match(document, '//*[@data-mendix-type]').to_h do |element|
      props = element.attributes['data-mendix-props']
      [element.attributes['data-mendix-type'], props && JSON.parse("{#{props}}")]
    end

    expect(contracts.fetch('mxui.widget.HorizontalScrollContainer')).to include(
      'fixed' => true,
      'config' => include(include('position' => 'left', 'toggleMode' => 'pushContentAside',
                                  'initiallyOpen' => false))
    )
    expect(contracts.fetch('mxui.widget.VerticalScrollContainer')['config'])
      .to contain_exactly({ 'position' => 'top' }, { 'position' => 'middle' })
    expect(contracts.fetch('mxui.widget.NavigationTree')).to eq('menuID' => navigation_id)
    expect(contracts.fetch('mxui.widget.Navbar')).to eq('menuID' => menu_id)
    expect(contracts.fetch('mxui.widget.SidebarToggleButton')).to include(
      'caption' => { 'text' => 'Menu' }, 'iconClass' => 'glyphicon-menu-hamburger'
    )
    expect(document.to_s).to include(
      'mx-layoutcontainer-nested', 'region-sidebar', 'width:240px', 'mx-header-center',
      'mxui.widget.Title'
    )
  end

  it 'renders every audited legacy action button family with executable client contracts' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir do |root|
      translated = lambda do |value|
        { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => value }] }
      end
      button = lambda do |name, action, style = 'Default'|
        {
          '$Type' => 'Forms$ActionButton', 'Name' => name, 'Action' => action,
          'ButtonStyle' => style, 'RenderType' => 'Button', 'TabIndex' => 0,
          'CaptionTemplate' => { 'Template' => translated.call(name) }
        }
      end
      target = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: { '$Type' => 'Forms$Page', 'Name' => 'Target', 'PopupResizable' => true }
      )
      microflow = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: {
          '$Type' => 'Microflows$Microflow', 'Name' => 'Run',
          'ObjectCollection' => { 'Objects' => [2, { '$Type' => 'Microflows$MicroflowParameter' }] }
        }
      )
      run_button = button.call(
        'run',
        {
          '$Type' => 'Forms$MicroflowAction',
          'MicroflowSettings' => {
            'Microflow' => 'Demo.Run', 'FormValidations' => 'All'
          }
        }
      )
      open_button = button.call(
        'open',
        {
          '$Type' => 'Forms$FormAction',
          'FormSettings' => { 'Form' => 'Demo.Target', 'Location' => 'ModalPopup' }
        }
      )
      save_button = button.call(
        'save',
        { '$Type' => 'Forms$SaveChangesClientAction', 'ClosePage' => true },
        'Success'
      )
      cancel_button = button.call(
        'cancel',
        { '$Type' => 'Forms$CancelChangesClientAction', 'ClosePage' => false }
      )
      close_button = button.call('close', { '$Type' => 'Forms$ClosePageClientAction' })
      docs_button = button.call(
        'docs',
        {
          '$Type' => 'Forms$OpenLinkClientAction', 'LinkType' => 'Web',
          'Address' => { 'IsDynamic' => false, 'Value' => 'https://example.test' }
        }
      )
      none_button = button.call('none', { '$Type' => 'Forms$NoAction' })
      source_page = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: {
          '$Type' => 'Forms$Page', 'Name' => 'Actions',
          'Widgets' => [
            2, run_button, open_button, save_button, cancel_button,
            close_button, docs_button, none_button
          ]
        }
      )
      source = instance_double(
        Mxrb::Compiler::SourceModel,
        documents: [source_page.document, target.document, microflow.document]
      )
      allow(source).to receive(:units_of) do |type|
        { 'Forms$Page' => [source_page, target], 'Forms$Layout' => [],
          'Microflows$Microflow' => [microflow], 'Images$ImageCollection' => [] }.fetch(type, [])
      end

      result = described_class.new(source, root).build
      xml = File.binread("#{result.directory}/en_US/Demo/Actions.page.xml").force_encoding('UTF-8')
      document = REXML::Document.new(xml)
      widgets = REXML::XPath.match(document, '//*[@data-mendix-type]').to_h do |element|
        props = JSON.parse("{#{element.attributes['data-mendix-props']}}")
        [props.dig('caption', 'text'), [element.attributes['data-mendix-type'], props]]
      end

      expect(result.unsupported_widgets).to be_empty
      expect(widgets.fetch('run').last.fetch('action')).to include(
        'type' => 'callMicroflow', 'hasParameter' => true,
        'params' => include('name' => 'Demo.Run', 'validate' => 'view', 'applyTo' => 'selection')
      )
      expect(widgets.fetch('open').last.fetch('action')).to include(
        'type' => 'openPage', 'params' => include(
          'path' => 'Demo/Target.page.xml', 'location' => 'modal', 'resizable' => true
        )
      )
      expect(widgets.fetch('save')).to match(['mxui.widget.SaveButton', include('closeForm' => true)])
      expect(widgets.fetch('cancel')).to match(['mxui.widget.CancelButton', include('closeForm' => false)])
      expect(widgets.fetch('close').first).to eq('mxui.widget.BackButton')
      expect(widgets.fetch('docs')).to match(
        ['mxui.widget.LinkButton', include('action' => 'open', 'address' => 'https://example.test')]
      )
      expect(widgets.fetch('none').last.fetch('action')).to include('type' => 'doNothing')
      expect(xml).to include('btn-success mx-name-save')
    end
  end # rubocop:enable Metrics/BlockLength

  it 'renders direct, association, and microflow data views with content and footer templates' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir do |root|
      translated = lambda do |value|
        { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => value }] }
      end
      child = {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DataView', 'Name' => 'child',
        'DataSource' => {
          '$Type' => 'Forms$DataViewSource',
          'EntityPath' => 'Demo.Item_Child/Demo.Child'
        },
        'Widget' => {
          '$Type' => 'Forms$VerticalFlow',
          'Widgets' => [2, {
            '$Type' => 'Forms$DynamicText', 'Name' => 'childTitle',
            'Content' => { 'Template' => translated.call('Child') }
          }]
        },
        'FooterWidget' => {
          '$Type' => 'Forms$VerticalFlow',
          'Widgets' => [2, {
            '$Type' => 'Forms$MobileSaveButton', 'Name' => 'saveChild',
            'CaptionTemplate' => { 'Template' => translated.call('Save') },
            'ButtonStyle' => 'Success', 'ClosePage' => false
          }]
        },
        'ShowFooter' => true, 'Editable' => true
      }
      direct = {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DataView', 'Name' => 'item',
        'DataSource' => {
          '$Type' => 'Forms$DataViewSource',
          'EntityRef' => { '$Type' => 'DomainModels$DirectEntityRef', 'Entity' => 'Demo.Item' }
        },
        'Widgets' => [2, child], 'FooterWidgets' => [2, {
          '$Type' => 'Forms$MobileBackButton', 'Name' => 'back',
          'CaptionTemplate' => { 'Template' => translated.call('Back') }
        }],
        'ShowFooter' => true, 'Editable' => false
      }
      report = {
        '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DataView', 'Name' => 'report',
        'DataSource' => {
          '$Type' => 'Forms$MicroflowSource',
          'MicroflowSettings' => { 'Microflow' => 'Demo.LoadReport' }
        },
        'Widgets' => [2], 'FooterWidgets' => [2], 'ShowFooter' => false
      }
      page = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: { '$Type' => 'Forms$Page', 'Name' => 'Data', 'Widgets' => [2, direct, report] }
      )
      flow = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: {
          '$Type' => 'Microflows$Microflow', 'Name' => 'LoadReport',
          'MicroflowReturnType' => { 'Entity' => 'Demo.Report' }
        }
      )
      source = instance_double(Mxrb::Compiler::SourceModel, documents: [page.document, flow.document])
      allow(source).to receive(:units_of) do |type|
        { 'Forms$Page' => [page], 'Forms$Layout' => [],
          'Microflows$Microflow' => [flow] }.fetch(type, [])
      end

      result = described_class.new(source, root).build
      document = REXML::Document.new(
        File.binread("#{result.directory}/en_US/Demo/Data.page.xml").force_encoding('UTF-8')
      )
      data_views = REXML::XPath.match(document, "//*[@data-mendix-type='mxui.widget.DataView']")
      properties = data_views.map do |element|
        JSON.parse("{#{element.attributes['data-mendix-props']}}")
      end
      templates = REXML::XPath.match(document, '//m:template')

      expect(result.unsupported_widgets).to be_empty
      expect(properties).to include(
        include('entity' => 'Demo.Item', 'readOnly' => true,
                'datasource' => { 'type' => 'direct', 'path' => 'Demo.Item' }),
        include('entity' => 'Demo.Child',
                'datasource' => { 'type' => 'direct',
                                  'path' => 'Demo.Item_Child/Demo.Child' }),
        include('entity' => 'Demo.Report', 'hideFooter' => true,
                'datasource' => include('type' => 'microflow',
                                        'microflow' => 'Demo.LoadReport'))
      )
      expect(templates.count { _1.attributes['name'] == 'content' }).to eq(3)
      expect(templates.count { _1.attributes['name'] == 'footer' }).to eq(2)
      expect(REXML::XPath.match(document, "//*[@data-mendix-type='mxui.widget.SaveButton']")).not_to be_empty
      expect(REXML::XPath.match(document, "//*[@data-mendix-type='mxui.widget.BackButton']")).not_to be_empty
    end
  end # rubocop:enable Metrics/BlockLength

  it 'links List View selection to listening Data Views and formats dynamic attributes' do # rubocop:disable Metrics/BlockLength
    translated = lambda do |value|
      { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => value }] }
    end
    parameter = lambda do |attribute|
      { 'AttributeRef' => { 'Attribute' => "Demo.Item.#{attribute}" } }
    end
    list = {
      '$ID' => SecureRandom.uuid, '$Type' => 'Forms$ListView', 'Name' => 'items', 'PageSize' => 10,
      'ClickAction' => { '$Type' => 'Forms$NoAction' },
      'DataSource' => {
        '$Type' => 'Forms$ListViewXPathSource', 'EntityPath' => 'Demo.Item',
        'XPathConstraint' => '[Active]',
        'SortBar' => { 'SortItems' => [2, { 'AttributePath' => 'Demo.Item.Name',
                                            'SortOrder' => 'Ascending' }] },
        'Search' => { 'SearchPaths' => [2, { 'AttributePath' => 'Demo.Item.Name' }] }
      },
      'Widget' => {
        '$Type' => 'Forms$DynamicText', 'Name' => 'summary',
        'Content' => {
          'Template' => translated.call('{1}: {2} on {3}'),
          'Parameters' => [2, parameter.call('Name'), parameter.call('Count'),
                           parameter.call('Due').merge('FormattingInfo' => { 'DateFormat' => 'Date' })]
        }
      }
    }
    listener = {
      '$ID' => SecureRandom.uuid, '$Type' => 'Forms$DataView', 'Name' => 'details',
      'DataSource' => { '$Type' => 'Forms$ListenTargetSource', 'ListenTarget' => 'items' },
      'Widget' => { '$Type' => 'Forms$TextBox', 'Name' => 'name',
                    'AttributePath' => 'Demo.Item.Name', 'Editable' => 'Always' }
    }
    page = Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
      document: { '$Type' => 'Forms$Page', 'Name' => 'Items', 'Widgets' => [2, list, listener] }
    )
    attribute = lambda do |name, type|
      { '$Type' => 'DomainModels$Attribute', 'Name' => name,
        'NewType' => { '$Type' => "DomainModels$#{type}AttributeType" } }
    end
    domain = Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
      document: {
        '$Type' => 'DomainModels$DomainModel',
        'Entities' => [2, { '$Type' => 'DomainModels$EntityImpl', 'Name' => 'Item',
                            'Attributes' => [2, attribute.call('Name', 'String'),
                                             attribute.call('Count', 'Integer'),
                                             attribute.call('Due', 'DateTime')] }]
      }
    )
    source = instance_double(Mxrb::Compiler::SourceModel, documents: [page.document, domain.document])
    allow(source).to receive(:units_of) do |type|
      { 'Forms$Page' => [page], 'Forms$Layout' => [], 'Forms$Snippet' => [],
        'DomainModels$DomainModel' => [domain] }.fetch(type, [])
    end

    Dir.mktmpdir do |root|
      result = described_class.new(source, root).build
      document = REXML::Document.new(
        File.binread("#{result.directory}/en_US/Demo/Items.page.xml").force_encoding('UTF-8')
      )
      list_element = REXML::XPath.first(document, "//*[@data-mendix-type='mxui.widget.ListView']")
      view_element = REXML::XPath.first(document, "//*[@data-mendix-type='mxui.widget.DataView']")
      dynamic = REXML::XPath.first(document, "//*[@data-mendix-type='mxui.widget.DynamicText']")
      list_props = JSON.parse("{#{list_element.attributes['data-mendix-props']}}")
      view_props = JSON.parse("{#{view_element.attributes['data-mendix-props']}}")
      dynamic_props = JSON.parse("{#{dynamic.attributes['data-mendix-props']}}")

      expect(result.unsupported_widgets).to be_empty
      expect(list_props).to include(
        'selectable' => 'single', 'hasSearch' => true,
        'datasource' => include('type' => 'xpath', 'path' => 'Demo.Item',
                                'xpathConstraints' => '[Active]', 'search' => ['Name'])
      )
      expect(view_props.dig('datasource', 'contextsource')).to eq(list_element.attributes['data-mendix-id'])
      expect(dynamic_props.dig('content', 'elements')).to eq([0, ': ', 1, ' on ', 2])
      expect(dynamic_props.dig('content', 'parameters')).to eq(
        '0' => 'Name', '1' => 'Count', '2' => 'Due'
      )
      expect(dynamic_props.dig('content', 'formats')).to eq(
        '0' => {}, '1' => { 'groupDigits' => false, 'decimalPrecision' => 2 },
        '2' => { 'type' => 'date' }
      )

      modern = list.merge('DataSource' => list['DataSource'].merge(
        '$Type' => 'Forms$NewListViewDatabaseSource'
      ))
      builder = described_class.new(source, '/not-used')
      expect(builder.send(:list_view_source, modern, 'Demo.Items', 'Demo.Item')).to include(
        'type' => 'database', 'offlineConstraints' => []
      )
    end
  end # rubocop:enable Metrics/BlockLength

  it 'renders scalar attribute editors with domain-aware Dojo contracts' do # rubocop:disable Metrics/BlockLength
    translated = lambda do |value|
      { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => value }] }
    end
    attribute = lambda do |name, type, extra = {}|
      { '$Type' => 'DomainModels$Attribute', 'Name' => name,
        'NewType' => { '$Type' => "DomainModels$#{type}AttributeType", **extra } }
    end
    domain = Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
      document: {
        '$Type' => 'DomainModels$DomainModel',
        'Entities' => [2, {
          '$Type' => 'DomainModels$EntityImpl', 'Name' => 'Item',
          'Attributes' => [
            2, attribute.call('Name', 'String', 'Length' => 80),
            attribute.call('Count', 'Integer'), attribute.call('Secret', 'String', 'Length' => 120),
            attribute.call('Notes', 'String', 'Length' => 500), attribute.call('Active', 'Boolean'),
            attribute.call('Due', 'DateTime'),
            attribute.call('Status', 'Enumeration', 'Enumeration' => 'Demo.Status')
          ]
        }]
      }
    )
    enumeration = Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
      document: {
        '$Type' => 'Enumerations$Enumeration', 'Name' => 'Status',
        'Values' => [2, {
          '$Type' => 'Enumerations$EnumerationValue', 'Name' => 'Open',
          'Caption' => translated.call('Open')
        }]
      }
    )
    input = lambda do |type, name, options = {}|
      {
        '$Type' => "Forms$#{type}", 'Name' => name,
        'AttributeRef' => { 'Attribute' => "Demo.Item.#{options.delete(:attribute) || name}" },
        'LabelText' => translated.call(name), 'Editable' => options.delete(:editable) || 'Always',
        **options.transform_keys(&:to_s)
      }
    end
    widgets = [
      input.call('TextBox', 'Name', MaxLengthCode: -1, Placeholder: translated.call('Type')),
      input.call('TextBox', 'count', attribute: 'Count'),
      input.call('TextBox', 'secret', attribute: 'Secret', IsPasswordBox: true,
                                      Required: true, RequiredMessage: translated.call('Required')),
      input.call('TextArea', 'notes', attribute: 'Notes', NumberOfLines: 8),
      input.call('CheckBox', 'active', attribute: 'Active'),
      input.call('DatePicker', 'due', attribute: 'Due',
                                      FormattingInfo: { 'DateFormat' => 'DateTime' }),
      input.call('DropDown', 'status', attribute: 'Status'),
      input.call('RadioButtonGroup', 'statusRadio', attribute: 'Status', Orientation: 'Vertical'),
      input.call(
        'ReferenceSelector', 'category',
        AttributeRef: {
          'Attribute' => 'Demo.Category.Name',
          'EntityRef' => { 'Steps' => [2, {
            'Association' => 'Demo.Item_Category', 'DestinationEntity' => 'Demo.Category'
          }] }
        },
        SelectorSource: { '$Type' => 'Forms$SelectorXPathSource', 'XPathConstraint' => '[Active]' }
      ),
      input.call(
        'InputReferenceSetSelector', 'tags',
        AttributePath: 'Demo.Item_Tags/Demo.Tag/Demo.Tag.Name',
        SelectorSource: {
          '$Type' => 'Forms$SelectorMicroflowSource',
          'DataSourceMicroflowSettings' => { 'Microflow' => 'Demo.LoadTags' }
        },
        PopupFormSettings: { 'Form' => 'Demo.SelectTags', 'Location' => 'Popup' }
      )
    ]
    select_page = Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
      document: { '$Type' => 'Forms$Page', 'Name' => 'SelectTags', 'PopupResizable' => true }
    )
    source = instance_double(Mxrb::Compiler::SourceModel, documents: [domain.document, enumeration.document])
    allow(source).to receive(:units_of) do |type|
      { 'DomainModels$DomainModel' => [domain],
        'Enumerations$Enumeration' => [enumeration], 'Forms$Page' => [select_page] }.fetch(type, [])
    end
    builder = described_class.new(source, '/not-used')
    builder.instance_variable_set(:@widget_sequence, 0)
    builder.instance_variable_set(
      :@data_view_stack, [{ entity: 'Demo.Item', label_width: 4, editable: true }]
    )
    document = REXML::Document.new(
      "<root>#{widgets.map { builder.send(:render_widget, _1, 'Demo.Data', 'en_US') }.join}</root>"
    )
    contracts = REXML::XPath.match(document, '//*[@data-mendix-type]').to_h do |element|
      [element.attributes['data-mendix-type'],
       JSON.parse("{#{element.attributes['data-mendix-props']}}")]
    end

    expect(contracts.fetch('mxui.widget.TextInput')).to include(
      'attributePath' => 'Demo.Item/Name', 'placeholder' => 'Type', 'maxLength' => 80
    )
    expect(contracts.fetch('mxui.widget.NumberInput')).to include('attributePath' => 'Demo.Item/Count')
    expect(contracts.fetch('mxui.widget.PasswordInput')).to include(
      'required' => 'true', 'requiredMsg' => 'Required', 'maxLength' => 120
    )
    expect(contracts.fetch('mxui.widget.TextArea')).to include('rows' => 8)
    expect(contracts.fetch('mxui.widget.BoolSelect')).to include('attributePath' => 'Demo.Item/Active')
    expect(contracts.fetch('mxui.widget.DateInput')).to include('selector' => 'datetime')
    expect(contracts.fetch('mxui.widget.EnumSelect')).to include('attributePath' => 'Demo.Item/Status')
    expect(contracts.fetch('mxui.widget.RadioButtonGroup')).to include(
      'horizontal' => false, 'options' => [{ 'key' => 'Open', 'caption' => 'Open' }]
    )
    expect(contracts.fetch('mxui.widget.ReferenceSelector')).to include(
      'attributePath' => 'Demo.Item/Demo.Item_Category/Demo.Category/Name',
      'datasource' => include('type' => 'xpath', 'path' => 'Demo.Category',
                              'constraint' => '[Active]')
    )
    expect(contracts.fetch('mxui.widget.InputReferenceSetSelector')).to include(
      'attributePath' => 'Demo.Item/Demo.Item_Tags/Demo.Tag/Name',
      'datasource' => include('type' => 'microflow', 'microflow' => 'Demo.LoadTags'),
      'selectPageSettings' => include('path' => 'Demo/SelectTags.page.xml',
                                      'location' => 'modal', 'resizable' => true)
    )
    expect(document.to_s).to include("class='control-label col-sm-4'", "class='col-sm-8")
  end # rubocop:enable Metrics/BlockLength

  it 'renders tabs, inline snippets, and actionable static images' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir do |root|
      translated = lambda do |value|
        { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => value }] }
      end
      snippet = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: {
          '$Type' => 'Forms$Snippet', 'Name' => 'Details',
          'Widgets' => [2, {
            '$Type' => 'Forms$DynamicText', 'Name' => 'snippetText',
            'Content' => { 'Template' => translated.call('From snippet') }
          }]
        }
      )
      image = {
        '$Type' => 'Forms$StaticImageViewer', 'Name' => 'logo',
        'Image' => 'Demo.Assets.Logo', 'Responsive' => true,
        'Height' => 28, 'HeightUnit' => 'Pixels',
        'ClickAction' => {
          '$Type' => 'Forms$MicroflowAction',
          'MicroflowSettings' => { 'Microflow' => 'Demo.OpenLogo', 'FormValidations' => 'All' }
        }
      }
      first_id = SecureRandom.uuid
      second_id = SecureRandom.uuid
      tabs = {
        '$Type' => 'Forms$TabControl', 'Name' => 'tabs', 'DefaultPagePointer' => second_id,
        'TabPages' => [2, {
          '$ID' => first_id, '$Type' => 'Forms$TabPage', 'Name' => 'details',
          'Caption' => translated.call('Details'), 'Widgets' => [2, {
            '$Type' => 'Forms$SnippetCallWidget', 'Name' => 'detailsCall',
            'FormCall' => { 'Form' => 'Demo.Details' }
          }]
        }, {
          '$ID' => second_id, '$Type' => 'Forms$TabPage', 'Name' => 'picture',
          'Caption' => translated.call('Picture'), 'Widgets' => [2, image]
        }]
      }
      page = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: { '$Type' => 'Forms$Page', 'Name' => 'Media', 'Widgets' => [2, tabs] }
      )
      flow = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: { '$Type' => 'Microflows$Microflow', 'Name' => 'OpenLogo' }
      )
      collection = Mxrb::Compiler::SourceModel::Unit.new(
        id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
        document: {
          '$Type' => 'Images$ImageCollection', 'Name' => 'Assets',
          'Images' => [2, {
            '$Type' => 'Images$Image', 'Name' => 'Logo',
            'Image' => BSON::Binary.new("\x89PNG\r\n\x1A\nimage".b)
          }]
        }
      )
      source = instance_double(
        Mxrb::Compiler::SourceModel,
        documents: [page.document, snippet.document, flow.document, collection.document]
      )
      allow(source).to receive(:units_of) do |type|
        {
          'Forms$Page' => [page], 'Forms$Layout' => [], 'Forms$Snippet' => [snippet],
          'Microflows$Microflow' => [flow], 'Images$ImageCollection' => [collection]
        }.fetch(type, [])
      end

      result = described_class.new(source, root).build
      document = REXML::Document.new(
        File.binread("#{result.directory}/en_US/Demo/Media.page.xml").force_encoding('UTF-8')
      )
      contents = REXML::XPath.match(document, "//*[@data-mendix-type='mxui.widget.TabContent']")
      image_element = REXML::XPath.first(
        document, "//*[@data-mendix-type='mxui.widget.StaticImage']"
      )
      image_props = JSON.parse("{#{image_element.attributes['data-mendix-props']}}")

      expect(result.unsupported_widgets).to be_empty
      expect(REXML::XPath.match(document, "//*[@data-mendix-type='mxui.widget.TabContainer']").size).to eq(1)
      expect(contents.map { JSON.parse("{#{_1.attributes['data-mendix-props']}}") }).to contain_exactly(
        include('title' => 'Details', 'delayLoading' => true, 'tabName' => 'details'),
        include('title' => 'Picture', 'delayLoading' => false, 'tabName' => 'picture')
      )
      expect(image_props).to include(
        'url' => 'img/Demo$Logo.png',
        'action' => include('type' => 'callMicroflow',
                            'params' => include('name' => 'Demo.OpenLogo'))
      )
      expect(document.to_s).to include('From snippet', 'img-responsive', 'height:28px')
    end
  end # rubocop:enable Metrics/BlockLength

  it 'renders legacy tables inside executable template-grid item templates' do
    text = { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Name' }] }
    table = {
      '$Type' => 'Forms$Table', 'Name' => 'details',
      'ColumnWidths' => [2, { 'Value' => 30 }, { 'Value' => 70 }],
      'Rows' => [2, { '$Type' => 'Forms$TableRow' }],
      'Cells' => [2,
                  { '$Type' => 'Forms$DbTableCell', 'IsHeader' => true,
                    'LeftColumnIndex' => 0, 'TopRowIndex' => 0, 'Width' => 1, 'Height' => 1,
                    'Widget' => { '$Type' => 'Forms$Label', 'Caption' => text } },
                  { '$Type' => 'Forms$DbTableCell', 'LeftColumnIndex' => 1,
                    'TopRowIndex' => 0, 'Width' => 1, 'Height' => 1,
                    'Widget' => { '$Type' => 'Forms$TextBox', 'Name' => 'name',
                                  'AttributePath' => 'Demo.Item.Name', 'Editable' => 'Never' } }]
    }
    template_grid = {
      '$ID' => SecureRandom.uuid, '$Type' => 'Forms$TemplateGrid', 'Name' => 'items',
      'NumberOfRows' => 5, 'NumberOfColumns' => 2, 'SelectionMode' => 'Single',
      'DataSource' => { '$Type' => 'Forms$GridDatabaseSource', 'EntityPath' => 'Demo.Item' },
      'ControlBar' => {}, 'Contents' => { 'Widget' => table }
    }
    page = Mxrb::Compiler::SourceModel::Unit.new(
      id: SecureRandom.uuid, container_id: nil, containment: nil, module_name: 'Demo',
      document: { '$Type' => 'Forms$Page', 'Name' => 'Cards', 'Widgets' => [2, template_grid] }
    )
    source = instance_double(Mxrb::Compiler::SourceModel, documents: [page.document])
    allow(source).to receive(:units_of) do |type|
      { 'Forms$Page' => [page], 'Forms$Layout' => [], 'DomainModels$DomainModel' => [] }.fetch(type, [])
    end

    Dir.mktmpdir do |root|
      result = described_class.new(source, root).build
      document = REXML::Document.new(
        File.binread("#{result.directory}/en_US/Demo/Cards.page.xml").force_encoding('UTF-8')
      )
      element = REXML::XPath.first(document, "//*[@data-mendix-type='mxui.widget.TemplateGrid']")
      props = JSON.parse("{#{element.attributes['data-mendix-props']}}")

      expect(result.unsupported_widgets).to be_empty
      expect(props.dig('config', 'gridpresentation')).to include('rows' => 5, 'columns' => 2)
      expect(props.dig('config', 'datasource')).to include('type' => 'database', 'path' => 'Demo.Item')
      expect(REXML::XPath.first(document, '//m:template').attributes['widget-id'])
        .to eq(element.attributes['data-mendix-id'])
      expect(document.to_s).to include(
        "class='mx-table mx-name-details'", "style='width:30%'", '<th',
        'mxui.widget.TextInput'
      )
    end
  end

  it 'renders legacy image viewers and uploaders against their Data View context' do
    source = instance_double(Mxrb::Compiler::SourceModel, documents: [])
    allow(source).to receive(:units_of).with('Images$ImageCollection').and_return([])
    builder = described_class.new(source, '/not-used')
    builder.instance_variable_set(:@widget_sequence, 0)
    builder.instance_variable_set(:@data_view_stack, [{ entity: 'Demo.Picture', editable: true }])
    viewer = {
      '$Type' => 'Forms$ImageViewer', 'Name' => 'preview',
      'DataSource' => { '$Type' => 'Forms$ImageViewerSource', 'EntityPath' => 'Demo.Picture' },
      'OnClickBehavior' => { '$Type' => 'Forms$OnClickNothing' },
      'DefaultImage' => 'System.Images.New', 'ShowAsThumbnail' => true,
      'Width' => 120, 'WidthUnit' => 'Pixels', 'HeightUnit' => 'Auto'
    }
    uploader = {
      '$Type' => 'Forms$ImageUploader', 'Name' => 'upload', 'ThumbnailSize' => '48;32',
      'MaxFileSize' => 8, 'AllowedExtensions' => 'png;jpg', 'Editable' => 'Always'
    }
    document = REXML::Document.new(
      "<root>#{builder.send(:render_widget, viewer, 'Demo.Edit', 'en_US')}" \
      "#{builder.send(:render_widget, uploader, 'Demo.Edit', 'en_US')}</root>"
    )
    contracts = REXML::XPath.match(document, '//*[@data-mendix-type]').to_h do |element|
      [element.attributes['data-mendix-type'],
       JSON.parse("{#{element.attributes['data-mendix-props']}}")]
    end

    expect(contracts.fetch('mxui.widget.Image')).to include(
      'datasource' => { 'type' => 'direct', 'path' => 'Demo.Picture' },
      'defaultUrl' => 'img/System$New.png', 'thumb' => true, 'width' => '120px'
    )
    expect(contracts.fetch('mxui.widget.ImageUploader')).to include(
      'thumbnailWidth' => 48, 'thumbnailHeight' => 32, 'maxFileSize' => 8,
      'restrictions' => 'png;jpg', 'uploadable' => true
    )
    expect(builder.send(:supported_image_viewer?, viewer, true)).to be(true)
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
    builder.send(
      :audit_unsupported_widgets,
      { '$Type' => 'Forms$ActionButton', 'Action' => { '$Type' => 'Forms$UnknownAction' } },
      'Demo.Home'
    )
    expect(builder.instance_variable_get(:@unsupported)['Demo.Home'])
      .to include('Forms$DivContainer(onClick)', 'Forms$UnknownAction')
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
    expect(builder.send(:grid_weight_class, 'md', nil)).to be_nil
    expect(builder.send(:grid_weight_class, 'md', 0)).to be_nil
    expect(builder.send(:widget_children, nil)).to eq([])
    expect(builder.send(:layout_argument_id, 'Demo.Missing.Main')).to eq('Demo.Missing.Main')
    expect(builder.send(:layout_argument_id, 'Demo.Shell.Missing')).to eq('Demo.Shell.Missing')
  end
end
# rubocop:enable Metrics/BlockLength
