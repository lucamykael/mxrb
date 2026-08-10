# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby application internal contracts' do
  it 'covers exporter artifact, endpoint, source restoration, and frontend helpers' do
    Dir.mktmpdir('mxrb-exporter-internals-') do |dir|
      exp = Mxrb::RubyApp::Exporter.allocate
      exp.instance_variable_set(:@output_dir, dir)
      exp.instance_variable_set(:@mendix_sidecar, File.join(dir, '.mxrb', 'mendix'))
      exp.instance_variable_set(:@mpr_path, File.join(dir, 'source.mpr'))
      exp.instance_variable_set(:@coverage, [])
      exp.instance_variable_set(:@nanoflow_entries, [])
      File.write(exp.instance_variable_get(:@mpr_path), 'mpr')

      contents = 'puts :ok'
      exp.send(:restore_embedded_sources, [
                 { path: 'app/x.rb', contents:, sha256: Digest::SHA256.hexdigest(contents), mode: 0o600 }
               ])
      expect(File.read(File.join(dir, 'app/x.rb'))).to eq(contents)
      expect do
        exp.send(:restore_embedded_sources, [{ path: 'x', contents: 'bad', sha256: 'wrong' }])
      end.to raise_error(Mxrb::SerializationError)

      attribute = double(name: 'Name', type: :string, required: false, default_value: nil, id: 'a')
      lifecycle_entity = double(
        name: 'Input', persistable: false, oql_view?: false, attributes: [attribute], id: 'e',
        system_members: nil, access_rules: nil, lifecycle: []
      )
      no_lifecycle_entity = double(
        name: 'View', persistable: false, oql_view?: true, attributes: [], id: 'v',
        system_members: {}, access_rules: {}
      )
      allow(no_lifecycle_entity).to receive(:respond_to?).with(:lifecycle).and_return(false)
      mod = double(name: 'Sales')
      dto = exp.send(:export_entity, lifecycle_entity, mod, 'Sales', 'sales')
      view = exp.send(:export_entity, no_lifecycle_entity, mod, 'Sales', 'sales')
      expect(dto).to include('dto' => true, 'ruby_class' => 'Sales::InputDto')
      expect(view).to include('dto' => false)

      parameter = { 'Name' => 'Input', 'VariableType' => { '$Type' => 'Object', 'Entity' => 'Sales.Input' } }
      flow = double(name: 'Run', id: 'f', parameters: [parameter], allowed_module_roles: [:User])
      expect(exp.send(:export_service, flow, mod, 'Sales', 'sales', :microflow))
        .to include('parameters' => [include('required' => true)])
      expect(exp.send(:flow_parameter_manifest,
                      'Name' => 'Optional', 'Type' => { '$Type' => 'String' }, 'IsRequired' => false))
        .to include('required' => false)

      non_rest = { type: 'Other' }
      rest_doc = {
        type: 'Rest$PublishedRestService', id: 'rest', name: 'Api',
        doc: { 'Path' => '/api/', 'Version' => '1', 'EnableCors' => true,
               'RequiresAuthentication' => true, 'Resources' => [] }
      }
      allow(Mxrb::IO::BsonCodec).to receive(:parse_array).and_return(items: [])
      allow(mod).to receive(:infrastructure_documents).and_return([non_rest, rest_doc])
      expect(exp.send(:export_endpoints, mod)).to contain_exactly(
        include('name' => 'Sales.Api', 'enable_cors' => true)
      )
      operation = { 'Microflow' => 'Run', 'HttpMethod' => 'get', 'Path' => '/{id}',
                    'SuccessStatusCode' => 'Created' }
      expect(exp.send(:rest_operation_manifest, mod, { 'Path' => '/api/' }, { 'Name' => 'One' }, operation))
        .to include('microflow' => 'Sales.Run', 'path' => '/api/{id}', 'success_status' => 201)
      operation['Microflow'] = 'Other.Run'
      expect(exp.send(:rest_operation_manifest, mod, { 'Path' => '' }, { 'Name' => 'One' }, operation))
        .to include('microflow' => 'Other.Run')
      expect(exp.send(:rest_success_status, nil)).to eq(200)
      expect(exp.send(:rest_success_status, 'HTTP 418')).to eq(418)
      expect(exp.send(:rest_success_status, 'Unknown')).to eq(200)

      nanoflow = double(name: 'Client', id: 'n', parameters: [], objects: [], flows: [])
      expect(exp.send(:export_nanoflow, nanoflow, mod, 'sales')).to include('runtime' => 'frontend')
      expect(exp.send(:frontend_nanoflows)).to include('Nanoflow0', '"Sales.Client"')
      expect(exp.send(:entity_source, 'M', 'E', 'M.E', 'id', [], dto: false, persistable: true))
        .to include('class E < Mxrb::RubyApp::Record')
      expect(exp.send(:entity_source, 'M', 'D', 'M.D', 'id', [], dto: true, persistable: false))
        .to include('class D < Mxrb::RubyApp::DTO')
      expect(exp.send(:ruby_constant, '123')).to eq('Artifact123')
      expect(exp.send(:ruby_constant, 'input', suffix: 'Dto')).to eq('InputDto')
      expect(exp.send(:ruby_method_name, 'class')).to eq('field_class')
      expect(exp.send(:ruby_method_name, '')).to eq('field')

      expect(exp.send(:rest_success_status, 'Value' => 'Accepted')).to eq(202)
      expect(exp.send(:widget_manifest, type: :text, name: 'x')).to eq('type' => 'text', 'name' => 'x')
      widget = exp.send(
        :widget_manifest,
        type: :container, options: { caption: 'Caption' }, events: [{ event: :click }],
        children: [{ type: :text }]
      )
      expect(widget).to include('caption' => 'Caption', 'events' => [include('event' => 'click')])
      expect(exp.send(:runtime_value, deep_structure: true, kept: :yes)).to eq('kept' => 'yes')

      sidecar_theme = File.join(dir, '.mxrb', 'mendix', 'theme')
      FileUtils.mkdir_p(File.join(sidecar_theme, 'web'))
      File.write(File.join(sidecar_theme, 'web', 'main.scss'), 'theme')
      exp.send(:copy_frontend_theme)
      expect(File.read(File.join(dir, 'frontend', 'src', 'mendix', 'theme', 'web', 'main.scss'))).to eq('theme')

      source_contents = File.join(dir, 'mprcontents')
      FileUtils.mkdir_p(source_contents)
      File.write(File.join(source_contents, 'x'), 'x')
      expect(exp.send(:copy_runtime_mpr)).to end_with('source.mpr')
    end

    allow(Mxrb::IO::MprFile).to receive(:open).and_raise(IOError, 'broken')
    expect { Mxrb::RubyApp::Exporter.allocate.send(:read_embedded_sources) }.to raise_error(IOError)
  end

  it 'covers record native synchronization and application CRUD/service branches' do
    record_class = Class.new(Mxrb::RubyApp::Record) do
      mendix_name 'M.E', id: 'e'
      attribute :name, type: :string, mendix_name: 'Name'
    end
    native = Mxrb::Runtime::Native::ObjectValue.new(entity: 'M.E', id: '1', members: { 'Name' => 'A' })
    record = record_class.from_native(native)
    record.name = 'B'
    record.run_lifecycle_callback(proc { _1.name = 'C' })
    expect(native.members['Name']).to eq('C')

    app = Mxrb::RubyApp::Application.allocate
    store = double
    interpreter = double(store:, effects: [{ type: 'effect' }])
    allow(interpreter).to receive_messages(clear_effects!: nil, call: 'native')
    project = double(modules: [])
    bridge = double(interpreter:, project:)
    app.instance_variable_set(:@bridge, bridge)
    policy = double
    allow(policy).to receive_messages(authorize!: true, filter_readable: [native],
                                      entity_allowed?: false, member_allowed?: true)
    app.instance_variable_set(:@access_control, policy)
    expect(policy).to receive(:authorize!).with(
      'M.E', kind: :entity, action: :read, context: anything, member: nil, record: nil
    ).once.and_return(true)
    app.send(:authorize_entity!, 'M.E', :read, Object.new)
    allow(store).to receive(:retrieve).with('M.E').and_return([native])
    allow(store).to receive(:find).with('M.E', '1').and_return(native)
    allow(store).to receive(:find).with('Missing', '1').and_return(nil)
    allow(store).to receive(:transaction).and_yield
    allow(store).to receive(:create).and_return(native)
    allow(store).to receive_messages(commit: native, delete: true)

    expect(app.records('M.E', context: Object.new)).to contain_exactly(include(id: '1'))
    expect(app.record('M.E', '1', context: Object.new)).to be_nil
    allow(policy).to receive(:entity_allowed?).and_return(true)
    expect(app.record('M.E', '1', context: Object.new)).to include(id: '1')
    expect(app.record('Missing', '1')).to be_nil
    expect(app.create_record('M.E', context: Object.new, Name: 'A')).to include(id: '1')
    expect(app.update_record('Missing', '1', {})).to be_nil
    expect(app.update_record('M.E', '1', { 'Name' => ['B'] }, context: Object.new)).to include(id: '1')
    expect(app.delete_record('Missing', '1')).to be(false)
    expect(app.delete_record('M.E', '1', context: Object.new)).to be(true)

    Class.new(Mxrb::RubyApp::Service) do
      mendix_name 'M.Ruby', id: 'r'
      def call(value: nil) = value
    end
    expect(app.call_service('M.Ruby', { 'value' => 3 })).to eq(3)
    expect { app.call_service('Missing') }.to raise_error(Mxrb::NativeRuntimeError)
    allow(project).to receive(:modules).and_return([double(name: 'M', microflows: [double(name: 'Native')])])
    expect(app.call_service('M.Native')).to eq('native')
    expect(app.invoke_service('M.Ruby', value: 2)).to include(result: 2)
    expect(app.native_call('M.Native', { value: 1 }, context: Object.new)).to eq('native')
  end

  it 'covers native bridge cleanup and entity synchronization validation' do
    scheduler = double(jobs: [], shutdown: nil)
    store = double(close: nil)
    project = double(close: nil, all_units: [])
    bridge = Mxrb::RubyApp::NativeBridge.allocate
    bridge.instance_variable_set(:@scheduler, scheduler)
    bridge.instance_variable_set(:@store, store)
    bridge.instance_variable_set(:@project, project)
    expect(bridge.start_scheduler).to equal(scheduler)
    allow(scheduler).to receive(:jobs).and_return([:job])
    expect(scheduler).to receive(:start)
    bridge.start_scheduler
    bridge.close

    sync = Mxrb::RubyApp::Synchronizer.allocate
    safe = double(safe?: true)
    allow(safe).to receive_messages(apply!: true, changes: [])
    unsafe = double(safe?: false, changes: ['unsafe'])
    entity = double(attributes: [], persistable: true)
    artifact = double(metadata: { model: entity })
    model_project = double
    allow(model_project).to receive_messages(
      plan_remove_entity: safe, plan_add_entity: safe, find_artifact: artifact,
      plan_remove_attribute: safe, plan_add_attribute: safe, plan_change_attribute: safe
    )
    implementation = double(persistable: true, attributes: [])
    expect { sync.send(:add_entity, model_project, 'Bad', implementation) }
      .to raise_error(Mxrb::ValidationError, /Module.Entity/)
    required = { mendix_name: 'Name', type: :string, required: true, default: nil }
    expect { sync.send(:add_entity, model_project, 'M.E', double(persistable: true, attributes: [required])) }
      .to raise_error(Mxrb::ValidationError, /required attribute/)
    valid = { mendix_name: 'Name', type: :string, required: false, default: nil }
    sync.send(:add_entity, model_project, 'M.E', double(persistable: false, attributes: [valid]))
    expect { sync.send(:synchronize_entity, double(find_artifact: nil), 'M.E', implementation) }
      .to raise_error(Mxrb::ValidationError, /missing/)
    expect do
      sync.send(:synchronize_entity, model_project, 'M.E', double(persistable: false, attributes: []))
    end.to raise_error(Mxrb::ValidationError, /persistence/)

    existing = double(name: 'Old', required: false, type: :string, default_value: nil)
    entity_with_old = double(attributes: [existing])
    sync.send(:synchronize_attributes, model_project, 'M.E', entity_with_old, [valid])
    allow(model_project).to receive(:plan_remove_attribute).and_return(unsafe)
    expect { sync.send(:synchronize_attributes, model_project, 'M.E', entity_with_old, []) }
      .to raise_error(Mxrb::ValidationError, /unsafe/)
    changed = double(name: 'Name', required: false, type: :integer, default_value: 'old')
    sync.send(:synchronize_attribute, model_project, 'M.E', changed, valid.merge(default: 'new'))
    same = double(name: 'Name', required: false, type: :string, default_value: '')
    expect(sync.send(:synchronize_attribute, model_project, 'M.E', same, valid)).to be_nil
    required_existing = double(name: 'Name', required: true, type: :string, default_value: nil)
    expect { sync.send(:synchronize_attribute, model_project, 'M.E', required_existing, valid) }
      .to raise_error(Mxrb::ValidationError, /changing required/)
  end

  it 'covers server lifecycle and supervisor internal/external process paths' do
    expect { Mxrb::RubyApp::Server.new('.', host: '0.0.0.0') }.to raise_error(ArgumentError, /loopback/)
    server = Mxrb::RubyApp::Server.allocate
    server.instance_variable_set(:@host, '127.0.0.1')
    server.instance_variable_set(:@port, 0)
    server.instance_variable_set(:@logger, WEBrick::Log.new(File::NULL))
    application = double(start_scheduler: nil, close: nil)
    server.instance_variable_set(:@application, application)
    http = double
    allow(http).to receive_messages(mount_proc: nil, start: nil, shutdown: nil)
    allow(WEBrick::HTTPServer).to receive(:new).and_return(http)
    yielded = false
    server.start { yielded = true }
    expect(yielded).to be(true)
    server.start
    server.shutdown

    environment = Mxrb::Environment.new('qa', root: '.', process: { 'VITE_X' => '1', 'IGNORED' => '2' })
    supervisor = Mxrb::RubyApp::Supervisor.new('.', environment:, frontend: false)
    expect(supervisor.instance_variable_get(:@environment)).to equal(environment)
    allow(Mxrb::RubyApp::Manifest).to receive(:load).and_return(
      double(data: { 'ruby_stack' => { 'preset' => 'flymetothemoon' } })
    )
    expect(supervisor.send(:external_backend?)).to be(true)
    allow(Mxrb::RubyApp::Manifest).to receive(:load).and_return(double(data: {}))
    expect(supervisor.send(:external_backend?)).to be(false)
    allow(Process).to receive(:spawn).and_return(12)
    expect(supervisor.send(:spawn_backend)).to eq(12)
    expect(supervisor.send(:profile_environment)).to include('MXRB_ENV' => 'qa', 'VITE_X' => '1')
    expect(supervisor.send(:terminate, nil)).to be_nil
    expect(Process).to receive(:kill).with('TERM', 12)
    expect(Process).to receive(:wait).with(12)
    supervisor.send(:terminate, 12)

    Dir.mktmpdir('mxrb-supervisor-') do |dir|
      frontend = File.join(dir, 'frontend')
      FileUtils.mkdir_p(frontend)
      local = Mxrb::RubyApp::Supervisor.new(dir, environment:, npm: 'npm')
      expect { local.send(:spawn_frontend) }.to raise_error(ArgumentError, /package not found/)
      File.write(File.join(frontend, 'package.json'), '{}')
      expect { local.send(:spawn_frontend) }.to raise_error(ArgumentError, /dependencies missing/)
      FileUtils.mkdir_p(File.join(frontend, 'node_modules'))
      allow(Process).to receive(:spawn).and_return(13)
      expect(local.send(:spawn_frontend)).to eq(13)
    end
  end

  it 'covers compilation cleanup, transition, initialization, and native bridge failure paths' do
    Dir.mktmpdir('mxrb-compile-contract-') do |dir|
      project_source = File.join(dir, 'project.rb')
      File.write(project_source, '# generated')
      manifest = double(
        mpr_name: 'x.mpr', absolute_path: project_source,
        data: {}, modules: [], coverage: []
      )
      allow(Mxrb::RubyApp::Manifest).to receive(:load).and_return(manifest)
      synchronizer = double(synchronize!: File.join(dir, 'out.mpr'))
      allow(Mxrb::RubyApp::Synchronizer).to receive(:new).and_return(synchronizer)
      old = ENV['MXRB_OUTPUT_PATH']
      ENV['MXRB_OUTPUT_PATH'] = 'previous'
      expect(Mxrb::RubyApp.compile(dir, File.join(dir, 'out.mpr'))).to end_with('out.mpr')
      expect(ENV['MXRB_OUTPUT_PATH']).to eq('previous')
      ENV['MXRB_OUTPUT_PATH'] = old

      loaded_environment = Mxrb::Environment.new('qa', root: dir, process: {})
      application = Mxrb::RubyApp::Application.new(dir, environment: loaded_environment)
      expect(application.environment).to equal(loaded_environment)
      application.instance_variable_set(:@bridge, double(close: nil))
      application.close
      application.close

      app = Mxrb::RubyApp::Application.allocate
      app.instance_variable_set(:@root, dir)
      app.instance_variable_set(:@environment, loaded_environment)
      expect(app.send(:runtime_database_path)).to end_with('qa.sqlite3')
      configured = Mxrb::Environment.new('qa', root: dir, process: { 'MXRB_DATABASE_PATH' => 'db/custom.sqlite3' })
      app.instance_variable_set(:@environment, configured)
      expect(app.send(:runtime_database_path)).to eq(File.join(dir, 'db/custom.sqlite3'))

      destructive = Mxrb::Environment.new(
        'qa', root: dir,
              process: {
                'MXRB_DATABASE_PATH' => 'db/custom.sqlite3',
                'MXRB_ALLOW_DESTRUCTIVE_MIGRATIONS' => 'true'
              }
      )
      app.instance_variable_set(:@environment, destructive)
      app.instance_variable_set(:@manifest, double(absolute_path: '/tmp/runtime.mpr'))
      native_bridge = double(close: nil)
      coordinator = app.send(:shared_store)
      allow(Mxrb::RubyApp::Registry).to receive(:all).and_return({})
      allow(Mxrb::RubyApp::Registry).to receive(:all).with(:record).and_return({})
      allow(Mxrb::RubyApp::Registry).to receive(:adapters).and_return({})
      allow(Mxrb::RubyApp::Registry).to receive(:java_custom_actions).and_return({})
      allow(Mxrb::RubyApp::NativeBridge).to receive(:new).and_call_original
      expect(Mxrb::RubyApp::NativeBridge).to receive(:new).with(
        '/tmp/runtime.mpr', database: File.join(dir, 'db/custom.sqlite3'),
                            record_hooks: {}, adapters: {}, java_custom_actions: {},
                            allow_destructive: true, coordinator:,
                            scheduler_lease_ttl: '300'
      ).and_return(native_bridge)
      expect(app.send(:bridge)).to eq(native_bridge)
      app.close
    ensure
      old ? ENV['MXRB_OUTPUT_PATH'] = old : ENV.delete('MXRB_OUTPUT_PATH')
    end

    migration = double(mendix_version: '1', close: nil)
    expect(migration).to receive(:migrate_to!).with('2')
    allow(Mxrb::Model::Project).to receive(:open).and_return(migration)
    Mxrb::RubyApp.transition('x', '2')
    allow(migration).to receive(:mendix_version).and_return('2')
    Mxrb::RubyApp.transition('x', '2')
    allow(Mxrb::Model::Project).to receive(:open).and_raise(IOError)
    expect { Mxrb::RubyApp.transition('x', '2') }.to raise_error(IOError)

    allow(Mxrb::Model::Project).to receive(:open).and_raise(IOError)
    expect { Mxrb::RubyApp::NativeBridge.new('bad', database: '/tmp/mxrb-native-failure/db.sqlite3') }
      .to raise_error(IOError)
  end

  it 'covers removal synchronization and all supervisor wait choices' do
    sync = Mxrb::RubyApp::Synchronizer.allocate
    manifest = double(modules: [{ 'models' => [{ 'name' => 'M.Removed' }], 'dtos' => [] }])
    sync.instance_variable_set(:@manifest, manifest)
    Mxrb::RubyApp::Registry.reset!
    safe = double(safe?: true, apply!: true, changes: [])
    project = double(plan_remove_entity: safe)
    sync.send(:synchronize_entities, project)
    unsafe = double(safe?: false, changes: ['unsafe'])
    allow(project).to receive(:plan_remove_entity).and_return(unsafe)
    expect { sync.send(:synchronize_entities, project) }.to raise_error(Mxrb::ValidationError, /unsafe/)

    build = lambda do |external:, frontend_pid: nil, backend_pid: 21, interrupt: false|
      supervisor = Mxrb::RubyApp::Supervisor.allocate
      supervisor.instance_variable_set(:@frontend, !frontend_pid.nil?)
      allow(supervisor).to receive_messages(external_backend?: external, spawn_backend: backend_pid,
                                            spawn_frontend: frontend_pid, shutdown: nil)
      fake_server = double(start: nil)
      allow(Mxrb::RubyApp::Server).to receive(:new).and_return(fake_server)
      thread = double(join: nil)
      allow(Thread).to receive(:new).and_return(thread)
      if interrupt
        allow(Process).to receive(:wait).and_raise(Errno::ECHILD)
      else
        allow(Process).to receive(:wait)
      end
      [supervisor, thread]
    end
    external, = build.call(external: true)
    expect(external.start { :yielded }).to be_nil
    internal, thread = build.call(external: false)
    internal.start
    expect(thread).to have_received(:join)
    frontend, = build.call(external: true, frontend_pid: 22)
    frontend.start
    expect(Process).to have_received(:wait).with(22)
    interrupted, = build.call(external: true, interrupt: true)
    expect(interrupted.start).to be_nil

    shutdown = Mxrb::RubyApp::Supervisor.allocate
    shutdown.instance_variable_set(:@server, double(shutdown: nil))
    shutdown.instance_variable_set(:@backend, double(join: nil))
    allow(shutdown).to receive(:terminate).and_raise(Errno::ESRCH)
    expect(shutdown.shutdown).to be_nil
    empty = Mxrb::RubyApp::Supervisor.allocate
    allow(empty).to receive(:terminate)
    expect(empty.shutdown).to be_nil
  end

  it 'covers remaining nil-safe and conditional runtime branches' do
    Mxrb::RubyApp::Registry.remove_instance_variable(:@records) if
      Mxrb::RubyApp::Registry.instance_variable_defined?(:@records)
    expect(Mxrb::RubyApp::Registry.all(:record)).to eq({})

    app = Mxrb::RubyApp::Application.allocate
    expect(app.page('Missing')).to be_nil
    policy = double(
      microflow_allowed?: true, page_allowed?: true, entity_allowed?: true,
      member_allowed?: true
    )
    app.instance_variable_set(:@access_control, policy)
    schema = {
      navigation: { profiles: [{ home_microflow: 'svc' }] },
      modules: [{ 'services' => [{ 'name' => 'svc' }], 'pages' => [], 'models' => [], 'dtos' => [] }]
    }
    expect(app.send(:secure_schema, schema, Object.new).dig(:navigation, :profiles, 0, :home_microflow))
      .to eq('svc')

    sync = Mxrb::RubyApp::Synchronizer.allocate
    sync.instance_variable_set(:@root, '/tmp/none')
    sync.instance_variable_set(:@target, '/tmp/target.mpr')
    project = double(close: nil, all_units: [])
    allow(Mxrb::Model::Project).to receive(:open).and_return(project)
    allow(sync).to receive(:synchronize_entities).and_raise(Mxrb::ValidationError, 'stop')
    expect { sync.synchronize! }.to raise_error(Mxrb::ValidationError)
    expect(project).to have_received(:close)
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise(IOError)
    allow(Mxrb::RubyApp).to receive(:source_bundle).and_return([])
    expect { sync.send(:embed_sources!) }.to raise_error(IOError)

    server = Mxrb::RubyApp::Server.allocate
    expect(server.shutdown).to be_nil
    request_class = Struct.new(:path, :request_method, :body, :query, :headers) do
      def [](name) = headers[name]
    end
    response_class = Mxrb::RubyApp::RackAdapter::Response
    context = double(user: nil, user_roles: [], module_roles: [])
    sessions = double(authenticate: context)
    application = double(rest_routes: [], root: '/tmp/missing')
    allow(application).to receive_messages(
      schema: { project: {}, navigation: {}, modules: [] }, page: nil, records: [],
      record: nil, create_record: {}, update_record: nil, delete_record: false
    )
    server.instance_variable_set(:@application, application)
    server.instance_variable_set(:@sessions, sessions)
    res = response_class.new
    server.send(:dispatch, request_class.new('/api/entities/M.E/1', 'POST', '', {}, {}), res)
    expect(res.status).to eq(404)
    expect(server.send(:request_json, request_class.new('/', 'POST', '', {}, {}))).to eq({})

    route = { 'method' => 'POST', 'path' => '/rest/{id}', 'microflow' => 'M.Run',
              'success_status' => 200, 'enable_cors' => false, 'requires_authentication' => false }
    allow(application).to receive_messages(rest_routes: [route], invoke_rest: 'ok')
    res = response_class.new
    server.send(:dispatch, request_class.new('/rest/x', 'POST', '{}', {}, {}), res)
    expect(res.headers).not_to have_key('Access-Control-Allow-Origin')
    expect(server.send(:rest_route, 'POST', '/not-rest')).to be_nil

    adapter = Mxrb::RubyApp::RackAdapter.new('.')
    expect(adapter.close).to be_nil
    adapter.instance_variable_set(:@server, double(application: nil))
    expect(adapter.close).to be_nil

    supervisor = Mxrb::RubyApp::Supervisor.allocate
    backend = double(join: nil)
    supervisor.instance_variable_set(:@backend, backend)
    allow(supervisor).to receive(:terminate)
    supervisor.shutdown
    expect(backend).to have_received(:join).with(2)
  end

  it 'wires scheduled microflows through the native bridge executor' do
    project = double(close: nil, all_units: [])
    store = double(close: nil)
    interpreter = double
    allow(interpreter).to receive(:call).with('M.Tick').and_return(:done)
    allow(Mxrb::Model::Project).to receive(:open).and_return(project)
    expect(Mxrb::Runtime::SQLiteStore).to receive(:new).with(
      project, path: '/tmp/mxrb-native-bridge/runtime.sqlite3', allow_destructive: true
    ).and_return(store)
    allow(Mxrb::Runtime::Native::Interpreter).to receive(:new).and_return(interpreter)
    scheduler = double(jobs: [], shutdown: nil)
    executors = []
    allow(Mxrb::Runtime::Scheduler).to receive(:new) do |_project, executor:, **|
      executors << executor
      scheduler
    end
    bridge = Mxrb::RubyApp::NativeBridge.new(
      '/tmp/source.mpr', database: '/tmp/mxrb-native-bridge/runtime.sqlite3', allow_destructive: true
    )
    expect(executors.first.call('M.Tick')).to eq(:done)
    bridge.close
  end
end
# rubocop:enable Metrics/BlockLength
