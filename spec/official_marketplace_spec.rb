# frozen_string_literal: true

require 'spec_helper'
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
      File.write(path, '{broken')
      expect { credentials.pat }.to raise_error(Mxrb::MarketplaceError, /invalid credentials/)
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
