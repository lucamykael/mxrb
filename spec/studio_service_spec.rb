# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio'
require 'tmpdir'

# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::Service do
  around do |example|
    Dir.mktmpdir('mxrb-studio-service-') do |directory|
      @directory = directory
      original = ENV.fetch('XDG_STATE_HOME', nil)
      isolation = ENV.fetch('MXRB_STUDIO_SYNC_ISOLATION', nil)
      ENV['XDG_STATE_HOME'] = File.join(directory, 'xdg')
      ENV['MXRB_STUDIO_SYNC_ISOLATION'] = 'process'
      example.run
    ensure
      ENV['XDG_STATE_HOME'] = original
      ENV['MXRB_STUDIO_SYNC_ISOLATION'] = isolation
    end
  end

  let(:state_root) { File.join(@directory, 'state') }
  let(:service) { described_class.new(state_root:, repository: fake_repository) }
  let(:notifications) { Queue.new }
  let(:context) do
    Mxrb::Studio::RequestContext.new(id: 1, notifier: ->(name, payload) { notifications << [name, payload] })
  end

  def call(method, params = {}, request = context) = service.dispatch(method, params, request)

  def fake_repository
    root = File.join(@directory, 'fake-mxrb')
    FileUtils.mkdir_p(File.join(root, 'bin'))
    File.write(File.join(root, 'bin', 'mxrb'), <<~RUBY)
      args = ARGV.drop(1)
      $stdout.sync = true
      case args.first
      when 'echo'
        puts args.drop(1).join(' ')
        warn 'to stderr'
        exit 3
      when 'read' then puts "got \#{$stdin.gets}"
      when 'sleep'
        puts 'sleeping'
        sleep 10
      when 'binary' then $stdout.write("\\xFF\\n".b)
      end
    RUBY
    root
  end

  def create_model
    path = File.join(@directory, 'model', 'Shop.mpr')
    FileUtils.mkdir_p(File.dirname(path))
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Shop) { entity(:Product) { string :Name } }
    end
    path
  end

  def wait_for(name)
    loop do
      message = notifications.pop(timeout: 5)
      raise "no #{name} notification" unless message
      return message.last if message.first == name
    end
  end

  it 'lists methods, rejects unknown ones and validates params' do
    expect(service.methods_list).to include('catalog/list', 'sync/run', 'locks/acquire')
    expect { call('nope') }.to raise_error(Mxrb::Studio::Protocol::Failure) { |error|
      expect(error.code).to eq(Mxrb::Studio::Protocol::METHOD_NOT_FOUND)
    }
    expect { call('files/read', []) }.to raise_error(Mxrb::Studio::Protocol::Failure, 'params must be an object')
    expect { service.dispatch('files/read', nil) }.to raise_error(Mxrb::Studio::Protocol::Failure,
                                                                  'missing parameter: root')
    params = described_class::Params.new('a' => 1)
    expect([params['a'], params.key?('a'), params.key?('b'), params.fetch('b', 2)]).to eq([1, true, false, 2])
    expect(described_class.default_state_root).to eq(File.join(@directory, 'xdg', 'mxrb', 'studio'))
    expect(described_class.new.instance_variable_get(:@state_root)).to eq(described_class.default_state_root)
  end

  it 'serves the catalog and prepares task arguments' do
    expect(call('catalog/list').map { _1[:name] }).to include('studio serve')
    expect(call('catalog/arguments', 'command_id' => 'modules', 'values' => { 'model' => 'A.mpr' }))
      .to eq(['modules', 'A.mpr'])
    expect(call('catalog/arguments', 'command_id' => 'modules', 'extra' => '--json'))
      .to eq(['modules', '{mpr}', '--json'])
    expect(call('tasks/prepare', 'command_id' => 'modules', 'substitutions' => { '{mpr}' => '/a b.mpr' }))
      .to eq(['modules', '/a b.mpr'])
    expect(call('tasks/prepare', 'command' => 'tree "My App.mpr"')).to eq(['tree', 'My App.mpr'])
    expect(call('tasks/prepare', 'arguments' => ['--version'])).to eq(['--version'])
    [[], 'x', [1], ["a\0"]].each do |arguments|
      expect { call('tasks/prepare', 'arguments' => arguments) }.to raise_error(ArgumentError, /select an MXRB/)
    end
    expect { call('tasks/prepare', 'arguments' => ['{mpr}']) }.to raise_error(ArgumentError, /unresolved/)
    expect { call('tasks/prepare', 'arguments' => ['x'], 'substitutions' => { 'x' => '' }) }
      .to raise_error(ArgumentError, /unresolved/)
  end

  it 'rejects catalog values that cannot become safe arguments' do
    catalog = Mxrb::Studio::Catalog.new
    expect { catalog.arguments('modules', { 'model' => "a\0b" }) }.to raise_error(ArgumentError, /invalid model/)
    expect { catalog.arguments('modules', {}, extra: ["x\0"]) }.to raise_error(ArgumentError, /extra arguments/)
    expect { catalog.arguments('modules', {}, extra: 'x') }.to raise_error(ArgumentError, /extra arguments/)
    expect { catalog.send(:inferred_positionals, 'unknown thing') }.to raise_error(ArgumentError, /missing Studio/)
    expect(catalog.fetch('studio serve')).to include(effect: 'service', context: 'global')
  end

  it 'replaces the process with the CLI for terminal clients' do
    backend = Mxrb::Studio::Backend.new(service:)
    allow(backend).to receive(:exec)
    backend.execute('directory' => @directory, 'arguments' => ['--version'])
    expect(backend).to have_received(:exec).with(include('NO_COLOR' => '1'), RbConfig.ruby, end_with('bin/mxrb'),
                                                 '--no-progress', '--version', chdir: File.realpath(@directory))
    expect { backend.call('action' => 'bogus') }.to raise_error(ArgumentError, /unknown Studio action/)
  end

  it 'runs tasks streaming their output and exit status' do
    result = call('tasks/run', 'arguments' => %w[echo hello world], 'directory' => @directory, 'task_id' => 't1')
    expect(result).to include(task: 't1', exit_code: 3, success: false, cancelled: false, signal: nil,
                              arguments: %w[echo hello world], directory: File.realpath(@directory))
    messages = []
    messages << notifications.pop until notifications.empty?
    expect(messages.first).to match(['tasks/started', include(task: 't1', pid: Integer)])
    outputs = messages.select { _1.first == 'tasks/output' }.map(&:last)
    expect(outputs).to include({ task: 't1', stream: 'stdout', text: "hello world\n" },
                               { task: 't1', stream: 'stderr', text: "to stderr\n" })
    call('tasks/run', 'arguments' => ['binary'], 'directory' => @directory)
    texts = []
    texts << notifications.pop until notifications.empty?
    expect(texts.find { _1.first == 'tasks/output' }.last[:text]).to be_valid_encoding
    expect { call('tasks/run', 'arguments' => ['echo'], 'directory' => File.join(@directory, 'missing')) }
      .to raise_error(Errno::ENOENT)
    expect { call('tasks/run', 'arguments' => [], 'directory' => @directory) }.to raise_error(ArgumentError)
  end

  it 'writes input to a running task and stops cancelled tasks' do
    runner = Thread.new { call('tasks/run', 'arguments' => ['read'], 'directory' => @directory, 'task_id' => 'in') }
    wait_for('tasks/started')
    expect(call('tasks/input', 'task' => 'in', 'text' => 'PAT')).to eq(written: true)
    expect(call('tasks/input', 'task' => 'in', 'text' => "\n", 'close' => true)).to eq(written: true)
    expect(runner.value).to include(exit_code: 0)
    expect(wait_for('tasks/output')).to include(text: "got PAT\n")
    expect { call('tasks/input', 'task' => 'in', 'text' => 'x') }.to raise_error(ArgumentError, /not running/)

    cancellable = Mxrb::Studio::RequestContext.new(notifier: ->(name, payload) { notifications << [name, payload] })
    runner = Thread.new { call('tasks/run', { 'arguments' => ['sleep'], 'directory' => @directory }, cancellable) }
    wait_for('tasks/output')
    cancellable.cancel!
    expect(runner.value).to include(cancelled: true, signal: Signal.list.fetch('TERM'), success: false)
  end

  it 'closes leases and running tasks with the connection' do
    model = create_model
    runner = Thread.new { call('tasks/run', 'arguments' => ['sleep'], 'directory' => @directory) }
    wait_for('tasks/output')
    lease = call('locks/acquire', 'target' => model)
    service.close
    expect(runner.value).to include(cancelled: true)
    expect(call('locks/status', 'target' => model)).to include(locked: false)
    expect { call('locks/release', 'lease' => lease[:lease]) }.to raise_error(ArgumentError, /unknown lease/)
    finished = Process.spawn(RbConfig.ruby, '-e', 'exit 0', pgroup: true)
    Process.wait(finished)
    expect(service.send(:stop, { pid: finished })).to be_nil
  end

  it 'holds model write locks for clients' do
    model = create_model
    lease = call('locks/acquire', 'target' => model, 'timeout' => 1)
    expect(lease).to include(target: File.realpath(model), path: Mxrb::Studio::WriteLock.path_for(File.realpath(model)))
    expect(call('locks/status', 'target' => model)).to include(locked: true)
    expect { call('locks/acquire', 'target' => model, 'timeout' => 0.1) }.to raise_error(Mxrb::Studio::Busy)
    expect(call('locks/release', 'lease' => lease[:lease])).to eq(released: true)
    expect(call('locks/status', 'target' => model)).to include(locked: false)
  end

  it 'reads, writes and moves workspace files and checks Ruby' do
    root = File.join(@directory, 'ruby')
    FileUtils.mkdir_p(root)
    expect(call('files/create', 'root' => root, 'path' => 'lib', 'directory' => true))
      .to eq(path: 'lib', directory: true)
    expect(call('files/create', 'root' => root, 'path' => 'lib/a.rb')).to eq(path: 'lib/a.rb', directory: false)
    revision = call('files/read', 'root' => root, 'path' => 'lib/a.rb')[:revision]
    expect(call('files/write', 'root' => root, 'path' => 'lib/a.rb', 'text' => "entity :A do\nend\n",
                               'revision' => revision)).to include(path: 'lib/a.rb')
    expect(call('files/move', 'root' => root, 'path' => 'lib/a.rb', 'destination' => 'lib/b.rb'))
      .to eq(path: 'lib/b.rb', previous_path: 'lib/a.rb')
    expect(call('files/list', 'root' => root).map { _1[:name] }).to eq(['lib'])
    expect(call('files/list', 'root' => root, 'path' => 'lib', 'include_ignored' => true).map { _1[:name] })
      .to eq(['b.rb'])
    expect(call('files/worktrees', 'root' => root)).to eq([])
    expect(call('ruby/syntax', 'text' => "def x\nend\n")).to eq(valid: true, diagnostics: [])
    broken = call('ruby/syntax', 'text' => "def x(\n", 'path' => 'x.rb')
    expect(broken[:valid]).to be(false)
    expect(broken[:diagnostics].first).to include(file: 'x.rb', line: 1, severity: 'error')
    expect { call('ruby/syntax', 'text' => 'x' * (Mxrb::Studio::Files::MAXIMUM_BYTES + 1)) }
      .to raise_error(ArgumentError, /4 MiB/)
    expect(call('ruby/declarations', 'text' => "entity :Order do\nend\n", 'path' => 'modules/Shop/x.rb'))
      .to eq([{ kind: 'entity', name: 'Order', qualified_name: 'Shop.Order', line: 1 }])
    expect(call('ruby/declarations', 'text' => 'page "Home"').first).to include(qualified_name: 'Home')
  end

  it 'serves model snapshots, documents, structural edits and their history' do
    model = create_model
    snapshot = call('snapshot/create', 'model' => model, 'destination_root' => File.join(@directory, 'copies'))
    expect(File).to exist(snapshot[:model])
    working = snapshot[:model]
    workspace = File.dirname(File.dirname(working))
    expect(call('model/capabilities', 'model' => working, 'workspace_root' => workspace)[:supported])
      .to include('add_attribute')
    revision = call('model/revision', 'model' => working, 'workspace_root' => workspace)
    operation = { 'operation' => 'add_attribute', 'target' => 'Shop.Product', 'name' => 'Price', 'type' => 'decimal' }
    base = { 'model' => working, 'workspace_root' => workspace }
    expect(call('model/preview', base.merge('operation' => operation, 'revision' => revision))).to include(safe: true)
    applied = call('model/apply', base.merge('operation' => operation, 'revision' => revision))
    expect(applied).to include(applied: true, history: include(label: 'Model operation add_attribute'))
    history = call('model/history', 'model' => working)
    expect(history[:undo].map { _1[:id] }).to eq([applied[:history][:id]])
    expect(call('model/undo', 'model' => working)).to include(direction: 'undo')
    expect(Mxrb.open(working) { |project| project.entities.first.attributes.map(&:name) }).to eq(['Name'])
    expect(call('model/redo', 'model' => working)).to include(direction: 'redo')
    expect(Mxrb.open(working) { |project| project.entities.first.attributes.map(&:name) }).to eq(%w[Name Price])

    documents = call('documents/list', 'model' => working)
    domain = documents.find { _1[:type] == 'DomainModels$DomainModel' }
    read = call('documents/read', 'model' => working, 'unit_id' => domain[:unit_id])
    editable = read[:properties].find { _1[:editable] && _1[:value].is_a?(String) }
    patched = call('documents/patch', 'model' => working, 'unit_id' => domain[:unit_id], 'revision' => read[:revision],
                                      'changes' => { editable[:path] => 'Edited by the IDE' })
    expect(patched).to include(history: include(label: 'Edit document properties'))
    expect(call('model/catalog', 'model' => working)).to be_a(Hash)
    expect(call('model/domainDiagram', 'model' => working, 'modules' => ['Shop'])[:modules].map { _1[:name] })
      .to eq(['Shop'])
  end

  it 'reports structured data results without a database' do
    model = create_model
    workspace = instance_double(Mxrb::Runtime::DatabaseWorkspace)
    allow(workspace).to receive(:query_rows).and_raise(Mxrb::ToolchainError, 'database is not running')
    allow(workspace).to receive(:explain).and_raise(Mxrb::ToolchainError, 'database is not running')
    allow(workspace).to receive(:status).and_raise(Mxrb::ToolchainError, 'docker is unavailable')
    allow(Mxrb::Runtime::DatabaseWorkspace).to receive(:new).and_return(workspace)
    expect(call('data/logical', 'model' => model)[:entities].map { _1[:qualified_name] }).to eq(['Shop.Product'])
    connection = call('data/connections', 'model' => model, 'database_port' => 1).first
    expect(connection).to include(running: false, port: 1, error: include(code: 'connection_status_unavailable'))
    chosen = { 'model' => model, 'database_port' => 1, 'connection' => { 'id' => connection[:id] } }
    expect(call('data/physical', chosen)).to include(status: 'unavailable', connection: include(id: connection[:id]))
    expect(call('data/query', chosen.merge('payload' => { 'sql' => 'SELECT 1' }))).to include(ok: false)
    expect(call('data/explain', chosen.merge('payload' => { 'sql' => 'SELECT 1' }))).to include(ok: false)
  end

  it 'discovers, converts and attaches Ruby projects and links them for synchronization' do
    model = create_model
    params = { 'source_model' => model }
    expect(call('project/status', params)).to include(state: 'missing')
    converted = call('project/convert', params)
    expect(converted).to include(state: 'ready')
    expect(call('project/attach', params.merge('root' => converted[:root]))).to include(root: converted[:root])
    sync = { 'model' => model, 'ruby_root' => converted[:root] }
    expect(call('sync/status', sync)).to include(linked: false)
    expect(call('sync/link', sync)).to include(linked: true, state: 'synced')
    expect(call('sync/run', sync.merge('dry_run' => true))).to include(applied: false, dry_run: true)
    expect(call('sync/run', sync)).to include(applied: true)
    expect(call('sync/unlink', sync)).to eq(linked: false)
    expect(Dir.children(File.join(state_root, 'ruby-projects'))).not_to be_empty
  end
end
# rubocop:enable Metrics
