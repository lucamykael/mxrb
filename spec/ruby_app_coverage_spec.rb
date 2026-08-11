# frozen_string_literal: true

require 'spec_helper'
require 'stringio'
require 'tmpdir'

# Exercises defensive and integration seams which are deliberately hard to
# reach through a generated application's happy path.
# rubocop:disable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
RSpec.describe 'Ruby application defensive coverage' do
  Request = Struct.new(:path, :request_method, :body, :query, :headers) do
    def [](name) = headers[name]
  end

  def response
    Mxrb::RubyApp::RackAdapter::Response.new
  end

  def exporter
    Mxrb::RubyApp::Exporter.allocate
  end

  def bare_application
    Mxrb::RubyApp::Application.allocate
  end

  def bare_server(application: double, sessions: double)
    Mxrb::RubyApp::Server.allocate.tap do |server|
      server.instance_variable_set(:@application, application)
      server.instance_variable_set(:@sessions, sessions)
    end
  end

  it 'covers source safety, manifests, registry, records, services, and pages' do
    Dir.mktmpdir('mxrb-ruby-contract-') do |dir|
      FileUtils.mkdir_p(File.join(dir, 'app', 'models', 'x'))
      FileUtils.mkdir_p(File.join(dir, 'frontend', 'node_modules'))
      File.write(File.join(dir, 'app', 'models', 'x', 'a.rb'), '# model')
      File.write(File.join(dir, 'frontend', 'node_modules', 'ignored.js'), 'ignored')
      bundle = Mxrb::RubyApp.source_bundle(dir)
      expect(bundle.map { _1[:path] }).to eq(['app/models/x/a.rb'])
      expect(Mxrb::RubyApp.application_files(dir)).to contain_exactly(
        File.join(dir, 'app', 'models', 'x', 'a.rb')
      )
      expect(Mxrb::RubyApp.safe_source_mode(nil, 'bin/server')).to eq(0o755)
      expect(Mxrb::RubyApp.safe_source_mode(nil, 'README.md')).to eq(0o644)
      expect { Mxrb::RubyApp.safe_source_mode(0o1000, 'x') }.to raise_error(Mxrb::ValidationError)
      expect { Mxrb::RubyApp.safe_source_path(dir, '../x') }.to raise_error(Mxrb::ValidationError)
      expect { Mxrb::RubyApp.safe_source_path(dir, '/x') }.to raise_error(Mxrb::ValidationError)

      manifest_dir = File.join(dir, '.mxrb')
      FileUtils.mkdir_p(manifest_dir)
      expect { Mxrb::RubyApp::Manifest.load(dir) }.to raise_error(ArgumentError, /not an MXRB/)
      File.write(File.join(manifest_dir, 'ruby-app.json'), '{')
      expect { Mxrb::RubyApp::Manifest.load(dir) }.to raise_error(ArgumentError, /invalid/)
      expect { Mxrb::RubyApp::Manifest.new(dir, 'mode' => 'mendix') }.to raise_error(ArgumentError)
      manifest = Mxrb::RubyApp::Manifest.new(
        dir,
        'mode' => 'ruby', 'source' => { 'name' => 'x.mpr' }, 'modules' => [], 'coverage' => [],
        'round_trip' => { 'runtime_mpr' => 'runtime/x.mpr' }
      )
      expect(manifest.mpr_name).to eq('x.mpr')
      expect(manifest.absolute_path('runtime_mpr')).to eq(File.join(dir, 'runtime/x.mpr'))
      manifest.data['round_trip']['runtime_mpr'] = '../x'
      expect { manifest.absolute_path('runtime_mpr') }.to raise_error(ArgumentError, /unsafe/)
    end

    Mxrb::RubyApp::Registry.reset!
    record = Class.new(Mxrb::RubyApp::Record) do
      mendix_name 'M.E', id: 'e'
      persistence true
      attribute :name, type: :string, mendix_name: 'Name'
      def normalize = self.name = name.to_s.upcase
    end
    expect(record.mendix_name).to eq('M.E')
    expect(record.persistable).to be(true)
    expect { record.lifecycle(:unknown) {} }.to raise_error(ArgumentError)
    expect { record.lifecycle(:before_commit) }.to raise_error(ArgumentError)
    record.before_commit :normalize
    instance = record.new(id: '1', name: 'ada', ignored: true)
    expect(instance.to_h).to include(id: '1', attributes: { name: 'ada' })
    expect(instance.sync_to_native!).to equal(instance)
    instance.run_lifecycle_callback(:normalize)
    expect(instance.name).to eq('ADA')

    service = Class.new(Mxrb::RubyApp::Service) { mendix_name 'M.Run', id: 'run' }
    page = Class.new(Mxrb::RubyApp::Page) do
      mendix_name 'M.Home', id: 'home'
      configure title: 'Home', widgets: [{}]
    end
    app = double(native_call: :native)
    expect(service.new(app).call(a: 1)).to eq(:native)
    expect(page.mendix_name).to eq('M.Home')
    expect(Mxrb::RubyApp::Registry.all(:page)).to include('M.Home' => page)
    expect { Mxrb::RubyApp::Registry.all(:bogus) }.to raise_error(KeyError)
  end

  it 'covers exporter nanoflow projections and BSON fallbacks' do
    exp = exporter
    allow(Mxrb::IO::BsonCodec).to receive(:extract_id).and_invoke(:to_s.to_proc)
    allow(Mxrb::IO::BsonCodec).to receive(:parse_array).and_return(items: [])
    flow = double(
      id: 'nf', parameters: [{ 'Name' => 'Input' }, nil],
      objects: [nil, { '$ID' => 'end', '$Type' => 'Microflows$EndEvent', 'ReturnValue' => 'true' },
                { '$ID' => 'split', '$Type' => 'Microflows$ExclusiveSplit',
                  'SplitCondition' => { 'Expression' => '$x' } },
                { '$ID' => 'action', '$Type' => 'Microflows$ActionActivity',
                  'Action' => { '$Type' => 'Microflows$CreateVariableAction',
                                'VariableName' => 'x', 'InitialValue' => '1' } }],
      flows: [{ 'IsErrorHandler' => true },
              { 'OriginPointer' => 'a', 'DestinationPointer' => 'b', 'CaseValues' => [] }]
    )
    plan = exp.send(:nanoflow_plan, flow, 'M.N')
    expect(plan['parameters']).to eq(['Input'])
    expect(plan['objects'].map { _1['type'] }).to eq(%w[EndEvent ExclusiveSplit ActionActivity])
    expect(plan['flows']).to contain_exactly(include('origin' => 'a', 'destination' => 'b'))

    expect(exp.send(:nanoflow_action, nil)).to eq({})
    expect(exp.send(:nanoflow_action,
                    '$Type' => 'Microflows$ChangeVariableAction',
                    'ChangeVariableName' => 'x', 'Value' => '2')).to include('value' => '2')
    allow(Mxrb::IO::BsonCodec).to receive(:parse_array).and_return(
      items: [{ 'Attribute' => 'M.E/Name', 'Value' => 'A' },
              { 'Attribute' => '', 'Association' => 'M.E_Link', 'Value' => 'B' }]
    )
    change = exp.send(:nanoflow_action,
                      '$Type' => 'Microflows$ChangeAction', 'ChangeVariableName' => 'obj', 'Items' => [])
    expect(change['changes'].map { _1['member'] }).to eq(%w[Name E_Link])
    log = exp.send(:nanoflow_action,
                   '$Type' => 'Microflows$LogMessageAction',
                   'MessageTemplate' => { 'Text' => 'hello' })
    expect(log['message']).to eq('hello')
    expect(exp.send(:nanoflow_action, '$Type' => 'Microflows$UnknownAction')).to eq('type' => 'Unknown')

    allow(Mxrb::IO::BsonCodec).to receive(:parse_array).and_raise(ArgumentError)
    expect(exp.send(:native_items, [2, 'a', 'b'])).to eq(%w[a b])
    expect(exp.send(:native_items, ['a'])).to eq(['a'])
    expect(exp.send(:nanoflow_case, 'CaseValues' => [],
                                    'NewCaseValue' => { '$Type' => 'Microflows$NoCase' })).to eq('')
    expect(exp.send(:nanoflow_case, 'CaseValues' => [],
                                    'NewCaseValue' => { 'Value' => 'yes' })).to eq('yes')
    expect(exp.send(:native_identifier, '$ID' => 'id')).to eq('id')
    expect(exp.send(:native_identifier, 'raw')).to eq('raw')
  end

  it 'covers application authorization, REST coercion, serialization, and navigation branches' do
    app = bare_application
    policy = double
    allow(policy).to receive_messages(
      microflow_allowed?: true, page_allowed?: true, entity_allowed?: true, member_allowed?: true,
      authorize!: true
    )
    app.instance_variable_set(:@access_control, policy)
    schema = {
      navigation: {
        profiles: [{ home_page: 'denied', sign_in_page: 'allowed', home_microflow: 'denied',
                     role_homes: [{ page: 'allowed' }, { page: 'denied' }, { microflow: 'svc' }],
                     items: [{ page: 'denied', items: [{ page: 'allowed' }] }, { page: 'denied' }] }]
      },
      modules: [{ 'services' => [{ 'name' => 'svc', 'id' => 'sid' }],
                  'pages' => [{ 'name' => 'allowed', 'id' => 'pid' }],
                  'models' => [{ 'name' => 'M.E' }], 'dtos' => [] }]
    }
    secured = app.send(:secure_schema, schema, Object.new)
    profile = secured[:navigation][:profiles].first
    expect(profile).to include(home_page: nil, sign_in_page: 'allowed', home_microflow: nil)
    expect(profile[:role_homes].size).to eq(2)
    expect(profile[:items]).to contain_exactly(include(page: 'denied', items: [include(page: 'allowed')]))

    store = double
    interpreter = double(store: store)
    bridge = double(interpreter: interpreter)
    app.instance_variable_set(:@bridge, bridge)
    allow(store).to receive(:create) do |entity|
      Mxrb::Runtime::Native::ObjectValue.new(entity:, id: '1', members: {})
    end
    allow(store).to receive(:retrieve).and_return([])
    allow(store).to receive(:find).and_return(nil)
    service = { 'parameters' => [{ 'name' => 'Input', 'entity' => 'M.E', 'required' => true }] }
    args = app.send(:request_arguments, service, {}, {}, { 'Name' => 'Ada' })
    expect(args['Input'].members).to eq('Name' => 'Ada')
    expect do
      app.send(:request_arguments, service, {}, {}, nil)
    end.to raise_error(Mxrb::NativeRuntimeError, /missing REST argument/)
    expect(app.send(:request_arguments, service, { 'INPUT' => 'x' }, {}, nil)).to eq('Input' => 'x')

    child = Mxrb::Runtime::Native::ObjectValue.new(entity: 'M.E', id: '2', members: { 'Secret' => 1 })
    expect(app.send(:serialize, child, {}, context: Object.new)).to include(type: 'M.E')
    expect(app.send(:serialize, { a: [child] })).to include(a: [include(id: '2')])
    allow(store).to receive(:find).with('M.E', '2').and_return(child)
    restored = app.send(
      :deserialize,
      { 'id' => '2', 'type' => 'M.E', 'attributes' => { 'Name' => ['A'] } },
      context: Object.new, synchronize: true
    )
    expect(restored.members['Name']).to eq(['A'])
    expect { app.send(:deserialize, { 'id' => 'missing', 'type' => 'M.E' }) }
      .to raise_error(Mxrb::NativeRuntimeError, /not found/)
    expect(app.send(:deserialize, { 'a' => [1] })).to eq('a' => [1])

    parent = Mxrb::Runtime::Native::ObjectValue.new(entity: 'M.Parent', id: 'p1', members: {})
    allow(store).to receive(:find).with('M.Parent', 'p1').and_return(parent)
    allow(store).to receive(:find).with('M.Parent', 'missing').and_return(nil)
    allow(store).to receive(:retrieve_association).with('M.E_Parent', parent).and_return([child])
    expect(
      app.records(
        'M.E', association: 'M.E_Parent', context_type: 'M.Parent', context_id: 'p1'
      )
    ).to contain_exactly(include(id: '2', type: 'M.E'))
    expect(app.records('M.E', association: 'M.E_Parent', context_type: 'M.Parent', context_id: 'missing'))
      .to eq([])
    expect { app.records('M.E', association: 'M.E_Parent') }
      .to raise_error(ArgumentError, /requires association, context_type, and context_id/)
  end

  it 'covers server routing, REST, errors, static assets, and Rack adaptation' do
    context = double(user: 'ada', user_roles: ['User'], module_roles: ['M.User'])
    sessions = double
    allow(sessions).to receive_messages(authenticate: context, logout: true, login: { token: 't' })
    environment = double(name: 'qa')
    app = double(environment:, root: '/tmp/no-app')
    allow(app).to receive_messages(
      schema: { project: { 'name' => 'P' }, navigation: {}, modules: [{ 'pages' => [] }] },
      page: nil, invoke_service: { result: 1, effects: [] }, records: [], record: nil,
      create_record: {}, update_record: nil, delete_record: false, rest_routes: []
    )
    server = bare_server(application: app, sessions: sessions)
    dispatch = lambda do |path, method = 'GET', body = '', query = {}, headers = {}|
      response.tap { server.send(:dispatch, Request.new(path, method, body, query, headers), _1) }
    end
    expect(dispatch.call('/api/health').status).to eq(200)
    expect(dispatch.call('/api/login', 'POST', '{}').status).to eq(200)
    expect(dispatch.call('/api/session').status).to eq(200)
    expect(dispatch.call('/api/logout', 'POST').status).to eq(200)
    expect(dispatch.call('/api/schema').status).to eq(200)
    expect(dispatch.call('/api/navigation').status).to eq(200)
    expect(dispatch.call('/api/pages').status).to eq(200)
    expect(dispatch.call('/api/pages/Missing').status).to eq(404)
    allow(app).to receive(:page).and_return(name: 'M.Home')
    expect(dispatch.call('/api/pages/M.Home').status).to eq(200)
    expect(dispatch.call('/api/microflows/M.Run', 'POST', '{}').status).to eq(200)
    expect(dispatch.call('/api/entities/M.E').status).to eq(200)
    expect(
      dispatch.call(
        '/api/entities/M.E', 'GET', '',
        'association' => 'M.E_Parent', 'context_type' => 'M.Parent', 'context_id' => 'p1'
      ).status
    ).to eq(200)
    expect(app).to have_received(:records).with(
      'M.E', context:, association: 'M.E_Parent', context_type: 'M.Parent', context_id: 'p1'
    )
    expect(dispatch.call('/api/entities/M.E/1').status).to eq(404)
    allow(app).to receive(:record).and_return(id: '1')
    expect(dispatch.call('/api/entities/M.E/1').status).to eq(200)
    expect(dispatch.call('/api/entities/M.E', 'POST', '{}').status).to eq(201)
    expect(dispatch.call('/api/entities/M.E/1', 'PATCH', '{}').status).to eq(404)
    allow(app).to receive(:update_record).and_return(id: '1')
    expect(dispatch.call('/api/entities/M.E/1', 'PUT', '{}').status).to eq(200)
    expect(dispatch.call('/api/entities/M.E/1', 'DELETE').status).to eq(404)
    allow(app).to receive(:delete_record).and_return(true)
    expect(dispatch.call('/api/entities/M.E/1', 'DELETE').status).to eq(200)
    expect(dispatch.call('/api/nope').status).to eq(404)
    expect(dispatch.call('/api/login', 'POST', '[]').status).to eq(400)
    expect(dispatch.call('/api/login', 'POST', '{').status).to eq(400)
    expect(dispatch.call('/api/login', 'POST', 'x' * (Mxrb::RubyApp::Server::MAX_BODY_BYTES + 1)).status).to eq(400)

    route = { 'method' => 'POST', 'path' => '/rest/{id}', 'microflow' => 'M.Run',
              'success_status' => 204, 'enable_cors' => true, 'requires_authentication' => true }
    allow(app).to receive(:rest_routes).and_return([route])
    expect(dispatch.call('/rest/a', 'POST').status).to eq(401)
    allow(app).to receive(:invoke_rest).and_return(nil)
    rest = dispatch.call('/rest/a', 'POST', '', {}, 'Authorization' => 'Bearer t')
    expect(rest.status).to eq(204)
    expect(rest['Access-Control-Allow-Origin']).to eq('*')
    expect(dispatch.call('/rest/a', 'OPTIONS').status).to eq(204)
    route['success_status'] = 202
    route['requires_authentication'] = false
    expect(dispatch.call('/rest/a', 'POST', '{}').status).to eq(202)
    expect(server.send(:rest_route, 'GET', '/rest/a')).to be_nil
    expect(server.send(:path_match, '/x/{id}', '/no')).to be_nil
    expect(server.send(:route_name, '/x', '/y')).to be_nil

    allow(sessions).to receive(:authenticate).and_raise(Mxrb::RubyApp::AuthenticationError, 'bad')
    expect(dispatch.call('/api/session').status).to eq(401)
    allow(sessions).to receive(:authenticate).and_raise(Mxrb::Runtime::AuthorizationError, 'no')
    expect(dispatch.call('/api/session').status).to eq(403)
    allow(sessions).to receive(:authenticate).and_raise(Mxrb::NativeRuntimeError, 'bad runtime')
    expect(dispatch.call('/api/session').status).to eq(422)

    Dir.mktmpdir('mxrb-static-') do |dir|
      dist = File.join(dir, 'frontend', 'dist')
      FileUtils.mkdir_p(dist)
      File.write(File.join(dist, 'index.html'), 'index')
      %w[js css json bin].each { File.write(File.join(dist, "asset.#{_1}"), _1) }
      allow(app).to receive(:root).and_return(dir)
      allow(sessions).to receive(:authenticate).and_return(context)
      expect(dispatch.call('/').body).to eq('index')
      %w[js css json bin].each { expect(dispatch.call("/asset.#{_1}").status).to eq(200) }
      expect(dispatch.call('/fallback').body).to eq('index')
      expect(dispatch.call('/../secret').status).to eq(404)
      FileUtils.rm_f(File.join(dist, 'index.html'))
      expect(dispatch.call('/missing').status).to eq(404)
    end

    adapter = Mxrb::RubyApp::RackAdapter.new('.')
    rack_application = double(close: nil)
    rack_server = double(application: rack_application)
    allow(rack_server).to receive(:dispatch) do |_request, rack_response|
      rack_response.status = 201
      rack_response.body = 'ok'
    end
    adapter.instance_variable_set(:@server, rack_server)
    input = StringIO.new('{}')
    expect(adapter.call('rack.input' => input, 'QUERY_STRING' => 'a=1', 'PATH_INFO' => '/x',
                        'SCRIPT_NAME' => '', 'REQUEST_METHOD' => 'POST',
                        'HTTP_AUTHORIZATION' => 'Bearer t')).to eq([201, {}, ['ok']])
    expect(adapter.send(:rack_request, 'QUERY_STRING' => '')).to have_attributes(path: '/', body: '')
    adapter.close
  end
end
# rubocop:enable Metrics/BlockLength, Lint/ConstantDefinitionInBlock
