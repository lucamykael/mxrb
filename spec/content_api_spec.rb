# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::OfficialMarketplace::ContentApi do
  let(:client) { instance_double(Mxrb::OfficialMarketplace::HttpClient) }
  let(:credentials) { instance_double(Mxrb::OfficialMarketplace::Credentials, pat: nil) }
  let(:api) { described_class.new(pat: 'secret', credentials:, client:) }

  def content(id: 170, name: 'Community Commons', type: 'Module', private_content: false)
    {
      'contentId' => id, 'publisher' => 'Mendix', 'type' => type,
      'isPrivate' => private_content, 'isCompanyApproved' => true,
      'latestVersion' => version(name:, number: '10.0.0')
    }
  end

  def version(number: '10.0.0', date: '2026-01-01T00:00:00Z', type: 'Regular', **extra)
    name = extra.delete(:name) || 'Community Commons'
    id = extra.delete(:id) || '123e4567-e89b-12d3-a456-426614174000'
    {
      'name' => name, 'versionId' => id, 'versionNumber' => number,
      'minSupportedMendixVersion' => '11.0.0', 'publicationDate' => date,
      'downloadURL' => "https://marketplace-api.mendix.com/v1/versions/#{id}/download",
      'versionType' => type, 'releaseNotes' => 'notes'
    }.merge(extra.transform_keys(&:to_s))
  end

  def query(url)
    URI.decode_www_form(URI(url).query.to_s).to_h
  end

  it 'requires the documented PAT and sends MxToken with all catalog filters' do
    expect { described_class.new(pat: '', credentials:, client:) }
      .to raise_error(Mxrb::MarketplaceError, /mx:marketplace-content:read/)
    allow(client).to receive(:json) do |url, authorization:|
      expect(authorization).to eq('MxToken secret')
      expect(query(url)).to include(
        'name' => 'Private Module', 'isPrivate' => 'true', 'isCompanyApproved' => 'false',
        'publishedSince' => '2026-06-16', 'limit' => '20', 'offset' => '2'
      )
      { 'items' => [content(private_content: true)] }
    end
    expect(api.search(name: 'Private Module', private: true, approved: 'false',
                      published_since: '2026-06-16', limit: '20', offset: '2').size).to eq(1)
  end

  it 'gets content and filtered versions with their documented bounds' do
    allow(client).to receive(:json) do |url, authorization:|
      expect(authorization).to eq('MxToken secret')
      if url.include?('/versions?')
        expect(query(url)).to include(
          'versionId' => '123e4567-e89b-12d3-a456-426614174000',
          'supportedMendixVersion' => '11.12.1', 'publishedSince' => '2026-01-01',
          'limit' => '20', 'offset' => '0'
        )
        { 'items' => [version] }
      else
        content
      end
    end
    expect(api.content(170).fetch('contentId')).to eq(170)
    expect(api.versions(170, version_id: '123e4567-e89b-12d3-a456-426614174000',
                             mendix_version: '11.12.1', published_since: '2026-01-01')).to eq([version])
  end

  it 'finds by numeric ID, exact name, and a PascalCase-to-display-name fallback' do
    allow(client).to receive(:json) do |url, authorization:|
      expect(authorization).to eq('MxToken secret')
      next content if url.end_with?('/content/170')

      name = query(url)['name']
      { 'items' => name == 'Community Commons' ? [content] : [] }
    end
    expect(api.find('170')).to eq(content)
    expect(api.find('CommunityCommons')).to eq(content)
  end

  it 'rejects missing, empty, and ambiguous content names and malformed API payloads' do
    allow(client).to receive(:json).and_return({ 'items' => [] }, { 'items' => [] })
    expect { api.find('MissingThing') }.to raise_error(Mxrb::MarketplaceError, /not found/)
    expect { api.find(' ') }.to raise_error(Mxrb::MarketplaceError, /must not be empty/)

    allow(client).to receive(:json).and_return('items' => [content, content(id: 171)])
    expect { api.find('Duplicate') }.to raise_error(Mxrb::MarketplaceError, /ambiguous/)
    allow(client).to receive(:json).and_return('items' => 'invalid')
    expect { api.search }.to raise_error(Mxrb::MarketplaceError, /must be an array/)
  end

  it 'resolves exact, compatible, and latest releases and retains official metadata' do
    older = version(number: '9.0.0', date: '2025-01-01T00:00:00Z')
    newer = version(number: '10.0.0', date: '2026-01-01T00:00:00Z')
    allow(client).to receive(:json) do |url, authorization:|
      expect(authorization).to eq('MxToken secret')
      if url.include?('/versions')
        { 'items' => query(url)['supportedMendixVersion'] ? [older] : [older, newer] }
      elsif url.end_with?('/content/170')
        content
      else
        { 'items' => [content] }
      end
    end
    exact = api.resolve('170', version: '10.0.0')
    expect(exact).to have_attributes(
      version: '10.0.0', source: :mendix, content_id: 170,
      content_type: 'Module', company_approved: true
    )
    expect(api.resolve('170', mendix_version: '11.12.1').version).to eq('9.0.0')
    expect(api.resolve('170').version).to eq('10.0.0')
  end

  it 'resolves a UUID and rejects unavailable versions' do
    allow(client).to receive(:json) do |url, **|
      if url.include?('/versions')
        { 'items' => query(url)['versionId'] ? [version] : [] }
      else
        content
      end
    end
    expect(api.resolve('170', version: version['versionId']).version_id).to eq(version['versionId'])
    expect { api.resolve('170', version: '99.0.0') }
      .to raise_error(Mxrb::MarketplaceError, /version "99.0.0"/)
    expect { api.resolve('170', mendix_version: '10.0.0') }
      .to raise_error(Mxrb::MarketplaceError, /compatible with Mendix/)
    expect { api.resolve('170') }
      .to raise_error(Mxrb::MarketplaceError, /a published version/)
  end

  it 'blocks vulnerable releases by default and exposes security fix metadata' do
    vulnerable = version(
      type: 'Vulnerable', vulnerabilities: [{ 'code' => 'CVE-2026-1234' }]
    )
    fixed = version(
      type: 'SecurityFix', number: '10.0.1',
      fixedSecurityIssues: [{ 'code' => 'CVE-2026-1234' }]
    )
    allow(client).to receive(:json).and_return(content, { 'items' => [vulnerable] })
    expect { api.resolve('170') }.to raise_error(Mxrb::MarketplaceError, /CVE-2026-1234/)

    allow(client).to receive(:json).and_return(
      content, { 'items' => [version(type: 'Vulnerable')] }
    )
    expect { api.resolve('170') }.to raise_error(Mxrb::MarketplaceError, /marked vulnerable;/)

    allow(client).to receive(:json).and_return(content, { 'items' => [vulnerable] })
    expect(api.resolve('170', allow_vulnerable: true).version_type).to eq('Vulnerable')
    allow(client).to receive(:json).and_return(content, { 'items' => [fixed] })
    expect(api.resolve('170').security_issues).to eq(['CVE-2026-1234'])
  end

  it 'downloads through the documented endpoint without leaking PAT to external signed URLs' do
    allow(client).to receive(:download).and_return('/tmp/package.mpk')
    api.download('123e4567-e89b-12d3-a456-426614174000', '/tmp/package.mpk')
    expect(client).to have_received(:download).with(
      include('/versions/123e4567-e89b-12d3-a456-426614174000/download'), '/tmp/package.mpk',
      authorization: 'MxToken secret'
    )
    api.download(
      '123e4567-e89b-12d3-a456-426614174000', '/tmp/package.mpk',
      download_url: 'https://signed-storage.example/package.mpk'
    )
    expect(client).to have_received(:download).with(
      'https://signed-storage.example/package.mpk', '/tmp/package.mpk', authorization: nil
    )
    api.download(
      '123e4567-e89b-12d3-a456-426614174000', '/tmp/package.mpk',
      download_url: 'https://marketplace.mendix.com/content/package.mpk'
    )
    expect(client).to have_received(:download).with(
      'https://marketplace.mendix.com/content/package.mpk', '/tmp/package.mpk',
      authorization: 'MxToken secret'
    )
  end

  it 'accepts the lowercase downloadUrl returned by the live API and checks minimum compatibility' do
    live = version
    live['downloadUrl'] = live.delete('downloadURL')
    allow(client).to receive(:json).and_return(content, { 'items' => [live] })
    expect(api.resolve('170', mendix_version: '11.12.1').download_url).to eq(live['downloadUrl'])

    incompatible = version(minSupportedMendixVersion: '12.0.0')
    allow(client).to receive(:json).and_return(content, { 'items' => [incompatible] })
    expect { api.resolve('170', mendix_version: '11.12.1') }
      .to raise_error(Mxrb::MarketplaceError, /requires Mendix 12.0.0/)
  end

  it 'paginates every release page' do
    calls = 0
    allow(client).to receive(:json) do |**|
      calls += 1
      { 'items' => calls == 1 ? Array.new(20) { version(number: "1.0.#{_1}") } : [version] }
    end
    expect(api.all_versions(170).size).to eq(21)
    expect(calls).to eq(2)
  end

  it 'validates all documented filters before making a request' do
    expect { api.search(private: 'yes') }.to raise_error(Mxrb::MarketplaceError, /true or false/)
    expect { api.search(published_since: 'yesterday') }.to raise_error(Mxrb::MarketplaceError, /full date/)
    expect { api.search(limit: 101) }.to raise_error(Mxrb::MarketplaceError, /outside/)
    expect { api.search(offset: 'x') }.to raise_error(Mxrb::MarketplaceError, /integer/)
    expect { api.content(0) }.to raise_error(Mxrb::MarketplaceError, /invalid content ID/)
    expect { api.versions(170, version_id: 'bad') }.to raise_error(Mxrb::MarketplaceError, /version ID/)
    expect { api.versions(170, mendix_version: '11.next') }
      .to raise_error(Mxrb::MarketplaceError, /invalid Mendix/)
  end
