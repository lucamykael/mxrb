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
    unit = source.units_of('Forms$Page').first
    unit.document['Appearance'] = { 'Class' => 'page-identity' }
    bundle = described_class.new(source).compile(unit)
    expect(bundle.qualified_name).to eq('Demo.Home')
    expect(bundle.source).to include(
      'PageFragment', 'export const title = "Welcome"', '"Main":',
      'mx-name-body body', '"Hello"',
      'export const classes = "mxrb-application-shell page-identity"'
    )
    expect(bundle.source).not_to include('Demo.Shell.Main')
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
      'window.mx?.ui?.openForm2?.("Demo.Home", {}, undefined, undefined'
    )
    expect(bundle.unsupported_widgets).to be_empty
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
    expect(compiler.send(:render_container, form_container)).to include('onClick', 'role')
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
    arguments << { 'Parameter' => 'Other.Main', 'Widgets' => [] }
    expect { described_class.new(source).compile(unit) }
      .to raise_error(Mxrb::CompilationError, /duplicate page slot "Main"/)
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
      expect(bundles.map(&:qualified_name)).to eq(['Demo.Home'])
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
end
# rubocop:enable Metrics/BlockLength
