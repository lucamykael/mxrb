# frozen_string_literal: true

require 'json'
require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::DomainDiagram do
  def build_project(path) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Sales) do
        entity(:Customer) do
          string :Name, required: true
          string :ExternalID, unique: true
        end
        entity(:Order) do
          string :Number
          decimal :Total
          association 'Sales.Customer', name: :Order_Customer
          association 'Logistics.Shipment', name: :Order_Shipment
        end
        entity(:OrderPayload) { non_persistent! }
        entity(:OrderSummary) { oql_view query: 'SELECT Number FROM Sales.Order' }
      end
      self.module(:Logistics) { entity(:Shipment) { string :TrackingCode } }
      self.module(:EmptyModule)
    end
  end

  it 'projects arbitrary modules as ER entities, attributes, and relationships' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Shop.mpr')
      build_project(path)
      payload = described_class::Document.new(path).to_h

      expect(payload.dig(:project, :name)).to eq('Shop')
      sales = payload.fetch(:modules).find { _1.fetch(:name) == 'Sales' }
      expect(sales.fetch(:entities).map { _1.fetch(:name) })
        .to contain_exactly('Customer', 'Order', 'OrderPayload', 'OrderSummary')
      expect(sales.fetch(:entities).find { _1.fetch(:name) == 'Customer' }.fetch(:attributes))
        .to include(include(name: 'Name', required: true), include(name: 'ExternalID', key: true))
      expect(sales.fetch(:entities)).to include(
        include(name: 'Customer', kind: 'entity'),
        include(name: 'OrderPayload', kind: 'dto'),
        include(name: 'OrderSummary', kind: 'oql_view')
      )
      expect(sales.fetch(:associations)).to include(
        include(name: 'Order_Customer', from: 'Sales.Order', to: 'Sales.Customer',
                source_anchor: 'west', target_anchor: 'east', anchor_storage: 'native'),
        include(name: 'Order_Shipment', from: 'Sales.Order', to: 'Logistics.Shipment',
                cross_module: true, editable_anchors: true, anchor_storage: 'mxrb')
      )
      filtered = described_class::Document.new(path, modules: %w[Sales Logistics]).to_h
      expect(filtered.fetch(:module_filter_applied)).to be(true)
      expect(filtered.fetch(:modules).map { _1.fetch(:name) }).to contain_exactly('Sales', 'Logistics')
      expect { described_class::Document.new(path, modules: ['Missing']).to_h }
        .to raise_error(ArgumentError, /unknown modules: Missing/)
    end
  end

  it 'writes only entity positions and association anchors into a valid MPR' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'Shop.mpr')
      build_project(path)
      sales = described_class::Document.new(path, modules: ['Sales']).to_h.fetch(:modules).first
      customer = sales.fetch(:entities).find { _1.fetch(:name) == 'Customer' }
      order = sales.fetch(:entities).find { _1.fetch(:name) == 'Order' }
      association = sales.fetch(:associations).first
      cross_association = sales.fetch(:associations).find { _1.fetch(:cross_module) }
      payload = {
        'modules' => [{
          'name' => 'Sales',
          'entities' => [
            { 'id' => customer.fetch(:id), 'x' => 420, 'y' => 130 },
            { 'id' => order.fetch(:id), 'x' => 80, 'y' => 130 }
          ],
          'associations' => [
            {
              'id' => association.fetch(:id),
              'source_anchor' => 'north', 'target_anchor' => 'south'
            },
            {
              'id' => cross_association.fetch(:id),
              'source_anchor' => 'south', 'target_anchor' => 'north'
            }
          ]
        }]
      }

      expect(described_class::LayoutWriter.new(path).apply!(payload)).to eq(4)
      expect(Mxrb.validate(path)).to be_valid
      updated = described_class::Document.new(path, modules: ['Sales']).to_h.fetch(:modules).first
      expect(updated.fetch(:entities).find { _1.fetch(:name) == 'Customer' })
        .to include(x: 420, y: 130)
      expect(updated.fetch(:associations).first)
        .to include(source_anchor: 'north', target_anchor: 'south')
      expect(updated.fetch(:associations).find { _1.fetch(:cross_module) })
        .to include(source_anchor: 'south', target_anchor: 'north')
      expect(described_class::LayoutWriter.new(path).apply!(payload)).to eq(0)

      readonly = Mxrb::IO::MprFile.open(path, readonly: true)
      expect { readonly.write_domain_diagram_anchors([]) }
        .to raise_error(Mxrb::ReadOnlyError)
      readonly.close

      invalid = { 'modules' => [{ 'name' => 'Sales', 'entities' => [{ 'id' => 'forged', 'x' => 0, 'y' => 0 }] }] }
      expect { described_class::LayoutWriter.new(path).apply!(invalid) }
        .to raise_error(Mxrb::ValidationError, /unknown domain entities/)
    end
  end

  it 'serves the DBeaver-style editor and exports to a safe MPR copy' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'Shop.mpr')
      output = File.join(dir, 'Shop-layout.mpr')
      build_project(source)
      server = described_class::Server.new(source, output:, modules: %w[Sales Logistics])
      expect(File).to exist(output)
      html = File.read(File.expand_path('../lib/mxrb/domain_diagram/index.html', __dir__))
      expect(html).to include('Exportar PNG', 'Salvar layout no MPR', 'Auto-organizar')
      expect(html).to include('onpointerdown', 'sourceAnchor', 'targetAnchor', 'toDataURL(\'image/png\')')
      expect(html).to include('visibleModules', 'visibleAssociations', 'startAnchorDrag')
      expect(html).to include('kind-entity', 'kind-dto', 'kind-oql_view', 'OQL view')

      request = Struct.new(:request_method, :path, :body, :headers) do
        def [](name) = headers[name]
      end.new('GET', '/api/diagram', '', {})
      response = Struct.new(:status, :body, :headers) do
        def []=(name, value)
          headers[name] = value
        end
      end.new(nil, nil, {})
      server.send(:dispatch, request, response)
      expect(response.status).to eq(200)
      expect(response.headers.fetch('X-Content-Type-Options')).to eq('nosniff')
      expect(JSON.parse(response.body).fetch('modules').map { _1.fetch('name') })
        .to contain_exactly('Sales', 'Logistics')

      expect do
        described_class::Server.new(source, output:)
      end.to raise_error(ArgumentError, /output already exists/)
      expect { described_class::Server.new(source, output: source, force: true) }
        .to raise_error(ArgumentError, /safe copy/)
    end
  end

  it 'refuses unsafe output aliases and pre-existing external-content destinations' do
    Dir.mktmpdir do |dir|
      source_dir = File.join(dir, 'source')
      target_dir = File.join(dir, 'target')
      FileUtils.mkdir_p(File.join(source_dir, 'mprcontents'))
      FileUtils.mkdir_p(File.join(target_dir, 'mprcontents'))
      source = File.join(source_dir, 'Shop.mpr')
      build_project(source)
      File.binwrite(File.join(source_dir, 'mprcontents', 'asset.bin'), 'source')
      existing = File.join(target_dir, 'mprcontents', 'asset.bin')
      File.binwrite(existing, 'unrelated')

      expect do
        described_class::Server.new(source, output: File.join(target_dir, 'Shop-layout.mpr'))
      end.to raise_error(ArgumentError, /external contents destination already exists/)
      expect(File.binread(existing)).to eq('unrelated')
      expect(File).not_to exist(File.join(target_dir, 'Shop-layout.mpr'))

      hard_link = File.join(dir, 'hard-link.mpr')
      File.link(source, hard_link)
      expect { described_class::Server.new(source, output: hard_link, force: true) }
        .to raise_error(ArgumentError, /safe copy/)
    end
  end

  it 'runs the managed up, status, down, resume, and destroy lifecycle' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'Shop.mpr')
      state_root = File.join(dir, 'state')
      build_project(source)
      lifecycle = described_class::Lifecycle.new(
        source, state_root:, executable: File.expand_path('../bin/mxrb', __dir__)
      )
      allow(lifecycle).to receive(:spawn_worker).and_return(12_345)
      allow(Process).to receive(:detach).with(12_345)
      allow(lifecycle).to receive(:running?).and_return(false, true, true)

      running = lifecycle.up(modules: %w[Sales Logistics], port: 4578)
      expect(running).to be_running
      expect(running.url).to eq('http://127.0.0.1:4578')
      expect(File).to exist(running.output)

      ok = Net::HTTPOK.new('1.1', '200', 'OK')
      allow(lifecycle).to receive(:running?).and_return(true, false, false)
      allow(lifecycle).to receive(:request).and_return(ok)
      stopped = lifecycle.down
      expect(stopped.state).to eq('stopped')
      expect(File).to exist(stopped.output)

      allow(lifecycle).to receive(:running?).and_return(false)
      destroyed = lifecycle.destroy(confirm: true)
      expect(destroyed.state).to eq('absent')
      expect(File).not_to exist(stopped.output)
      expect(lifecycle.status.state).to eq('absent')
    end
  end

  it 'protects lifecycle control routes with the private token' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'Shop.mpr')
      output = File.join(dir, 'layout.mpr')
      build_project(source)
      server = described_class::Server.new(source, output:, lifecycle_token: 'secret')
      request_class = Struct.new(:request_method, :path, :body, :headers) do
        def [](name) = headers[name]
      end
      response_class = Struct.new(:status, :body, :headers) do
        def []=(name, value)
          headers[name] = value
        end
      end
      dispatch = lambda do |method, path, headers = {}|
        response = response_class.new(nil, nil, {})
        server.send(:dispatch, request_class.new(method, path, '', headers), response)
        response
      end

      expect(dispatch.call('GET', '/api/admin/status').status).to eq(403)
      expect(dispatch.call(
        'GET', '/api/admin/status', 'X-MXRB-Lifecycle-Token' => 'secret'
      ).status).to eq(200)
      expect(dispatch.call(
        'POST', '/api/admin/shutdown', 'X-MXRB-Lifecycle-Token' => 'secret'
      ).status).to eq(200)
      expect(dispatch.call(
        'GET', '/api/admin/unknown', 'X-MXRB-Lifecycle-Token' => 'secret'
      ).status).to eq(404)
      expect(dispatch.call('GET', '/api/unknown').status).to eq(404)
      expect { described_class::Server.new(source, output:, reuse: true) }.not_to raise_error
      expect { described_class::Server.new(source, output: File.join(dir, 'missing.mpr'), reuse: true) }
        .to raise_error(ArgumentError, /output not found/)
    end
  end

  it 'distinguishes an online server from fresh and stale starting state' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'Shop.mpr')
      output = File.join(dir, 'Shop-layout.mpr')
      build_project(source)
      FileUtils.cp(source, output)
      lifecycle = described_class::Lifecycle.new(source, state_root: File.join(dir, 'state'))
      state = {
        'version' => 1, 'source' => source, 'output' => output, 'host' => '127.0.0.1',
        'port' => 4568, 'token' => 'private', 'state' => 'starting', 'pid' => 123,
        'log' => File.join(dir, 'server.log'), 'managed_paths' => [output],
        'created_at' => Time.now.utc.iso8601
      }
      lifecycle.send(:write_state, state)
      allow(lifecycle).to receive(:running?).and_return(false)

      expect(lifecycle.status.state).to eq('starting')
      expect { lifecycle.up }.to raise_error(ArgumentError, /already starting/)
      expect { lifecycle.down }.to raise_error(ArgumentError, /still starting/)

      lifecycle.send(:write_state, state.merge('created_at' => (Time.now.utc - 30).iso8601))
      expect(lifecycle.status.state).to eq('stopped')
      expect(lifecycle.down.state).to eq('stopped')
    end
  end

  it 'never destroys a source MPR even if lifecycle state is malformed' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'Shop.mpr')
      build_project(source)
      lifecycle = described_class::Lifecycle.new(source, state_root: File.join(dir, 'state'))
      lifecycle.send(:write_state, {
        'version' => 1, 'source' => source, 'output' => source,
        'host' => '127.0.0.1', 'port' => 4568, 'token' => 'private',
        'state' => 'stopped', 'pid' => nil, 'managed_paths' => [source]
      })
      allow(lifecycle).to receive(:running?).and_return(false)

      expect { lifecycle.destroy(confirm: true) }
        .to raise_error(ArgumentError, /source MPR/)
      expect(File).to exist(source)
    end
  end

  it 'covers lifecycle state roots, retained settings, and worker spawning' do
    Dir.mktmpdir do |dir|
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('MXRB_DIAGRAM_STATE_ROOT').and_return(File.join(dir, 'custom'))
      expect(described_class::Lifecycle.default_state_root).to eq(File.join(dir, 'custom'))
      allow(ENV).to receive(:[]).with('MXRB_DIAGRAM_STATE_ROOT').and_return('')
      expect(described_class::Lifecycle.default_state_root)
        .to eq(File.join(Dir.home, '.local', 'state', 'mxrb', 'diagram-er'))

      source = File.join(dir, 'Shop.mpr')
      output = File.join(dir, 'Shop-layout.mpr')
      build_project(source)
      FileUtils.cp(source, output)
      lifecycle = described_class::Lifecycle.new(
        source, state_root: File.join(dir, 'state'), executable: File.join(dir, 'mxrb')
      )
      previous = {
        'output' => output, 'modules' => ['Sales'], 'port' => 4578,
        'managed_paths' => [output]
      }
      settings = lifecycle.send(:settings_for, previous, output: nil, modules: nil, port: nil)
      expect(settings).to include('output' => output, 'modules' => ['Sales'], 'port' => 4578)
      expect(lifecycle.send(:prepare_output, previous, settings, force: false)).to eq([output])
      defaults = lifecycle.send(:settings_for, nil, output: nil, modules: nil, port: nil)
      expect(defaults).to include('modules' => [], 'port' => 4568)
      expect do
        lifecycle.send(
          :settings_for, previous, output: File.join(dir, 'other.mpr'), modules: [], port: 4568
        )
      end.to raise_error(ArgumentError, /before changing --output/)

      log = File.join(dir, 'worker.log')
      state = settings.merge('token' => 'secret', 'log' => log, 'modules' => %w[Sales Logistics])
      allow(Process).to receive(:spawn).and_return(98_765)
      expect(lifecycle.send(:spawn_worker, state)).to eq(98_765)
      expect(Process).to have_received(:spawn).with(
        RbConfig.ruby, File.join(dir, 'mxrb'), 'diagram-er', '__serve', source,
        '--output', output, '--port', '4578', '--token', 'secret',
        '--state-root', File.join(dir, 'state'), '--module', 'Sales', '--module', 'Logistics',
        out: log, err: %i[child out]
      )
      expect(File.stat(log).mode & 0o777).to eq(0o600)

      expect(lifecycle.send(:prepare_output, previous, settings, force: true))
        .to include(output)
    end
  end

  it 'runs the lifecycle worker and rejects missing or mismatched state' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'Shop.mpr')
      output = File.join(dir, 'Shop-layout.mpr')
      state_root = File.join(dir, 'state')
      build_project(source)
      FileUtils.cp(source, output)
      lifecycle = described_class::Lifecycle.new(source, state_root:)

      expect do
        lifecycle.run_worker(output:, modules: [], port: 4568, token: 'secret')
      end.to raise_error(ArgumentError, /state is missing/)
      expect do
        lifecycle.run_worker(output:, modules: [], port: 4568, token: nil)
      end.to raise_error(ArgumentError, /state is missing/)

      state = {
        'source' => source, 'output' => output, 'host' => '127.0.0.1', 'port' => 4568,
        'token' => 'secret', 'state' => 'starting', 'managed_paths' => [output],
        'created_at' => Time.now.utc.iso8601
      }
      lifecycle.send(:write_state, state)
      expect do
        lifecycle.run_worker(output:, modules: [], port: 4568, token: 'wrong')
      end.to raise_error(ArgumentError, /token does not match/)

      server = instance_double(described_class::Server)
      handlers = {}
      allow(described_class::Server).to receive(:new).and_return(server)
      allow(server).to receive(:start) { |&block| block.call }
      allow(server).to receive(:shutdown)
      allow(lifecycle).to receive(:trap) { |signal, &block| handlers[signal] = block }
      allow(lifecycle).to receive(:mark_stopped).and_call_original

      lifecycle.run_worker(output:, modules: ['Sales'], port: 4568, token: 'secret')
      handlers.values.map(&:call).each(&:join)
      expect(described_class::Server).to have_received(:new).with(
        source, output:, modules: ['Sales'], port: 4568, reuse: true,
                lifecycle_token: 'secret'
      )
      expect(server).to have_received(:shutdown).twice
      expect(lifecycle).to have_received(:mark_stopped).with('secret').at_least(:once)
      expect(lifecycle.status.state).to eq('stopped')
    end
  end

  it 'covers lifecycle command refusal and cleanup branches' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'Shop.mpr')
      output = File.join(dir, 'Shop-layout.mpr')
      build_project(source)
      lifecycle = described_class::Lifecycle.new(source, state_root: File.join(dir, 'state'))
      state = {
        'source' => source, 'output' => output, 'host' => '127.0.0.1', 'port' => 4568,
        'token' => 'secret', 'state' => 'running', 'managed_paths' => [],
        'created_at' => Time.now.utc.iso8601
      }
      lifecycle.send(:write_state, state)

      allow(lifecycle).to receive(:running?).and_return(true)
      expect { lifecycle.up }.to raise_error(ArgumentError, /already running/)
      expect { lifecycle.down }.to raise_error(ArgumentError, /refused/)
      expect { lifecycle.destroy }.to raise_error(ArgumentError, /requires --yes/)

      allow(lifecycle).to receive(:status).and_return(
        described_class::Lifecycle::Status.new('running', source, output, nil, nil, nil)
      )
      allow(lifecycle).to receive(:down)
      allow(lifecycle).to receive(:read_state).and_return(state)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with(lifecycle.send(:instance_dir)).and_return(false)
      expect(lifecycle.destroy(confirm: true).state).to eq('absent')
      expect(lifecycle).to have_received(:down)

      failed = described_class::Lifecycle.new(source, state_root: File.join(dir, 'failed-state'))
      allow(failed).to receive(:running?).and_return(false)
      allow(failed).to receive(:prepare_output).and_return([])
      allow(failed).to receive(:spawn_worker).and_raise(Errno::ENOENT, 'worker')
      allow(failed).to receive(:mark_stopped).and_call_original
      expect { failed.up }.to raise_error(Errno::ENOENT)
      expect(failed).to have_received(:mark_stopped).with(kind_of(String))
    end
  end

  it 'covers lifecycle network, timeout, malformed-state, and removal defenses' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'Shop.mpr')
      output = File.join(dir, 'Shop-layout.mpr')
      build_project(source)
      lifecycle = described_class::Lifecycle.new(source, state_root: File.join(dir, 'state'))
      state = {
        'source' => source, 'output' => output, 'host' => '127.0.0.1', 'port' => 4568,
        'token' => 'secret', 'state' => 'running', 'managed_paths' => [output]
      }

      expect(lifecycle.send(:starting?, state.merge('state' => 'starting', 'created_at' => 'invalid')))
        .to be(false)
      expect(lifecycle.send(:running?, nil)).to be(false)
      expect(lifecycle.send(:running?, state, token: nil)).to be(false)

      ok = Net::HTTPOK.new('1.1', '200', 'OK')
      client = instance_double(Net::HTTP)
      allow(client).to receive(:request).and_return(ok)
      allow(Net::HTTP).to receive(:start).and_yield(client)
      expect(lifecycle.send(:running?, state)).to be(true)
      sent_request = nil
      allow(client).to receive(:request) { |request|
        sent_request = request
        ok
      }
      expect(lifecycle.send(:request, state, Net::HTTP::Post, '/shutdown')).to equal(ok)
      expect(sent_request['X-MXRB-Lifecycle-Token']).to eq('secret')

      allow(Net::HTTP).to receive(:start).and_raise(SocketError, 'offline')
      expect(lifecycle.send(:request, state, Net::HTTP::Get, '/status')).to be_nil

      allow(Process).to receive(:clock_gettime).and_return(0.0, 0.5, 1.0)
      allow(lifecycle).to receive(:sleep)
      expect { lifecycle.send(:wait_until, 1.0) { false } }
        .to raise_error(ArgumentError, /timed out/)
      expect(lifecycle).to have_received(:sleep).with(0.05).once

      external = File.join(dir, 'mprcontents')
      FileUtils.mkdir_p(external)
      lifecycle.send(:remove_managed_path, external, output)
      expect(File).not_to exist(external)
      expect(lifecycle.send(:remove_managed_path, output, output)).to be_nil
      expect do
        lifecycle.send(:remove_managed_path, File.join(dir, 'unmanaged'), output)
      end.to raise_error(ArgumentError, /unmanaged path/)

      lifecycle.send(:prepare_instance_dir)
      File.binwrite(lifecycle.send(:state_path), '{invalid')
      expect { lifecycle.send(:read_state) }.to raise_error(ArgumentError, /invalid diagram lifecycle state/)

      unwritable = described_class::Lifecycle.new(source, state_root: File.join(dir, 'unwritable'))
      allow(unwritable).to receive(:state_path).and_raise(Errno::EACCES, 'state path')
      expect { unwritable.send(:write_state, state) }.to raise_error(Errno::EACCES)
    end
  end
end
# rubocop:enable Metrics/BlockLength
