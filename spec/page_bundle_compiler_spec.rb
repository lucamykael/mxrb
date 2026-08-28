# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::PageBundleCompiler do
  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @mpr = File.join(root, 'Pages.mpr')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module(:Demo) do
          layout :Shell
          nanoflow :ClientAction
          microflow :ServerAction
          native_document :Assets, type: 'Images$ImageCollection', deep_structure: {
            'Images' => Mxrb::IO::BsonCodec.build_array([
                                                          {
                                                            '$Type' => 'Images$Image', 'Name' => 'Logo',
                                                            'Image' => BSON::Binary.new("\x89PNG\r\n\x1A\nimage".b)
                                                          }
                                                        ])
          }
          page(:Home) do
            layout 'Demo.Shell'
            title 'Welcome'
            container(:body, class_name: 'body') { text :caption, caption: 'Hello' }
          end
        end
      end
      example.run
    end
  end

  it 'renders page content, layout metadata, and translated text as an ES module' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    allow(source).to receive(:units_of).and_call_original
    allow(source).to receive(:documents).and_call_original
    unit = source.units_of('Forms$Page').first
    unit.document['Appearance'] = { 'Class' => 'page-identity' }
    bundle = described_class.new(source).compile(unit)
    expect(bundle.qualified_name).to eq('Demo.Home')
    expect(bundle.source).to include(
      'PageFragment', 'export const title = "Welcome"', '"Demo.Shell.Main":',
      'mx-name-body body', '"Hello"',
      'export const classes = "mxrb-application-shell page-identity"'
    )
    expect(bundle.source).to include('import { content as parentContent } from "../layouts/Demo.Shell.js";')
    expect(bundle.unsupported_widgets).to be_empty
  end

  it 'emits an auditable fallback for an unsupported widget type' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    argument = unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }
    argument['Widgets'] << { '$Type' => 'Forms$UnknownWidget', 'Name' => 'future' }
    argument['Widgets'] << {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'futureCustom', 'Object' => {}
    }
    bundle = described_class.new(source).compile(unit)
    expect(bundle.source).to include('mxrb-unsupported-widget', 'Forms$UnknownWidget')
    expect(bundle.unsupported_widgets).to eq(
      ['CustomWidgets$CustomWidget', 'Forms$UnknownWidget']
    )
  end

  it 'renders responsive grids, headings, and page action buttons' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    argument = unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }
    argument['Widgets'] = [
      { '$Type' => 'Forms$LayoutGrid', 'Name' => 'grid', 'Rows' => [
        { '$Type' => 'Forms$LayoutGridRow', 'Name' => 'row', 'Columns' => [
          { '$Type' => 'Forms$LayoutGridColumn', 'Name' => 'column', 'Weight' => 6,
            'TabletWeight' => 12, 'PhoneWeight' => 12, 'Widgets' => [
              { '$Type' => 'Forms$DynamicText', 'Name' => 'heading', 'RenderMode' => 'H1',
                'Content' => { 'Template' => { 'Items' => [
                  { 'LanguageCode' => 'en_US', 'Text' => 'Dashboard' }
                ] } } },
              { '$Type' => 'Forms$ActionButton', 'Name' => 'open', 'ButtonStyle' => 'Primary',
                'CaptionTemplate' => { 'Template' => { 'Items' => [
                  { 'LanguageCode' => 'en_US', 'Text' => 'Open' }
                ] } }, 'Action' => { '$Type' => 'Forms$FormAction',
                                     'FormSettings' => { 'Form' => 'Demo.Home' } } }
            ] }
        ] }
      ] }
    ]

    bundle = described_class.new(source).compile(unit)
    expect(bundle.source).to include(
      'mx-layoutgrid mx-layoutgrid-fluid', 'row', 'col-md-6 col-sm-12 col-xs-12',
      'React.createElement("h1"', '"Dashboard"', 'btn-primary',
      '"type": "openPage"', '"name": "Demo/Home.page.xml"'
    )
    expect(bundle.unsupported_widgets).to be_empty
  end

  it 'supplies complete Runtime contracts for sidebar toggles and navigation menus' do
    compiler = described_class.new(Mxrb::Compiler::SourceModel.read(@mpr))
    compiler.instance_variable_set(:@qualified_name, 'Demo.Shell')
    compiler.instance_variable_set(:@scope_prefix, 'l')
    toggle = compiler.send(
      :render_sidebar_toggle,
      '$Type' => 'Forms$SidebarToggleButton', 'Name' => 'sidebarToggle',
      'ButtonStyle' => 'Primary',
      'CaptionTemplate' => { 'Template' => { 'Items' => [
        { 'LanguageCode' => 'en_US', 'Text' => 'Menu' }
      ] } },
      'Tooltip' => { 'Items' => [{ 'LanguageCode' => 'en_US', 'Text' => 'Open navigation' }] }
    )

    expect(toggle).to include(
      'React.createElement($SidebarToggle', '"buttonClass": "btn-primary"',
      '"caption": TextProperty({ value: "Menu" })',
      '"tooltip": TextProperty({ value: "Open navigation" })'
    )
    allow(compiler).to receive(:menu_items).and_return([])
    expect(compiler.send(:render_menu, {
      '$Type' => 'Forms$NavigationTree', 'Name' => 'navigation',
      'MenuSource' => { '$Type' => 'Forms$NavigationSource', 'NavigationProfile' => 'Responsive' }
    }, 'NavigationTree')).to include('"name": "navigation"')
  end

  it 'maps Mendix scroll-region enums to the Runtime toggle contract' do
    compiler = described_class.new(Mxrb::Compiler::SourceModel.read(@mpr))

    expect(compiler.send(:scroll_toggle_mode, '')).to eq('none')
    expect(compiler.send(:scroll_toggle_mode, 'None')).to eq('none')
    expect(compiler.send(:scroll_toggle_mode, 'ShrinkContentInitiallyClosed')).to eq('shrink')
    expect(compiler.send(:scroll_toggle_mode, 'PushContentInitiallyOpen')).to eq('push')
    expect(compiler.send(:scroll_toggle_mode, 'SlideOverContentInitiallyClosed')).to eq('slide')
    expect { compiler.send(:scroll_toggle_mode, 'FutureMode') }
      .to raise_error(Mxrb::CompilationError, /unsupported scroll container toggle mode/)
  end

  it 'authorizes every project role when Mendix security checks are disabled' do
    compiler = described_class.new(Mxrb::Compiler::SourceModel.read(@mpr))

    expect(compiler.send(:allowed_roles_for, 'Forms$Page', 'Demo.Home'))
      .to eq(['Administrator'])
  end

  it 'normalizes explicit render modes and translation fallbacks' do
    compiler = described_class.new(Mxrb::Compiler::SourceModel.read(@mpr))
    expect(compiler.send(:render_mode, 'RenderMode' => 'Section')).to eq('section')
    expect(compiler.send(:render_mode, {})).to eq('div')
    expect(compiler.send(:translated_text, nil)).to eq('')
    expect(compiler.send(:translated_text, 'Items' => [
                           3, { 'LanguageCode' => 'pt_BR', 'Text' => 'Olá' }
                         ])).to eq('Olá')
    expect(compiler.send(:translated_text, 'Items' => [3])).to eq('')
  end

  it 'formats bound list values and preserves their dynamic-text template' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    compiler = described_class.new(source)
    compiler.instance_variable_set(:@qualified_name, 'Demo.Home')
    compiler.instance_variable_set(:@list_scopes, [{ scope: 'p.Demo.Home.gallery', entity: 'Demo.Item' }])
    widget = {
      '$Type' => 'Forms$DynamicText', 'Name' => 'duration', 'RenderMode' => 'Text',
      'Content' => {
        'Template' => { 'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => '{1} day(s)' }] },
        'Parameters' => [2, { 'AttributeRef' => {
          'Attribute' => 'Demo.Item.Duration',
          'EntityRef' => { 'Steps' => [2, {
            'Association' => 'Demo.Parent_Items', 'DestinationEntity' => 'Demo.Item'
          }] }
        } }]
      }
    }

    output = compiler.send(:render_text, widget)
    expect(output).to include(
      'React.createElement($MxrbFormattedText', '"template": "{1} day(s)"',
      '"value1": AttributeProperty', '"path": "Demo.Parent_Items/Demo.Item"',
      '"attribute": "Duration"'
    )
    expect(compiler.send(:widget_imports)).to include(
      'props[key]?.displayValue', 'text.split(`{${index + 1}}`)', '$MxrbFormattedText'
    )
  end

  it 'formats expression parameters and evaluates simple conditional visibility' do
    compiler = described_class.new(Mxrb::Compiler::SourceModel.read(@mpr))
    compiler.instance_variable_set(:@qualified_name, 'Sudoku.Game_Play')
    compiler.instance_variable_set(:@data_view_scopes, [])
    compiler.instance_variable_set(
      :@list_scopes, [{ scope: 'p.Sudoku.Game_Play.board', entity: 'Sudoku.Cell' }]
    )
    widget = {
      '$Type' => 'Forms$DynamicText', 'Name' => 'status', 'RenderMode' => 'Text',
      'Content' => {
        'Template' => { 'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => '{1} / {2}' }] },
        'Parameters' => [3,
                         { 'Expression' => 'toString($currentObject/Value)' },
                         { 'Expression' => 'toString($currentObject/Row)' }]
      },
      'ConditionalVisibilitySettings' => {
        'Expression' => '$currentObject/Value != empty and $currentObject/Row != 0'
      }
    }

    output = compiler.send(:render_widget, widget)
    expect(output).to include(
      'React.createElement($MxrbConditional', 'React.createElement($MxrbFormattedText',
      '"value1": AttributeProperty', '"attribute": "Value"',
      '"value2": AttributeProperty', '"attribute": "Row"',
      '"test": props =>', 'mxrbValue(props.value1)', 'Number(mxrbValue(props.value2)) === 0',
      '"$widgetId": "p.Sudoku.Game_Play.status$visibility"'
    )
    expect(compiler.send(:widget_imports)).to include('$MxrbConditional', 'const mxrbValue')
  end

  it 'materializes attribute-backed dynamic classes on list content' do
    compiler = described_class.new(Mxrb::Compiler::SourceModel.read(@mpr))
    compiler.instance_variable_set(:@qualified_name, 'Sudoku.Game_Play')
    compiler.instance_variable_set(:@data_view_scopes, [])
    compiler.instance_variable_set(
      :@list_scopes, [{ scope: 'p.Sudoku.Game_Play.board', entity: 'Sudoku.Cell' }]
    )
    widget = {
      '$Type' => 'Forms$DivContainer', 'Name' => 'cell', 'RenderMode' => 'Div', 'Widgets' => [],
      'Appearance' => {
        'Class' => '',
        'DynamicClasses' => '$currentObject/CellClass + ' \
                            "(if $currentObject/IsPeer then ' sd-peer' else '') + " \
                            "(if $currentObject/IsInvalid then ' sd-bad' else '')"
      }
    }

    output = compiler.send(:render_widget, widget)
    expect(output).to include(
      'React.createElement($MxrbDynamicClass', 'React.createElement("div"',
      '"attribute": "CellClass"', '"attribute": "IsPeer"', '"attribute": "IsInvalid"',
      'String(mxrbValue(props.value1) ?? \'\')',
      'Boolean(mxrbValue(props.value2)) ? " sd-peer" : ""',
      'Boolean(mxrbValue(props.value3)) ? " sd-bad" : ""',
      '"$widgetId": "p.Sudoku.Game_Play.cell$class"'
    )
    expect(compiler.send(:widget_imports)).to include(
      '$MxrbDynamicClass', 'React.cloneElement(children, classProp)'
    )
  end

  it 'renders parameter-backed data views, editable fields, save, and cancel actions' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    unit.document['Parameters'] << {
      '$Type' => 'Forms$PageParameter', 'Name' => 'Item',
      'ParameterType' => { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'Demo.Item' }
    }
    unit.document['Parameters'] << {
      '$Type' => 'Forms$PageParameter', 'Name' => 'Ignored',
      'ParameterType' => { '$Type' => 'DataTypes$StringType' }
    }
    text_box = {
      '$Type' => 'Forms$TextBox', 'Name' => 'name', 'IsPasswordBox' => true,
      'InputMask' => 'AAA', 'MaxLengthCode' => 42, 'Autocomplete' => false,
      'SubmitBehaviour' => 'OnTyping', 'SubmitOnInputDelay' => 150,
      'AttributeRef' => { 'Attribute' => 'Demo.Item.Name' },
      'LabelTemplate' => { 'Template' => { 'Items' => [
        3, { 'LanguageCode' => 'en_US', 'Text' => 'Name' }
      ] } },
      'PlaceholderTemplate' => { 'Template' => { 'Items' => [
        3, { 'LanguageCode' => 'en_US', 'Text' => 'Enter a name' }
      ] } }
    }
    date_picker = {
      '$Type' => 'Forms$DatePicker', 'Name' => 'dueDate',
      'AttributeRef' => { 'Attribute' => 'Demo.Item.DueDate' },
      'FormattingInfo' => { 'DateFormat' => 'Date' },
      'LabelTemplate' => { 'Template' => { 'Items' => [
        3, { 'LanguageCode' => 'en_US', 'Text' => 'Due date' }
      ] } },
      'PlaceholderTemplate' => { 'Template' => { 'Items' => [3] } }
    }
    actions = %w[Forms$SaveChangesClientAction Forms$CancelChangesClientAction].map.with_index do |type, index|
      {
        '$Type' => 'Forms$ActionButton', 'Name' => "action#{index}",
        'ButtonStyle' => index.zero? ? 'Primary' : 'Default',
        'CaptionTemplate' => { 'Template' => { 'Items' => [
          3, { 'LanguageCode' => 'en_US', 'Text' => index.zero? ? 'Save' : 'Cancel' }
        ] } },
        'Action' => { '$Type' => type, 'ClosePage' => index.zero?,
                      'DisabledDuringExecution' => index.zero? }
      }
    end
    data_view = {
      '$Type' => 'Forms$DataView', 'Name' => 'editor', 'ShowFooter' => false,
      'DataSource' => { 'SourceVariable' => { 'PageParameter' => 'Item' } },
      'NoEntityMessage' => { 'Items' => [3] },
      'Widgets' => [3, text_box, text_box.merge(
        'Name' => 'code', 'IsPasswordBox' => false, 'MaxLengthCode' => -1,
        'Autocomplete' => true, 'SubmitBehaviour' => 'OnEndEditing',
        'AttributeRef' => { 'Attribute' => 'Demo.Item.Code' }
      ), date_picker],
      'FooterWidgets' => [2, *actions]
    }
    unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }['Widgets'] = [2, data_view]

    compiler = described_class.new(source)
    bundle = compiler.compile(unit)
    expect(bundle.source).to include(
      '$DataView', '$TextBox', '$DatePicker', '$FormGroup', '$ActionButton',
      'AssociationObjectProperty({ scope: "$Item"',
      'AttributeProperty({ "scope": "p.Demo.Home.editor"',
      '"isPassword": true', '"maxLength": 42', '"autocomplete": "off"',
      '"submitWhileEditing": true', 'TextProperty({ value: "Name" })',
      '"mode": "date"', '"formatting": { "dateFormat": { "type": "date" } }',
      '"type": "saveChanges"', '"type": "cancelChanges"',
      'export const parameters = {"$Item":{"kind":"object"}}'
    )
    expect(bundle.unsupported_widgets).to be_empty

    expect(compiler.send(:render_data_view, {
      '$Type' => 'Forms$DataView', 'Name' => 'unsafe', 'DataSource' => {}
    })).to include('mxrb-unsupported-widget')
    expect(compiler.send(:render_text_box, {
      '$Type' => 'Forms$TextBox', 'Name' => 'unsafe', 'AttributeRef' => { 'Attribute' => 'unsafe' }
    })).to include('mxrb-unsupported-widget')
    expect(compiler.send(:js_literal, [true, nil])).to eq('[true, null]')
    compiler.instance_variable_set(:@uses_data_grid, true)
    expect(compiler.send(:widget_imports)).to include('$Datagrid', '$DataView')
  end

  it 'infers an omitted microflow mapping from the current DataView entity' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    unit.document['Parameters'] << {
      '$Type' => 'Forms$PageParameter', 'Name' => 'Item',
      'ParameterType' => { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'Demo.Item' }
    }
    flow = source.units_of('Microflows$Microflow').find { _1.document['Name'] == 'ServerAction' }
    flow.document.dig('ObjectCollection', 'Objects') << {
      '$Type' => 'Microflows$MicroflowParameter', 'Name' => 'CurrentItem',
      'VariableType' => { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'Demo.Item' }
    }
    button = {
      '$Type' => 'Forms$ActionButton', 'Name' => 'saveWithFlow',
      'CaptionTemplate' => { 'Template' => { 'Items' => [
        3, { 'LanguageCode' => 'en_US', 'Text' => 'Save' }
      ] } },
      'Action' => {
        '$Type' => 'Forms$MicroflowAction',
        'MicroflowSettings' => { 'Microflow' => 'Demo.ServerAction', 'ParameterMappings' => [2] }
      }
    }
    data_view = {
      '$Type' => 'Forms$DataView', 'Name' => 'editor',
      'DataSource' => { 'SourceVariable' => { 'PageParameter' => 'Item' } },
      'Widgets' => [2], 'FooterWidgets' => [2, button]
    }
    unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }['Widgets'] = [2, data_view]

    bundle = described_class.new(source).compile(unit)
    expect(bundle.source).to include(
      '"argMap": { "CurrentItem": { "widget": "p.Demo.Home.editor", "source": "object" } }'
    )
  end

  it 'renders core labels, check boxes, tabs, images, links, and server actions' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    unit.document['Parameters'] << {
      '$Type' => 'Forms$PageParameter', 'Name' => 'Item',
      'ParameterType' => { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'Demo.Item' }
    }
    label = {
      '$Type' => 'Forms$Label', 'Name' => 'notice',
      'Caption' => { 'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => 'Notice' }] }
    }
    checkbox = {
      '$Type' => 'Forms$CheckBox', 'Name' => 'active',
      'AttributeRef' => { 'Attribute' => 'Demo.Item.Active' },
      'LabelTemplate' => { 'Template' => { 'Items' => [
        3, { 'LanguageCode' => 'en_US', 'Text' => 'Active' }
      ] } }
    }
    buttons = [
      {
        '$Type' => 'Forms$ActionButton', 'Name' => 'docs',
        'CaptionTemplate' => { 'Template' => { 'Items' => [
          3, { 'LanguageCode' => 'en_US', 'Text' => 'Docs' }
        ] } },
        'Action' => {
          '$Type' => 'Forms$OpenLinkClientAction', 'LinkType' => 'Web',
          'Address' => { 'IsDynamic' => false, 'Value' => 'https://example.test' }
        }
      },
      {
        '$Type' => 'Forms$ActionButton', 'Name' => 'run',
        'CaptionTemplate' => { 'Template' => { 'Items' => [
          3, { 'LanguageCode' => 'en_US', 'Text' => 'Run' }
        ] } },
        'Action' => {
          '$Type' => 'Forms$MicroflowAction',
          'MicroflowSettings' => { 'Microflow' => 'Demo.ServerAction', 'ParameterMappings' => [2] }
        }
      }
    ]
    tab = {
      '$Type' => 'Forms$TabControl', 'Name' => 'tabs',
      'TabPages' => [2, {
        '$Type' => 'Forms$TabPage', 'Name' => 'first',
        'Caption' => { 'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => 'General' }] },
        'Widgets' => [2, label], 'RefreshOnShow' => false
      }]
    }
    image = {
      '$Type' => 'Forms$StaticImageViewer', 'Name' => 'logo', 'Image' => 'Demo.Assets.Logo',
      'Width' => 80, 'WidthUnit' => 'Pixels', 'Height' => 50, 'HeightUnit' => 'Pixels',
      'Responsive' => true
    }
    data_view = {
      '$Type' => 'Forms$DataView', 'Name' => 'editor',
      'DataSource' => { 'SourceVariable' => { 'PageParameter' => 'Item' } },
      'Widgets' => [2, checkbox, tab, image, *buttons, {
        '$Type' => 'Forms$DivContainer', 'Name' => 'clickable', 'Widgets' => [2, label],
        'OnClickAction' => {
          '$Type' => 'Forms$MicroflowAction',
          'MicroflowSettings' => { 'Microflow' => 'Demo.ServerAction', 'ParameterMappings' => [2] }
        }
      }], 'FooterWidgets' => [2]
    }
    unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }['Widgets'] = [2, data_view]

    bundle = described_class.new(source).compile(unit)
    expect(bundle.source).to include(
      '$CheckBox', '$Label', '$TabContainer', '$Image', '$Container', 'WebStaticImageProperty',
      'img/Demo$Assets$Logo.png', '"type": "openLink"', 'https://example.test',
      '"type": "callMicroflow"'
    )
    expect(bundle.source).to include(
      Mxrb::Compiler::WebOperationCompiler.operation_id('Demo.Home', 'run')
    )
    expect(bundle.unsupported_widgets).to be_empty

    compiler = described_class.new(source)
    compiler.compile(unit)
    compiler.instance_variable_set(:@data_view_scopes, ['p.Demo.Home.editor'])
    dynamic = {
      '$Type' => 'Forms$OpenLinkClientAction', 'LinkType' => 'Web',
      'Address' => {
        'IsDynamic' => true, 'AttributeRef' => { 'Attribute' => 'Demo.Item.URL' }
      }
    }
    expect(compiler.send(:open_link_config, dynamic)).to include(
      argMap: { '$object': { widget: 'p.Demo.Home.editor', source: 'object' } },
      config: { schema: 'web', addressAttribute: 'Demo.Item/URL' }
    )
    compiler.instance_variable_set(:@data_view_scopes, [])
    expect(compiler.send(:open_link_config, dynamic)).to be_nil
    expect(compiler.send(:microflow_config, {}, '$Type' => 'Forms$MicroflowAction')).to be_nil
    expect(compiler.send(:microflow_argument, 'Parameter' => '', 'Expression' => '$Item')).to be_nil
    invalid_mapping = { 'ParameterMappings' => [2, { 'Parameter' => '', 'Expression' => '$Item' }] }
    expect(compiler.send(:microflow_argument_map, invalid_mapping)).to be_nil
    expect(compiler.send(
             :microflow_config, { 'Name' => 'invalid' },
             { '$Type' => 'Forms$MicroflowAction',
               'MicroflowSettings' => invalid_mapping.merge('Microflow' => 'Demo.ServerAction') }
           )).to be_nil
    compiler.instance_variable_set(:@list_scopes, [{ scope: 'p.Demo.Home.items' }])
    expect(compiler.send(
             :microflow_argument, 'Parameter' => 'Demo.ServerAction.Item', 'Expression' => '$currentObject'
           )).to eq([:Item, { widget: 'p.Demo.Home.items', source: 'object' }])
    nanoflow = { '$Type' => 'Forms$CallNanoflowClientAction', 'Nanoflow' => 'Demo.ClientAction',
                 'ParameterMappings' => [2] }
    expect(compiler.send(:container_action_config, {}, nanoflow)).to include(
      action: include(type: 'callNanoflow')
    )
    form_container = {
      '$Type' => 'Forms$DivContainer', 'Name' => 'navigate', 'Widgets' => [2],
      'OnClickAction' => {
        '$Type' => 'Forms$FormAction', 'FormSettings' => { 'Form' => 'Demo.Home' }
      }
    }
    expect(compiler.send(:render_container, form_container)).to include(
      '$Container', 'ActionProperty', '"type": "openPage"'
    )
    expect(compiler.send(:render_check_box, '$Type' => 'Forms$CheckBox', 'Name' => 'loose'))
      .to include('mxrb-unsupported-widget')
    expect(compiler.send(:image_uri, 'Demo.Assets.Missing')).to be_nil
    expect(compiler.send(:image_uri, 'Demo.Unknown.Missing')).to be_nil
    expect(compiler.send(:render_static_image, {
      '$Type' => 'Forms$StaticImageViewer', 'Name' => 'missing', 'Image' => 'Demo.Unknown.Missing'
    })).to include('mxrb-unsupported-widget')
  end

  it 'renders a parameterless nanoflow action through the client action property' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    argument = unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }
    argument['Widgets'] = [2, {
      '$Type' => 'Forms$ActionButton', 'Name' => 'runClient', 'ButtonStyle' => 'Primary',
      'CaptionTemplate' => { 'Template' => { 'Items' => [
        3, { 'LanguageCode' => 'en_US', 'Text' => 'Run locally' }
      ] } },
      'Action' => {
        '$Type' => 'Forms$CallNanoflowClientAction', 'Nanoflow' => 'Demo.ClientAction',
        'ParameterMappings' => [2], 'DisabledDuringExecution' => true
      }
    }]

    bundle = described_class.new(source).compile(unit)
    expect(bundle.source).to include(
      '$ActionButton', 'ActionProperty', '"type": "callNanoflow"',
      'const mxrbNanoflow_', '"name": "Demo.ClientAction"',
      '"nanoflow": () => mxrbNanoflow_', '"disabledDuringExecution": true'
    )
    expect(bundle.unsupported_widgets).to be_empty
  end

  it 'renders a supported nanoflow-backed data view through the client object property' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    argument = unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }
    argument['Widgets'] = [2, {
      '$Type' => 'Forms$DataView', 'Name' => 'clientView',
      'DataSource' => {
        '$Type' => 'Forms$NanoflowSource', 'Nanoflow' => 'Demo.ClientAction',
        'ParameterMappings' => [2]
      },
      'NoEntityMessage' => { 'Items' => [3] }, 'Widgets' => [2], 'FooterWidgets' => [2]
    }]

    bundle = described_class.new(source).compile(unit)
    expect(bundle.source).to include(
      'NanoflowObjectProperty', '"source": { "nanoflow": () => mxrbNanoflow_',
      '"dataSourceId": "p.Demo.Home.clientView"', '"name": "Demo.ClientAction"'
    )
    expect(bundle.unsupported_widgets).to be_empty

    form_argument = unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }
    source_doc = form_argument.dig('Widgets', 1, 'DataSource')
    source_doc['ParameterMappings'] << { 'Parameter' => 'Demo.Input' }
    expect(described_class.new(source).compile(unit).unsupported_widgets)
      .to include('Forms$DataView')
  end

  it 'integrates Gallery rendering and fails closed for an uncompiled nanoflow source' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    compiler = described_class.new(source)
    unit = source.units_of('Forms$Page').first
    compiler.compile(unit)
    grid = instance_double(Mxrb::Compiler::DataGridBundleCompiler, supported?: false)
    data_source = instance_double(Mxrb::Compiler::WebListDataSource, nanoflow?: false)
    gallery = instance_double(
      Mxrb::Compiler::GalleryBundleCompiler, supported?: true, data_source:,
                                             widget_key: 'p.Demo.Home.gallery',
                                             entity_name: 'Demo.Item', content_widgets: [],
                                             render: 'gallery-output'
    )
    allow(Mxrb::Compiler::DataGridBundleCompiler).to receive(:new).and_return(grid)
    allow(Mxrb::Compiler::GalleryBundleCompiler).to receive(:new).and_return(gallery)
    expect(compiler.send(:render_custom_widget, {})).to eq('gallery-output')
    expect(compiler.send(:widget_imports)).to include('$Gallery')

    nano_source = instance_double(
      Mxrb::Compiler::WebListDataSource, nanoflow?: true, nanoflow_name: 'Demo.Missing'
    )
    allow(gallery).to receive(:data_source).and_return(nano_source)
    expect(compiler.send(:render_custom_widget, '$Type' => 'CustomWidgets$CustomWidget'))
      .to include('mxrb-unsupported-widget')
  end

  it 'fails closed on invalid slots and covers safe page-action fallbacks' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    compiler = described_class.new(source)
    compiler.compile(unit)

    expect(compiler.send(:grid_weight_class, 'md', nil)).to be_nil
    expect(compiler.send(:open_form_handler, '../unsafe')).to be_nil
    expect(compiler.send(:create_object_handler, '../unsafe', 'Demo.Home')).to be_nil
    expect(compiler.send(:create_object_handler, 'Demo.Item', '../unsafe')).to be_nil
    expect(compiler.send(:action_handler, {})).to be_nil
    expect(compiler.send(:action_handler, '$Type' => 'Forms$UnknownAction')).to be_nil
    expect(compiler.send(:render_action_button, {
      '$Type' => 'Forms$ActionButton', 'Name' => '', 'Action' => {},
      'CaptionTemplate' => { 'Template' => { 'Items' => [] } }
    })).to include('"disabled": true', 'btn-default')
    unit.document['Parameters'] << {
      '$Type' => 'Forms$PageParameter', 'Name' => 'Item',
      'ParameterType' => { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'Demo.Item' }
    }
    compiler.compile(unit)
    create = compiler.send(:action_handler, {
      '$Type' => 'Forms$CreateObjectClientAction',
      'EntityRef' => { 'Entity' => 'Demo.Item' },
      'PageSettings' => { 'Form' => 'Demo.Home' }
    })
    expect(create).to include(
      'window.mx?.data?.create?', 'Demo.Item', 'Demo.Home', '"$Item": object.getGuid()',
      'window.mx?.ui?.openForm2?'
    )
    expect(compiler.send(:create_object_handler, 'Demo.Other', 'Demo.Home')).to be_nil
    expect(compiler.send(:create_object_handler, 'Demo.Item', 'Demo.Missing')).to be_nil
    expect(compiler.send(:page_parameters)).to eq('$Item' => { kind: 'object' })
    expect(compiler.send(:widget_id, '$ID' => {
      '$binary' => { 'base64' => 'ab+/cd==' }
    })).to eq('abcd')
    expect(compiler.send(:widget_id, {})).to eq('')

    arguments = unit.document['FormCall']['Arguments']
    arguments << { 'Parameter' => arguments.find { _1.is_a?(Hash) }['Parameter'], 'Widgets' => [] }
    expect { described_class.new(source).compile(unit) }
      .to raise_error(Mxrb::CompilationError, /duplicate page slot "Demo\.Shell\.Main"/)
    arguments.pop
    arguments.find { _1.is_a?(Hash) }['Parameter'] = '../unsafe'
    expect { described_class.new(source).compile(unit) }
      .to raise_error(Mxrb::CompilationError, /invalid page slot/)
  end

  it 'skips list-scope text binding for multiple or malformed attribute parameters' do
    compiler = described_class.new(Mxrb::Compiler::SourceModel.read(@mpr))
    compiler.instance_variable_set(:@list_scopes, [{ scope: 'p.Demo.Home.gallery', entity: 'Demo.Item' }])

    two_parameters = { 'Content' => { 'Parameters' => [
      3, { 'AttributeRef' => { 'Attribute' => 'Demo.Item.First' } },
      { 'AttributeRef' => { 'Attribute' => 'Demo.Item.Second' } }
    ] } }
    expect(compiler.send(:bound_text_attributes, two_parameters)).to eq(
      %w[Demo.Item.First Demo.Item.Second]
    )

    malformed = { 'Content' => { 'Parameters' => [
      2, { 'AttributeRef' => { 'Attribute' => 'NoSeparator' } }
    ] } }
    expect(compiler.send(:bound_text_attributes, malformed)).to be_nil
  end

  it 'covers guarded page-expression, Combo box, and DatePicker branches' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    compiler = described_class.new(source)
    compiler.compile(source.units_of('Forms$Page').first)
    compiler.instance_variable_set(:@data_view_scopes, [
                                     { scope: 'p.Demo.Home.editor', entity: 'Demo.Item' }
                                   ])
    compiler.instance_variable_set(:@list_scopes, [])

    allow(Mxrb::Compiler::DataGridBundleCompiler).to receive(:new)
      .and_return(instance_double(Mxrb::Compiler::DataGridBundleCompiler, supported?: false))
    allow(Mxrb::Compiler::GalleryBundleCompiler).to receive(:new)
      .and_return(instance_double(Mxrb::Compiler::GalleryBundleCompiler, supported?: false))
    allow(Mxrb::Compiler::ImageBundleCompiler).to receive(:new)
      .and_return(instance_double(Mxrb::Compiler::ImageBundleCompiler, supported?: false))
    combo = instance_double(Mxrb::Compiler::ComboBoxBundleCompiler,
                            supported?: true, render: 'combo-output')
    allow(Mxrb::Compiler::ComboBoxBundleCompiler).to receive(:new).and_return(combo)

    expect(compiler.send(:render_custom_widget, 'Name' => 'combo')).to eq('combo-output')
    expect(compiler.send(:widget_imports)).to include('$Combobox', 'AssociationProperty')
    expect(compiler.send(:attribute_reference_path, nil)).to eq('')
    expect(compiler.send(:bound_text_attributes, 'Content' => { 'Parameters' => [2] })).to be_nil

    compiler.instance_variable_set(:@list_scopes, [])
    compiler.instance_variable_set(:@data_view_scopes, [])
    expect(compiler.send(:text_parameter_attribute,
                         'Expression' => '$currentObject/Name')).to be_nil
    compiler.instance_variable_set(:@list_scopes, ['legacy-scope'])
    expect(compiler.send(:current_object_scope)).to eq(scope: 'legacy-scope', entity: '')

    compiler.instance_variable_set(:@list_scopes, [
                                     { scope: 'p.Demo.Home.items', entity: 'Demo.Item' }
                                   ])
    attributes = []
    expect(compiler.send(
             :conditional_visibility,
             'Expression' => '$currentObject/Active = true or $currentObject/State = Demo.State.Open'
           )).to be_an(Array)
    expect(compiler.send(:conditional_visibility, 'Expression' => 'invalid')).to be_nil
    expect(compiler.send(:logical_predicate, ['$currentObject/Active', 'invalid'], attributes, '&&'))
      .to be_nil
    expect(compiler.send(:visibility_atom, 'invalid', attributes)).to be_nil
    expect(compiler.send(:visibility_atom, '$currentObject/State = invalid value', attributes)).to be_nil
    expect(compiler.send(:visibility_atom, '$currentObject/Active = true', attributes))
      .to include('=== true')
    expect(compiler.send(:visibility_comparison, 'value', 'false')).to eq('value === false')
    expect(compiler.send(:visibility_comparison, 'value', 'Demo.State.Open')).to include('"Open"')
    expect(compiler.send(:visibility_comparison, 'value', "'ready'")).to include('"ready"')
    expect(compiler.send(:visibility_comparison, 'value', 'not valid')).to be_nil

    dynamic_widget = {
      'Name' => 'invalidClass', 'Appearance' => { 'DynamicClasses' => 'not supported' }
    }
    expect(compiler.send(:wrap_dynamic_classes, dynamic_widget, 'content')).to eq('content')
    expect(compiler.send(:dynamic_class_expression, 'not supported', [])).to be_nil
    expect(compiler.send(:dynamic_class_conditional, 'invalid', [])).to be_nil
    expect(compiler.send(:dynamic_class_conditional,
                         "if invalid then 'yes' else 'no'", [])).to be_nil

    expect(compiler.send(:microflow_argument_map, 'ParameterMappings' => [2, {
      'Parameter' => 'Demo.Item', 'Expression' => '$Item'
    }])).to eq(Item: { widget: '$Item', source: 'object' })
    compiler.instance_variable_set(:@list_scopes, [])
    compiler.instance_variable_set(:@data_view_scopes, [])
    expect(compiler.send(:inferred_microflow_argument_map, 'Demo.ServerAction')).to eq({})
    expect(compiler.send(:inferred_microflow_parameters, 'Demo.Missing', 'Demo.Item')).to eq([])

    compiler.instance_variable_set(:@data_view_scopes, [
                                     { scope: 'p.Demo.Home.editor', entity: 'Demo.Item' }
                                   ])
    expect(compiler.send(:render_date_picker, {
      '$Type' => 'Forms$DatePicker', 'Name' => 'invalid', 'AttributeRef' => { 'Attribute' => 'invalid' }
    })).to include('mxrb-unsupported-widget')
    expect(compiler.send(:render_date_picker, {
      '$Type' => 'Forms$DatePicker', 'Name' => 'startTime',
      'AttributeRef' => { 'Attribute' => 'Demo.Item.Start' },
      'FormattingInfo' => { 'DateFormat' => 'Time' }, 'ShowCalendarButton' => false,
      'LabelTemplate' => { 'Template' => { 'Items' => [2] } },
      'PlaceholderTemplate' => { 'Template' => { 'Items' => [2] } }
    })).to include('"mode": "time"', '"timeFormat"')
  end

  it 'covers advanced standard widgets, menus, actions, lists, and import flags' do # rubocop:disable Metrics/BlockLength
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    unit = source.units_of('Forms$Page').first
    compiler = described_class.new(source)
    compiler.send(:prepare_compile, unit, 'p')
    compiler.instance_variable_set(:@data_view_scopes, [{ scope: 'p.Demo.Home.item', entity: 'Demo.Item' }])

    expect(compiler.send(:render_widget, '$Type' => 'Forms$Title', 'Name' => 'title')).to include('h1')
    expect(compiler.send(:render_widget, {
      '$Type' => 'Forms$GroupBox', 'Name' => 'group', 'Collapsible' => 'YesInitiallyCollapsed',
      'HeaderMode' => 'H2', 'Widgets' => []
    })).to include('"collapsible": "yes"')
    expect(compiler.send(:render_group_box, {
      'Name' => 'expanded', 'Collapsible' => 'YesInitiallyExpanded', 'Widgets' => []
    })).to include('"collapsible": "expanded"')
    expect(compiler.send(:render_group_box, { 'Name' => 'plain', 'Widgets' => [] }))
      .to include('"collapsible": "no"')
    expect(compiler.send(:render_group_box, {
      'Name' => 'content', 'Widgets' => [2, { '$Type' => 'Forms$DynamicText', 'Name' => 'child' }]
    })).to include('child')

    radio = { '$Type' => 'Forms$RadioButtonGroup', 'Name' => 'state',
              'AttributeRef' => { 'Attribute' => 'Demo.Item.State' } }
    expect(compiler.send(:render_widget, radio)).to include('$RadioButtonGroup')
    expect(compiler.send(:render_widget, {
      '$Type' => 'Forms$FileManager', 'Name' => 'file', 'Type' => '', 'MaxFileSize' => 'invalid'
    })).to include('$FileManager', '"widgetType": "both"')
    expect(compiler.send(:render_text_area, {
      'Name' => 'description', 'AttributeRef' => { 'Attribute' => 'Demo.Item.Description' },
      'AutoGrow' => true, 'MaxLengthCode' => 100, 'Autocomplete' => false,
      'SubmitBehaviour' => 'WhileEditing'
    })).to include('$TextArea', '"autoGrow": true')

    expect(compiler.send(:menu_items, nil)).to be_nil
    expect(compiler.send(:menu_items, '$Type' => 'Unknown')).to be_nil
    expect(compiler.send(:menu_icon_property, nil)).to be_nil
    expect(compiler.send(:menu_icon_property, 'Image' => 'Demo.Icons.AddItem')).to include('add-item')
    expect(compiler.send(:grid_weight_class, 'md', 0)).to be_nil
    expect(compiler.send(:grid_weight_class, 'md', 12)).to eq('col-md-12')
    expect(compiler.send(:compile_menu_item, {
      'Caption' => { 'Items' => [2] }, 'Items' => [2, { 'Caption' => { 'Items' => [2] } }]
    }, {}, [0])).to include(:items)
    expect(compiler.send(:menu_microflow_config, '$Type' => 'Other')).to be_nil
    expect(compiler.send(:menu_microflow_config, {
      '$Type' => 'Forms$MicroflowAction',
      'MicroflowSettings' => { 'Microflow' => 'Demo.ServerAction', 'ParameterMappings' => [2] }
    })).to include(type: 'callMicroflow')

    expect(compiler.send(:open_page_config, '$Type' => 'Forms$FormAction', 'FormSettings' => {
      'Form' => '', 'ParameterMappings' => [2]
    })).to be_nil
    expect(compiler.send(:sign_out_config, '$Type' => 'Other')).to be_nil
    expect(compiler.send(:sign_out_config, '$Type' => 'Forms$SignOutClientAction'))
      .to include(type: 'signOut')
    expect(compiler.send(:create_object_config, {}, '$Type' => 'Other')).to be_nil
    unit.document['Parameters'] << {
      'Name' => 'Item', 'ParameterType' => { '$Type' => 'DataTypes$ObjectType', 'Entity' => 'Demo.Item' }
    }
    expect(compiler.send(:create_object_config, { 'Name' => 'create' }, {
      '$Type' => 'Forms$CreateObjectClientAction', 'EntityRef' => { 'Entity' => 'Demo.Item' },
      'PageSettings' => { 'Form' => 'Demo.Home' }
    })).to include(type: 'createObject')
    expect(compiler.send(:open_link_config, '$Type' => 'Forms$OpenLinkClientAction',
                                            'Address' => { 'Value' => 'https://example.invalid' }))
      .to include(type: 'openLink')
    expect(compiler.send(:action_handler, '$Type' => 'Forms$FormAction',
                                          'FormSettings' => { 'Form' => 'Demo.Home' })).to include('openForm2')
    expect(compiler.send(:action_handler, '$Type' => 'Forms$UnknownAction')).to be_nil
    expect(compiler.send(:open_form_handler, '')).to be_nil

    expect(compiler.send(:entity_ref_destination, nil)).to eq('')
    expect(compiler.send(:entity_ref_destination, 'Entity' => 'Demo.Item')).to eq('Demo.Item')
    expect(compiler.send(:entity_ref_destination, 'Steps' => [2, {
      'DestinationEntity' => 'Demo.Child'
    }])).to eq('Demo.Child')
    expect(compiler.send(:flow_return_entity, '$Type' => 'Unknown')).to eq('')
    expect(compiler.send(:flow_return_entity, '$Type' => 'Forms$MicroflowSource',
                                              'MicroflowSettings' => { 'Microflow' => 'Demo.ServerAction' }))
      .to eq('')
    expect(compiler.send(:positive_integer, 5, 20)).to eq(5)
    expect(compiler.send(:positive_integer, 0, 20)).to eq(20)
    expect(compiler.send(:positive_integer, 'bad', 20)).to eq(20)

    xpath = instance_double(Mxrb::Compiler::WebListDataSource, xpath?: true, entity: 'Demo.Item')
    expect(compiler.send(:list_view_property, { 'Name' => 'items' }, 'key', xpath))
      .to include('DatabaseObjectListProperty')
    association = instance_double(
      Mxrb::Compiler::WebListDataSource,
      xpath?: false, association?: true, association_path: 'Demo.Item_Parent/Demo.Parent'
    )
    expect(compiler.send(:list_view_property, { 'Name' => 'items' }, 'key', association))
      .to include('AssociationObjectListProperty')
    microflow = instance_double(
      Mxrb::Compiler::WebListDataSource, xpath?: false, association?: false, microflow?: true
    )
    allow(compiler).to receive(:microflow_argument_map).and_return({})
    expect(compiler.send(:list_view_property, { 'Name' => 'items', 'DataSource' => {} }, 'key', microflow))
      .to include('MicroflowObjectListProperty')
    nanoflow = instance_double(
      Mxrb::Compiler::WebListDataSource,
      xpath?: false, association?: false, microflow?: false, nanoflow_name: 'Demo.ClientAction'
    )
    allow(compiler).to receive(:nanoflow_reference).and_return('() => flow')
    expect(compiler.send(:list_view_property, { 'Name' => 'items' }, 'key', nanoflow))
      .to include('NanoflowObjectListProperty')

    allow(Mxrb::Compiler::WebListDataSource).to receive(:new).and_return(
      instance_double(
        Mxrb::Compiler::WebListDataSource,
        supported?: true, entity: 'Demo.Item', xpath?: true
      )
    )
    expect(compiler.send(:render_widget, {
      '$Type' => 'Forms$ListView', 'Name' => 'list', 'Widgets' => [], 'PageSize' => 10
    })).to include('$ListView', 'DatabaseObjectListProperty')

    compiler.instance_variable_set(:@snippet_scopes, [{ 'Context' => { scope: 'snippet', entity: 'Demo.Item' } }])
    expect(compiler.send(:data_source_scope, 'SourceVariable' => { 'SnippetParameter' => 'Context' }))
      .to eq(scope: 'snippet', entity: 'Demo.Item')
    expect(compiler.send(:data_source_scope, 'SourceVariable' => { 'SnippetParameter' => 'Missing' })).to be_nil
    expect(compiler.send(:microflow_object_property, {
      'MicroflowSettings' => { 'Microflow' => 'Demo.ServerAction' }
    }, { 'Name' => 'view' }, 'scope')).to include('MicroflowObjectProperty')

    compiler.instance_variable_set(:@list_scopes, [{ scope: 'scope', entity: 'Demo.Item' }])
    expect(compiler.send(:snippet_scope_map, 'Parameters' => [2, {
      'Name' => 'Context', 'ParameterType' => { '$Type' => 'DataTypes$ObjectType' }
    }, { 'Name' => 'Ignored', 'ParameterType' => { '$Type' => 'DataTypes$StringType' } }]))
      .to include('Context' => include(scope: 'scope'))
    expect(compiler.send(:data_view_object_property, {
      'Name' => 'nested', 'DataSource' => {
        'SourceVariable' => { 'PageParameter' => 'Item' }, 'EntityRef' => { 'Steps' => [2, {
          'Association' => 'Demo.Item_Child', 'DestinationEntity' => 'Demo.Child'
        }] }
      }
    }, 'nested-scope')).to include('AssociationObjectProperty')

    unit.document['Parameters'] = [2, { 'Name' => 'PageItem' }]
    compiler.instance_variable_set(:@list_scopes, [{ scope: 'list-scope', entity: 'Demo.Item' }])
    expect(compiler.send(:nanoflow_argument, 'Parameter' => 'Flow.Input', 'Expression' => '$PageItem').last)
      .to include(kind: 'object')
    expect(compiler.send(:nanoflow_argument, 'Parameter' => 'Flow.Input', 'Expression' => '$Item').last
                   .dig(:expression, :args, :Item, :widget)).to eq('list-scope')
    expect(compiler.send(:nanoflow_argument, 'Parameter' => 'Flow.Input', 'Expression' => '$Other').last
                   .dig(:expression, :args, :Other, :widget)).to eq('$Other')

    flags = %i[
      @uses_form_widgets @uses_date_picker @uses_text_area @uses_radio_button_group
      @uses_group_box @uses_file_manager @uses_microflow_object @uses_container
      @uses_list_view @uses_nanoflow_object
    ]
    flags.each { compiler.instance_variable_set(_1, true) }
    compiler.instance_variable_set(:@generic_widgets, { 'Custom' => 'example/Custom' })
    imports = compiler.send(:widget_imports)
    expect(imports).to include(
      'RadioButtonGroup', 'GroupBox', 'FileManager', 'MicroflowObjectProperty',
      'ListView', 'NanoflowObjectProperty', 'CustomWidgetModule',
      'const Custom = CustomWidgetModule["Custom"] || CustomWidgetModule.default;'
    )
    expect(imports).not_to include('Object.getOwnPropertyDescriptor')
  end

  it 'executes custom image and generic action-property callbacks' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    compiler = described_class.new(source)
    compiler.send(:prepare_compile, source.units_of('Forms$Page').first, 'p')
    allow(Mxrb::Compiler::DataGridBundleCompiler).to receive(:new)
      .and_return(instance_double(Mxrb::Compiler::DataGridBundleCompiler, supported?: false))
    allow(Mxrb::Compiler::GalleryBundleCompiler).to receive(:new)
      .and_return(instance_double(Mxrb::Compiler::GalleryBundleCompiler, supported?: false))
    allow(Mxrb::Compiler::ComboBoxBundleCompiler).to receive(:new)
      .and_return(instance_double(Mxrb::Compiler::ComboBoxBundleCompiler, supported?: false))

    allow(Mxrb::Compiler::ImageBundleCompiler).to receive(:new) do |*, action_property:, **|
      rendered = [
        action_property.call('$Type' => 'Forms$SignOutClientAction'),
        action_property.call('$Type' => 'Forms$NoAction')
      ].compact.join
      instance_double(Mxrb::Compiler::ImageBundleCompiler, supported?: true, render: rendered)
    end
    expect(compiler.send(:render_custom_widget, 'Name' => 'image')).to include('ActionProperty')

    allow(Mxrb::Compiler::ImageBundleCompiler).to receive(:new)
      .and_return(instance_double(Mxrb::Compiler::ImageBundleCompiler, supported?: false))
    allow(Mxrb::Compiler::GenericWidgetBundleCompiler).to receive(:new) do |*, render_widgets:, action_property:, **|
      rendered = render_widgets.call([{ '$Type' => 'Forms$DynamicText', 'Name' => 'child' }])
      actions = [
        action_property.call('$Type' => 'Forms$CallNanoflowClientAction',
                             'Nanoflow' => 'Demo.ClientAction'),
        action_property.call('$Type' => 'Forms$SignOutClientAction'),
        action_property.call('$Type' => 'Forms$UnknownAction')
      ].compact.join
      instance_double(Mxrb::Compiler::GenericWidgetBundleCompiler,
                      supported?: true, component_name: 'Custom', module_path: 'example/Custom',
                      render: "#{rendered}#{actions}")
    end
    allow(compiler).to receive(:nanoflow_reference).and_return('() => flow')
    expect(compiler.send(:render_custom_widget, 'Name' => 'generic'))
      .to include('child', 'callNanoflow', 'signOut')
  end

  it 'unwinds snippet scope stacks when child rendering raises' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    compiler = described_class.new(source)
    compiler.send(:prepare_compile, source.units_of('Forms$Page').first, 'p')
    snippet = Struct.new(:document).new({ 'Widgets' => [2, {}], 'Parameters' => [2] })
    compiler.instance_variable_set(:@snippet_index, { 'Demo.Broken' => snippet })
    allow(compiler).to receive(:children).and_raise(Mxrb::CompilationError, 'broken child')

    expect do
      compiler.send(:render_snippet_call, 'Name' => 'call', 'FormCall' => { 'Form' => 'Demo.Broken' })
    end.to raise_error(Mxrb::CompilationError, 'broken child')
    expect(compiler.instance_variable_get(:@snippet_scopes)).to be_empty
    expect(compiler.instance_variable_get(:@snippet_stack)).to be_empty
  end

  it 'covers fail-closed branches for menus, containers, actions, sources, and fields' do # rubocop:disable Metrics/BlockLength
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    allow(source).to receive(:units_of).and_call_original
    allow(source).to receive(:documents).and_call_original
    unit = source.units_of('Forms$Page').first
    compiler = described_class.new(source)
    compiler.send(:prepare_compile, unit, 'p')

    expect(compiler.send(:render_menu, { 'Name' => 'menu', 'MenuSource' => nil }, 'MenuBar'))
      .to include('mxrb-unsupported-widget')
    expect(compiler.send(:menu_items, '$Type' => 'Forms$MenuDocumentSource',
                                      'Menu' => 'Demo.Missing')).to be_nil
    expect(compiler.send(:menu_items, '$Type' => 'Forms$NavigationSource',
                                      'NavigationProfile' => 'Missing')).to be_nil
    expect(compiler.send(:render_snippet_call, 'Name' => 'missing',
                                               'FormCall' => { 'Form' => 'Demo.Missing' }))
      .to include('mxrb-unsupported-widget')
    expect(compiler.send(:menu_microflow_config, {
      '$Type' => 'Forms$MicroflowAction', 'MicroflowSettings' => {
        'Microflow' => 'Demo.ServerAction', 'ParameterMappings' => [2, {
          'Parameter' => 'Demo.ServerAction.Item', 'Expression' => '$Item'
        }]
      }
    })).to be_nil

    parameterized = {
      '$Type' => 'Forms$DivContainer', 'Name' => 'clickable', 'Widgets' => [],
      'OnClickAction' => { '$Type' => 'Forms$FormAction', 'FormSettings' => {
        'Form' => 'Demo.Home', 'ParameterMappings' => [2, {}]
      } }
    }
    expect(compiler.send(:render_container, parameterized)).to include('role')
    expect(compiler.send(:render_container, {
      '$Type' => 'Forms$DivContainer', 'Name' => 'unknown', 'Widgets' => [],
      'OnClickAction' => { '$Type' => 'Forms$UnknownAction' }
    })).not_to include('role')
    expect(compiler.send(:render_action_button, {
      '$Type' => 'Forms$ActionButton', 'Name' => 'legacy', 'Action' => parameterized['OnClickAction']
    })).not_to include('"disabled": true')
    expect(compiler.send(:open_page_config, parameterized['OnClickAction'])).to be_nil
    expect(compiler.send(:action_handler, {})).to be_nil

    expect(compiler.send(:create_object_config, {}, {
      '$Type' => 'Forms$CreateObjectClientAction', 'EntityRef' => { 'Entity' => 'Missing.Entity' },
      'PageSettings' => { 'Form' => 'Demo.Missing' }
    })).to be_nil
    missing_layout_page = Struct.new(:document).new({ 'FormCall' => { 'Form' => 'Demo.MissingLayout' } })
    expect(compiler.send(:page_location, missing_layout_page)).to eq('content')
    expect(compiler.send(:allowed_roles_for, 'Forms$Page', 'Demo.Missing')).to eq([])
    popup_layout = Struct.new(:module_name, :document).new('Demo', {
      'Name' => 'Popup', 'CanvasWidth' => 600
    })
    allow(source).to receive(:units_of).with('Forms$Layout').and_return([popup_layout])
    popup_page = Struct.new(:document).new({ 'FormCall' => { 'Form' => 'Demo.Popup' } })
    expect(compiler.send(:page_location, popup_page)).to eq('modal')
    allow(source).to receive(:documents).with('Security$ProjectSecurity').and_return([{
      'UserRoles' => [2,
                      { 'Name' => 'Admin', 'ModuleRoles' => [1, 'Demo.Admin'] },
                      { 'Name' => 'User', 'ModuleRoles' => [1, 'Demo.User'] }]
    }])
    role_unit = Struct.new(:module_name, :document).new('Demo', {
      'Name' => 'Secure', 'AllowedModuleRoles' => [1, 'Demo.Admin']
    })
    allow(source).to receive(:units_of).with('Forms$Page').and_return([role_unit])
    expect(compiler.send(:allowed_roles_for, 'Forms$Page', 'Demo.Secure')).to eq(['Admin'])
    allow(source).to receive(:documents).with('Security$ProjectSecurity').and_return([{
      'SecurityLevel' => 'CheckNothing',
      'UserRoles' => [2, { 'Name' => 'Admin' }, { 'Name' => '' }]
    }])
    expect(compiler.send(:allowed_roles_for, 'Forms$Page', 'Demo.Secure')).to eq(['Admin'])
    allow(source).to receive(:documents).with('Security$ProjectSecurity').and_return([])
    expect(compiler.send(:allowed_roles_for, 'Forms$Page', 'Demo.Secure')).to eq([])

    invalid_mapping = { 'Parameter' => '', 'Expression' => 'invalid' }
    expect(compiler.send(:nanoflow_argument_map, 'ParameterMappings' => [2, invalid_mapping])).to be_nil
    expect(compiler.send(:nanoflow_argument, invalid_mapping)).to be_nil
    compiler.instance_variable_set(:@list_scopes, [{ scope: 'scope', entity: 'Demo.Item' }])
    expect(compiler.send(:data_view_object_property, {
      'Name' => 'child', 'DataSource' => { 'EntityRef' => { 'Steps' => [2, {
        'Association' => 'Demo.Item_Child', 'DestinationEntity' => 'Demo.Child'
      }] } }
    }, 'child')).to include('AssociationObjectProperty')
    compiler.instance_variable_set(:@list_scopes, [])
    expect(compiler.send(:data_view_object_property, {
      'Name' => 'flow', 'DataSource' => {
        '$Type' => 'Forms$MicroflowSource', 'MicroflowSettings' => { 'Microflow' => 'Demo.ServerAction' }
      }
    }, 'flow')).to include('MicroflowObjectProperty')
    expect(compiler.send(:association_object_property, 'scope', '', 'child'))
      .not_to include('operationId')
    expect(compiler.send(:microflow_object_property, {
      'MicroflowSettings' => { 'Microflow' => '' }
    }, { 'Name' => 'child' }, 'scope')).to be_nil
    expect(compiler.send(:flow_return_entity, '$Type' => 'Forms$MicroflowSource',
                                              'MicroflowSettings' => { 'Microflow' => 'Demo.Missing' })).to eq('')

    unsupported_source = instance_double(Mxrb::Compiler::WebListDataSource, supported?: false, entity: '')
    allow(Mxrb::Compiler::WebListDataSource).to receive(:new).and_return(unsupported_source)
    expect(compiler.send(:render_list_view, '$Type' => 'Forms$ListView', 'Name' => 'bad'))
      .to include('mxrb-unsupported-widget')
    association = instance_double(
      Mxrb::Compiler::WebListDataSource,
      xpath?: false, association?: true, association_path: 'Demo.Item_Parent/Demo.Parent'
    )
    compiler.instance_variable_set(:@list_scopes, [])
    compiler.instance_variable_set(:@data_view_scopes, [])
    expect(compiler.send(:list_view_property, { 'Name' => 'items' }, 'key', association)).to be_nil
    microflow = instance_double(
      Mxrb::Compiler::WebListDataSource, xpath?: false, association?: false, microflow?: true
    )
    allow(compiler).to receive(:microflow_argument_map).and_return(nil)
    expect(compiler.send(:list_view_property, { 'Name' => 'items' }, 'key', microflow)).to be_nil
    nanoflow = instance_double(
      Mxrb::Compiler::WebListDataSource,
      xpath?: false, association?: false, microflow?: false, nanoflow_name: 'Demo.Missing'
    )
    allow(compiler).to receive(:nanoflow_reference).and_return(nil)
    expect(compiler.send(:list_view_property, { 'Name' => 'items' }, 'key', nanoflow)).to be_nil
    supported_without_value = instance_double(
      Mxrb::Compiler::WebListDataSource,
      supported?: true, entity: 'Demo.Item', xpath?: false, association?: false,
      microflow?: false, nanoflow_name: 'Demo.Missing'
    )
    allow(Mxrb::Compiler::WebListDataSource).to receive(:new).and_return(supported_without_value)
    allow(compiler).to receive(:nanoflow_reference).and_return(nil)
    expect(compiler.send(:render_list_view, '$Type' => 'Forms$ListView', 'Name' => 'missingFlow'))
      .to include('mxrb-unsupported-widget')

    invalid_field_renderers = %i[
      render_text_area render_radio_button_group render_file_manager render_date_picker render_check_box
    ]
    invalid_field_renderers.each do |method|
      expect(compiler.send(method, { '$Type' => 'Forms$Unknown', 'Name' => method.to_s }))
        .to include('mxrb-unsupported-widget')
    end
    compiler.instance_variable_set(:@data_view_scopes, [{ scope: 'scope', entity: 'Demo.Item' }])
    expect(compiler.send(:render_file_manager, { 'Name' => 'download', 'Type' => 'Download' }))
      .to include('"widgetType": "download"')

    expect(compiler.send(:custom_widget_identifier, 'Object' => {})).to eq('CustomWidgets$CustomWidget')
    allow(source).to receive(:document_index).and_return({
      'schema' => { 'ObjectType' => { '$ID' => 'other' } }
    })
    expect(compiler.send(:custom_widget_identifier, 'Object' => { 'TypePointer' => 'missing' }))
      .to eq('CustomWidgets$CustomWidget')
    allow(source).to receive(:document_index).and_return({
      'schema' => { 'ObjectType' => { '$ID' => 'object' }, 'WidgetId' => 'Vendor.Widget' }
    })
    expect(compiler.send(:custom_widget_identifier, 'Object' => { 'TypePointer' => 'object' }))
      .to eq('Vendor.Widget')
    allow(source).to receive(:document_index).and_return({
      'schema' => { 'ObjectType' => { '$ID' => 'object' }, 'WidgetId' => '' }
    })
    expect(compiler.send(:custom_widget_identifier, 'Object' => { 'TypePointer' => 'object' }))
      .to eq('CustomWidgets$CustomWidget')
    compiler.instance_variable_set(:@generic_widgets, nil)
    %i[
      @uses_data_grid @uses_form_widgets @uses_gallery @uses_bound_text @uses_tab_container
      @uses_image @uses_conditional @uses_dynamic_class @uses_list_view
    ].each { compiler.instance_variable_set(_1, false) }
    compiler.instance_variable_set(:@uses_list_view, false)
    compiler.instance_variable_set(:@uses_layout_widgets, true)
    expect(compiler.send(:widget_imports)).to include('ScrollContainer')
    compiler.instance_variable_set(:@layout_mode, true)
    compiler.instance_variable_set(:@nanoflow_programs, double(declarations: ''))
    allow(compiler).to receive(:parent_layout_name).and_return('')
    expect(compiler.send(:layout_module_source, '[]')).to include('Object.assign({}, {}')
    allow(compiler).to receive(:parent_layout_name).and_return('Demo.Shell')
    expect(compiler.send(:layout_module_source, '[]')).to include('Object.assign({}, parentContent')
    allow(compiler).to receive(:parent_layout_name).and_call_original
    compiler.instance_variable_set(:@layout_mode, false)
    compiler.instance_variable_set(:@unit, unit)
    shell = Struct.new(:module_name, :document).new('Demo', { 'Name' => 'Shell' })
    allow(source).to receive(:units_of).with('Forms$Layout').and_return([shell])
    allow(source).to receive(:web_layout?).and_return(false)
    expect(compiler.send(:parent_layout_name)).to eq('')
    expect(compiler.send(:action_handler, '$Type' => '')).to be_nil
  end
