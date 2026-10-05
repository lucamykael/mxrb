# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative '../lib/mxrb/ruby_app/presentation_exporter'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Standalone runtime defensive contracts' do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'retains a deliberate legacy bridge while new source-only bridges use Ruby declarations' do
    Dir.mktmpdir('mxrb-runtime-contracts-') do |directory|
      source = File.join(directory, 'Source.mpr')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(source)
      load File.expand_path('fixtures/ruby_presentation_widgets/project.rb', __dir__)
      target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      application = Mxrb::RubyApp::Application.new(target)
      context = application.session_manager.authenticate(nil)
      expect(application.schema(context:).fetch(:presentation).fetch('Presentation.Main')[:items]).not_to be_empty
      bridge = application.send(:bridge)
      bridge.scheduler.instance_variable_get(:@executor).call('Presentation.Ping')
      expect(bridge.interpreter.effects).to include(include(type: 'show_message', message: 'Ruby action executed'))
      legacy = Mxrb::RubyApp::NativeBridge.new(source, database: File.join(directory, 'legacy.sqlite3'),
                                                       runtime_records: Mxrb::RubyApp::Registry.all(:record))
      expect(legacy.store.schema.associations).not_to be_empty
      expect(application.file_content('Presentation.Document', 'missing')).to be_nil
      expect { application.file_content('Presentation.Document', 'missing', upload: {}) }
        .to raise_error(ArgumentError, /requires string/)
      server = Mxrb::RubyApp::Server.new(target)
      request = Mxrb::Http::Request.new(path: '/api/files/Presentation.Document', request_method: 'PUT',
                                        body: '{}', query: {}, headers: Mxrb::Http::Headers.new)
      response = Mxrb::Http::Response.new
      server.send(:dispatch, request, response)
      expect(response.status).to eq(400)
      expect { server.send(:request_json, request.with(body: 'long'), max_bytes: 1) }
        .to raise_error(ArgumentError, /allowed limit/)
    ensure
      server&.application&.close
      legacy&.close
      application&.close
    end
  end

  it 'handles optional flow declarations and legacy page roles without opening a project' do
    Mxrb::RubyApp::Registry.reset!
    project = Mxrb::RubyApp::RuntimeProject.allocate
    expect(project.all_units).to eq([])
    expect(project.send(:build_security)).to be_nil
    expect(project.send(:build_flow, double(native_definition: nil), 'App')).to be_nil
    page = double(mendix_name: 'App.Home', native_definition: { allowed_roles: ['App.Native'] },
                  allowed_module_roles: nil)
    expect(project.send(:page_roles, page, 'App')).to eq(['App.Native'])
    allow(page).to receive(:native_definition).and_return(nil)
    pages = [{ 'name' => 'App.Home', 'allowed_module_roles' => ['App.Legacy'] }]
    project.instance_variable_set(:@manifest, double(modules: [{ 'name' => 'App', 'pages' => pages }]))
    expect(project.send(:page_roles, page, 'App')).to eq(['App.Legacy'])
  end

  it 'supports empty presentation declarations and rejects paths outside public assets' do
    presentation = Mxrb::RubyApp::Presentation
    presentation.menu('App.Empty')
    presentation.snippet('App.EmptySnippet')
    expect(Mxrb::RubyApp::Registry.fetch(:presentation, 'App.Empty')).to eq(kind: 'menu', items: [])
    expect(Mxrb::RubyApp::Registry.fetch(:presentation, 'App.EmptySnippet')).to eq(kind: 'snippet', widgets: [])
    expect { presentation.image('App.Bad', path: '/assets/../secret') }.to raise_error(ArgumentError)
    expect { presentation.image('App.Bad', path: 'https://example.test/a.png') }.to raise_error(ArgumentError)
    exporter = Mxrb::RubyApp::PresentationExporter.new(double, double)
    expect(exporter.send(:images, double(asset_documents: [{ type: 'Other' }]))).to eq([])
    expect { exporter.send(:image_source, 'App.Image', 'ImageFormat' => '../../bad') }
      .to raise_error(Mxrb::SerializationError, /unsupported presentation image format/)
  end

  it 'projects named regions through the typed widget builders' do
    page = Mxrb::Model::Page.allocate
    %i[navigation_list scroll_container].each do |type|
      native = type == :navigation_list ? 'Forms$NavigationList' : 'Forms$ScrollContainer'
      expect(page.send(:widget_type, native)).to eq(type)
      expect(page.send(:widget_options, {}, type)).to be_a(Hash)
    end
    builder = Mxrb::Dsl::WidgetBuilder.new(:scroll_container, 'Scroll')
    builder.region(:center) { text 'Inside' }
    expect(builder.to_h.dig(:regions, :center, 0, :name)).to eq('Inside')
    builder.slot(path: ['content']) { text 'Slot content' }
    expect(builder.to_h.dig(:slots, 0, :path)).to eq(['content'])
  end

  it 'recognizes safe raster types and checks decoded size independently of encoded size' do
    database = SQLite3::Database.new(':memory:')
    database.results_as_hash = true
    files = Mxrb::RubyApp::FileContent.new(database)
    { 'image/jpeg' => "\xff\xd8\xff".b, 'image/gif' => 'GIF89a', 'image/webp' => 'RIFF0000WEBP' }.each do |type, bytes|
      expect(files.write('App.File', '1', 'image', Base64.strict_encode64(bytes))).to include(media_type: type)
    end
    decoded = 'x' * (Mxrb::RubyApp::FileContent::MAX_BYTES + 1)
    allow(Base64).to receive(:strict_decode64).with('large').and_return(decoded)
    expect { files.write('App.File', '1', 'image', 'large') }.to raise_error(ArgumentError, /20 MiB/)
  ensure
    database&.close
  end
end
# rubocop:enable Metrics/BlockLength
