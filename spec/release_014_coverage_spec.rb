# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'stringio'
require 'tmpdir'
require 'spec_helper'

# Defensive and protocol coverage for the 0.1.4 release surface.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'MXRB 0.1.4 release paths' do
  def diagram_project(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Sales) do
        entity(:Customer) { string :Name }
        entity(:Order) do
          string :Number
          association 'Sales.Customer', name: :Order_Customer
        end
      end
    end
  end

  def ruby_project(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Sales) do
        entity(:Order) { string :Number }
        microflow(:Ping) { return_value "'pong'" }
        page(:Dashboard) { text :Heading, caption: 'Orders' }
      end
    end
  end

  def export_ruby_app(dir)
    source = File.join(dir, 'Sales.mpr')
    root = File.join(dir, 'sales_app')
    ruby_project(source)
    Mxrb::Exporter.new(source, root, mode: :ruby).export!
    root
  end

  it 'covers every direct CLI help discovery path' do
    status = Mxrb::CLI::ReleaseStatus.new('0.1.3', '0.1.4', Time.now)
    welcome = Mxrb::CLI::Help.welcome(release: status)
    expect(welcome).to include('Update available', 'mxrb update')
    expect(Mxrb::CLI::Help.overview).to include('mxrb changelog')
    expect(Mxrb::CLI::Help.commands).to include('diagram-er')
    expect(Mxrb::CLI::Help.commands('cache')).to include('cache status')
    expect(Mxrb::CLI::Help.command('domain-model')).to include('mxrb diagram-er')
    expect(Mxrb::CLI::Help.command(%w[marketplace pull])).to include('Parent help')
    expect(Mxrb::CLI::Help.command('run')).to include('--server-port', '--no-progress')
    expect(Mxrb::CLI::Help.command('marketplace')).to include('Subcommands:')
    expect(Mxrb::CLI::Help.command('missing')).to include('No help is registered')
    scaffold = Mxrb::Scaffold::Help::COMMANDS.keys.find { !Mxrb::CLI::Help::COMMANDS.key?(_1) }
    expect(Mxrb::CLI::Help.command(scaffold)).to include('Usage:')
    expect(Mxrb::CLI::Help.known?('run')).to be(true)
    expect(Mxrb::CLI::Help.known?(scaffold)).to be(true)
    expect(Mxrb::CLI::Help.known?('missing')).to be(false)
    expect(Mxrb::CLI::Help.scaffold_command?(scaffold)).to be(true)
    expect(Mxrb::CLI::Help.scaffold_command?('run')).to be(false)
    expect(Mxrb::CLI::Help.scaffold_commands).not_to be_empty
    expect(Mxrb::CLI::ReleaseStatus.new('bad', 'worse', Time.now).available?).to be(false)
  end

  it 'covers release caching, fallback URLs, HTTP failures, and both updater commands' do
    Dir.mktmpdir do |dir|
      now = Time.utc(2026, 8, 7, 12)
      clock = -> { now }
      cache = File.join(dir, 'cache', 'release.json')
      calls = []
      request = lambda do |uri|
        calls << uri
        uri.host == 'rubygems.org' ? JSON.generate(version: '0.1.4') : '{}'
      end
      releases = Mxrb::CLI::Releases.new(
        installed: '0.1.3', cache_path: cache, clock:, request:
      )
      expect(releases.status.latest).to eq('0.1.4')
      expect(releases.status.latest).to eq('0.1.4')
      expect(calls.count { _1.host == 'rubygems.org' }).to eq(1)
      expect(releases.changelog).to include(
        version: '0.1.4', title: 'mxrb 0.1.4',
        url: 'https://github.com/lucamykael/mxrb/releases/tag/v0.1.4'
      )

      now += Mxrb::CLI::Releases::CACHE_TTL + 1
      expect(releases.status.latest).to eq('0.1.4')
      File.write(cache, '{}')
      expect(releases.status.latest).to eq('0.1.4')
      File.write(cache, 'not-json')
      expect(releases.status.latest).to be_nil

      broken = Mxrb::CLI::Releases.new(
        installed: '0.1.3', cache_path: File.join(dir, 'broken.json'),
        request: ->(_uri) { raise IOError, 'offline' }
      )
      expect(broken.status.latest).to be_nil
      expect { broken.changelog }.to raise_error(Mxrb::CLI::ReleaseError, /Could not load changelog/)

      connection = instance_double(Net::HTTP)
      success = Net::HTTPOK.new('1.1', '200', 'OK')
      success.instance_variable_set(:@body, '{"ok":true}')
      success.instance_variable_set(:@read, true)
      allow(connection).to receive(:request).and_return(success)
      allow(Net::HTTP).to receive(:start).and_yield(connection)
      expect(releases.send(:http_get, URI('https://example.test'))).to eq('{"ok":true}')
      failure = Net::HTTPInternalServerError.new('1.1', '500', 'Failure')
      allow(connection).to receive(:request).and_return(failure)
      expect { releases.send(:http_get, URI('https://example.test')) }
        .to raise_error(Mxrb::CLI::ReleaseError, /HTTP 500/)

      empty_cache = Mxrb::CLI::Releases.new
      begin
        previous = ENV['XDG_CACHE_HOME']
        ENV['XDG_CACHE_HOME'] = dir
        expect(empty_cache.send(:default_cache_path)).to start_with(dir)
        ENV['XDG_CACHE_HOME'] = ''
        expect(empty_cache.send(:default_cache_path)).to include('.cache/mxrb')
      ensure
        previous.nil? ? ENV.delete('XDG_CACHE_HOME') : ENV['XDG_CACHE_HOME'] = previous
      end

      unavailable = instance_double(
        Mxrb::CLI::Releases,
        status: Mxrb::CLI::ReleaseStatus.new('0.1.3', nil, now)
      )
      expect { Mxrb::CLI::Updater.new(releases: unavailable, source_root: dir).update! }
        .to raise_error(Mxrb::CLI::ReleaseError, /Could not check/)
      current = instance_double(
        Mxrb::CLI::Releases,
        status: Mxrb::CLI::ReleaseStatus.new('0.1.4', '0.1.4', now)
      )
      expect(Mxrb::CLI::Updater.new(releases: current, source_root: dir).update!.latest).to eq('0.1.4')

      available = instance_double(
        Mxrb::CLI::Releases,
        status: Mxrb::CLI::ReleaseStatus.new('0.1.3', '0.1.4', now)
      )
      bundled = Mxrb::CLI::Updater.new(
        releases: available, source_root: dir, env: { 'BUNDLE_GEMFILE' => 'Gemfile' },
        runner: ->(*command) { command == %w[bundle update mxrb] }
      )
      expect(bundled.update!.latest).to eq('0.1.4')
      failing = Mxrb::CLI::Updater.new(
        releases: available, source_root: dir, env: {}, runner: ->(*_command) { false }
      )
      expect { failing.update! }.to raise_error(Mxrb::CLI::ReleaseError, /Update command failed/)
      unbundled = Mxrb::CLI::Updater.new(
        releases: available, source_root: dir, env: {}, runner: ->(*command) { command.include?('gem') }
      )
      expect(unbundled.update!.latest).to eq('0.1.4')
    end
  end

  it 'covers diagram server routes, validation failures, copies, and lifecycle' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'Shop.mpr')
      diagram_project(source)
      expect { Mxrb::DomainDiagram::Server.new(File.join(dir, 'missing.mpr')) }
        .to raise_error(ArgumentError, /MPR not found/)
      expect { Mxrb::DomainDiagram::Server.new(source, host: '0.0.0.0') }
        .to raise_error(ArgumentError, /loopback/)

      server = Mxrb::DomainDiagram::Server.new(source, modules: ['Sales'])
      expect(server.output).to end_with('Shop.domain-layout.mpr')
      forced = Mxrb::DomainDiagram::Server.new(source, output: server.output, force: true)
      forced.shutdown

      request_class = Struct.new(:request_method, :path, :body, :headers) do
        def [](name) = headers[name]
      end
      response_class = Struct.new(:status, :body, :headers) do
        def []=(name, value)
          headers[name] = value
        end
      end
      dispatch = lambda do |method, path, body = '', headers = {}|
        response = response_class.new(nil, nil, {})
        server.send(:dispatch, request_class.new(method, path, body, headers), response)
        response
      end
      expect(dispatch.call('GET', '/').status).to eq(200)
      diagram = dispatch.call('GET', '/api/diagram')
      payload = JSON.parse(diagram.body)
      expect(payload.fetch('csrf_token')).not_to be_empty
      expect(dispatch.call('GET', '/client-route').status).to eq(404)
      expect(dispatch.call('POST', '/missing').status).to eq(404)
      expect(dispatch.call('POST', '/api/layout', '{}').status).to eq(422)
      expect(dispatch.call(
        'POST', '/api/layout', 'x' * (Mxrb::DomainDiagram::Server::MAX_BODY_BYTES + 1),
        'X-MXRB-Token' => payload.fetch('csrf_token')
      ).status).to eq(422)
      expect(dispatch.call(
        'POST', '/api/layout', '{', 'X-MXRB-Token' => payload.fetch('csrf_token')
      ).status).to eq(422)
      expect(dispatch.call(
        'POST', '/api/layout', JSON.generate(modules: []),
        'X-MXRB-Token' => payload.fetch('csrf_token')
      ).status).to eq(200)

      fake_http = instance_double(Mxrb::Http::Server)
      puma = instance_double(Puma::Server)
      allow(fake_http).to receive(:start).and_yield(puma)
      allow(fake_http).to receive(:shutdown)
      allow(Mxrb::Http::Server).to receive(:new).and_return(fake_http)
      expect { |block| server.start(&block) }.to yield_with_args(puma)
      server.start
      server.shutdown

      FileUtils.mkdir_p(File.join(dir, 'mprcontents'))
      File.write(File.join(dir, 'mprcontents', 'asset.txt'), 'asset')
      outside = File.join(dir, 'outside', 'Shop-layout.mpr')
      copied = Mxrb::DomainDiagram::Server.new(source, output: outside)
      expect(File).to exist(File.join(File.dirname(outside), 'mprcontents', 'asset.txt'))
      copied.shutdown
    end
  end

  it 'covers invalid diagram layout anchors, positions, and association ids' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Shop.mpr')
      diagram_project(path)
      sales = Mxrb::DomainDiagram::Document.new(path, modules: ['Sales']).to_h.fetch(:modules).first
      entity = sales.fetch(:entities).first
      association = sales.fetch(:associations).first
      writer = Mxrb::DomainDiagram::LayoutWriter.new(path)
      expect do
        writer.apply!('modules' => [{ 'name' => 'Sales', 'entities' => [
                        { 'id' => entity.fetch(:id), 'x' => 100_001, 'y' => 0 }
                      ] }])
      end.to raise_error(Mxrb::ValidationError, /outside/)
      expect do
        writer.apply!('modules' => [{ 'name' => 'Sales', 'associations' => [
                        { 'id' => association.fetch(:id), 'source_anchor' => 'diagonal', 'target_anchor' => 'east' }
                      ] }])
      end.to raise_error(Mxrb::ValidationError, /unknown association anchor/)
      expect do
        writer.apply!('modules' => [{ 'name' => 'Sales', 'associations' => [
                        { 'id' => 'forged', 'source_anchor' => 'west', 'target_anchor' => 'east' }
                      ] }])
      end.to raise_error(Mxrb::ValidationError, /unknown domain associations/)
    end
  end

  it 'covers new native expression, loop, list, association, and page-effect paths' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Native.mpr')
      diagram_project(path)
      project = Mxrb::Model::Project.open(path)
      interpreter = Mxrb::Runtime::Native::Interpreter.new(project)
      expression = Mxrb::Runtime::Native::Expression.new
      node = Mxrb::Runtime::Native::ObjectValue.new(entity: 'Sales.Order', id: '1', members: {})
      expect(expression.evaluate('Missing', {}, node: node)).to be_nil
      expect { expression.evaluate('@', {}) }.to raise_error(Mxrb::NativeRuntimeError)
      expect(expression.evaluate('parseDecimal(\'1.5\')', {})).to eq(1.5)
      expect(expression.evaluate('contains(\'abc\', \'b\')', {})).to be(true)
      expect(expression.evaluate('startsWith(\'abc\', \'a\')', {})).to be(true)
      expect(expression.evaluate('endsWith(\'abc\', \'c\')', {})).to be(true)
      expect(expression.evaluate('random()', {})).to be_between(0, 1)
      expect { expression.evaluate("'unterminated", {}) }.to raise_error(Mxrb::NativeRuntimeError)

      expect do
        interpreter.send(:execute_loop, { 'LoopSource' => { '$Type' => 'Unknown' } }, {}, {}, label: 'x')
      end.to raise_error(Mxrb::NativeRuntimeError, /unsupported loop source/)
      variables = { 'list' => [1, 2] }
      nested_break = [{ '$Type' => 'Microflows$BreakEvent', '$ID' => 'break' }]
      interpreter.send(
        :execute_iterable_loop,
        { 'ListVariableName' => 'list', 'VariableName' => 'item' }, nested_break, {}, variables, label: 'items'
      )
      expect(variables.fetch('item')).to eq(1)
      interpreter.send(:action_create_list, { 'VariableName' => 'values' }, variables)
      interpreter.send(:action_change_list, { 'ChangeVariableName' => 'values', 'Type' => 'add', 'Value' => '1' },
                       variables)
      interpreter.send(:action_change_list, { 'ChangeVariableName' => 'values', 'Type' => 'add', 'Value' => '1' },
                       variables)
      interpreter.send(:action_change_list, { 'ChangeVariableName' => 'values', 'Type' => 'remove', 'Value' => '1' },
                       variables)
      interpreter.send(:action_change_list, { 'ChangeVariableName' => 'values', 'Type' => 'clear', 'Value' => '1' },
                       variables)
      expect do
        interpreter.send(
          :action_change_list,
          { 'ChangeVariableName' => 'values', 'Type' => 'invalid', 'Value' => '1' }, variables
        )
      end.to raise_error(Mxrb::NativeRuntimeError, /unsupported list change/)

      interpreter.instance_variable_set(
        :@associations, 'Sales.Order_Customer' => { type: :Reference, from: 'Sales.Order' }
      )
      customer = interpreter.store.create('Sales.Customer')
      order = interpreter.store.create('Sales.Order')
      order.members['Order_Customer'] = customer
      association_variables = { 'customer' => customer, 'order' => order }
      interpreter.send(
        :action_association_retrieve,
        { 'ResultVariableName' => 'orders' },
        { '$Type' => 'Microflows$AssociationRetrieveSource', 'StartVariableName' => 'customer',
          'AssociationId' => 'Sales.Order_Customer' }, association_variables
      )
      expect(association_variables.fetch('orders')).to eq([order])
      interpreter.send(
        :action_association_retrieve,
        { 'ResultVariableName' => 'selected' },
        { '$Type' => 'Microflows$AssociationRetrieveSource', 'StartVariableName' => 'order',
          'AssociationId' => 'Sales.Order_Customer' }, association_variables
      )
      expect(association_variables.fetch('selected')).to eq(customer)

      interpreter.send(
        :action_show_form,
        { 'FormSettings' => { 'Form' => 'Sales.Page', 'ParameterMappings' => [
          { 'Parameter' => 'Order', 'Argument' => '$order' }
        ] } }, association_variables
      )
      interpreter.send(:action_close_form, {}, association_variables)
      expect(interpreter.effects.map { _1.fetch(:type) }).to eq(%w[open_page close_page])
    ensure
      project&.close
    end
  end

  it 'covers initializer, legacy Ruby source modes, and source manifest failures' do
    expect { Mxrb::Initializer.new('App', mode: :ruby, stack: :unknown) }
      .to raise_error(ArgumentError, /Ruby stack must be/)
    Dir.mktmpdir do |dir|
      previous = ENV['MXRB_OUTPUT_PATH']
      ENV['MXRB_OUTPUT_PATH'] = 'keep-me'
      result = Mxrb::Initializer.new(
        'EnvApp', mode: :ruby, mxrb_path: File.expand_path('..', __dir__)
      ).scaffold(into: dir)
      expect(result.root).to end_with('EnvApp')
      expect(ENV.fetch('MXRB_OUTPUT_PATH')).to eq('keep-me')
    ensure
      previous.nil? ? ENV.delete('MXRB_OUTPUT_PATH') : ENV['MXRB_OUTPUT_PATH'] = previous
    end

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Legacy.mpr')
      diagram_project(path)
      mpr = Mxrb::IO::MprFile.open(path, readonly: false)
      db = mpr.instance_variable_get(:@db)
      db.execute('DROP TABLE IF EXISTS _MxrbRubySource')
      db.execute('CREATE TABLE _MxrbRubySource (Path TEXT PRIMARY KEY, Contents BLOB, Sha256 TEXT)')
      mpr.write_ruby_app_sources([
                                   { path: 'bin/server', contents: 'x', sha256: Digest::SHA256.hexdigest('x'), mode: 0o755 }
                                 ])
      expect(mpr.ruby_app_sources.first.fetch(:mode)).to eq(0o755)
    ensure
      mpr&.close
    end

    Dir.mktmpdir do |dir|
      manifest = File.join(dir, 'invalid.json')
      File.write(manifest, '{')
      writer = Mxrb::Writer.new(
        File.join(dir, 'invalid-ruby-source.mpr'), version: '11.12.1', modules: [],
                                                   ruby_app_sources_path: manifest
      )
      expect { writer.send(:ruby_app_source_files) }
        .to raise_error(Mxrb::SerializationError, /invalid Ruby source manifest/)
    end
  end

  it 'covers page gallery, template parameter, and qualified action projections' do
    doc = { '$ID' => 'page', '$Type' => 'Pages$Page', 'Name' => 'Projection', 'Widgets' => [3] }
    page = Mxrb::Model::Page.new(
      { 'UnitID' => 'page', 'ContainmentName' => 'Documents' }, double(parse_contents: doc)
    )
    parameters = page.send(
      :template_parameters,
      'Content' => { 'Parameters' => [3,
                                      { 'Expression' => '$currentObject/Name' },
                                      { 'Expression' => '', 'AttributeRef' => { 'Attribute' => 'Sales.Order.Number' } },
                                      { 'Expression' => '' }] }
    )
    expect(parameters).to eq(['$currentObject/Name', '$currentObject/Number'])

    properties = {
      'datasource' => { 'DataSource' => {
        'EntityRef' => { 'Entity' => 'Sales.Order' },
        'XPathConstraint' => '[Sales.Order_Customer = $Customer]',
        'SortBar' => { 'SortItems' => [3, {
          'AttributeRef' => { 'Attribute' => 'Sales.Order.Number' }, 'SortDirection' => 'Ascending'
        }] }
      } },
      'content' => { 'Widgets' => [3, { '$Type' => 'Pages$Text', 'Name' => 'Nested' }] }
    }
    allow(page).to receive(:custom_property_map).and_return(properties)
    gallery = page.send(
      :gallery_widget,
      '$Type' => 'Pages$PluggableWidget', 'Name' => 'Orders',
      'Type' => { 'ObjectType' => 'Gallery' }, 'Object' => {}
    )
    expect(gallery).to include(type: :gallery, name: 'Orders')
    expect(gallery.dig(:options, :entity)).to eq('Sales.Order')
    expect(gallery.fetch(:children)).not_to be_empty

    microflow = page.send(:parse_action, {
      '$Type' => 'Pages$MicroflowClientAction',
      'MicroflowSettings' => {
        'Microflow' => 'Sales.Ping',
        'ParameterMappings' => [3, { 'Parameter' => 'Sales.Ping.Order', 'Expression' => '$Order' }]
      }
    })
    form = page.send(:parse_action, {
      '$Type' => 'Pages$FormAction',
      'FormSettings' => {
        'Form' => 'Sales.Dashboard',
        'ParameterMappings' => [3, { 'Parameter' => 'Sales.Dashboard.Order', 'Expression' => '$Order' }]
      }
    })
    expect(microflow).to include(kind: :microflow, handler: 'Ping', arguments: { 'Order' => '$Order' })
    expect(form).to include(kind: :page, handler: 'Sales.Dashboard', arguments: { 'Order' => '$Order' })
    expect(page.send(:parse_action, '$Type' => 'Pages$FormAction')).to be_nil
  end

  it 'covers remaining native parser, defaults, collection, and loop branches' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Native.mpr')
      ruby_project(path)
      project = Mxrb::Model::Project.open(path)
      interpreter = Mxrb::Runtime::Native::Interpreter.new(project)
      expression = Mxrb::Runtime::Native::Expression.new
      expect { expression.resolve_identifier('invalid', nil) }.to raise_error(ArgumentError)
      expect { expression.evaluate(')', {}) }.to raise_error(Mxrb::NativeRuntimeError)
      expect(expression.evaluate('-1 + 2', {})).to eq(1)

      attribute = Struct.new(:type, :default_value)
      expect(interpreter.send(:attribute_default, attribute.new(:boolean, 'true'))).to be(true)
      expect(interpreter.send(:attribute_default, attribute.new(:decimal, '1.5'))).to eq(1.5)

      origin = { '$Type' => 'Microflows$ActionActivity', '$ID' => 'origin' }
      target = { '$Type' => 'Microflows$BreakEvent', '$ID' => 'target' }
      edge = { 'DestinationPointer' => 'target' }
      allow(interpreter).to receive(:identifier) do |value|
        value.is_a?(Hash) ? value['$ID'] : value
      end
      expect(interpreter.send(
               :collection_entry, [origin, target], { 'origin' => origin, 'target' => target },
               { 'origin' => [edge] }, root: false
             )).to eq(origin)

      variables = { 'list' => [1] }
      iterable = {
        'LoopSource' => {
          '$Type' => 'Microflows$IterableList', 'ListVariableName' => 'list', 'VariableName' => 'item'
        },
        'ObjectCollection' => { 'Objects' => [{ '$Type' => 'Microflows$BreakEvent', '$ID' => 'break' }] }
      }
      interpreter.send(:execute_loop, iterable, {}, variables, label: 'iterable')
      expect(variables.fetch('item')).to eq(1)

      allow(interpreter.instance_variable_get(:@expression)).to receive(:evaluate).and_return(true)
      allow(interpreter).to receive(:execute_collection).and_return([:continue, nil])
      expect do
        interpreter.send(
          :execute_while_loop, { 'WhileExpression' => 'true' }, [], {}, {}, label: 'infinite'
        )
      end.to raise_error(Mxrb::NativeRuntimeError, /exceeded 10000/)
      expect do
        interpreter.send(:action_retrieve, { 'RetrieveSource' => { '$Type' => 'Unknown' } }, {})
      end.to raise_error(Mxrb::NativeRuntimeError, /unsupported retrieve source/)
    ensure
      project&.close
    end
  end

  it 'covers Ruby app contracts, manifest failures, and synchronization guards' do
    record_class = Class.new(Mxrb::RubyApp::Record)
    expect(record_class.mendix_name).to be_nil
    record_class.mendix_name('Sales.Record', id: 'record-id')
    record_class.persistence(true)
    record_class.attribute(:name, type: :string, mendix_name: 'Name')
    record = record_class.new(id: '1', name: 'Ada', ignored: true)
    expect(record.to_h).to include(type: 'Sales.Record', attributes: { name: 'Ada' })

    page_class = Class.new(Mxrb::RubyApp::Page)
    expect(page_class.mendix_name).to be_nil
    page_class.mendix_name('Sales.Page', id: 'page-id')
    page_class.configure(title: 'Page')
    expect(page_class.title).to eq('Page')

    service_class = Class.new(Mxrb::RubyApp::Service)
    expect(service_class.mendix_name).to be_nil
    service_class.mendix_name('Sales.Service', id: 'service-id')
    application = double(native_call: 'native')
    expect(service_class.new(application).call(value: 1)).to eq('native')
    expect { Mxrb::RubyApp::Registry.register(:unknown, 'x', Object) }.to raise_error(KeyError)

    Dir.mktmpdir do |dir|
      expect { Mxrb::RubyApp::Manifest.load(dir) }.to raise_error(ArgumentError, /not an MXRB/)
      FileUtils.mkdir_p(File.join(dir, '.mxrb'))
      manifest_path = File.join(dir, Mxrb::RubyApp::MANIFEST_PATH)
      File.write(manifest_path, '{')
      expect { Mxrb::RubyApp::Manifest.load(dir) }.to raise_error(ArgumentError, /invalid/)
      File.write(manifest_path, JSON.generate(mode: 'mendix'))
      expect { Mxrb::RubyApp::Manifest.load(dir) }.to raise_error(ArgumentError, /mode ruby/)
      unsafe = Mxrb::RubyApp::Manifest.new(
        dir, 'mode' => 'ruby', 'round_trip' => { 'runtime_mpr' => '../outside.mpr' }
      )
      expect { unsafe.absolute_path('runtime_mpr') }.to raise_error(ArgumentError, /unsafe/)
    end

    synchronizer = Mxrb::RubyApp::Synchronizer.allocate
    expect { synchronizer.send(:qualified_parts, 'Unqualified') }
      .to raise_error(Mxrb::ValidationError, /Module.Entity/)
    expect do
      synchronizer.send(
        :reject_unsupported_required!, 'Sales.Order',
        { required: true, mendix_name: 'Required' }
      )
    end.to raise_error(Mxrb::ValidationError, /adding required/)

    attribute = Struct.new(:name, :required, :type, :default_value).new('Number', false, :string, '')
    unsafe_plan = double(safe?: false, changes: ['unsafe'])
    project = double(plan_remove_attribute: unsafe_plan)
    entity = double(attributes: [attribute])
    expect do
      synchronizer.send(:synchronize_attributes, project, 'Sales.Order', entity, [])
    end.to raise_error(Mxrb::ValidationError, /unsafe/)
    expect do
      synchronizer.send(
        :synchronize_attribute, project, 'Sales.Order', attribute,
        { required: true, type: :string, default: nil }
      )
    end.to raise_error(Mxrb::ValidationError, /changing required/)
    expect do
      synchronizer.send(:synchronize_entity, double(find_artifact: nil), 'Sales.Missing', record_class)
    end.to raise_error(Mxrb::ValidationError, /missing/)

    model = double(persistable: false)
    artifact = double(metadata: { model: model })
    expect do
      synchronizer.send(:synchronize_entity, double(find_artifact: artifact), 'Sales.Record', record_class)
    end.to raise_error(Mxrb::ValidationError, /changing persistence/)
  end

  it 'covers Ruby exporter nanoflow and runtime-value projections' do
    exporter = Mxrb::RubyApp::Exporter.new('source.mpr', 'output', mendix_sidecar: 'sidecar')
    expect(exporter.send(:nanoflow_action, nil)).to eq({})
    expect(exporter.send(:nanoflow_action, {
      '$Type' => 'Microflows$CreateVariableAction', 'VariableName' => 'x', 'InitialValue' => '1'
    })).to include('type' => 'CreateVariable', 'variable' => 'x', 'value' => '1')
    expect(exporter.send(:nanoflow_action, {
      '$Type' => 'Microflows$ChangeVariableAction', 'ChangeVariableName' => 'x', 'Value' => '2'
    })).to include('type' => 'ChangeVariable', 'variable' => 'x')
    expect(exporter.send(:nanoflow_action, {
      '$Type' => 'Microflows$ChangeAction', 'ChangeVariableName' => 'object',
      'Items' => [{ 'Attribute' => 'Sales.Order.Number', 'Value' => "'1'" },
                  { 'Association' => 'Sales.Order_Customer', 'Value' => '$Customer' }]
    })['changes']).to contain_exactly(
      { 'member' => 'Number', 'value' => "'1'" },
      { 'member' => 'Order_Customer', 'value' => '$Customer' }
    )
    expect(exporter.send(:nanoflow_action, {
      '$Type' => 'Microflows$LogMessageAction', 'MessageTemplate' => { 'Text' => 'hello' }
    })).to include('message' => 'hello')

    object = exporter.send(:nanoflow_object, {
      '$ID' => 'split', '$Type' => 'Microflows$ExclusiveSplit',
      'SplitCondition' => { 'Expression' => '$x = 1' }
    })
    expect(object).to include('condition' => '$x = 1')
    expect(exporter.send(:nanoflow_object, 'not-a-hash')).to be_nil
    expect(exporter.send(:nanoflow_case, 'NewCaseValue' => { 'Value' => 'true' })).to eq('true')
    allow(Mxrb::IO::BsonCodec).to receive(:parse_array).and_raise(ArgumentError)
    expect(exporter.send(:native_items, [1, 'value'])).to eq(['value'])

    value = exporter.send(
      :runtime_value,
      { symbol: :value, array: [:x], number: 1, boolean: true, nil_value: nil,
        deep_structure: { hidden: true }, object: Object.new }
    )
    expect(value).to include('symbol' => 'value', 'array' => ['x'], 'number' => 1, 'boolean' => true)
    expect(value).not_to have_key('deep_structure')
    expect(value.fetch('object')).to start_with('#<Object:')

    preset = Mxrb::RubyApp::Preset.allocate
    expect(preset.send(:baseline_file?, File.join(Dir.tmpdir, "missing-#{SecureRandom.hex}"))).to be(true)
  end

  it 'covers the complete Ruby HTTP and Rack routing surface' do
    Dir.mktmpdir do |dir|
      root = export_ruby_app(dir)
      manifest_path = File.join(root, Mxrb::RubyApp::MANIFEST_PATH)
      manifest = JSON.parse(File.read(manifest_path))
      sales = manifest.fetch('modules').find { _1.fetch('name') == 'Sales' }
      sales['endpoints'] = [{
        'name' => 'Sales.API', 'enable_cors' => true, 'requires_authentication' => true,
        'operations' => [{
          'method' => 'GET', 'path' => '/rest/ping/{name}', 'microflow' => 'Sales.Ping',
          'success_status' => 204
        }]
      }]
      File.write(manifest_path, JSON.pretty_generate(manifest))

      dist = File.join(root, 'frontend', 'dist')
      FileUtils.mkdir_p(dist)
      {
        'index.html' => '<main>app</main>', 'app.js' => 'js', 'app.css' => 'css',
        'data.json' => '{}', 'asset.bin' => 'bin'
      }.each { |name, contents| File.binwrite(File.join(dist, name), contents) }

      File.write(
        File.join(root, '.env'),
        "MXRB_AUTH_TOKENS={\"token\":{\"user\":\"coverage\"}}\n"
      )

      server = Mxrb::RubyApp::Server.new(root, port: 0)
      request_class = Struct.new(:path, :request_method, :body, :query, :headers) do
        def [](name) = headers[name]
      end
      response_class = Struct.new(:status, :body, :headers) do
        def []=(name, value)
          headers[name] = value
        end

        def [](name) = headers[name]
      end
      dispatch = lambda do |method, path, body = '', query = {}, headers = {}|
        response = response_class.new(nil, nil, {})
        request = request_class.new(path, method, body, query, headers)
        server.send(:dispatch, request, response)
        response
      end

      expect(dispatch.call('GET', '/api/health').status).to eq(200)
      expect(dispatch.call('GET', '/api/schema').status).to eq(200)
      expect(dispatch.call('GET', '/api/pages').status).to eq(200)
      expect(dispatch.call('GET', '/api/pages/Sales.Dashboard').status).to eq(200)
      expect(dispatch.call('GET', '/api/pages/Sales.Missing').status).to eq(404)
      expect(dispatch.call('POST', '/api/microflows/Sales.Ping', '{}').status).to eq(200)
      expect(dispatch.call('POST', '/api/microflows/Sales.Missing', '{}').status).to eq(422)
      expect(dispatch.call('POST', '/api/microflows/Sales.Ping', '{').status).to eq(400)

      expect(dispatch.call('GET', '/api/entities/Sales.Order').status).to eq(200)
      created = dispatch.call(
        'POST', '/api/entities/Sales.Order', JSON.generate('Number' => 'SO-1')
      )
      id = JSON.parse(created.body).fetch('id')
      expect(created.status).to eq(201)
      expect(dispatch.call('DELETE', "/api/entities/Sales.Order/#{id}").status).to eq(200)
      expect(dispatch.call('DELETE', "/api/entities/Sales.Order/#{id}").status).to eq(404)

      expect(dispatch.call('GET', '/rest/ping/Ada').status).to eq(401)
      authorized = dispatch.call(
        'GET', '/rest/ping/Ada', '', {}, 'Authorization' => 'Bearer token'
      )
      expect(authorized.status).to eq(204)
      expect(authorized.body).to eq('')
      options = dispatch.call('OPTIONS', '/rest/ping/Ada')
      expect(options.status).to eq(204)
      expect(options['Access-Control-Allow-Origin']).to eq('*')
      expect(dispatch.call('POST', '/api/missing').status).to eq(404)

      %w[/ /app.js /app.css /data.json /asset.bin].each do |path|
        expect(dispatch.call('GET', path).status).to eq(200)
      end
      expect(dispatch.call('GET', '/../secret').status).to eq(404)
      FileUtils.rm_f(File.join(dist, 'index.html'))
      expect(dispatch.call('GET', '/missing').status).to eq(404)
      expect(server.send(:content_type, 'x.unknown')).to eq('application/octet-stream')
      expect(server.send(:route_name, '/other', '/api/')).to be_nil
      expect(server.send(:rest_route, 'DELETE', '/none')).to be_nil
      expect(server.send(:path_match, '/x/{id}', '/other')).to be_nil
      expect { server.send(:request_json, request_class.new('/', 'POST', '[]', {}, {})) }
        .to raise_error(ArgumentError, /must be an object/)
      expect do
        server.send(
          :request_json,
          request_class.new('/', 'POST', 'x' * (Mxrb::RubyApp::Server::MAX_BODY_BYTES + 1), {}, {})
        )
      end.to raise_error(ArgumentError, /exceeds/)

      application = server.application
      service = { 'parameters' => [{ 'name' => 'Required', 'required' => true }] }
      expect do
        application.send(:request_arguments, service, {}, {}, nil)
      end.to raise_error(Mxrb::NativeRuntimeError, /missing REST argument/)
      expect do
        application.send(:deserialize, 'id' => 'missing', 'type' => 'Sales.Order')
      end.to raise_error(Mxrb::NativeRuntimeError, /not found/)
      expect(application.send(:deserialize, { 'nested' => [1, 2] })).to eq('nested' => [1, 2])

      adapter = Mxrb::RubyApp::RackAdapter.new(root)
      adapter.close
      status, headers, body = adapter.call(
        'rack.input' => StringIO.new(''), 'SCRIPT_NAME' => '/api', 'PATH_INFO' => '/health',
        'REQUEST_METHOD' => 'GET', 'QUERY_STRING' => 'x=1'
      )
      expect([status, headers.fetch('Content-Type'), body.join]).to include(200)
      adapter.close
    ensure
      server&.application&.close
    end
  end

  it 'covers Ruby compilation environment restoration and synchronization updates' do
    Dir.mktmpdir do |dir|
      root = export_ruby_app(dir)
      target = File.join(dir, 'rebuilt.mpr')
      previous = ENV['MXRB_OUTPUT_PATH']
      ENV['MXRB_OUTPUT_PATH'] = 'preserved'
      expect(Mxrb::RubyApp.compile(root, target)).to eq(target)
      expect(ENV.fetch('MXRB_OUTPUT_PATH')).to eq('preserved')
    ensure
      previous.nil? ? ENV.delete('MXRB_OUTPUT_PATH') : ENV['MXRB_OUTPUT_PATH'] = previous
    end

    synchronizer = Mxrb::RubyApp::Synchronizer.allocate
    attribute = Struct.new(:name, :required, :type, :default_value).new('Number', false, :string, '')
    plan = double
    expect(plan).to receive(:apply!).twice
    project = double(plan_change_attribute: plan)
    synchronizer.send(
      :synchronize_attribute, project, 'Sales.Order', attribute,
      { required: false, type: :decimal, default: '1' }
    )
    synchronizer.send(
      :synchronize_attribute, project, 'Sales.Order', attribute,
      { required: false, type: :integer, default: '' }
    )
    expect(project).not_to receive(:plan_change_attribute)
    synchronizer.send(
      :synchronize_attribute, project, 'Sales.Order', attribute,
      { required: false, type: :string, default: nil }
    )

    unsafe = double(safe?: false, changes: ['unsafe'])
    manifest = double(modules: [{ 'models' => [{ 'name' => 'Sales.Legacy' }], 'dtos' => [] }])
    synchronizer.instance_variable_set(:@manifest, manifest)
    Mxrb::RubyApp::Registry.reset!
    expect do
      synchronizer.send(:synchronize_entities, double(plan_remove_entity: unsafe))
    end.to raise_error(Mxrb::ValidationError, /unsafe/)
  end

  it 'covers supervisor process selection, waiting, shutdown, and validation failures' do
    Dir.mktmpdir do |dir|
      root = export_ruby_app(dir)
      supervisor = Mxrb::RubyApp::Supervisor.new(root, frontend: false)
      allow(supervisor).to receive(:external_backend?).and_return(true)
      allow(supervisor).to receive(:spawn_backend).and_return(101)
      allow(Process).to receive(:wait).with(101)
      allow(supervisor).to receive(:shutdown)
      expect { |block| supervisor.start(&block) }.to yield_with_args(supervisor)

      frontend = Mxrb::RubyApp::Supervisor.new(root, frontend: true)
      allow(frontend).to receive(:external_backend?).and_return(true)
      allow(frontend).to receive(:spawn_backend).and_return(102)
      allow(frontend).to receive(:spawn_frontend).and_return(202)
      allow(Process).to receive(:wait).with(202).and_raise(Errno::ECHILD)
      allow(frontend).to receive(:shutdown)
      expect(frontend.start).to be_nil

      internal = Mxrb::RubyApp::Supervisor.new(root, frontend: false)
      allow(internal).to receive(:external_backend?).and_return(false)
      fake_server = double(start: nil, shutdown: nil)
      fake_thread = double(join: nil)
      allow(Mxrb::RubyApp::Server).to receive(:new).and_return(fake_server)
      allow(Thread).to receive(:new).and_return(fake_thread)
      internal.start

      shutdown = Mxrb::RubyApp::Supervisor.new(root)
      shutdown.instance_variable_set(:@server, fake_server)
      shutdown.instance_variable_set(:@frontend_pid, 301)
      shutdown.instance_variable_set(:@backend_pid, 302)
      shutdown.instance_variable_set(:@backend, fake_thread)
      allow(Process).to receive(:kill)
      allow(Process).to receive(:wait)
      shutdown.shutdown
      shutdown.send(:terminate, nil)
      allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
      expect(shutdown.shutdown).to be_nil

      empty = File.join(dir, 'empty')
      FileUtils.mkdir_p(empty)
      missing_package = Mxrb::RubyApp::Supervisor.new(empty)
      expect { missing_package.send(:spawn_frontend) }.to raise_error(ArgumentError, /package not found/)
      FileUtils.mkdir_p(File.join(empty, 'frontend'))
      File.write(File.join(empty, 'frontend', 'package.json'), '{}')
      expect { missing_package.send(:spawn_frontend) }.to raise_error(ArgumentError, /dependencies missing/)
    end
  end

  it 'covers remaining compact defensive branches across codecs, manifests, and initialization' do
    expect { Mxrb::Initializer.new('App', mode: :invalid) }.to raise_error(ArgumentError, /mode/)
    Dir.mktmpdir do |dir|
      library = File.expand_path('../lib', __dir__)
      removed = $LOAD_PATH.delete(library)
      result = Mxrb::Initializer.new('PlainRuby', mode: :ruby).scaffold(into: dir)
      expect(result.root).to end_with('PlainRuby')
    ensure
      $LOAD_PATH.unshift(library) if removed && !$LOAD_PATH.include?(library)
    end

    stub_const('Mxrb::CLI::Help::SUBCOMMAND_HELP', {})
    expect(Mxrb::CLI::Help.group_commands('cache')).to include('cache status')
    expect do
      allow(FileUtils).to receive(:mkdir_p).and_raise(Errno::EACCES)
      Mxrb::CLI::Releases.new(cache_path: '/denied/cache').send(:write_cache, {})
    end.to raise_error(Errno::EACCES)
    allow(FileUtils).to receive(:mkdir_p).and_call_original

    uuid = SecureRandom.uuid
    bytes = [uuid.delete('-')].pack('H*')
    encoded = Base64.strict_encode64(bytes)
    expect(Mxrb::IO::BsonCodec.extract_id(
             '$binary' => { 'base64' => encoded, 'subType' => '04' }
           )).to match(/\A[0-9a-f-]{36}\z/)
    expect(Mxrb::IO::BsonCodec.send(:extended_binary, '$binary' => {})).to be_nil

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Legacy.mpr')
      diagram_project(path)
      mpr = Mxrb::IO::MprFile.open(path, readonly: false)
      db = mpr.instance_variable_get(:@db)
      db.execute('DROP TABLE IF EXISTS _MxrbRubySource')
      db.execute('CREATE TABLE _MxrbRubySource (Path TEXT PRIMARY KEY, Contents BLOB, Sha256 TEXT)')
      db.execute("INSERT INTO _MxrbRubySource VALUES ('app/file.rb', 'a', 'b')")
      db.execute("INSERT INTO _MxrbRubySource VALUES ('bin/server', 'a', 'b')")
      expect(mpr.ruby_app_sources.map { _1.fetch(:mode) }).to contain_exactly(0o644, 0o755)
      readonly = Mxrb::IO::MprFile.open(path, readonly: true)
      expect { readonly.write_ruby_app_sources([]) }.to raise_error(Mxrb::ReadOnlyError)
      expect { readonly.write_legacy_unit_identity_mismatches([]) }.to raise_error(Mxrb::ReadOnlyError)
    ensure
      readonly&.close
      mpr&.close
    end

    expect(Mxrb::RubyApp.source_bundle(Dir.mktmpdir)).to eq([])
    expect { Mxrb::RubyApp.safe_source_path('.', '/absolute') }.to raise_error(Mxrb::ValidationError)
    expect { Mxrb::RubyApp.safe_source_mode(0o1000, 'file') }.to raise_error(Mxrb::ValidationError)
    expect { Mxrb::RubyApp.transition('/missing.mpr', '11.12.1') }.to raise_error(Mxrb::Error)
    Mxrb::RubyApp::Registry.remove_instance_variable(:@records) if
      Mxrb::RubyApp::Registry.instance_variable_defined?(:@records)
    expect(Mxrb::RubyApp::Registry.all(:record)).to eq({})
  end

  it 'covers remaining diagram projection and layout representation branches' do
    document = Mxrb::DomainDiagram::Document.allocate
    expect(document.send(:module_payload, double(domain_model: nil), {})).to be_nil
    entity = double(
      id: 'entity', name: 'Entity', qualified_name: nil, persistable: false,
      location: nil, attributes: []
    )
    expect(document.send(:entity_payload, entity, 'Sales')).to include(
      qualified_name: 'Sales.Entity', x: 0, y: 0
    )
    association = double(from_entity_id: 'missing', to_entity_id: 'other')
    expect(document.send(:association_payload, association, {}, {})).to be_nil
    expect { Mxrb::DomainDiagram::Document.new('/missing.mpr').to_h }.to raise_error(Mxrb::Error)

    writer = Mxrb::DomainDiagram::LayoutWriter.allocate
    fake_mpr = double(children_of: [])
    expect do
      writer.send(:apply_module, fake_mpr, { 'UnitID' => 'module' }, 'name' => 'NoDomain')
    end.to raise_error(Mxrb::ValidationError, /domain model/)
    expect { Mxrb::DomainDiagram::LayoutWriter.new('/missing.mpr').apply!('modules' => []) }
      .to raise_error(Mxrb::Error)

    unchanged = {
      'Entities' => Mxrb::IO::BsonCodec.build_array([
                                                      { '$ID' => 'one', 'Location' => { 'x' => 1, 'y' => 2 } },
                                                      { '$ID' => 'two', 'Location' => '3;4' }
                                                    ]),
      'Associations' => Mxrb::IO::BsonCodec.build_array([{ '$ID' => 'association' }]),
      'CrossAssociations' => Mxrb::IO::BsonCodec.build_array([{ '$ID' => 'cross-association' }])
    }
    expect(writer.send(:update_entities, unchanged, [
                         { 'id' => 'one', 'x' => 1, 'y' => 2 }, { 'id' => 'two', 'x' => 3, 'y' => 4 }
                       ])).to eq(0)
    expect(writer.send(:update_associations, unchanged, [])).to eq([0, []])

    Dir.mktmpdir do |dir|
      source = File.join(dir, 'Shop.mpr')
      diagram_project(source)
      FileUtils.mkdir_p(File.join(dir, 'mprcontents'))
      File.write(File.join(dir, 'mprcontents', 'asset'), 'x')
      server = Mxrb::DomainDiagram::Server.new(source)
      expect(server.output).to end_with('.domain-layout.mpr')
    end
  end

  it 'covers remaining native scalar and graph branch alternatives' do
    store = Mxrb::Runtime::Native::Store.new
    expect(store.retrieve_association('missing', nil)).to eq([])
    expression = Mxrb::Runtime::Native::Expression.new
    expect(expression.evaluate('empty', {})).to be_nil
    expect(expression.send(:matching_parenthesis, "(')')", 0)).to eq(4)
    expect(expression.send(:mendix_string, true)).to eq('true')
    expect(expression.send(:mendix_string, false)).to eq('false')
    expect(expression.send(:substring, 'abc', 1)).to eq('bc')
    expect { expression.evaluate('1 2', {}) }.to raise_error(Mxrb::NativeRuntimeError)
    expect { expression.evaluate('1 +', {}) }.to raise_error(Mxrb::NativeRuntimeError)
    expect { expression.evaluate('(1', {}) }.to raise_error(Mxrb::NativeRuntimeError)

    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Native.mpr')
      ruby_project(path)
      project = Mxrb::Model::Project.open(path)
      interpreter = Mxrb::Runtime::Native::Interpreter.new(project)
      attribute = Struct.new(:type, :default_value)
      expect(interpreter.send(:attribute_default, attribute.new(:integer, ''))).to be_nil
      expect(interpreter.send(:attribute_default, attribute.new(:decimal, ''))).to be_nil
      expect(interpreter.send(:attribute_default, attribute.new(:unknown, 'x'))).to eq('x')
      expect(interpreter.send(
               :execute_collection, [{ '$Type' => 'Microflows$BreakEvent', '$ID' => 'break' }],
               {}, {}, label: 'nested'
             )).to eq([:break, nil])
      expect(interpreter.send(
               :execute_collection, [{ '$Type' => 'Microflows$ContinueEvent', '$ID' => 'continue' }],
               {}, {}, label: 'nested'
             )).to eq([:continue, nil])
      expect(interpreter.send(
               :execute_collection, [{ '$Type' => 'Microflows$ActionActivity', '$ID' => 'action',
                                       'Action' => { '$Type' => 'Microflows$CommitAction' } }],
               {}, {}, label: 'nested'
             )).to eq([:complete, nil])
      no_break = [{ '$Type' => 'Microflows$EndEvent', '$ID' => 'end', 'ReturnValue' => '1' }]
      variables = { 'list' => [1] }
      interpreter.send(
        :execute_iterable_loop,
        { 'ListVariableName' => 'list', 'VariableName' => 'item' }, no_break, {}, variables, label: 'items'
      )
      interpreter.instance_variable_set(:@associations, {})
      object = interpreter.store.create('Sales.Order')
      vars = { 'order' => object }
      interpreter.send(
        :action_association_retrieve, { 'ResultVariableName' => 'values' },
        { 'StartVariableName' => 'order', 'AssociationId' => 'Unknown.Relation' }, vars
      )
      expect(vars.fetch('values')).to eq([])
      expect(interpreter.send(:identifier, 'already')).to eq('already')
    ensure
      project&.close
    end
  end

  it 'covers remaining synchronization success and server lifecycle paths' do
    synchronizer = Mxrb::RubyApp::Synchronizer.allocate
    safe_plan = double(safe?: true, changes: [])
    expect(safe_plan).to receive(:apply!).twice
    Mxrb::RubyApp::Registry.reset!
    synchronizer.instance_variable_set(
      :@manifest, double(modules: [{ 'models' => [{ 'name' => 'Sales.Legacy' }], 'dtos' => [] }])
    )
    synchronizer.send(:synchronize_entities, double(plan_remove_entity: safe_plan))
    attribute = Struct.new(:name).new('Old')
    synchronizer.send(
      :synchronize_attributes, double(plan_remove_attribute: safe_plan),
      'Sales.Order', double(attributes: [attribute]), []
    )

    Dir.mktmpdir do |dir|
      root = export_ruby_app(dir)
      expect { Mxrb::RubyApp::Server.new(root, host: 'public.example') }
        .to raise_error(ArgumentError, /loopback/)
      server = Mxrb::RubyApp::Server.new(root, port: 0)
      fake_http = instance_double(Mxrb::Http::Server, shutdown: nil)
      puma = instance_double(Puma::Server)
      allow(fake_http).to receive(:start).and_yield(puma)
      allow(Mxrb::Http::Server).to receive(:new).and_return(fake_http)
      expect { |block| server.start(&block) }.to yield_with_args(puma)
      server.start
      server.shutdown

      request = Struct.new(:path, :request_method, :body, :query, :headers) do
        def [](name) = headers[name]
      end
      response = Struct.new(:status, :body, :headers) do
        def []=(name, value)
          headers[name] = value
        end
      end
      output = response.new(nil, nil, {})
      server.send(
        :dispatch, request.new('/api/entities/Sales.Order/id', 'GET', '', {}, {}), output
      )
      expect(output.status).to eq(404)
      expect(server.send(:request_json, request.new('/', 'POST', '', {}, {}))).to eq({})

      adapter = Mxrb::RubyApp::RackAdapter.new(root)
      rack_request = adapter.send(
        :rack_request,
        'rack.input' => nil, 'SCRIPT_NAME' => '', 'PATH_INFO' => '/', 'QUERY_STRING' => ''
      )
      expect(rack_request.body).to eq('')
      adapter.close
      empty_supervisor = Mxrb::RubyApp::Supervisor.new(root, frontend: false)
      empty_supervisor.shutdown
    end
  end

  it 'covers preset and exporter idempotency and fallback branches' do
    Dir.mktmpdir do |dir|
      root = export_ruby_app(dir)
      expect { Mxrb::RubyApp::Preset.new(root, :invalid) }.to raise_error(ArgumentError, /Ruby stack/)
      FileUtils.rm_f(File.join(root, 'Gemfile'))
      preset = Mxrb::RubyApp::Preset.new(root, :onrails)
      preset.send(:ensure_gems)
      preset.send(:ensure_gems)
      FileUtils.rm_f(File.join(root, 'README.md'))
      preset.send(:append_readme)
      preset.send(:append_readme)
      marker = File.join(root, Mxrb::RubyApp::Preset::MARKER_PATH)
      expect(preset.send(:baseline_file?, marker)).to be(true)
      expect(preset.send(:ruby_constant, '123')).to start_with('Application')

      exporter = Mxrb::RubyApp::Exporter.new(
        File.join(dir, 'missing.mpr'), File.join(dir, 'output'), mendix_sidecar: root
      )
      expect { exporter.send(:read_embedded_sources) }.to raise_error(Mxrb::Error)
      expect do
        exporter.send(:restore_embedded_sources, [
                        { path: 'file', contents: 'x', sha256: 'wrong', mode: 0o644 }
                      ])
      end.to raise_error(Mxrb::SerializationError, /checksum/)
      expect(exporter.send(:rest_success_status, nil)).to eq(200)
      expect(exporter.send(:rest_success_status, '404 Not Found')).to eq(404)
      expect(exporter.send(:rest_success_status, { 'Name' => 'Created' })).to eq(201)
      expect(exporter.send(
        :rest_operation_manifest, double(name: 'Sales'), { 'Path' => '' }, {},
        { 'Microflow' => 'Ping', 'Path' => '', 'SuccessStatusCode' => nil }
      ).fetch('microflow')).to eq('Sales.Ping')

      flow = double(
        id: 'flow', parameters: [nil, { 'Name' => 'Value' }],
        objects: [
          { '$ID' => 'end', '$Type' => 'Microflows$EndEvent', 'ReturnValue' => '1' },
          { '$ID' => 'action', '$Type' => 'Microflows$ActionActivity', 'Action' => {} }
        ],
        flows: [{ 'IsErrorHandler' => true }]
      )
      plan = exporter.send(:nanoflow_plan, flow, 'Sales.Flow')
      expect(plan.fetch('parameters')).to eq(['Value'])
      expect(plan.fetch('objects').map { _1.fetch('type') }).to contain_exactly('EndEvent', 'ActionActivity')
      expect(exporter.send(:nanoflow_action, '$Type' => 'Microflows$UnknownAction'))
        .to eq('type' => 'Unknown')
      expect(exporter.send(:widget_manifest, type: :text, name: 'x')).to eq(
        'type' => 'text', 'name' => 'x'
      )
      expect(exporter.send(:ruby_constant, '', suffix: 'Dto')).to eq('ArtifactDto')
      expect(exporter.send(:ruby_method_name, 'class')).to eq('field_class')
      expect(exporter.send(:ruby_method_name, '')).to eq('field')
    end
  end

  it 'closes the remaining parser, diagram, exporter, and writer alternatives' do
    doc = { '$ID' => 'page', '$Type' => 'Pages$Page', 'Name' => 'Branches', 'Widgets' => [3] }
    page = Mxrb::Model::Page.new(
      { 'UnitID' => 'page', 'ContainmentName' => 'Documents' }, double(parse_contents: doc)
    )
    widget = {
      '$Type' => 'Pages$Text', 'Name' => 'Text',
      'Content' => { 'Parameters' => [3, { 'Expression' => '$Value' }] },
      'OnClickAction' => { '$Type' => 'Pages$SaveChangesClientAction' }
    }
    expect(page.send(:widget_options, widget, :text)).to include(parameters: ['$Value'])
    expect(page.send(:container_events, widget)).not_to be_empty
    allow(page).to receive(:gallery_widget).and_return(type: :gallery)
    expect(page.send(
             :pluggable_widget,
             'Type' => { 'WidgetId' => 'com.mendix.widget.web.gallery.Gallery' }
           )).to eq(type: :gallery)

    allow(Mxrb::Model::Project).to receive(:open).and_raise(Mxrb::Error, 'open failed')
    expect { Mxrb::DomainDiagram::Document.new('x').to_h }.to raise_error(Mxrb::Error)
    allow(Mxrb::Model::Project).to receive(:open).and_call_original
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Diagram.mpr')
      diagram_project(path)
      expect do
        Mxrb::DomainDiagram::LayoutWriter.new(path).apply!(
          'modules' => [{ 'name' => 'Missing' }]
        )
      end.to raise_error(Mxrb::ValidationError, /module/)
    end
    layout_writer = Mxrb::DomainDiagram::LayoutWriter.allocate
    native_doc = {
      'entities' => Mxrb::IO::BsonCodec.build_array([
                                                      { '$ID' => 'one', 'location' => '1;2' }
                                                    ]),
      'associations' => Mxrb::IO::BsonCodec.build_array([])
    }
    expect(layout_writer.send(:update_entities, native_doc, [{ 'id' => 'one', 'x' => 1, 'y' => 2 }])).to eq(0)
    fake_mpr = double(
      children_of: [{ 'UnitID' => 'domain', 'ContainmentName' => 'DomainModel' }],
      parse_contents: native_doc
    )
    expect(fake_mpr).not_to receive(:update_unit)
    expect(layout_writer.send(
             :apply_module, fake_mpr, { 'UnitID' => 'module' },
             'name' => 'Sales', 'entities' => [], 'associations' => []
           )).to eq([0, []])

    expression = Mxrb::Runtime::Native::Expression.new
    expect(expression.evaluate('5 - 2', {})).to eq(3)
    expect(expression.evaluate('6 / 2', {})).to eq(3)
    expect(expression.evaluate('not false', {})).to be(true)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Native.mpr')
      ruby_project(path)
      project = Mxrb::Model::Project.open(path)
      interpreter = Mxrb::Runtime::Native::Interpreter.new(project)
      attribute = Struct.new(:type, :default_value)
      expect(interpreter.send(:attribute_default, attribute.new(:integer, '1'))).to eq(1)
      expect(interpreter.send(:attribute_default, attribute.new(:decimal, '1.0'))).to eq(1.0)
      flow = Struct.new(:name, :objects, :flows).new('Nil', [], [])
      allow(interpreter).to receive(:execute_collection).and_return(nil)
      expect(interpreter.send(:execute, flow, {})).to be_nil
      allow(interpreter).to receive(:execute_collection).and_call_original
      allow(interpreter).to receive(:identifier) do |value|
        value.is_a?(Hash) ? value['$ID'] : value
      end
      action = { '$Type' => 'Microflows$ActionActivity', '$ID' => 'action',
                 'Action' => { '$Type' => 'Microflows$CommitAction' } }
      edge = { 'DestinationPointer' => 'missing' }
      expect(interpreter.send(
               :execute_collection, [action], { 'action' => [edge] }, {}, label: 'nested'
             )).to eq([:complete, nil])
      unknown_edge = { 'DestinationPointer' => 'outside' }
      expect(interpreter.send(
               :collection_entry, [action], { 'action' => action }, { 'action' => [unknown_edge] }, root: false
             )).to eq(action)
      native_expression = interpreter.instance_variable_get(:@expression)
      allow(native_expression).to receive(:evaluate).and_return(true, false)
      allow(interpreter).to receive(:execute_collection).and_return(nil)
      expect(interpreter.send(
               :execute_while_loop, { 'WhileExpression' => 'x' }, [], {}, {}, label: 'while'
             )).to be_nil
      allow(native_expression).to receive(:evaluate).and_return(true)
      allow(interpreter).to receive(:execute_collection).and_return([:break, nil])
      expect(interpreter.send(
               :execute_while_loop, { 'WhileExpression' => 'x' }, [], {}, {}, label: 'while'
             )).to be_nil
      allow(interpreter).to receive(:execute_collection).and_return(nil)
      variables = { 'list' => [1] }
      interpreter.send(
        :execute_iterable_loop,
        { 'ListVariableName' => 'list', 'VariableName' => 'item' }, [], {}, variables, label: 'items'
      )
    ensure
      project&.close
    end

    Dir.mktmpdir do |dir|
      root = export_ruby_app(dir)
      ignored = File.join(root, 'frontend', 'node_modules', 'ignored.js')
      FileUtils.mkdir_p(File.dirname(ignored))
      File.write(ignored, 'ignored')
      expect(Mxrb::RubyApp.source_bundle(root).map do
        _1.fetch(:path)
      end).not_to include('frontend/node_modules/ignored.js')
      manifest = Mxrb::RubyApp::Manifest.load(root)
      expect(manifest.absolute_path('runtime_mpr')).to start_with(root)
      synchronizer = Mxrb::RubyApp::Synchronizer.new(
        root, manifest.absolute_path('runtime_mpr'), manifest:
      )
      allow(synchronizer).to receive(:synchronize_entities).and_raise(Mxrb::ValidationError, 'stop')
      expect { synchronizer.synchronize! }.to raise_error(Mxrb::ValidationError, /stop/)
      broken = Mxrb::RubyApp::Synchronizer.allocate
      broken.instance_variable_set(:@root, root)
      broken.instance_variable_set(:@target, File.join(dir, 'missing.mpr'))
      expect { broken.send(:embed_sources!) }.to raise_error(Mxrb::Error)

      server = Mxrb::RubyApp::Server.new(root, port: 0)
      server.shutdown
      manifest_data = JSON.parse(File.read(File.join(root, Mxrb::RubyApp::MANIFEST_PATH)))
      sales = manifest_data.fetch('modules').find { _1.fetch('name') == 'Sales' }
      sales['endpoints'] = [{
        'name' => 'NoCors', 'enable_cors' => false, 'requires_authentication' => false,
        'operations' => [{
          'method' => 'GET', 'path' => '/rest/no-cors', 'microflow' => 'Sales.Ping',
          'success_status' => 200
        }]
      }]
      File.write(File.join(root, Mxrb::RubyApp::MANIFEST_PATH), JSON.generate(manifest_data))
      no_cors = Mxrb::RubyApp::Server.new(root, port: 0)
      request = Struct.new(:path, :request_method, :body, :query, :headers) do
        def [](name) = headers[name]
      end.new('/rest/no-cors', 'GET', '', {}, {})
      response = Struct.new(:status, :body, :headers) do
        def []=(name, value)
          headers[name] = value
        end
      end.new(nil, nil, {})
      no_cors.send(:dispatch, request, response)
      expect(response.headers).not_to have_key('Access-Control-Allow-Origin')
      preset = Mxrb::RubyApp::Preset.new(root, :flymetothemoon)
      existing = File.join(root, 'existing.txt')
      File.write(existing, 'old')
      preset.send(:write, 'existing.txt', 'new')
      expect(File.read(existing)).to eq('old')

      source = File.join(dir, 'source.mpr')
      ruby_project(source)
      FileUtils.mkdir_p(File.join(dir, 'mprcontents'))
      File.write(File.join(dir, 'mprcontents', 'asset'), 'x')
      exporter = Mxrb::RubyApp::Exporter.new(
        source, File.join(dir, 'exported'), mendix_sidecar: root
      )
      expect(File).to exist(exporter.send(:copy_runtime_mpr))
      expect(exporter.send(:export_endpoints, double(infrastructure_documents: [{ type: 'Other' }]))).to eq([])
      allow(Mxrb::IO::BsonCodec).to receive(:parse_array).and_raise(ArgumentError)
      expect(exporter.send(:native_items, ['value'])).to eq(['value'])
      widget_manifest = exporter.send(
        :widget_manifest,
        type: :button, name: 'Button', events: [{ kind: :action }]
      )
      expect(widget_manifest.fetch('events')).not_to be_empty
      theme = File.join(root, 'theme')
      FileUtils.mkdir_p(theme)
      File.write(File.join(theme, 'theme.txt'), 'theme')
      exporter.send(:copy_frontend_theme)
    ensure
      no_cors&.application&.close
      server&.application&.close
    end

    Dir.mktmpdir do |dir|
      manifest_path = File.join(dir, 'sources.json')
      File.write(manifest_path, JSON.generate(files: [{
        path: 'file.rb', contents: Base64.strict_encode64('x'), sha256: 'wrong'
      }]))
      writer = Mxrb::Writer.new(
        File.join(dir, 'out.mpr'), version: '11.12.1', modules: [], ruby_app_sources_path: manifest_path
      )
      expect { writer.send(:ruby_app_source_files) }
        .to raise_error(Mxrb::SerializationError, /checksum mismatch/)

      stable = { 'UnitID' => 'stable' }
      mpr = double(
        unit: stable, parse_contents: { '$Type' => 'Type', '$ID' => 'stable' },
        children_of: []
      )
      expect(mpr).to receive(:update_unit)
      expect(writer.send(
               :upsert_native_unit, mpr, 'container',
               'unit_id' => 'stable', 'containment' => 'Documents', 'doc' => { '$Type' => 'Type' }
             )).to eq('stable')

      compatibility = double
      expect(compatibility).to receive(:write_legacy_unit_identity_mismatches).with([])
      allow(compatibility).to receive(:unit).and_return(nil, { 'UnitID' => 'second' })
      allow(compatibility).to receive(:parse_contents).and_return(
        '$ID' => 'different', '$Type' => 'Other'
      )
      writer.send(:write_native_compatibility, compatibility, [
                    { 'unit_id' => 'first', 'doc' => { '$ID' => 'content', '$Type' => 'Type' } },
                    { 'unit_id' => 'second', 'doc' => { '$ID' => 'content', '$Type' => 'Type' } }
                  ])
    end
  end

  it 'covers nil project cleanup in diagram projection and version transition' do
    allow(Mxrb::Model::Project).to receive(:open).and_return(nil)
    expect { Mxrb::DomainDiagram::Document.new('nil-project').to_h }.to raise_error(NoMethodError)
    expect { Mxrb::RubyApp.transition('nil-project', '11.12.1') }.to raise_error(NoMethodError)
  end

  it 'skips an unnecessary Mendix version transition' do
    project = instance_double(Mxrb::Model::Project, mendix_version: '11.12.1')
    allow(Mxrb::Model::Project).to receive(:open).and_return(project)
    expect(project).not_to receive(:migrate_to!)
    expect(project).to receive(:close)

    expect(Mxrb::RubyApp.transition('current-version.mpr', '11.12.1')).to be_nil
  end

  it 'covers empty custom-widget schemas and caption fallbacks' do
    page = Mxrb::Model::Page.allocate
    grid = page.send(
      :data_grid2_widget,
      'Name' => 'Grid', 'Object' => {}, 'Type' => {}
    )
    expect(grid).to include(type: :data_grid, name: 'Grid', options: { columns: [] })

    exporter = Mxrb::RubyApp::Exporter.allocate
    expect(exporter.send(:translated_caption, nil, 'Fallback')).to eq('Fallback')
  end
end
# rubocop:enable Metrics/BlockLength
