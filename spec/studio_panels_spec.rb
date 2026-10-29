# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio'
require 'mxrb/studio/files'
require 'mxrb/studio/task_configurations'
require 'mxrb/studio/parity'
require 'open3'
require 'tmpdir'

# Backend contracts of the Studio panels: explorer file operations and
# worktrees, saved task configurations, explicit database connections and the
# parity matrix.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'Studio panels backend' do
  around do |example|
    Dir.mktmpdir('mxrb-studio-panels-') do |directory|
      @directory = directory
      original = ENV.fetch('XDG_STATE_HOME', nil)
      ENV['XDG_STATE_HOME'] = File.join(directory, 'xdg')
      example.run
    ensure
      ENV['XDG_STATE_HOME'] = original
    end
  end

  let(:root) { File.join(@directory, 'workspace').tap { FileUtils.mkdir_p(_1) } }
  let(:files) { Mxrb::Studio::Files.new(root) }
  let(:state_root) { File.join(@directory, 'state') }
  let(:service) { Mxrb::Studio::Service.new(state_root:) }

  def call(method, params = {}) = service.dispatch(method, params)

  def git(*arguments, chdir: root)
    output, error, status = Open3.capture3('git', '-C', chdir, *arguments)
    raise error unless status.success?

    output
  end

  def create_model(name = 'Shop')
    path = File.join(@directory, name, "#{name}.mpr")
    FileUtils.mkdir_p(File.dirname(path))
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:Shop) { entity(:Product) { string :Name } }
    end
    path
  end

  describe 'file deletion' do
    it 'deletes files only at the revision the caller saw' do
      File.write(File.join(root, 'a.rb'), 'one')
      revision = files.read('a.rb')[:revision]
      File.write(File.join(root, 'a.rb'), 'changed elsewhere')
      expect { files.delete('a.rb', revision:) }.to raise_error(Mxrb::Studio::Conflict)
      expect(File.read(File.join(root, 'a.rb'))).to eq('changed elsewhere')
      expect(files.delete('a.rb', revision: files.read('a.rb')[:revision]))
        .to eq(path: 'a.rb', directory: false, deleted: true)
      expect(File).not_to exist(File.join(root, 'a.rb'))
    end

    it 'requires recursion for non-empty folders and refuses Git metadata, the root and symlinks' do
      files.create('models', directory: true)
      files.create('models/order.rb', text: 'x')
      expect { files.delete('models') }.to raise_error(Mxrb::Studio::Conflict, 'folder is not empty')
      expect(files.delete('models', recursive: true)).to include(path: 'models', directory: true)
      expect(Dir.children(root)).to be_empty
      Dir.mkdir(File.join(root, '.git'))
      expect { files.delete('.git', recursive: true) }.to raise_error(ArgumentError, /Git metadata/)
      expect { files.delete('.') }.to raise_error(ArgumentError, /below the workspace root/)
      File.symlink('/', File.join(root, 'outside'))
      expect { files.delete('outside') }.to raise_error(ArgumentError, /symlink/)
      expect { files.delete('missing.rb') }.to raise_error(Mxrb::Studio::Conflict, /no longer exists/)
    end

    it 'is exposed as files/delete' do
      File.write(File.join(root, 'b.rb'), 'b')
      expect(call('files/delete', 'root' => root, 'path' => 'b.rb')).to include(deleted: true)
    end
  end

  describe 'worktrees' do
    before do
      git('init', '-q', '-b', 'main')
      File.write(File.join(root, 'project.rb'), "# app\n")
      git('add', '.')
      git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-q', '-m', 'init')
    end

    it 'adds worktrees on new or existing branches and removes clean linked ones' do
      target = File.join(@directory, 'feature')
      added = call('files/worktreeAdd', 'root' => root, 'path' => target, 'branch' => 'feature/x')
      expect(added).to include(path: target, branch: 'refs/heads/feature/x', current: false)
      listed = call('files/worktrees', 'root' => root)
      expect(listed.map { _1[:path] }).to eq([File.realpath(root), target])
      expect(listed.first).to include(current: true)
      expect(call('files/worktreeRemove', 'root' => root, 'path' => target)).to eq(path: target, removed: true)
      again = File.join(@directory, 'feature-again')
      expect(files.add_worktree(again, branch: 'feature/x')).to include(branch: 'refs/heads/feature/x')
    end

    it 'validates destinations and branch names and preserves uncommitted work' do
      expect { files.add_worktree('relative', branch: 'x') }.to raise_error(ArgumentError, /absolute/)
      expect { files.add_worktree(File.join(root, 'nested'), branch: 'x') }.to raise_error(ArgumentError, /outside/)
      expect { files.add_worktree(File.join(@directory, 'w'), branch: '-x') }.to raise_error(ArgumentError, /branch/)
      expect { files.add_worktree(File.join(@directory, 'w'), branch: 'bad..name') }
        .to raise_error(ArgumentError, /branch/)
      expect { files.add_worktree(File.join(@directory, 'w'), branch: 'ok', base: 'nope') }
        .to raise_error(ArgumentError, /unknown base/)
      target = File.join(@directory, 'dirty')
      files.add_worktree(target, branch: 'dirty', base: 'main')
      File.write(File.join(target, 'project.rb'), "# changed\n")
      expect { files.remove_worktree(target) }.to raise_error(Mxrb::Studio::Conflict)
      expect(File.read(File.join(target, 'project.rb'))).to eq("# changed\n")
      expect { files.remove_worktree(root) }.to raise_error(ArgumentError, /main worktree/)
      expect { Mxrb::Studio::Files.new(target).remove_worktree(target) }.to raise_error(ArgumentError, /open worktree/)
      expect { files.remove_worktree(File.join(@directory, 'none')) }.to raise_error(ArgumentError, /not a worktree/)
    end

    it 'refuses worktree changes outside a Git repository' do
      plain = File.join(@directory, 'plain').tap { Dir.mkdir(_1) }
      expect { Mxrb::Studio::Files.new(plain).add_worktree(File.join(@directory, 'p'), branch: 'p') }
        .to raise_error(ArgumentError, /not a Git repository/)
    end
  end

  describe 'saved task configurations' do
    let(:model) { create_model }

    it 'saves, renames, lists per project and deletes configurations with unresolved placeholders' do
      params = { 'project' => model, 'state_root' => state_root }
      expect(call('tasks/configurations', params)).to eq(project: File.realpath(model), configurations: [])
      saved = call('tasks/saveConfiguration', params.merge(
                                                'configuration' => { 'name' => 'Validate', 'command_id' => 'validate',
                                                                     'values' => { 'model' => '{mpr}' } }
                                              ))
      expect(saved).to include('name' => 'Validate', 'command_id' => 'validate', 'values' => { 'model' => '{mpr}' })
      expect(saved['id']).to match(/\A\h{8}-/)
      renamed = call('tasks/saveConfiguration', params.merge('configuration' => saved.merge('name' => 'Check model')))
      expect(renamed).to include('id' => saved['id'], 'created_at' => saved['created_at'], 'name' => 'Check model')
      expect(call('tasks/configurations', params)[:configurations].map { _1['name'] }).to eq(['Check model'])
      other = create_model('Other')
      expect(call('tasks/configurations', params.merge('project' => other))[:configurations]).to eq([])
      expect(call('tasks/deleteConfiguration', params.merge('id' => saved['id']))).to eq(id: saved['id'], deleted: true)
      expect(call('tasks/configurations', params)[:configurations]).to eq([])
      store = Mxrb::Studio::TaskConfigurations.new(model, state_root:)
      expect(File.stat(store.path).mode & 0o777).to eq(0o600)
    end

    it 'rejects unknown commands, fields, choices, duplicate names and corrupt stores' do
      store = Mxrb::Studio::TaskConfigurations.new(model, state_root:)
      expect { store.save('name' => 'x', 'command_id' => 'nope') }.to raise_error(ArgumentError, /unknown Studio/)
      expect { store.save('name' => 'x', 'command_id' => 'validate', 'values' => { 'bogus' => '1' }) }
        .to raise_error(ArgumentError, /unknown fields/)
      expect { store.save('name' => ' ', 'command_id' => 'validate') }.to raise_error(ArgumentError, /name/)
      expect { store.save('name' => 'x', 'command_id' => 'validate', 'extra' => '"open') }
        .to raise_error(ArgumentError)
      store.save('name' => 'Lint', 'command_id' => 'lint')
      expect { store.save('name' => 'lint', 'command_id' => 'validate') }
        .to raise_error(Mxrb::Studio::Conflict, /already exists/)
      expect { store.delete('missing') }.to raise_error(ArgumentError, /unknown saved task/)
      File.write(store.path, '{')
      expect { store.list }.to raise_error(Mxrb::Studio::Conflict, /corrupt/)
    end
  end

  describe 'explicit database connections' do
    let(:model) { create_model }
    let(:workspace) { instance_double(Mxrb::Runtime::DatabaseWorkspace) }
    let(:info) do
      Mxrb::Runtime::DatabaseInfo.new('id', '/state', 'db', 'runtime', '127.0.0.1', 55_499, 'mxrb', 'mxrb_reader',
                                      true, 'abc', 'http://127.0.0.1:18080/', 'abc', :status)
    end

    before do
      allow(workspace).to receive(:status).and_return(info)
      allow(Mxrb::Runtime::DatabaseWorkspace).to receive(:new).and_return(workspace)
    end

    it 'describes the connection and environment and requires the client to choose it' do
      connection = call('data/connections', 'model' => model, 'database_port' => 55_499).first
      expect(connection).to include(kind: 'mxrb_database_workspace', environment: 'local', running: true,
                                    host: '127.0.0.1', port: 55_499, database: 'mxrb', user: 'mxrb_reader',
                                    read_only: true, schema_current: true)
      call('data/connections', 'model' => model, 'database_port' => 55_499, 'runtime_port' => 18_099)
      expect(Mxrb::Runtime::DatabaseWorkspace).to have_received(:new)
        .with(File.realpath(model), port: 55_499, runtime_port: 18_099)
      expect { call('data/physical', 'model' => model) }.to raise_error(Mxrb::Studio::Protocol::Failure,
                                                                        'missing parameter: connection')
      expect { call('data/physical', 'model' => model, 'connection' => {}) }
        .to raise_error(Mxrb::Studio::Protocol::Failure) { expect(_1.code).to eq(-32_020) }
      stale = { 'model' => model, 'connection' => { 'id' => 'mxrb-workspace:other:1' }, 'payload' => {} }
      expect { call('data/query', stale) }
        .to raise_error(Mxrb::Studio::Protocol::Failure, /not available/)
    end

    it 'introspects only the chosen connection and echoes it with each result' do
      tables = [{ schema: 'public', name: 'shop$product', kind: 'table',
                  columns: [{ name: 'id', ordinal: 1, type: 'bigint', nullable: false }],
                  constraints: [{ name: 'shop$product_pkey', type: 'p', columns: ['id'] }],
                  indexes: [] }]
      allow(workspace).to receive(:query_rows).and_return([{ 'tables_json' => JSON.generate(tables) }])
      connection = call('data/connections', 'model' => model, 'database_port' => 55_499).first
      chosen = { 'model' => model, 'database_port' => 55_499, 'connection' => { 'id' => connection[:id] } }
      physical = call('data/physical', chosen)
      expect(physical).to include(status: 'available', confirmed: true, connection: include(id: connection[:id]))
      expect(physical[:tables].first).to include(id: '"public"."shop$product"', logical_mapping: { status: 'unmapped' })
      expect(call('data/query', chosen.merge('payload' => { 'sql' => 'SELECT 1 AS one' })))
        .to include(connection: include(port: 55_499), sql: 'SELECT 1 AS one')
    end
  end

  describe 'parity matrix' do
    it 'lists both directions with per-capability states and no completion percentages' do
      matrix = call('parity/matrix')
      legend = matrix.fetch('states').keys
      expect(matrix.fetch('studio_pro_to_mxrb').size).to be > 30
      matrix.fetch('studio_pro_to_mxrb').each do |row|
        expect(row.keys).to include('id', 'family', 'capability', 'studio_pro', 'mxrb', 'states', 'gaps')
        expect(row['states'].values - legend).to eq([]), row['id']
      end
      reverse = matrix.fetch('mxrb_to_studio_pro')
      ids = reverse.map { _1['id'] }
      expect(ids).to include('studio:data/physical', 'studio:files/delete', 'cli:validate', 'cli:db up')
      expect(reverse.select { _1['states']['ide'] == 'missing' }.map { _1['id'] })
        .not_to include('studio:tasks/run', 'studio:parity/matrix')
      expect(service.methods_list.map { "studio:#{_1}" } - ids).to eq([])
      expect(JSON.generate(matrix)).not_to match(/percent|%"/i)
    end
  end
end
# rubocop:enable Metrics/BlockLength
