# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::OfficialMarketplace do
  def zip_file(path, entries)
    Zip::File.open(path, create: true) do |zip|
      entries.each do |name, content|
        zip.get_output_stream(name) { _1.write(content) }
      end
    end
    path
  end

  it 'stores PAT credentials with owner-only permissions' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config', 'credentials')
      credentials = described_class::Credentials.new(path:)
      expect(credentials.save_pat(" token\n")).to eq(path)
      expect(credentials.pat).to eq('token')
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect { credentials.save_pat(' ') }.to raise_error(Mxrb::MarketplaceError, /must not be empty/)
      File.write(path, '[]')
      expect { credentials.pat }.to raise_error(Mxrb::MarketplaceError, /expected a JSON object/)
      File.write(path, '{broken')
      expect { credentials.pat }.to raise_error(Mxrb::MarketplaceError, /invalid credentials/)
    end
  end

  it 'stores only an absolute PAT-file reference and reads plaintext, JSON, and .env secrets' do
    Dir.mktmpdir do |dir|
      config = File.join(dir, 'config', 'credentials')
      secret = File.join(dir, 'marketplace.pat')
      File.write(secret, " first-token\n")
      File.chmod(0o640, secret)
      credentials = described_class::Credentials.new(path: config)

      expect(credentials.configure_pat_file(secret)).to eq(config)
      expect(JSON.parse(File.read(config))).to eq('mendix_pat_file' => File.expand_path(secret))
      expect(File.read(config)).not_to include('first-token')
      expect(File.stat(secret).mode & 0o777).to eq(0o640)
      expect(credentials.pat).to eq('first-token')

      File.write(secret, %({"mendix_pat":"json-token"}\n))
      expect(credentials.pat).to eq('json-token')

      env = File.join(dir, '.env')
      File.write(env, "OTHER=value\nMXRB_MENDIX_PAT='env-token'\n")
      expect(credentials.configure_pat_file(env)).to eq(config)
      expect(described_class::Credentials.new(path: config).pat).to eq('env-token')
    end
  end

  it 'validates referenced PAT files without modifying or silently accepting bad formats' do
    Dir.mktmpdir do |dir|
      credentials = described_class::Credentials.new(path: File.join(dir, 'credentials'))
      expect { credentials.configure_pat_file(' ') }
        .to raise_error(Mxrb::MarketplaceError, /must not be empty/)

      missing = File.join(dir, 'missing.pat')
      expect { credentials.configure_pat_file(missing) }
        .to raise_error(Mxrb::MarketplaceError, /not found/)

      empty = File.join(dir, 'empty.pat')
      File.write(empty, '')
      expect { credentials.configure_pat_file(empty) }
        .to raise_error(Mxrb::MarketplaceError, /empty/)

      env = File.join(dir, '.env')
      File.write(env, 'OTHER=value')
      expect { credentials.configure_pat_file(env) }
        .to raise_error(Mxrb::MarketplaceError, /MXRB_MENDIX_PAT not found/)

      env = File.join(dir, 'marketplace.env')
      File.write(env, "export MXRB_MENDIX_PAT=x\n")
      expect(credentials.configure_pat_file(env)).to eq(credentials.path)
      expect(credentials.pat).to eq('x')

      json = File.join(dir, 'secret.json')
      File.write(json, '{}')
      expect { credentials.configure_pat_file(json) }
        .to raise_error(Mxrb::MarketplaceError, /must contain/)
      File.write(json, '[]')
      expect { credentials.configure_pat_file(json) }
        .to raise_error(Mxrb::MarketplaceError, /must contain/)

      unreadable = File.join(dir, 'unreadable.pat')
      File.write(unreadable, 'token')
      allow(File).to receive(:binread).and_call_original
      allow(File).to receive(:binread).with(unreadable).and_raise(Errno::EACCES, unreadable)
      expect { credentials.configure_pat_file(unreadable) }
        .to raise_error(Mxrb::MarketplaceError, /cannot read Mendix PAT file/)
    end
  end

  it 'documents and executes both marketplace login storage modes' do
    executable = File.expand_path('../bin/mxrb', __dir__)
    Dir.mktmpdir do |dir|
      env = File.join(dir, '.env')
      File.write(env, "MXRB_MENDIX_PAT=file-token\n")
      process_env = { 'XDG_CONFIG_HOME' => File.join(dir, 'config') }

      stdout, stderr, status = Open3.capture3(
        process_env, RbConfig.ruby, executable, 'marketplace', 'login',
        '--pat-file', env, '--no-verify'
      )
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include('PAT file reference saved', 'Secret remains in')
      stored = File.join(dir, 'config', 'mxrb', 'credentials')
      expect(JSON.parse(File.read(stored))).to eq('mendix_pat_file' => env)
      expect(File.read(stored)).not_to include('file-token')

      stdout, stderr, status = Open3.capture3(
        process_env.merge('MXRB_MENDIX_PAT' => 'managed-token'), RbConfig.ruby, executable,
        'marketplace', 'login', '--store-pat', '--no-verify'
      )
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include('Explicit managed-secret mode', 'mode: 0600', 'Destination:')
      expect(JSON.parse(File.read(stored))).to eq('mendix_pat' => 'managed-token')

      stdout, stderr, status = Open3.capture3(
        process_env, RbConfig.ruby, executable, 'marketplace', 'login', '--help'
      )
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include('--pat-file FILE', '--store-pat', 'MXRB_MENDIX_PAT_FILE')
    end
  end

  it 'searches the known catalog and GitHub and resolves release assets' do
    client = instance_double(described_class::HttpClient)
    resolver = described_class::GitHubResolver.new(client:)
    expect(resolver.search('community')).to include(
      name: 'CommunityCommons', repository: 'mendix/CommunityCommons'
    )

    allow(client).to receive(:json).and_return(
      { 'items' => [{ 'name' => 'Widgets', 'full_name' => 'mendix/Widgets',
                      'description' => 'UI widgets' }] },
      { 'tag_name' => '3.4.0', 'assets' => [
        { 'name' => 'source.zip', 'browser_download_url' => 'https://example.test/source.zip' },
        { 'name' => 'CommunityCommons.mpk',
          'browser_download_url' => 'https://example.test/module.mpk' }
      ], 'zipball_url' => 'https://example.test/archive.zip' }
    )
    expect(resolver.search('widgets')).to eq(
      [{ name: 'Widgets', repository: 'mendix/Widgets', description: 'UI widgets' }]
    )
    package = resolver.resolve('CommunityCommons', version: '3.4.0')
    expect(package).to have_attributes(
      name: 'CommunityCommons', version: '3.4.0', source: :github,
      download_url: 'https://example.test/module.mpk'
    )
    expect(client).to have_received(:json).with(include('releases/tags/3.4.0'))
  end

  it 'imports MPK archives, writes a lock, and verifies installed contents' do
    Dir.mktmpdir do |dir|
      archive = zip_file(File.join(dir, 'CommunityCommons.mpk'), {
        'CommunityCommons/module.xml' => '<module />',
        'CommunityCommons/resources/readme.txt' => 'hello'
      })
      target = File.join(dir, 'project')
      result = described_class::Installer.new(target:).import(archive)
      expect(result.destination).to eq(File.join(target, 'modules', 'CommunityCommons'))
      expect(File).to exist(File.join(result.destination, 'module.xml'))
      expect(described_class.lock(target).dig('packages', 'CommunityCommons', 'source')).to eq('mpk')
      expect(described_class.verify(target).dig('CommunityCommons', :valid)).to be(true)

      File.write(File.join(result.destination, 'module.xml'), 'changed')
      expect(described_class.verify(target).dig('CommunityCommons', :valid)).to be(false)
      expect { described_class::Installer.new(target:).import(archive) }
        .to raise_error(Mxrb::MarketplaceError, /already exists/)
    end
  end

  it 'rejects missing, invalid, and path-traversing packages without residue' do
    Dir.mktmpdir do |dir|
      installer = described_class::Installer.new(target: File.join(dir, 'project'))
      expect { installer.import(File.join(dir, 'missing.mpk')) }
        .to raise_error(Mxrb::MarketplaceError, /not found/)

      invalid = File.join(dir, 'Invalid.mpk')
      File.write(invalid, 'not a zip')
      expect { installer.import(invalid) }
        .to raise_error(Mxrb::MarketplaceError, /invalid MPK/)

      unsafe = zip_file(File.join(dir, 'Unsafe.mpk'), '../outside' => 'bad')
      expect { installer.import(unsafe) }
        .to raise_error(Mxrb::MarketplaceError, /unsafe package path/)
      expect(File).not_to exist(File.join(dir, 'outside'))
    end
  end

  it 'pulls a resolved GitHub release through the bounded client' do
    Dir.mktmpdir do |dir|
      archive = zip_file(File.join(dir, 'release.zip'), 'repo-main/module.xml' => '<module />')
      client = instance_double(described_class::HttpClient)
      allow(client).to receive(:json).and_return(
        'tag_name' => 'v1', 'assets' => [], 'zipball_url' => 'https://example.test/release.zip'
      )
      allow(client).to receive(:download) do |_url, destination|
        FileUtils.cp(archive, destination)
        destination
      end
      target = File.join(dir, 'project')
      result = described_class::Installer.new(target:, client:).pull('github:mendix/TestModule')
      expect(result.package).to have_attributes(name: 'TestModule', version: 'v1')
      expect(File).to exist(File.join(result.destination, 'module.xml'))
    end
  end
end
# rubocop:enable Metrics/BlockLength
