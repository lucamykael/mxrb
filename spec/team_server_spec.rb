# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

module TeamServerSpecSupport
  APP_ID = 'a9e4af8a-2776-4b10-a471-8c42df8f5f43'
  URL = "https://git.api.mendix.com/#{APP_ID}.git".freeze

  Status = Data.define(:success?)

  class FakeRunner
    attr_reader :calls

    def initialize(&callback)
      @callback = callback
      @calls = []
    end

    def capture(environment, command, chdir: nil)
      @calls << { environment:, command:, chdir: }
      result = @callback&.call(environment, command, chdir)
      return result if result.is_a?(Array) && result.length == 2

      ["ok\n", Status.new(success?: true)]
    end
  end

  class FakeHttp
    attr_reader :calls

    def initialize
      @calls = []
    end

    def json(url, authorization:)
      @calls << { url:, authorization: }
      { 'items' => [], 'url' => url }
    end
  end
end

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::TeamServer do
  def credentials(root)
    pat = File.join(root, '.env.team-server')
    File.write(pat, "MXRB_TEAM_SERVER_PAT=secret-token\n")
    described_class::Credentials.new(
      path: File.join(root, 'credentials'), pat_file: pat
    )
  end

  it 'normalizes only official credential-free Team Server URLs' do
    expect(described_class::Repository.repository_url(TeamServerSpecSupport::APP_ID))
      .to eq(TeamServerSpecSupport::URL)
    expect(described_class::Repository.repository_url(TeamServerSpecSupport::URL))
      .to eq(TeamServerSpecSupport::URL)
    [
      "http://git.api.mendix.com/#{TeamServerSpecSupport::APP_ID}.git",
      "https://evil.example/#{TeamServerSpecSupport::APP_ID}.git",
      "https://pat:secret@git.api.mendix.com/#{TeamServerSpecSupport::APP_ID}.git",
      'https://git.api.mendix.com/not-an-id.git'
    ].each do |value|
      expect { described_class::Repository.repository_url(value) }
        .to raise_error(Mxrb::TeamServerError, /invalid Team Server/)
    end
  end

  it 'stores only the PAT file path and reads supported secret file formats' do
    Dir.mktmpdir do |root|
      config = File.join(root, 'credentials')
      File.write(config, JSON.generate('mendix_pat' => 'marketplace-secret'))
      creds = credentials(root)
      source = File.join(root, '.env.team-server')
      creds.configure_pat_file(source)
      saved = JSON.parse(File.read(config))

      expect(saved).to include(
        'mendix_pat' => 'marketplace-secret',
        'team_server_pat_file' => source
      )
      expect(saved).not_to have_key('team_server_pat')
      expect(creds.pat).to eq('secret-token')
      expect(File.stat(config).mode & 0o777).to eq(0o600)
    end
  end

  it 'handles all PAT formats and configuration errors' do
    Dir.mktmpdir do |root|
      config = File.join(root, 'credentials')
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('XDG_CONFIG_HOME').and_return('')
      expect(described_class::Credentials.new.path).to end_with('/.config/mxrb/credentials')
      expect(described_class::Credentials.new(path: config).pat).to be_nil
      expect { described_class::Credentials.new(path: config).configure_pat_file('') }
        .to raise_error(Mxrb::TeamServerError, /must not be empty/)
      expect { described_class::Credentials.new(path: config, pat_file: File.join(root, 'missing')).pat }
        .to raise_error(Mxrb::TeamServerError, /not found/)

      json = File.join(root, 'pat.json')
      File.write(json, JSON.generate('team_server_pat' => 'json-secret'))
      expect(described_class::Credentials.new(path: config, pat_file: json).pat).to eq('json-secret')
      plain = File.join(root, 'plain-pat')
      File.write(plain, 'plain-secret')
      expect(described_class::Credentials.new(path: config, pat_file: plain).pat).to eq('plain-secret')
      allow(File).to receive(:binread).and_call_original
      allow(File).to receive(:binread).with(plain).and_raise(Errno::EACCES, plain)
      expect { described_class::Credentials.new(path: config, pat_file: plain).pat }
        .to raise_error(Mxrb::TeamServerError, /cannot read/)
      allow(File).to receive(:binread).and_call_original
      File.write(json, '[]')
      expect { described_class::Credentials.new(path: config, pat_file: json).pat }
        .to raise_error(Mxrb::TeamServerError, /JSON Team Server/)
      File.write(json, JSON.generate('team_server_pat' => ''))
      expect { described_class::Credentials.new(path: config, pat_file: json).pat }
        .to raise_error(Mxrb::TeamServerError, /is empty/)

      env = File.join(root, '.env')
      File.write(env, "OTHER=x\n")
      expect { described_class::Credentials.new(path: config, pat_file: env).pat }
        .to raise_error(Mxrb::TeamServerError, /variable not found/)
      File.write(env, "export MXRB_MENDIX_PAT='quoted-secret'\n")
      expect(described_class::Credentials.new(path: config, pat_file: env).pat).to eq('quoted-secret')

      File.write(config, '[]')
      expect { described_class::Credentials.new(path: config).pat }
        .to raise_error(Mxrb::TeamServerError, /expected a JSON object/)
      File.write(config, '{')
      expect { described_class::Credentials.new(path: config).pat }
        .to raise_error(Mxrb::TeamServerError, /invalid credentials/)

      fresh = File.join(root, 'fresh-credentials')
      File.write(json, JSON.generate('team_server_pat' => 'secret'))
      expect(described_class::Credentials.new(path: fresh).configure_pat_file(json)).to eq(fresh)
      blocked = File.join(root, 'blocked')
      File.write(blocked, 'file')
      expect do
        described_class::Credentials.new(path: File.join(blocked, 'credentials')).configure_pat_file(json)
      end.to raise_error(SystemCallError)
    end
  end

  it 'runs commands with and without a working directory' do
    status = TeamServerSpecSupport::Status.new(success?: true)
    allow(Open3).to receive(:capture2e).and_return(["ok\n", status])
    runner = described_class::CommandRunner.new
    expect(runner.capture({}, %w[git status])).to eq(["ok\n", status])
    expect(runner.capture({}, %w[git status], chdir: Dir.tmpdir)).to eq(["ok\n", status])
    expect(Open3).to have_received(:capture2e).with({}, 'git', 'status')
    expect(Open3).to have_received(:capture2e).with({}, 'git', 'status', chdir: Dir.tmpdir)
  end

  it 'clones with ephemeral askpass, validates the MPR, and never exposes the PAT' do
    Dir.mktmpdir do |root|
      target = File.join(root, 'app')
      runner = TeamServerSpecSupport::FakeRunner.new do |_environment, command, _chdir|
        next unless command[0, 2] == %w[git clone]

        FileUtils.mkdir_p(File.join(target, '.git'))
        Mxrb.define(File.join(target, 'App.mpr')) do
          mendix_version '11.12.1'
          self.module(:App) { entity(:Item) { string :Name } }
        end
      end
      repository = described_class::Repository.new(
        credentials: credentials(root), runner:
      )
      result = repository.clone(TeamServerSpecSupport::URL, target:, branch: 'main', depth: 1)
      call = runner.calls.first

      expect(result.mpr_files).to eq([File.join(target, 'App.mpr')])
      expect(call[:command]).to include(
        '--branch', 'main', '--depth', '1', TeamServerSpecSupport::URL
      )
      expect(call[:command].join(' ')).not_to include('secret-token')
      expect(call[:environment]).to include(
        'GIT_ASKPASS_REQUIRE' => 'force', 'MXRB_TEAM_SERVER_PAT' => 'secret-token'
      )
      expect(File.exist?(call[:environment].fetch('GIT_ASKPASS'))).to be(false)
    end
  end

  it 'queries the official App Repository API with MxToken authentication' do
    Dir.mktmpdir do |root|
      http = TeamServerSpecSupport::FakeHttp.new
      api = described_class::Api.new(credentials: credentials(root), client: http)
      api.info(TeamServerSpecSupport::APP_ID)
      api.branches(TeamServerSpecSupport::APP_ID, cursor: 'next')
      api.commits(TeamServerSpecSupport::APP_ID, 'branches/development', limit: 10)

      expect(http.calls.first).to include(
        url: "https://repository.api.mendix.com/v1/repositories/#{TeamServerSpecSupport::APP_ID}/info",
        authorization: 'MxToken secret-token'
      )
      expect(http.calls.last[:url]).to include(
        '/branches/branches%2Fdevelopment/commits?limit=10'
      )
    end
  end

  it 'supports unauthenticated Git helpers and every repository operation' do
    Dir.mktmpdir do |root|
      git = File.join(root, 'app')
      FileUtils.mkdir_p(File.join(git, '.git'))
      Mxrb.define(File.join(git, 'App.mpr')) { mendix_version '11.12.1' }
      runner = TeamServerSpecSupport::FakeRunner.new do |_environment, command, _chdir|
        if command[0, 4] == %w[git remote get-url origin]
          ["#{TeamServerSpecSupport::URL}\n", TeamServerSpecSupport::Status.new(success?: true)]
        end
      end
      credentials = described_class::Credentials.new(path: File.join(root, 'none'))
      repository = described_class::Repository.new(credentials:, runner:)

      expect(repository.status(git)).to eq("ok\n")
      expect(repository.fetch(git, prune: false).output).to eq("ok\n")
      expect(repository.fetch(git).output).to eq("ok\n")
      expect(repository.pull(git, ff_only: false).output).to eq("ok\n")
      expect(repository.pull(git).output).to eq("ok\n")
      expect(repository.push(git).output).to eq("ok\n")
      expect(repository.push(git, branch: 'main').output).to eq("ok\n")
      expect(runner.calls.flat_map { _1[:command] }).to include('--prune', '--ff-only', 'main')
      expect(runner.calls.first[:environment]).to eq('GIT_TERMINAL_PROMPT' => '0')
    end
  end

  it 'rejects unsafe repository states and cleans incomplete clones' do
    Dir.mktmpdir do |root|
      credentials = described_class::Credentials.new(path: File.join(root, 'none'))
      failing = TeamServerSpecSupport::FakeRunner.new do |_environment, command, _chdir|
        if command[0, 2] == %w[git clone]
          FileUtils.mkdir_p(command.last)
          ['denied', TeamServerSpecSupport::Status.new(success?: false)]
        end
      end
      repository = described_class::Repository.new(credentials:, runner: failing)
      target = File.join(root, 'partial')
      expect { repository.clone(TeamServerSpecSupport::URL, target:) }
        .to raise_error(Mxrb::TeamServerError, /operation failed/)
      expect(File.exist?(target)).to be(false)
      FileUtils.mkdir_p(target)
      expect { repository.clone(TeamServerSpecSupport::URL, target:) }
        .to raise_error(Mxrb::TeamServerError, /destination already exists/)
      expect { repository.status(File.join(root, 'not-git')) }
        .to raise_error(Mxrb::TeamServerError, /not a Git repository/)
      expect { described_class::Repository.repository_url('https://%') }
        .to raise_error(Mxrb::TeamServerError, /invalid Team Server/)
    end
  end

  it 'rejects invalid clone depth, empty clones, and invalid cloned MPRs' do
    Dir.mktmpdir do |root|
      credentials = described_class::Credentials.new(path: File.join(root, 'none'))
      repository = described_class::Repository.new(credentials:, runner: TeamServerSpecSupport::FakeRunner.new)
      expect { repository.clone(TeamServerSpecSupport::URL, target: File.join(root, 'depth'), depth: 0) }
        .to raise_error(Mxrb::TeamServerError, /positive integer/)

      empty_runner = TeamServerSpecSupport::FakeRunner.new do |_environment, command, _chdir|
        FileUtils.mkdir_p(File.join(command.last, '.git')) if command[0, 2] == %w[git clone]
      end
      empty = described_class::Repository.new(credentials:, runner: empty_runner)
      expect { empty.clone(TeamServerSpecSupport::URL, target: File.join(root, 'empty')) }
        .to raise_error(Mxrb::TeamServerError, /no MPR/)

      invalid_runner = TeamServerSpecSupport::FakeRunner.new do |_environment, command, _chdir|
        next unless command[0, 2] == %w[git clone]

        FileUtils.mkdir_p(File.join(command.last, '.git'))
        File.write(File.join(command.last, 'Broken.mpr'), 'broken')
      end
      invalid = described_class::Repository.new(credentials:, runner: invalid_runner)
      expect { invalid.clone(TeamServerSpecSupport::URL, target: File.join(root, 'invalid')) }
        .to raise_error(Mxrb::TeamServerError, /invalid/)
    end
  end

  it 'reports App Repository API authentication, identifiers, and transport errors' do
    empty = described_class::Credentials.new(path: File.join(Dir.tmpdir, 'mxrb-no-team-server-config'))
    api = described_class::Api.new(credentials: empty, client: TeamServerSpecSupport::FakeHttp.new)
    expect { api.info(TeamServerSpecSupport::APP_ID) }
      .to raise_error(Mxrb::TeamServerError, /requires --pat-file/)

    Dir.mktmpdir do |root|
      http = TeamServerSpecSupport::FakeHttp.new
      api = described_class::Api.new(credentials: credentials(root), client: http)
      expect { api.info('invalid') }.to raise_error(Mxrb::TeamServerError, /invalid Team Server app ID/)
      api.branch(TeamServerSpecSupport::APP_ID, 'feature one')
      expect(http.calls.last[:url]).to end_with('/branches/feature%20one')
      failing = Object.new
      def failing.json(*) = raise Mxrb::MarketplaceError, 'remote failed'
      expect { described_class::Api.new(credentials: credentials(root), client: failing).info(TeamServerSpecSupport::APP_ID) }
        .to raise_error(Mxrb::TeamServerError, /remote failed/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