end

RSpec.describe Mxrb::OfficialMarketplace::SecurityAuditor do
  it 'does not require credentials when there are no official lock entries' do
    Dir.mktmpdir do |dir|
      expect(described_class.new(target: dir).audit).to eq([])
    end
  end

  it 'audits only official lock entries for updates and vulnerabilities' do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, '.mxrb'))
      File.write(File.join(dir, '.mxrb', 'marketplace.lock.json'), JSON.generate('packages' => {
        'Safe' => { 'source' => 'mendix', 'content_id' => 1, 'version_id' => 'safe',
                    'version' => '1.0.0' },
        'Unsafe' => { 'source' => 'mendix', 'content_id' => 2, 'version_id' => 'unsafe',
                      'version' => '1.0.0' },
        'Missing' => { 'source' => 'mendix', 'content_id' => 3, 'version_id' => 'missing',
                       'version' => '1.0.0' },
        'GitHub' => { 'source' => 'github' }
      }))
      api = instance_double(Mxrb::OfficialMarketplace::ContentApi)
      allow(api).to receive(:versions) do |id, **|
        next [] if id == 3

        type = id == 1 ? 'Regular' : 'Vulnerable'
        issues = id == 1 ? [] : [{ 'code' => 'CVE-1' }]
        [{ 'versionNumber' => '1.0.0', 'versionType' => type, 'vulnerabilities' => issues }]
      end
      allow(api).to receive(:resolve) do |id, **|
        version = id == '2' ? '1.1.0' : '1.0.0'
        Mxrb::OfficialMarketplace::OfficialPackage.new(
          'Module', version, :mendix, nil, "content:#{id}", id.to_i, 'version',
          'Module', 'Regular', [], false, true
        )
      end
      results = described_class.new(target: dir, api:).audit(mendix_version: '11.12.1')
      expect(results.map(&:name)).to eq(%w[Safe Unsafe Missing])
      expect(results.first).to have_attributes(valid: true, outdated: false)
      expect(results[1]).to have_attributes(valid: false, outdated: true, issues: ['CVE-1'])
      expect(results.last).to have_attributes(valid: false, version_type: 'Unknown')
    end
  end
