# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'mxrb/ruby_app/presentation_exporter'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Advanced standalone presentation contracts' do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'keeps a newly authored page usable when its default layout is not registered' do
    page = Class.new(Mxrb::RubyApp::Page) do
      mendix_name 'App.NewPage'
      native { text :Greeting, caption: 'Hello' }
    end
    result = Mxrb::RubyApp::Presentation.page(page)
    expect(result[:layout]).to be_nil
    expect(result[:widgets]).to eq(page.widgets)
  end

  it 'renders the declared native page layout with its Main slot through the page API' do
    presentation = Mxrb::RubyApp::Presentation
    presentation.layout('App.Shell') do
      container :Header, class_name: 'region-topbar' do
        text :Brand, caption: 'Shared theme header'
      end
      placeholder :Main, parameter: 'Main'
    end
    page = Class.new(Mxrb::RubyApp::Page) do
      mendix_name 'App.Home'
      native do
        layout 'App.Shell'
        text :Greeting, caption: 'Page content'
      end
    end
    result = Mxrb::RubyApp::Application.allocate.page('App.Home')
    expect(result[:layout]).to eq('App.Shell')
    expect(result[:widgets].map { _1['name'] || _1[:name] }).to eq(%w[Header Greeting])
    expect(result[:widgets].first.dig('options', 'class')).to eq('region-topbar')
    expect(page.widgets.map { _1[:name] || _1['name'] }).to eq(['Greeting'])
  end

  it 'keeps empty declarations, legacy file policy fallback and frontend child definitions supported' do
    presentation = Mxrb::RubyApp::Presentation
    presentation.layout('Empty')
    presentation.menu('Plain') { item 'No action' }
    expect(presentation.compose({ type: :placeholder, name: 'Empty' })).to eq([])
    expect { presentation.compose({ type: 'layout', options: { layout: 'Plain' } }) }
      .to raise_error(ArgumentError, /missing layout/)
    expect { presentation.compose({ type: 'layout', options: { layout: 'Empty' } }, stack: Array.new(32, 'parent')) }
      .to raise_error(ArgumentError, /recursive layout/)
    exporter = Mxrb::RubyApp::Exporter.allocate
    declarations = []
    exporter.send(:frontend_widget_jsx, { 'type' => 'container', 'name' => 'Root', 'children' => [
                    { 'type' => 'text', 'name' => 'Child' }
                  ] }, [0], declarations, 0)
    expect(declarations.join).to include('widget0_0', '"children": [widget0_0]')
    exporter.instance_variable_set(:@module_manifests, [{ 'pages' => [{ 'name' => 'Empty', 'widgets' => [] }] }])
    expect(exporter.send(:frontend_types)).to include('EmptyWidgetName = never')
    resources = Mxrb::RubyApp::PresentationExporter.new(exporter, nil)
    expect(resources.send(:menu_source, [{ caption: 'Plain' }], 0)).to eq('item "Plain"')
    expect(resources.send(:menu_items, [{ caption: 'No document' }], [], 'App').first.fetch(:caption))
      .to eq('No document')
    expect(resources.send(:menu_action, { '$Type' => 'Forms$ClosePageClientAction' }, 'App'))
      .to include(kind: :action)
    expect(resources.send(:menu_action, { '$Type' => 'Forms$MicroflowAction', 'Microflow' => 'Run' }, 'App'))
      .to include(handler: 'App.Run')
    expect(resources.send(:menu_action, { '$Type' => 'Forms$CallNanoflowClientAction', 'Nanoflow' => 'Other.Run' },
                          'App'))
      .to include(handler: 'Other.Run')
  end

  it 'projects snippet mappings, image sources, association paths and region settings into clean editable Ruby' do
    steps = [2, { 'Association' => 'App.Owner', 'DestinationEntity' => 'App.Document' },
             { 'Association' => 'App.Tags', 'DestinationEntity' => 'App.Tag' }]
    mappings = [2, { 'Parameter' => 'App.Detail.Document',
                     'Variable' => { 'SnippetParameter' => 'App.Outer.Document' } },
                { 'Parameter' => 'App.Detail.Label', 'Argument' => "'Label'" }]
    source = { '$Type' => 'Forms$MicroflowSource', 'MicroflowSettings' => { 'Microflow' => 'App.Image' } }
    reference = { '$Type' => 'DomainModels$IndirectEntityRef', 'Steps' => steps }
    region = { 'SizeMode' => 'Pixels', 'Size' => 240, 'ToggleMode' => 'ShrinkContentInitiallyClosed' }
    center = { 'Widgets' => [2, { '$Type' => 'Forms$DynamicText', 'Name' => 'Center' }] }
    widgets = [
      { '$Type' => 'Forms$SnippetCallWidget', 'Name' => 'Snippet',
        'SnippetCall' => { 'Snippet' => 'App.Detail', 'ParameterMappings' => mappings } },
      { '$Type' => 'Forms$DynamicImageViewer', 'Name' => 'Image', 'DataSource' => source },
      { '$Type' => 'Forms$InputReferenceSetSelector', 'Name' => 'Tags',
        'AttributeRef' => { 'EntityRef' => reference, 'Attribute' => 'App.Tag.Name' } },
      { '$Type' => 'Forms$ScrollContainer', 'Name' => 'Shell', 'LayoutMode' => 'Sidebar',
        'Left' => region, 'Center' => center }
    ]
    page = Mxrb::Model::Page.allocate
    page.decode('Widgets' => [2, *widgets])
    exporter = Mxrb::RubyApp::Exporter.allocate
    widgets = page.widgets.map { exporter.send(:widget_manifest, _1) }
    source = exporter.send(:runtime_widget_dsl_source, widgets, 0)
    expect(source).to include('snippet_arguments(', 'page_variable(', 'microflow_source(', 'association_path(',
                              'scroll_regions(')
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.instance_eval(source)
    expect(tree.widgets.first.dig('options', 'arguments', 'Document', 'kind')).to eq('snippet_parameter')
    expect(tree.widgets[1].dig('options', 'source', 'kind')).to eq('microflow')
    expect(tree.widgets[2].dig('options', 'association_path').length).to eq(2)
    expect(tree.widgets.last.dig('options', 'region_options', 'left',
                                 'toggle_mode')).to eq('shrink_content_initially_closed')
    expect(tree.widgets.last.dig('regions', 'center', 0, 'name')).to eq('Center')
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, 'presentation.rb'), source)
      expect(Mxrb::PublicSourceAudit.new(directory)).to be_clean
    end
  end

  it 'composes nested shared layouts, replaces repeated named slots, preserves data arrays and detects cycles' do
    presentation = Mxrb::RubyApp::Presentation
    presentation.layout('App.Base') do
      container 'Frame' do
        placeholder 'Main', parameter: 'Main'
        placeholder 'Missing', parameter: 'Missing'
      end
    end
    presentation.layout('App.Shell') do
      layout 'base', layout: 'App.Base' do
        region 'Main' do
          text 'Header', caption: 'Ruby layout'
          placeholder 'Body', parameter: 'Body'
          placeholder 'BodyAgain', parameter: 'Body'
        end
      end
    end
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.layout 'shell', layout: 'App.Shell' do
      region('Body') { text 'Value', caption: 'Editable content' }
    end
    composed = presentation.compose(tree.widgets)
    expect(composed.first.fetch('children').map { _1['name'] }).to eq(%w[Header Value Value])
    expect(presentation.compose([[1, 2], [3, 4]])).to eq([[1, 2], [3, 4]])
    presentation.layout('App.Base') { text 'Changed', caption: 'Edited shared Ruby' }
    expect(presentation.compose(tree.widgets).first.fetch('name')).to eq('Changed')
    presentation.layout('App.Base') { layout 'cycle', layout: 'App.Shell' }
    expect { presentation.compose(tree.widgets) }.to raise_error(ArgumentError, /recursive layout/)
    expect { presentation.compose({ type: 'layout', options: { layout: 'Missing' } }) }
      .to raise_error(ArgumentError, /missing layout/)
  end

  it 'exports nested layout placeholders as typed declarations that preserve slot composition' do
    original = Mxrb::RubyApp::Page::WidgetTree.new
    original.layout_grid('Shell') do
      row do
        column { widget :placeholder, 'Main', options: { parameter: 'Main' }, events: [] }
      end
    end
    exporter = Mxrb::RubyApp::Exporter.allocate
    source = exporter.send(:runtime_widget_dsl_source, original.widgets, 0)
    expect(source).to include('placeholder "Main", parameter: "Main"')
    expect(source).not_to include('widget :placeholder', '=>')
    reconstructed = Mxrb::RubyApp::Page::WidgetTree.new
    reconstructed.instance_eval(source)
    expect(reconstructed.widgets).to eq(original.widgets)
    Mxrb::RubyApp::Presentation.layout('App.Shell') { instance_eval(source) }
    composed = Mxrb::RubyApp::Presentation.compose(
      reconstructed.widgets, slots: { 'Main' => [{ 'type' => 'text', 'name' => 'Content' }] }
    )
    expect(JSON.generate(composed)).to include('Content')
    expect(JSON.generate(composed)).not_to include('placeholder')
    missing_parameter = { 'type' => 'placeholder', 'name' => 'Main', 'options' => {}, 'events' => [] }
    expect(exporter.send(:runtime_widget_dsl_source, [missing_parameter], 0, generic_sink: true))
      .to include('widget :placeholder')
  end

  it 'declares translated menu actions with editable named arguments and snippet parameters' do
    Mxrb::RubyApp::Presentation.menu('App.Menu') do
      item 'Open', translations: [%w[pt_BR Abrir]], icon: 'home' do
        on_click nanoflow: 'App.Open' do
          argument 'Document', page_variable('Document', kind: :snippet_parameter)
        end
      end
    end
    item = Mxrb::RubyApp::Registry.fetch(:presentation, 'App.Menu').fetch(:items).first
    expect(item.dig(:caption_translations, 'pt_BR')).to eq('Abrir')
    expect(item.dig(:action, :kind)).to eq(:nanoflow)
    Mxrb::RubyApp::Presentation.snippet('App.Detail', parameters: %w[Document Label])
    expect(Mxrb::RubyApp::Registry.fetch(:presentation, 'App.Detail').fetch(:parameters)).to eq(%w[Document Label])
  end

  it 'enforces server upload policy and metadata, including transactional deletion without lifecycle events' do
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'Files.mpr')
      target = File.join(directory, 'app')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module :Files do
          entity(:Document) do
            string :Name
            integer :FileSize
            boolean :HasContents
          end
        end
      end
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      application = Mxrb::RubyApp::Application.new(target)
      record = application.create_record('Files.Document')
      implementation = Mxrb::RubyApp::Registry.fetch(:record, 'Files.Document')
      expect { implementation.file_policy(max_bytes: 0) }.to raise_error(ArgumentError)
      implementation.file_policy(max_bytes: 16, extensions: ['.PNG'], images_only: true)
      upload = lambda do |name, bytes|
        application.file_content('Files.Document', record.fetch(:id),
                                 upload: { 'name' => name, 'content' => Base64.strict_encode64(bytes) })
      end
      expect { upload.call('file.png', 'not image') }.to raise_error(ArgumentError, /requires an image/)
      expect { upload.call('file.txt', 'x') }.to raise_error(ArgumentError, /extension/)
      expect { upload.call('file.png', 'x' * 17) }.to raise_error(ArgumentError, /upload policy/)
      bytes = "\x89PNG\r\n\x1a\n".b
      upload.call('file.png', bytes)
      expect(application.record('Files.Document', record.fetch(:id)).fetch(:attributes))
        .to include('Name' => 'file.png', 'FileSize' => 8, 'HasContents' => true)
      store = application.send(:bridge).store
      value = store.find('Files.Document', record.fetch(:id))
      expect do
        store.transaction do
          store.delete(value, events: false)
          expect(store.database.get_first_value('SELECT COUNT(*) FROM mxrb_file_contents')).to eq(0)
          raise 'rollback'
        end
      end.to raise_error('rollback')
      expect(application.file_content('Files.Document', record.fetch(:id)).fetch('content')).to eq(bytes)
      store.delete(store.find('Files.Document', record.fetch(:id)), events: false)
      expect(store.database.get_first_value('SELECT COUNT(*) FROM mxrb_file_contents')).to eq(0)
      replacement = application.create_record('Files.Document')
      allow(Mxrb::RubyApp::Registry).to receive(:fetch).and_call_original
      allow(Mxrb::RubyApp::Registry).to receive(:fetch).with(:record, 'Files.Document').and_return(nil)
      expect(application.file_content('Files.Document', replacement.fetch(:id),
                                      upload: { 'name' => 'legacy.txt', 'content' => 'YQ==' }))
        .to include(name: 'legacy.txt')
    ensure
      application&.close
    end
  end
end
# rubocop:enable Metrics/BlockLength
