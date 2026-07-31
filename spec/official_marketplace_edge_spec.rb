# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::OfficialMarketplace, 'edge contracts' do
  def response(klass, code, body: '', location: nil)
    value = klass.new('1.1', code, 'test')
    value.instance_variable_set(:@read, true)
    value.instance_variable_set(:@body, body)
    value['location'] = location if location
    value
  end

  it 'covers lock defaults, invalid locks, missing installations, and credential defaults' do
    Dir.mktmpdir do |dir|
      expect(described_class.lock(dir)).to eq('packages' => {})
      lock_path = File.join(dir, '.mxrb', 'marketplace.lock.json')
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.write(lock_path, '{broken')
      expect { described_class.lock(dir) }.to raise_error(Mxrb::MarketplaceError, /invalid/)

      File.write(lock_path, JSON.generate('packages' => {
        'Missing' => { 'destination' => 'modules/Missing', 'sha256' => 'expected' }
      }))
      expect(described_class.verify(dir).dig('Missing', :actual)).to be_nil

      config = File.join(dir, 'xdg')
      stub_const('ENV', ENV.to_h.merge('XDG_CONFIG_HOME' => config))
      credentials = described_class::Credentials.new
      expect(credentials.pat).to be_nil
      expect(credentials.save_pat('pat')).to eq(File.join(config, 'mxrb', 'credentials'))
    end
  end

  it 'validates HTTP responses, JSON, schemes, redirects, size, and network failures' do
    invalid_client = described_class::HttpClient.new(github_token: '')
    allow(invalid_client).to receive(:get).and_return('not json')
    expect { invalid_client.json('https://example.test') }
      .to raise_error(Mxrb::MarketplaceError, /invalid JSON/)

    client = described_class::HttpClient.new(github_token: '')
    expect { client.send(:get, 'http://example.test', accept: 'x') }
      .to raise_error(Mxrb::MarketplaceError, /require HTTPS/)
    expect { client.send(:get, 'https://example.test', accept: 'x', redirects: -1) }
      .to raise_error(Mxrb::MarketplaceError, /too many/)

    allow(client).to receive(:perform).and_raise(SocketError, 'offline')
    expect { client.send(:get, 'https://example.test', accept: 'x') }
      .to raise_error(Mxrb::MarketplaceError, /request failed/)

    failed = response(Net::HTTPNotFound, '404')
    expect { client.send(:response_body, failed) }
      .to raise_error(Mxrb::MarketplaceError, /HTTP 404/)
    stub_const('Mxrb::OfficialMarketplace::HttpClient::MAX_BYTES', 2)
    expect { client.send(:response_body, response(Net::HTTPOK, '200', body: 'big')) }
      .to raise_error(Mxrb::MarketplaceError, /exceeds/)
  end

  it 'follows HTTPS redirects, downloads bodies, and sends optional authorization' do
    client = described_class::HttpClient.new(github_token: 'secret')
    redirect = response(
      Net::HTTPFound, '302', location: 'https://downloads.example.test/file'
    )
    ok = response(Net::HTTPOK, '200', body: 'payload')
    allow(client).to receive(:perform).and_return(redirect, ok)
    expect(client.send(:get, 'https://example.test/start', accept: 'x')).to eq('payload')

    Dir.mktmpdir do |dir|
      allow(client).to receive(:get).and_return('archive')
      destination = File.join(dir, 'download')
      expect(client.download('https://example.test', destination)).to eq(destination)
      expect(File.binread(destination)).to eq('archive')
    end

    authenticated = described_class::HttpClient.new(github_token: 'secret')
    http = double
    requests = []
    expect(http).to receive(:request).twice do |request|
      requests << request
      ok
    end
    allow(Net::HTTP).to receive(:start).and_yield(http)
    expect(authenticated.send(:perform, URI('https://example.test'), 'x')).to eq(ok)

    anonymous = described_class::HttpClient.new(github_token: nil)
    expect(anonymous.send(:perform, URI('https://example.test'), 'x')).to eq(ok)
    expect(requests.map { _1['Authorization'] }).to eq(['Bearer secret', nil])
    expect(requests.map { _1['User-Agent'] }).to all(include('mxrb/'))
  end

  it 'resolves latest releases, zip assets, fallbacks, and malformed identifiers' do
    client = instance_double(described_class::HttpClient)
    resolver = described_class::GitHubResolver.new(client:)
    allow(client).to receive(:json).and_return(
      { 'tag_name' => nil, 'assets' => [
        { 'name' => 'module.zip', 'browser_download_url' => 'https://example.test/module.zip' }
      ], 'zipball_url' => 'https://example.test/fallback.zip' },
      { 'assets' => [], 'zipball_url' => 'https://example.test/fallback.zip' },
      { 'assets' => [] }
    )
    latest = resolver.resolve('github:mendix/Example')
    expect(latest).to have_attributes(version: 'latest', download_url: end_with('module.zip'))
    fallback = resolver.resolve('UnitTesting')
    expect(fallback.download_url).to end_with('fallback.zip')
    expect { resolver.resolve('CommunityCommons') }
      .to raise_error(Mxrb::MarketplaceError, /incomplete/)
    expect { resolver.resolve('Unknown') }.to raise_error(Mxrb::MarketplaceError, /no GitHub/)
    expect(client).to have_received(:json).with(include('releases/latest')).at_least(:once)
  end

  it 'imports flat archives, sanitizes names, and rejects unsafe or invalid names' do
    Dir.mktmpdir do |dir|
      archive = File.join(dir, 'package.mpk')
      Zip::File.open(archive, create: true) do |zip|
        zip.mkdir('resources')
        zip.get_output_stream('module.xml') { _1.write('<module />') }
        zip.get_output_stream('resources/readme') { _1.write('readme') }
      end
      target = File.join(dir, 'project')
      installer = described_class::Installer.new(target:)
      result = installer.import(archive, name: 'My-Module')
      expect(result.package.name).to eq('MyModule')
      expect(File).to exist(File.join(result.destination, 'resources', 'readme'))

      other = File.join(dir, 'other.mpk')
      FileUtils.cp(archive, other)
      expect { installer.import(other, name: '123') }
        .to raise_error(Mxrb::MarketplaceError, /invalid marketplace module name/)
      expect { installer.send(:safe_destination, '/absolute', dir) }
        .to raise_error(Mxrb::MarketplaceError, /unsafe/)
      expect { installer.send(:safe_destination, '..\\outside', dir) }
        .to raise_error(Mxrb::MarketplaceError, /unsafe/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