end

RSpec.describe Mxrb::Compiler::ImageBundleCompiler do
  def image_property_type(id, key, type)
    { '$ID' => id, 'PropertyKey' => key, 'ValueType' => { 'Type' => type } }
  end

  def image_property(type, **values)
    { 'TypePointer' => type, 'Value' => { 'PrimitiveValue' => '' }.merge(values.transform_keys(&:to_s)) }
  end

  def image_text(value, language = 'en_US')
    { 'Template' => { 'Items' => [3, { 'LanguageCode' => language, 'Text' => value }] } }
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def image_compiler(datasource: 'image', image: 'Demo.Assets.Logo', widget_id: described_class::WIDGET_ID)
    types = [
      image_property_type('datasource', 'datasource', 'Enumeration'),
      image_property_type('image', 'imageObject', 'Image'),
      image_property_type('responsive', 'responsive', 'Boolean'),
      image_property_type('width', 'width', 'Integer'),
      image_property_type('alt', 'alternativeText', 'TextTemplate'),
      image_property_type('url', 'imageUrl', 'TextTemplate'),
      image_property_type('ignored', 'onClick', 'Action')
    ]
    schema = {
      '$ID' => 'widget-type', 'WidgetId' => widget_id,
      'ObjectType' => { '$ID' => 'object-type', 'PropertyTypes' => [2, *types] }
    }
    image_unit = Struct.new(:module_name, :document, keyword_init: true).new(module_name: 'Demo', document: {
      'Name' => 'Assets', 'Images' => [2, {
        'Name' => 'Logo', 'Image' => BSON::Binary.new("\x89PNG\r\n\x1A\nimage".b)
      }]
    })
    source = instance_double(Mxrb::Compiler::SourceModel, documents: [schema, ['nested']])
    allow(source).to receive(:units_of).with('Images$ImageCollection').and_return([image_unit])
    widget = {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'logo',
      'Appearance' => { 'Class' => 'brand' },
      'Object' => { 'TypePointer' => 'object-type', 'Properties' => [
        2, image_property('datasource', PrimitiveValue: datasource),
        image_property('image', Image: image), image_property('responsive', PrimitiveValue: 'true'),
        image_property('width', PrimitiveValue: '80'),
        image_property('alt', TextTemplate: image_text('Logo')),
        image_property('url', TextTemplate: image_text('Adresse', 'de_DE')),
        image_property('ignored'), image_property('missing')
      ] }
    }
    described_class.new(source, 'Demo.Home', widget)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  it 'compiles the official static Image widget and its primitive properties' do
    compiler = image_compiler
    expect(compiler).to be_supported
    expect(compiler.render).to include(
      'React.createElement($Image', 'WebStaticImageProperty', 'Demo$Assets$Logo.png',
      '"responsive": true', '"width": 80', 'Logo', 'Adresse', 'mx-name-logo brand'
    )
    expect(described_class.javascript(described_class.raw('raw'))).to eq('raw')
    expect(described_class.javascript([true, nil])).to eq('[true, null]')
    expect(described_class.javascript(test: 1)).to eq('{ "test": 1 }')
    expect(described_class.unit(nil)).to eq('auto')
    expect(described_class.number(nil, 7)).to eq(7)
    expect(compiler.send(:translated_text, nil)).to eq('')
    compiler.instance_variable_set(:@values, {})
    expect(compiler.send(:primitive, 'missing')).to be_nil
    expect(compiler.send(:text_value, 'missing')).to eq('')
    expect(compiler.send(:image_uri)).to be_nil
    expect(compiler.send(:property_values, nil)).to eq({})
    compiler.instance_variable_set(:@index, {})
    expect(compiler).not_to be_supported

    populated = image_compiler
    page_compiler = Mxrb::Compiler::PageBundleCompiler.new(populated.instance_variable_get(:@source))
    page_compiler.instance_variable_set(:@qualified_name, 'Demo.Home')
    page_compiler.instance_variable_set(:@list_scopes, [])
    rendered = page_compiler.send(:render_custom_widget, populated.instance_variable_get(:@widget))
    expect(rendered).to include('React.createElement($Image')
    expect(page_compiler.send(:widget_imports))
      .to include('../widgets/com/mendix/widget/web/image/Image.mjs')
  end

  it 'rejects another widget, a dynamic source, and an unresolved image' do
    expect(image_compiler(widget_id: 'other')).not_to be_supported
    expect(image_compiler(datasource: 'imageUrl')).not_to be_supported
    missing = image_compiler(image: 'Demo.Assets.Missing')
    expect(missing).not_to be_supported
    expect(missing.send(:image_uri)).to be_nil
  end

  it 'compiles dynamic image URLs and optional actions while failing closed for malformed values' do
    compiler = image_compiler
    action = { '$Type' => 'Forms$MicroflowAction' }
    compiler.instance_variable_get(:@values)['onClick'] = ['Action', { 'Action' => action }]
    compiler.instance_variable_set(:@action_property, ->(value) { "ActionProperty(#{value['$Type']})" })
    expect(compiler).to be_supported
    expect(compiler.render).to include('ActionProperty(Forms$MicroflowAction)')

    compiler.instance_variable_set(:@action_property, nil)
    expect(compiler).not_to be_supported
    expect(compiler.send(:compiled_action)).to be_nil
    compiler.instance_variable_get(:@values)['onClick'] = ['Action', {
      'Action' => { '$Type' => 'Forms$NoAction' }
    }]
    expect(compiler.send(:compiled_action)).to be_nil

    compiler.instance_variable_get(:@values).delete('onClick')
    expect(compiler.send(:supported_action?)).to be(true)
    expect(compiler.send(:image_url_parameter)).to be_nil
    compiler.instance_variable_get(:@values).delete('imageUrl')
    expect(compiler.send(:image_url_parameter)).to be_nil
    compiler.instance_variable_get(:@values)['imageUrl'] = []
    expect(compiler.send(:image_url_parameter)).to be_nil

    compiler.instance_variable_set(:@scope, 'p.Demo.Home.context')
    compiler.instance_variable_get(:@values)['datasource'] = ['Enumeration', { 'PrimitiveValue' => 'imageUrl' }]
    compiler.instance_variable_get(:@values)['imageUrl'] = ['TextTemplate', {
      'TextTemplate' => { 'Parameters' => [2, {
        'AttributeRef' => {
          'Attribute' => 'Demo.Item.Picture', 'EntityRef' => { 'Steps' => [2, {
            'Association' => 'Demo.Parent_Item', 'DestinationEntity' => 'Demo.Item'
          }] }
        }
      }] }
    }]
    expect(compiler).to be_supported
    expect(compiler.render).to include('Demo.Parent_Item/Demo.Item/Picture')

    compiler.instance_variable_set(:@scope, nil)
    expect(compiler.send(:dynamic_image_url)).to be_nil
    compiler.instance_variable_get(:@values)['imageUrl'] = ['TextTemplate', { 'TextTemplate' => nil }]
    expect(compiler.send(:image_url_parameter)).to be_nil
  end
