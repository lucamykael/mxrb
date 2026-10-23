# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'
require 'digest'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Studio::Backend do
  let(:backend) { described_class.new }
  let(:catalog) { Mxrb::Studio::Catalog.new }

  it 'covers every public command and registered nested action with a concrete argument schema' do
    entries = catalog.entries
    expect(entries.map { _1[:name] }.uniq.size).to eq(entries.size)
    parents = entries.map { _1[:prefix].first }.uniq
    expect(parents).to include(*Mxrb::CLI::Help::COMMANDS.keys)
    Mxrb::CLI::Help::SUBCOMMANDS.each do |parent, children|
      expect(entries.map { _1[:name] }).to include(*children.map { "#{parent} #{_1}" })
    end
    expect(entries.map do
      _1[:name]
    end).to include('widgets new', 'widgets build', 'query new', 'page templates', 'page generate')
    entries.each do |entry|
      expect(entry[:fields].map { _1[:key] }.uniq.size).to eq(entry[:fields].size), entry[:name]
      expect(entry[:context]).not_to be_empty
      values = entry[:fields].to_h do |field|
        value = field[:default]
        value = field[:choices].first || 'Example' if field[:required] && (value.nil? || value == '')
        [field[:key], value]
      end
      args = catalog.arguments(entry[:name], values)
      expect(args.take(entry[:prefix].size)).to eq(entry[:prefix]), entry[:name]
      expect(Mxrb::CLI::Help.command(entry[:prefix])).not_to include('No help is registered'), entry[:name]
    end
  end

  it 'keeps SQL and filenames with spaces, quotes and shell syntax as single arguments' do
    sql = "SELECT 'ação; $(touch /tmp/not-executed)' FROM x WHERE name = :Name"
    expect(backend.call('action' => 'prepare', 'command_id' => 'db sql',
                        'values' => { 'query' => sql },
                        'substitutions' => { '{mpr}' => '/tmp/ação com espaços.mpr' })).to eq(
                          ['db', 'sql', '/tmp/ação com espaços.mpr', sql]
                        )
    expect(backend.call('action' => 'command_arguments', 'command_id' => 'export',
                        'values' => { 'output_directory' => '/tmp/a b', 'mode' => 'ruby' },
                        'extra' => '--onrails')).to eq(['export', '{mpr}', '/tmp/a b', '--mode', 'ruby', '--onrails'])
  end

  it 'validates required values, unknown fields, quoting, choices and unresolved context' do
    expect { catalog.arguments('rename') }.to raise_error(ArgumentError, /old name is required/)
    expect { catalog.arguments('export', { 'mode' => 'other' }) }.to raise_error(ArgumentError, /invalid --mode/)
    expect { catalog.arguments('modules', { 'bogus' => 'x' }) }.to raise_error(ArgumentError, /unknown fields/)
    expect { backend.call('action' => 'prepare', 'command' => 'export "unterminated') }.to raise_error(ArgumentError)
    expect do
      backend.call('action' => 'prepare', 'command' => 'generate {file}')
    end.to raise_error(ArgumentError, /unresolved/)
    expect { backend.call('action' => 'prepare', 'arguments' => ["bad\0arg"]) }.to raise_error(ArgumentError)
    expect do
      backend.call('action' => 'prepare', 'command' => 'modules {mpr}',
                   'substitutions' => { '{mpr}' => '' })
    end.to raise_error(ArgumentError)
  end

  it 'keeps destructive and applying flags opt-in' do
    expect(catalog.arguments('db destroy')).to eq(['db', 'destroy', '{mpr}'])
    expect(catalog.arguments('db destroy', { 'yes' => true })).to eq(['db', 'destroy', '{mpr}', '--yes'])
    expect(catalog.arguments('rename', { 'old_name' => 'App.A', 'new_name' => 'App.B' })).not_to include('--apply')
    expect(catalog.fetch('team-server push')[:effect]).to eq('publish')
    expect(catalog.fetch('db sql')[:effect]).to eq('read_or_write')
  end

  it 'can prepare global commands without an open model' do
    expect(backend.call('action' => 'prepare', 'command_id' => 'module search',
                        'values' => {})).to eq(%w[module search])
    expect(backend.call('action' => 'prepare', 'arguments' => ['--version'])).to eq(['--version'])
  end

  it 'executes the actual CLI without shell interpretation and preserves its exit status' do
    Dir.mktmpdir('mxrb studio ') do |directory|
      request = { 'action' => 'execute', 'directory' => directory, 'arguments' => ['--version'] }
      runner = "require 'mxrb/studio'; Mxrb::Studio::Backend.new.execute(JSON.parse(STDIN.read))"
      out, err, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', runner, stdin_data: JSON.generate(request))
      expect(status).to be_success
      expect(out).to include("mxrb #{Mxrb::VERSION}")
      expect(err).to be_empty
      request['arguments'] = ['does-not-exist']
      _out, _err, status = Open3.capture3(RbConfig.ruby, '-Ilib', '-e', runner, stdin_data: JSON.generate(request))
      expect(status).not_to be_success
    end
  end

  it 'accepts managed PAT input over the IDE pipe without echoing it' do
    Dir.mktmpdir do |directory|
      environment = { 'XDG_CONFIG_HOME' => directory, 'MXRB_MENDIX_PAT' => nil, 'MXRB_MENDIX_PAT_FILE' => nil }
      cli = File.expand_path('../bin/mxrb', __dir__)
      token = 'fake-ide-token-for-isolated-test'
      output, errors, status = Open3.capture3(environment, RbConfig.ruby, cli, '--no-progress',
                                              'marketplace', 'login', '--store-pat', '--no-verify',
                                              stdin_data: "#{token}\n")
      expect(status).to be_success, errors
      expect(output).to include('Mendix PAT:')
      expect(output).not_to include(token)
      credential = File.join(directory, 'mxrb', 'credentials')
      expect(JSON.parse(File.read(credential))).to include('mendix_pat' => token)
      expect(File.stat(credential).mode & 0o777).to eq(0o600)
    end
  end

  it 'makes the query scaffold reachable while retaining SQL/OQL conversion' do
    Dir.mktmpdir do |temporary|
      directory = Mxrb::Initializer.new('shop').scaffold(into: temporary).root
      fingerprint = lambda do
        paths = Dir.glob(File.join(directory, '**', '*'), File::FNM_DOTMATCH).select { File.file?(_1) }
        paths.to_h { [_1, Digest::SHA256.file(_1).hexdigest] }
      end
      before = fingerprint.call
      args = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), '--no-progress']
      out, err, status = Open3.capture3(*args, 'query', 'new', 'Shop.Search', '--target', directory, '--dry-run',
                                        '--json')
      expect(status).to be_success, err
      expect(out).to include('Search')
      expect(fingerprint.call).to eq(before)
      out, err, status = Open3.capture3(*args, 'query', 'SELECT p.Name FROM Shop.Product p', '--from', 'oql', '--json')
      expect(status).to be_success, err
      expect(JSON.parse(out)).to include('sql' => a_string_matching(/SELECT/i))
    end
  end
end
# rubocop:enable Metrics/BlockLength
