# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp, 'edge contracts' do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'rejects and disambiguates duplicate service registrations' do
    implementation = Struct.new(:mendix_name, :mendix_id)
    first = implementation.new('App.Run', '')
    second = implementation.new('App.Run', 'second')
    registry = Mxrb::RubyApp::Registry
    registry.register(:service, 'App.Run', first)
    expect { registry.register(:service, 'App.Run', second, unit_id: 'second') }
      .to raise_error(Mxrb::ValidationError, /duplicate names require explicit unit ids/)

    registry.reset!
    first.mendix_id = 'first'
    registry.register(:service, 'App.Run', first, unit_id: 'first')
    registry.register(:service, 'App.Run', second, unit_id: 'second')
    expect { registry.fetch(:service, 'App.Run') }
      .to raise_error(Mxrb::ValidationError, /specify its unit id/)
    expect(registry.fetch(:service, 'App.Run', unit_id: 'second')).to equal(second)
  end

  it 'delegates controller lookup and validates missing records and model classes' do
    model = Class.new(Mxrb::RubyApp::Record)
    model.mendix_name('App.Item')
    application = double(:application)
    allow(application).to receive(:record).with('App.Item', 'known', context: :request)
                                          .and_return(id: 'known')
    allow(application).to receive(:record).with('App.Item', 'missing', context: :request)
                                          .and_return(nil)
    controller = Mxrb::RubyApp::Controller.new(application, context: :request)

    expect(controller.find(model, 'known')).to eq(id: 'known')
    expect { controller.find!(model, 'missing') }.to raise_error(Mxrb::NotFoundError, /not found/)
    expect { controller.find(String, 'id') }.to raise_error(ArgumentError, /Record class/)
  end

  it 'tracks explicit security removals and rejects empty names' do
    module_security = Class.new(Mxrb::RubyApp::ModuleSecurity)
    expect { module_security.remove_module_role('') }.to raise_error(ArgumentError, /requires a role name/)
    module_security.remove_module_role(:Reader)
    expect(module_security.instance_variable_get(:@removed_roles)).to eq(['Reader'])

    project_security = Class.new(Mxrb::RubyApp::ProjectSecurity)
    expect { project_security.remove_user_role(nil) }.to raise_error(ArgumentError, /requires a role name/)
    expect { project_security.remove_demo_user('') }.to raise_error(ArgumentError, /requires a user name/)
    project_security.remove_user_role(:Manager)
    project_security.remove_demo_user(:Demo)
    expect(project_security.instance_variable_get(:@removed_user_roles)).to eq(['Manager'])
    expect(project_security.instance_variable_get(:@removed_demo_users)).to eq(['Demo'])
  end

  it 'validates controller declarations and builds structured runtime widgets' do
    service = Class.new(Mxrb::RubyApp::Service)
    expect { service.controller(Object.new, action: :index) }
      .to raise_error(ArgumentError, /controller must be/)
    controller = Class.new(Mxrb::RubyApp::Controller)
    expect { service.controller(controller, action: :index) }.not_to raise_error

    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.table(:Matrix) do
      column width: 100
      row { cell { text :Value } }
    end
    tree.layout_grid(:Grid) { row { column { text :Nested } } }
    tree.native_widget(:Native, type: 'Vendor$Widget', deep_structure: { 'Future' => true })
    expect { tree.native_widget(:Bad, type: 'Vendor$Bad', deep_structure: []) }
      .to raise_error(ArgumentError, /requires a Hash/)

    expect(tree.widgets.map { _1.fetch('type') }).to eq(%w[table layout_grid native_widget])
    expect(tree.sort_by(:Name, direction: :descending)).to eq(
      'attribute' => 'Name', 'direction' => 'descending'
    )
  end

  it 'restores no runtime project when the manifest omits its private path' do
    manifest = double(:manifest)
    allow(manifest).to receive(:absolute_path).with('runtime_project').and_raise(KeyError)

    expect(described_class.restore_runtime_project(manifest, '/tmp/output.mpr')).to be_nil
  end

  it 'copies runtime MPR contents before synchronizing a compiled application' do
    Dir.mktmpdir('mxrb-runtime-copy-') do |root|
      runtime = File.join(root, 'runtime', 'Base.mpr')
      contents = File.join(File.dirname(runtime), 'mprcontents')
      destination = File.join(root, 'build', 'App.mpr')
      FileUtils.mkdir_p(contents)
      File.write(runtime, 'mpr')
      File.write(File.join(contents, 'asset'), 'content')
      manifest = double(:manifest, data: { 'project' => { 'mendix_version' => '11.12.1' } })
      allow(manifest).to receive(:absolute_path).with('runtime_mpr').and_return(runtime)
      allow(Mxrb::RubyApp::Manifest).to receive(:load).with(root).and_return(manifest)
      allow(described_class).to receive(:restore_runtime_project)
      synchronizer = instance_double(Mxrb::RubyApp::Synchronizer, synchronize!: true)
      allow(Mxrb::RubyApp::Synchronizer).to receive(:new).and_return(synchronizer)

      expect(described_class.compile(root, destination)).to eq(destination)
      expect(File.read(destination)).to eq('mpr')
      expect(File.read(File.join(root, 'build', 'mprcontents', 'asset'))).to eq('content')
    end
  end

  it 'loads the generated project definition when no runtime MPR exists' do
    Dir.mktmpdir('mxrb-runtime-definition-') do |root|
      destination = File.join(root, 'build', 'App.mpr')
      definition = File.join(root, 'mendix_project.rb')
      File.write(definition, "FileUtils.mkdir_p(File.dirname(ENV.fetch('MXRB_OUTPUT_PATH')))\n" \
                             "File.write(ENV.fetch('MXRB_OUTPUT_PATH'), 'generated')\n")
      manifest = double(:manifest, data: { 'project' => { 'mendix_version' => '11.12.1' } })
      allow(manifest).to receive(:absolute_path).with('runtime_mpr').and_return(File.join(root, 'missing.mpr'))
      allow(manifest).to receive(:absolute_path).with('mendix_project').and_return(definition)
      allow(Mxrb::RubyApp::Manifest).to receive(:load).with(root).and_return(manifest)
      synchronizer = instance_double(Mxrb::RubyApp::Synchronizer, synchronize!: true)
      allow(Mxrb::RubyApp::Synchronizer).to receive(:new).and_return(synchronizer)

      expect(described_class.compile(root, destination)).to eq(destination)
      expect(File.read(destination)).to eq('generated')
    end
  end

  it 'suppresses page synchronization when the preserve marker exists' do
    Dir.mktmpdir('mxrb-preserve-pages-') do |root|
      FileUtils.mkdir_p(File.join(root, '.mxrb'))
      File.write(File.join(root, '.mxrb', 'preserve_native_pages'), '')
      synchronizer = Mxrb::RubyApp::Synchronizer.allocate
      synchronizer.instance_variable_set(:@root, root)
      synchronizer.instance_variable_set(:@target, File.join(root, 'App.mpr'))
      project = double(:project, mendix_version: '11.12.1')
      allow(project).to receive(:refresh!)
      allow(Mxrb::RubyApp::Registry).to receive(:all).with(:service).and_return({})
      allow(Mxrb::RubyApp::Registry).to receive(:all).with(:page).and_return(
        'App.Home' => double(native_definition: { name: 'Home' })
      )

      expect { synchronizer.send(:synchronize_native_documents, project) }.not_to raise_error
      expect(project).to have_received(:refresh!)
    end
  end
end
# rubocop:enable Metrics/BlockLength
