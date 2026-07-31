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
      @callback&.call(environment, command, chdir)
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
end
# rubocop:enable Metrics/BlockLength