end

RSpec.describe Mxrb::OfficialMarketplace::Installer, 'official Content API' do
  it 'requires an MPR for official module imports' do
    installer = described_class.new(target: Dir.pwd)
    expect { installer.pull_official('10', api: double) }
      .to raise_error(Mxrb::MarketplaceError, /requires --mpr/)
  end

  it 'rejects non-module content when importing into an MPR' do
    package = Mxrb::OfficialMarketplace::OfficialPackage.new(
      'Widget', '1.0.0', :mendix, nil, 'content:10', 10,
      '123e4567-e89b-12d3-a456-426614174000', 'Widget', 'Regular', [], false, false
    )
    api = instance_double(Mxrb::OfficialMarketplace::ContentApi, resolve: package)
    installer = described_class.new(target: Dir.pwd, mpr: __FILE__)
    allow(installer).to receive(:detect_mendix_version).and_return('11.12.1')
    expect { installer.pull_official('10', api:) }
      .to raise_error(Mxrb::MarketplaceError, /not a Module/)
  end

  it 'closes safely when target Mendix version detection cannot open the MPR' do
    installer = described_class.new(target: Dir.pwd)
    allow(Mxrb::IO::MprFile).to receive(:open).and_raise(Mxrb::Error, 'invalid MPR')
    expect { installer.send(:detect_mendix_version, 'missing.mpr') }
      .to raise_error(Mxrb::Error, /invalid MPR/)
  end

  it 'keeps the resolved Marketplace version when a package manifest omits it' do
    package = Mxrb::OfficialMarketplace::OfficialPackage.new(
      'Display Name', '1.2.3', :mendix, nil, 'content:10', 10, 'version-id',
      'Module', 'Regular', [], false, true
    )
    result = double(module_name: 'ModuleName', package_version: '')
    resolved = described_class.new(target: Dir.pwd).send(:resolved_package, package, result)
    expect(resolved).to have_attributes(name: 'ModuleName', version: '1.2.3')
  end
end
# rubocop:enable Metrics/BlockLength
