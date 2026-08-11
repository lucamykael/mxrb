# frozen_string_literal: true

require 'digest'
require 'spec_helper'
require 'tmpdir'

# rubocop:disable Lint/ConstantDefinitionInBlock, Metrics/BlockLength, Metrics/ParameterLists
RSpec.describe 'Pure-Ruby runtime layers' do
  Context = Data.define(:user, :user_roles, :module_roles, :attributes)

  let(:policy) do
    Class.new do
      def context(user: nil, user_roles: nil, roles: nil, module_roles: nil, attributes: {}, **)
        Context.new(user, Array(user_roles || roles), Array(module_roles), attributes)
      end
    end.new
  end

  it 'authenticates profile users, static tokens, expiration, and logout without leaking passwords' do
    now = Time.utc(2026, 1, 1)
    users = JSON.generate(
      'ada' => {
        'password_digest' => "sha256$#{Digest::SHA256.hexdigest('secret')}",
        'roles' => ['User']
      }
    )
    tokens = JSON.generate('service-token' => { 'user' => 'service', 'module_roles' => ['Api.Reader'] })
    sessions = Mxrb::RubyApp::SessionManager.new(
      policy, users:, tokens:, ttl: 60, clock: -> { now }
    )

    login = sessions.login('ada', 'secret')
    context = sessions.authenticate("Bearer #{login.fetch(:token)}")
    expect(context).to have_attributes(user: 'ada', user_roles: ['User'])
    expect(sessions.authenticate('Bearer service-token').module_roles).to eq(['Api.Reader'])
    expect(sessions.logout("Bearer #{login.fetch(:token)}")).to be(true)
    expect { sessions.authenticate("Bearer #{login.fetch(:token)}") }
      .to raise_error(Mxrb::RubyApp::AuthenticationError, /invalid or expired/)
    expect { sessions.login('ada', 'wrong') }
      .to raise_error(Mxrb::RubyApp::AuthenticationError, /invalid username or password/)
    expiring = sessions.login('ada', 'secret')
    now += 61
    expect { sessions.authenticate("Bearer #{expiring.fetch(:token)}") }
      .to raise_error(Mxrb::RubyApp::AuthenticationError, /expired/)
    expect do
      Mxrb::RubyApp::SessionManager.new(policy, users: '{', tokens: nil)
    end.to raise_error(ArgumentError, /invalid MXRB_USERS_JSON/)
    expect do
      Mxrb::RubyApp::SessionManager.new(policy, users: '[]', tokens: nil)
    end.to raise_error(ArgumentError, /must contain a JSON object/)
    unsupported = JSON.generate('bob' => { 'password_digest' => 'bcrypt$value' })
    expect { Mxrb::RubyApp::SessionManager.new(policy, users: unsupported).login('bob', 'value') }
      .to raise_error(Mxrb::RubyApp::AuthenticationError)
    expect(users).not_to include('secret"')
  end

  it 'supports generated Ruby entity lifecycle callbacks and syncs mutations to native values' do
    record = Class.new(Mxrb::RubyApp::Record) do
      mendix_name 'Sales.Order', id: 'order'
      persistence true
      attribute :number, type: :string, mendix_name: 'Number'
      before_commit { |value| value.number = "#{value.number}-checked" }
    end
    value = Mxrb::Runtime::Native::ObjectValue.new(
      entity: 'Sales.Order', id: '1', members: { 'Number' => 'SO-1' }
    )
    callback = record.lifecycle_callbacks.fetch(:before_commit).first

    record.from_native(value).run_lifecycle_callback(callback)

    expect(value.members['Number']).to eq('SO-1-checked')
  end

  it 'round-trips BSON entity lifecycle metadata into the model layer' do
    Dir.mktmpdir('mxrb-lifecycle-') do |dir|
      path = File.join(dir, 'Lifecycle.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module :Sales do
          entity(:Order) { before_commit microflow: :ValidateOrder }
          microflow(:ValidateOrder) do
            return_type :Boolean
            return_value 'false'
          end
        end
      end

      Mxrb.open(path) do |project|
        entity = project.modules.first.entities.first
        lifecycle = entity.lifecycle
        expect(lifecycle).to contain_exactly(
          include(event: :before_commit, handler: 'ValidateOrder', pass_event_object: true)
        )
        event = Mxrb::IO::BsonCodec.parse_array(entity.to_bson.fetch('eventHandlers'))[:items].first
        expect(event).to include(
          'Event' => 'Commit', 'Moment' => 'Before', 'Microflow' => 'ValidateOrder',
          'PassEventObject' => true, 'RaiseErrorOnFalse' => true
        )
        interpreter = Mxrb::Runtime::Native::Interpreter.new(project)
        value = interpreter.store.create('Sales.Order')
        expect { interpreter.store.commit(value) }
          .to raise_error(Mxrb::NativeRuntimeError, /entity lifecycle.*rejected/)
      end
    end
  end

  it 'enforces authenticated page, microflow, entity, and member access on HTTP requests' do
    Dir.mktmpdir('mxrb-secure-app-') do |dir|
      source = File.join(dir, 'Secure.mpr')
      root = File.join(dir, 'secure_app')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        security do
          security_level 'CheckEverything'
          user_role :User, module_roles: ['Sales.User']
          user_role :Administrator, module_roles: ['Sales.Admin'], admin: true
        end
        navigation do
          profile :Responsive, home_page: 'Sales.Dashboard' do
            item 'Dashboard', page: 'Sales.Dashboard'
          end
        end
        self.module :Sales do
          module_role :User
          module_role :Admin
          entity :Order do
            string :Number
            string :Secret
            access_rule 'Sales.User', create: true, read: [:Number], write: [:Number]
          end
          page(:Dashboard) { allowed_roles 'Sales.User' }
          microflow(:Ping) { allowed_roles 'Sales.User' }
        end
      end
      Mxrb::Exporter.new(source, root, mode: :ruby).export!
      record_source = File.join(root, 'app', 'models', 'sales', 'order.rb')
      File.write(
        record_source,
        File.read(record_source).sub(
          '    persistence true',
          "    persistence true\n    before_commit { |record| record.number = \"\#{record.number}-hook\" }"
        )
      )
      profile = File.join(root, 'config', 'environments', 'qa.env')
      File.write(profile, <<~ENV_FILE)
        MXRB_USERS_JSON={"ada":{"password":"secret","roles":["User"]}}
      ENV_FILE
      server = Mxrb::RubyApp::Server.new(root, port: 0, environment: :qa)
      request = Struct.new(:path, :request_method, :body, :query, :headers) do
        def [](name) = headers[name]
      end

      anonymous = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      server.send(:dispatch, request.new('/api/pages/Sales.Dashboard', 'GET', '', {}, {}), anonymous)
      expect(anonymous.status).to eq(403)

      health = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      server.send(:dispatch, request.new('/api/health', 'GET', '', {}, {}), health)
      expect(JSON.parse(health.body)).to include('environment' => 'qa')

      login = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      server.send(
        :dispatch,
        request.new(
          '/api/login', 'POST', JSON.generate(username: 'ada', password: 'secret'), {}, {}
        ),
        login
      )
      token = JSON.parse(login.body).fetch('token')
      headers = { 'Authorization' => "Bearer #{token}" }
      session = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      server.send(:dispatch, request.new('/api/session', 'GET', '', {}, headers), session)
      expect(JSON.parse(session.body)).to include('user' => 'ada', 'roles' => ['User'])
      navigation = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      server.send(:dispatch, request.new('/api/navigation', 'GET', '', {}, headers), navigation)
      expect(JSON.parse(navigation.body).fetch('profiles').first).to include('name' => 'Responsive')
      authorized = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      server.send(
        :dispatch, request.new('/api/pages/Sales.Dashboard', 'GET', '', {}, headers), authorized
      )
      expect(authorized.status).to eq(200)

      context = server.application.session_manager.authenticate(headers['Authorization'])
      created = server.application.create_record(
        'Sales.Order', { 'Number' => 'SO-1' },
        context:
      )
      expect(created.fetch(:attributes)).to eq('Number' => 'SO-1-hook')
      expect(server.application.record('Sales.Order', created.fetch(:id), context:)).to eq(created)
      fetched = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      server.send(
        :dispatch,
        request.new("/api/entities/Sales.Order/#{created.fetch(:id)}", 'GET', '', {}, headers),
        fetched
      )
      expect(fetched.status).to eq(200)
      updated = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      server.send(
        :dispatch,
        request.new(
          "/api/entities/Sales.Order/#{created.fetch(:id)}", 'PATCH',
          JSON.generate('Number' => 'SO-2'), {}, headers
        ),
        updated
      )
      expect(JSON.parse(updated.body).dig('attributes', 'Number')).to eq('SO-2-hook')
      expect(server.application.record('Sales.Order', 'missing', context:)).to be_nil
      expect(server.application.update_record('Sales.Order', 'missing', {}, context:)).to be_nil
      expect do
        server.application.create_record(
          'Sales.Order', { 'Secret' => 'hidden' },
          context: server.application.session_manager.authenticate(headers['Authorization'])
        )
      end.to raise_error(Mxrb::Runtime::AuthorizationError)
      logout = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      server.send(:dispatch, request.new('/api/logout', 'POST', '', {}, headers), logout)
      expect(JSON.parse(logout.body)).to include('ok' => true)
      expired = WEBrick::HTTPResponse.new(WEBrick::Config::HTTP)
      server.send(:dispatch, request.new('/api/session', 'GET', '', {}, headers), expired)
      expect(expired.status).to eq(401)
      server.application.close
    end
  end
end
# rubocop:enable Lint/ConstantDefinitionInBlock, Metrics/BlockLength, Metrics/ParameterLists
