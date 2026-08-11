# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'MXRB CLI discovery and releases' do
  def cli(*arguments)
    Open3.capture3(RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), *arguments)
  end

  it 'provides global, command, nested, and complete command discovery' do
    stdout, stderr, status = cli('--help')
    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include('mxrb init MyApp', 'mxrb export App.mpr', 'mxrb COMMAND --help')

    stdout, stderr, status = cli('export', '--help')
    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include('Usage: mxrb export', '--mode mendix|ruby')

    stdout, stderr, status = cli('diagram-er', '--help')
    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include('Usage: mxrb diagram-er', '--module NAME', '--output FILE')

    stdout, stderr, status = cli('query', '--help')
    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include('Usage: mxrb query', '--from LANGUAGE', '--to LANGUAGE')

    stdout, stderr, status = cli('uml', '--help')
    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include('Usage: mxrb uml', '--export TYPE', '--format FORMAT', '--microflow NAME')

    stdout, stderr, status = cli('marketplace', 'pull', '--help')
    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include('Usage: mxrb marketplace pull', '--mpr FILE')

    commands, _stderr, status = cli('--commands')
    expect(status).to be_success
    expect(commands).to include('Available MXRB commands', 'diagram-er', 'query', 'uml', 'update', 'run')
    expect(commands).not_to include('sql-to-oql')
    expect(commands).not_to match(/^\s+domain-model\s+/)
    expect(cli('--comands').first).to eq(commands)
  end

  it 'keeps domain-model as a hidden compatibility alias for diagram-er help' do
    stdout, stderr, status = cli('domain-model', '--help')
    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include('Usage: mxrb diagram-er')
  end

  it 'shows a concise versioned welcome without dumping every command' do
    welcome = Mxrb::CLI::Help.welcome
    expect(welcome).to start_with("mxrb #{Mxrb::VERSION}")
    expect(welcome).to include('Common next steps:', 'mxrb --commands')
    expect(welcome.lines.size).to be < 20
  end

  it 'checks cached versions and reads release notes through injectable HTTP' do
    Dir.mktmpdir do |dir|
      requests = []
      request = lambda do |uri|
        requests << uri.to_s
        if uri.host == 'rubygems.org'
          JSON.generate('version' => '9.9.9')
        else
          JSON.generate(
            'name' => 'Future release', 'published_at' => '2026-08-07T00:00:00Z',
            'body' => 'Release notes', 'html_url' => 'https://example.test/release'
          )
        end
      end
      releases = Mxrb::CLI::Releases.new(
        installed: '1.0.0', cache_path: File.join(dir, 'release.json'), request:
      )

      expect(releases.status).to be_available
      expect(releases.status.latest).to eq('9.9.9')
      expect(requests.count { _1.include?('rubygems.org') }).to eq(1)
      expect(releases.changelog('9.9.9')).to include(
        version: '9.9.9', title: 'Future release', body: 'Release notes'
      )
    end
  end

  it 'refuses to overwrite a source checkout during self-update' do
    release_status = Mxrb::CLI::ReleaseStatus.new('1.0.0', '2.0.0', Time.now)
    releases = instance_double(Mxrb::CLI::Releases, status: release_status)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, '.git'))
      updater = Mxrb::CLI::Updater.new(releases:, source_root: dir)
      expect { updater.update! }.to raise_error(Mxrb::CLI::ReleaseError, /source checkout/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
