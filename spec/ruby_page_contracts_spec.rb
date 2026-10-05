# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/ruby_app/presentation_exporter'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Page invocation contracts' do
  let(:contracts) { Mxrb::RubyApp::PresentationContracts }

  it 'uses typed Ruby page declarations for runtime and native parameter, variable and popup contracts' do
    page = Class.new(Mxrb::RubyApp::Page)
    page.mendix_name('App.Editor')
    definition = page.native do
      layout 'App.PopupLayout'
      parameter :Caption, type: :string, required: false, default_value: "'Default'"
      parameter :Item, entity: 'App.Item'
      parameter :Status, enumeration: 'App.Status'
      variable :Draft, type: :string, default_value: '$Caption'
      variable :Count, type: :long, default_value: '0'
      popup! mode: :popup, width: 520, height: 0, resizable: false, close_action: 'App.Editor.Cancel'
      autofocus :disabled
    end
    expect(page.presentation_contract.dig(:parameters, 0, 'type', 'kind')).to eq('string')
    expect(page.presentation_contract.dig(:variables, 1, 'type', 'kind')).to eq('long')
    expect(page.presentation_contract[:popup]).to include(mode: 'popup', width: 520, height: 0)
    writer = Mxrb::Writer.allocate
    writer.instance_variable_set(:@definition, version: '11.12.1')
    document = writer.send(:page_doc, definition, 'App')
    encoded = Mxrb::Forms::MprCodec.new.encode(Mxrb::Forms::MprCodec.new.decode(document.reject do |key, _|
      key.start_with?('__mxrb_')
    end))
    expect(contracts.parameters(encoded).map { _1.fetch('type').fetch('kind') }).to eq(%w[string object enumeration])
    expect(contracts.variables(encoded).map { _1.fetch('name') }).to eq(%w[Draft Count])
    expect(encoded).to include('PopupWidth' => 520, 'PopupHeight' => 0, 'PopupResizable' => false,
                               'PopupCloseAction' => 'App.Editor.Cancel', 'Autofocus' => 'Off')
    previous = document.merge('Parameters' => [3], 'Variables' => [2], 'Autofocus' => 'All',
                              'PopupCloseAction' => '')
    merged = writer.send(:merge_existing_document, previous, document)
    expect(merged.values_at('Parameters', 'Variables', 'Autofocus', 'PopupCloseAction'))
      .to eq(document.values_at('Parameters', 'Variables', 'Autofocus', 'PopupCloseAction'))
    expect(contracts.declared_type(type: 'date_time')).to eq('kind' => 'datetime')
    [{}, { type: 'binary' }, { type: 'object' }, { type: 'list' }, { type: 'enumeration' }].each do |invalid|
      expect { contracts.declared_type(invalid) }.to raise_error(ArgumentError)
    end
    builder = Mxrb::Dsl::PageBuilder.new('Bad')
    expect { builder.popup!(mode: :window) }.to raise_error(ArgumentError, /mode/)
    expect { builder.popup!(width: -1) }.to raise_error(ArgumentError, /dimensions/)
    expect { builder.autofocus(:unknown) }.to raise_error(ArgumentError, /autofocus/)
  end

  it 'exports typed optional parameters, local defaults and layout-based modeless popup properties' do
    document = {
      'Parameters' => [3, { 'Name' => 'Label', 'IsRequired' => false, 'DefaultValue' => "'Hello'",
                            'ParameterType' => { '$Type' => 'DataTypes$StringType' } }],
      'Variables' => [2, { 'Name' => 'Draft', 'DefaultValue' => '$Label',
                           'VariableType' => { '$Type' => 'DataTypes$StringType' } }],
      'FormCall' => { 'Form' => 'App.PopupLayout' }, 'PopupWidth' => 480, 'PopupHeight' => 320,
      'PopupResizable' => false, 'PopupCloseAction' => 'App.Popup.Cancel', 'Autofocus' => 'Off'
    }
    result = contracts.page(document, layouts: { 'App.PopupLayout' => { 'Content' => { 'LayoutType' => 'Popup' } } })
    expect(result.dig(:parameters, 0, 'type', 'kind')).to eq('string')
    expect(result.dig(:parameters, 0, 'required')).to be(false)
    expect(result.dig(:variables, 0, 'default')).to eq('$Label')
    expect(result[:popup]).to include(mode: 'popup', width: 480, height: 320, resizable: false,
                                      close_action: 'App.Popup.Cancel')
    expect(contracts.page({})).to eq({})
    expect(contracts.page({ 'PopupHeight' => 200 }).dig(:popup, :mode)).to eq('modal')
    modal = contracts.page({ 'LayoutCall' => { 'Layout' => 'App.Modal' } },
                           layouts: { 'App.Modal' => { 'LayoutType' => 'ModalPopup' } })
    expect(modal.dig(:popup, :mode)).to eq('modal')
    expect(contracts.items(nil)).to eq([])
    expect(contracts.items([1, 2])).to eq([2])
    expect(contracts.items(['item'])).to eq(['item'])
    expect(contracts.data_type(nil)).to eq('kind' => 'unknown')
    expect(eval(contracts.source(result))).to eq(result) # rubocop:disable Security/Eval
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, 'contracts.rb'), contracts.source(result))
      expect(Mxrb::PublicSourceAudit.new(directory)).to be_clean
    end
  end

  it 'round-trips client action settings and return mappings' do
    writer = Mxrb::Writer.allocate
    parser = Mxrb::Model::Page.allocate
    source = { kind: :local_variable, name: 'Label' }
    settings = {
      disabled_during_execution: false, close_count: '2',
      confirmation: { question: 'Continue?', proceed: 'Yes', cancel: 'No' },
      progress: 'Blocking', progress_message: 'Working', asynchronous: true,
      outputs: [{ source:, expression: 'toString($ActionReturnValue)', attribute: 'App.Item.Name',
                  source_attribute: 'App.Item.Other' }]
    }
    %i[microflow nanoflow].each do |kind|
      encoded = writer.send(:client_action_doc, kind:, handler: 'App.Run', settings:)
      decoded = parser.send(:parse_action, encoded)
      expect(decoded[:settings]).to eq(settings)
    end
    asynchronous = writer.send(:client_action_doc, kind: :microflow, handler: 'App.Run',
                                                   settings: { asynchronous: true })
    expect(parser.send(:parse_action, asynchronous).fetch(:settings))
      .to include(asynchronous: true, progress: 'NonBlocking')
    event = { kind: :action, handler: 'delete', close_page: false,
              settings: { source: { kind: :widget, name: 'App.Home.Rows', use_all_pages: true } } }
    expect(parser.send(:parse_action, writer.send(:client_action_doc, event))).to eq(event)
    page = parser.send(:parse_action, writer.send(:client_action_doc, kind: :page, handler: 'App.Detail',
                                                                      settings: { title: 'Overridden' }))
    expect(page.dig(:settings, :title)).to eq('Overridden')
  end

  it 'round trips sign out, static and attribute links, create-object pages and close-page expressions' do
    writer = Mxrb::Writer.allocate
    parser = Mxrb::Model::Page.allocate
    events = [
      { kind: :action, handler: 'sign_out' },
      { kind: :action, handler: 'open_link', settings: { link: { type: 'Call', value: '+123' } } },
      { kind: :action, handler: 'open_link',
        settings: { link: { type: 'Web', value: '', attribute: 'App.Item.Url' } } },
      { kind: :action, handler: 'create_object', arguments: {},
        settings: { create: { entity: 'App.Item', page: 'App.Editor' } } },
      { kind: :action, handler: 'close_page', settings: { close_count: '2' } }
    ]
    events.each do |event|
      expect(parser.send(:parse_action, writer.send(:client_action_doc, event))).to eq(event)
    end
    exporter = Mxrb::RubyApp::Exporter.allocate
    widgets = [{ 'name' => 'call', 'type' => 'button', 'events' => [
      { 'event' => 'on_click', 'kind' => 'microflow', 'handler' => 'App.Run', 'settings' => {
        'confirmation' => { 'question' => 'Continue?' },
        'outputs' => [{ 'source' => { 'kind' => 'local_variable', 'name' => 'Label' },
                        'expression' => '$ActionReturnValue' }]
      } }
    ] }]
    code = exporter.send(:runtime_widget_dsl_source, widgets, 0)
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.instance_eval(code)
    expect(tree.widgets.first.dig('events', 0, 'settings', 'outputs', 0, 'expression')).to eq('$ActionReturnValue')
  end

  it 'preserves association creation, selection sources and optional outputs in editable Ruby' do
    writer = Mxrb::Writer.allocate
    parser = Mxrb::Model::Page.allocate
    exporter = Mxrb::RubyApp::Exporter.allocate
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.button('Create') do
      on_click action: :create_object, settings: client_settings(
        create: action_create(entity: 'App.Item', association: 'App.Owner_Items')
      )
    end
    tree.button('Link') do
      on_click action: :open_link, settings: client_settings(link: action_link(value: 'https://example.org'))
    end
    tree.button('Run') do
      on_click microflow: 'App.Run', settings: client_settings(
        source: page_variable('Rows', kind: :widget),
        outputs: [action_output(source: page_variable('Result', kind: :local_variable))]
      )
    end
    source = exporter.send(:runtime_widget_dsl_source, tree.widgets, 0)
    restored = Mxrb::RubyApp::Page::WidgetTree.new
    restored.instance_eval(source)
    expect(restored.widgets).to eq(tree.widgets)
    creation = { kind: :action, handler: 'create_object', settings: {
      create: { entity: 'App.Item', association: 'App.Owner_Items' }
    } }
    expect(parser.send(:parse_action, writer.send(:client_action_doc, creation)))
      .to eq(creation.merge(arguments: {}))
    direct = creation.merge(settings: { create: { entity: 'App.Item' } })
    expect(parser.send(:parse_action, writer.send(:client_action_doc, direct)))
      .to eq(direct.merge(arguments: {}))
    expect(parser.send(:parse_action, nil)).to be_nil
    expect(parser.send(:parse_action_base, nil)).to be_nil
    creation[:settings][:create][:page] = 'App.Editor'
    creation[:arguments] = { 'Label' => "'New'" }
    expect(parser.send(:parse_action, writer.send(:client_action_doc, creation))).to eq(creation)
    expect(parser.send(:parse_action, { '$Type' => 'Forms$CreateObjectClientAction' }))
      .to eq(kind: :action, handler: 'create_object', arguments: {}, settings: { create: {} })
    output = { kind: :microflow, handler: 'App.Run', settings: {
      outputs: [{ source: { kind: :local_variable, name: 'Result' }, expression: '' }]
    } }
    expect(parser.send(:parse_action, writer.send(:client_action_doc, output)))
      .to eq(output.merge(handler: 'Run', arguments: {}))
  end

  it 'exports local-variable inputs and typed snippet variables without losing their contracts' do
    page = Class.new(Mxrb::RubyApp::Page)
    page.mendix_name('App.Editor')
    definition = page.native do
      variable :Item, entity: 'App.Item'
      variable :State, enumeration: 'App.State'
      variable :Draft, type: :string, default_value: "'Draft'"
      text_box :DraftInput, source_variable: page_variable('App.Editor.Draft', kind: :local_variable),
                            aria_label: 'Draft label'
      sidebar_toggle :Toggle, caption: 'Menu', tooltip: 'Open menu'
      menu_bar :Navigation, menu: '', navigation_profile: 'Responsive'
    end
    writer = Mxrb::Writer.allocate
    writer.instance_variable_set(:@definition, version: '11.12.1')
    document = writer.send(:page_doc, definition, 'App')
    parser = Mxrb::Model::Page.allocate
    parser.decode(document)
    exporter = Mxrb::RubyApp::Exporter.allocate
    widgets = parser.widgets.map { exporter.send(:widget_manifest, _1) }
    code = exporter.send(:runtime_widget_dsl_source, widgets, 0)
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.instance_eval(code)
    expect(tree.widgets.first.dig('options', 'source_variable'))
      .to include('kind' => 'local_variable', 'name' => 'Draft')
    expect(tree.widgets.first.dig('options', 'max_length')).to eq(0)
    expect(tree.widgets[1]).to include('type' => 'sidebar_toggle')
    expect(tree.widgets[1].fetch('options')).to include('caption' => 'Menu', 'tooltip' => 'Open menu')
    expect(tree.widgets[2].fetch('options')).to include('navigation_profile' => 'Responsive')
    native_exporter = Mxrb::Exporter.allocate
    restored = Mxrb::Dsl::PageBuilder.new('Editor')
    restored.instance_eval(native_exporter.send(:render_widget, parser.widgets[1], 0).join("\n"))
    expect(restored.to_h.fetch(:widgets).first.fetch(:options))
      .to include(caption: 'Menu', tooltip: 'Open menu', button_style: 'default')
    expect(page.presentation_contract[:variables].map { _1.fetch('type').fetch('kind') })
      .to eq(%w[object enumeration string])
    Mxrb::RubyApp::Presentation.snippet('App.Details', variables: page.presentation_contract[:variables])
    expect(Mxrb::RubyApp::Registry.fetch(:presentation, 'App.Details').fetch(:variables))
      .to eq(page.presentation_contract[:variables])
  ensure
    Mxrb::RubyApp::Registry.reset!
  end

  it 'retains dynamic and literal titles, location and context in exported nanoflow navigation' do
    exporter = Mxrb::RubyApp::Exporter.allocate
    text = { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Editor' }] }
    action = { '$Type' => 'Microflows$ShowFormAction', 'NumberOfPagesToClose' => '2',
               'FormObjectVariable' => 'Item', 'FormSettings' => {
                 'Form' => 'App.Editor', 'Location' => 'ModalPopup', 'TitleOverride' => text
               } }
    expect(exporter.send(:nanoflow_action, action).fetch('settings'))
      .to include('close' => '2', 'context' => 'Item', 'location' => 'modal', 'title' => 'Editor')
    action['FormSettings']['TitleOverride'] = {
      'Text' => { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Editor {1}' }] },
      'Parameters' => [2, { 'Expression' => '$Name' }]
    }
    expect(exporter.send(:nanoflow_action, action).fetch('settings'))
      .to include('title' => 'Editor {1}', 'title_parameters' => ['$Name'])
  end

  it 'retains input presentation and action settings in the Mendix-mode Ruby projection' do
    exporter = Mxrb::Exporter.allocate
    field = { type: :text_box, name: 'Draft', events: [], options: {
      placeholder: 'Enter a name', aria_label: 'Name', max_length: 40, editable: 'never',
      password: false, tab_index: 3, source_variable: { kind: :local_variable, name: 'App.Editor.Draft' },
      editability: { expression: '$Allowed' }
    } }
    button_widget = { type: :button, name: 'Run', options: { caption: 'Run', button_style: 'success' },
                      events: [{ event: :on_click, kind: :microflow, handler: 'App.Run',
                                 settings: { disabled_during_execution: false }, arguments: {} }] }
    builder = Mxrb::Dsl::PageBuilder.new('Editor')
    [field, button_widget].each { builder.instance_eval(exporter.send(:render_widget, _1, 0).join("\n")) }
    widgets = builder.to_h.fetch(:widgets)
    expect(widgets.first.fetch(:options)).to include(field.fetch(:options))
    expect(widgets.last.fetch(:options)).to include(button_style: :success)
    expect(widgets.last.fetch(:events).first.fetch(:settings)).to eq(disabled_during_execution: false)
    field[:options][:editability] = { roles: ['App.Editor'] }
    builder.instance_eval(exporter.send(:render_widget, field, 0).join("\n"))
    expect(builder.to_h.fetch(:widgets).last.dig(:options, :editability)).to eq(roles: ['App.Editor'])
    parser = Mxrb::Model::Page.allocate
    legacy = { '$Type' => 'Forms$TextBox', 'Name' => 'Name', 'Placeholder' => 'Legacy hint' }
    parser.decode('Widgets' => [2, legacy])
    expect(parser.widgets.first.dig(:options, :placeholder)).to eq('Legacy hint')
    parser.decode('Widgets' => [2, legacy.merge('PlaceholderTemplate' => 'Modern hint')])
    expect(parser.widgets.first.dig(:options, :placeholder)).to eq('Modern hint')
  end

  it 'accepts exported grid behavior inside nested widget builders and rejects unknown options' do
    exporter = Mxrb::RubyApp::Exporter.allocate
    widget = { 'name' => 'Items', 'type' => 'data_grid', 'events' => [], 'options' => {
      'entity' => 'App.Item', 'page_size' => 20, 'presentation' => 'native',
      'columns_resizable' => true, 'columns_draggable' => true, 'columns_hidable' => false,
      'columns' => [{ 'name' => 'Name', 'attribute' => 'Name', 'sortable' => true }]
    } }
    builder = Mxrb::Dsl::PageBuilder.new('Editor')
    builder.instance_eval(exporter.send(:runtime_widget_call_source, widget, 0, generic_sink: true))
    expect(JSON.parse(JSON.generate(builder.to_h.fetch(:widgets).first))).to eq(widget)
    expect { builder.data_grid('Bad', missing_option: true) }.to raise_error(ArgumentError, /unknown data grid/)
  end

  it 'generates distinct native popup layouts and retains modes through export and compilation' do
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'Popups.mpr')
      target = File.join(directory, 'ruby')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module :App do
          page(:Home) { text 'Home' }
          page(:Editor) { popup! mode: :modal, width: 520, height: 0 }
          page(:Child) { popup! mode: :modal }
          page(:Floating) { popup! mode: :popup, width: 0, height: 0 }
        end
      end
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      application = Mxrb::RubyApp::Application.new(target)
      expect(application.page('App.Home')[:popup]).to be_nil
      expect(application.page('App.Editor')[:popup]).to include(mode: 'modal', width: 520, height: 0)
      expect(application.page('App.Floating')[:popup]).to include(mode: 'popup', width: 0, height: 0)
      application.close
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      Mxrb::RubyApp.compile(target, rebuilt)
      Mxrb.open(rebuilt) do |project|
        layouts = project.modules.find { _1.name == 'App' }.presentation_documents
                         .select { _1[:type] == 'Forms$Layout' }.to_h { [_1[:name], _1.fetch(:doc)] }
        expect(layouts.keys).to contain_exactly('ApplicationLayout', 'ModalPopupLayout', 'PopupLayout')
        expect(layouts.fetch('ModalPopupLayout').dig('Content', 'LayoutType')).to eq('ModalPopup')
        expect(layouts.fetch('PopupLayout').dig('Content', 'LayoutType')).to eq('Popup')
        writer = Mxrb::Writer.allocate
        writer.instance_variable_set(:@definition, version: '7.17.0')
        expect(writer.send(:legacy_layout_doc, layouts.fetch('PopupLayout'))['LayoutType']).to eq('Popup')
      end
    ensure
      application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end
end
# rubocop:enable Metrics/BlockLength
