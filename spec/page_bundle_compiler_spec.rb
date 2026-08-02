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
    bundle = described_class.new(source).compile(source.units_of('Forms$Page').first)
    expect(bundle.qualified_name).to eq('Demo.Home')
    expect(bundle.source).to include(
      'PageFragment', 'export const title = "Welcome"', '"Main":',
      'mx-name-body body', '"Hello"'
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
        'Parameters' => [2, { 'AttributeRef' => { 'Attribute' => 'Demo.Item.Duration' } }]
      }
    }

    output = compiler.send(:render_text, widget)
    expect(output).to include(
      'React.createElement($MxrbFormattedText', '"template": "{1} day(s)"',
      '"value": AttributeProperty', '"attribute": "Duration"'
    )
    expect(compiler.send(:widget_imports)).to include(
      'value?.displayValue', 'template.split("{1}")', '$MxrbFormattedText'
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
      'Widgets' => [2, text_box, text_box.merge(
        'Name' => 'code', 'IsPasswordBox' => false, 'MaxLengthCode' => -1,
        'Autocomplete' => true, 'SubmitBehaviour' => 'OnEndEditing',
        'AttributeRef' => { 'Attribute' => 'Demo.Item.Code' }
      )],
      'FooterWidgets' => [2, *actions]
    }
    unit.document['FormCall']['Arguments'].find { _1.is_a?(Hash) }['Widgets'] = [2, data_view]

    compiler = described_class.new(source)
    bundle = compiler.compile(unit)
    expect(bundle.source).to include(
      '$DataView', '$TextBox', '$FormGroup', '$ActionButton',
      'AssociationObjectProperty({ scope: "$Item"',
      'AttributeProperty({ "scope": "p.Demo.Home.editor"',
      '"isPassword": true', '"maxLength": 42', '"autocomplete": "off"',
      '"submitWhileEditing": true', 'TextProperty({ value: "Name" })',
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