end

RSpec.describe Mxrb::Compiler::PageBundleBuilder do
  it 'replaces stale page sources and writes the support manifest' do
    Dir.mktmpdir do |root|
      mpr = File.join(root, 'Pages.mpr')
      Mxrb.define(mpr) do
        mendix_version '11.12.1'
        self.module(:Demo) { page(:Home) { text :caption, caption: 'Hello' } }
      end
      web = File.join(root, 'web')
      FileUtils.mkdir_p(File.join(web, 'pages'))
      File.write(File.join(web, 'pages', 'Stale.js'), 'stale')
      bundles = described_class.new(Mxrb::Compiler::SourceModel.read(mpr), web).build
      expect(bundles.map(&:qualified_name)).to contain_exactly(
        'Demo.Home', 'Demo.ApplicationLayout'
      )
      expect(File).not_to exist(File.join(web, 'pages', 'Stale.js'))
      expect(JSON.parse(File.read(File.join(web, 'mxrb-pages.json')))).to eq('Demo.Home' => [])
    end
  end
end

RSpec.describe Mxrb::Compiler::WidgetPackageExtractor do
  it 'extracts safe packages, ignores an absent widget directory, and rejects traversal' do
    Dir.mktmpdir do |root|
      web = File.join(root, 'web')
      expect(described_class.new(File.join(root, 'absent'), web).extract).to eq(0)
      widgets = File.join(root, 'widgets')
      FileUtils.mkdir_p(widgets)
      package = File.join(widgets, 'safe.mpk')
      Zip::File.open(package, create: true) do |zip|
        zip.get_output_stream('vendor/widget/Widget.mjs') { _1.write('export default {};') }
      end
      expect(described_class.new(root, web).extract).to eq(1)
      expect(File).to exist(File.join(web, 'widgets', 'vendor', 'widget', 'Widget.mjs'))

      unsafe = File.join(widgets, 'unsafe.mpk')
      allow(Zip::File).to receive(:open).with(unsafe).and_yield([
                                                                  instance_double(
                                                                    Zip::Entry, directory?: false,
                                                                                name: '../outside',
                                                                                get_input_stream: StringIO.new('x')
                                                                  )
                                                                ])
      expect { described_class.new(root, web).send(:extract_package, unsafe) }
        .to raise_error(Mxrb::CompilationError, /unsafe widget/)
    end
  end

  it 'reports corrupt widget archives' do
    Dir.mktmpdir do |root|
      widgets = File.join(root, 'widgets')
      FileUtils.mkdir_p(widgets)
      File.write(File.join(widgets, 'broken.mpk'), 'broken')
      expect { described_class.new(root, File.join(root, 'web')).extract }
        .to raise_error(Mxrb::CompilationError, /invalid widget package/)
    end
  end

  it 'extracts root-level JavaScript, CSS, and assets beside a root runtime module' do
    Dir.mktmpdir do |root|
      widgets = File.join(root, 'widgets')
      web = File.join(root, 'web')
      FileUtils.mkdir_p(widgets)
      Zip::File.open(File.join(widgets, 'root.mpk'), create: true) do |zip|
        zip.get_output_stream('Widget.mjs') { _1.write('export default {};') }
        zip.get_output_stream('Widget.css') { _1.write('.widget {}') }
        zip.get_output_stream('assets/icon.svg') { _1.write('<svg/>') }
        zip.get_output_stream('ignored.xml') { _1.write('<widget/>') }
      end

      expect(described_class.new(root, web).extract).to eq(3)
      expect(File).to exist(File.join(web, 'widgets', 'Widget.css'))
      expect(File).to exist(File.join(web, 'widgets', 'assets', 'icon.svg'))
      expect(File).not_to exist(File.join(web, 'widgets', 'ignored.xml'))
      expect(File).not_to exist(File.join(web, 'mxrb-widgets.css'))
    end
  end
end
# rubocop:enable Metrics/BlockLength
