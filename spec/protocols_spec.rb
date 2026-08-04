# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Protocols do
  def entry(protocol:, guids: [], name: 'Test', marketplace_id: '1')
    described_class::Entry.new(
      protocol: protocol, name: name, publisher: 'Mendix', category: 'Messaging',
      marketplace_id: marketplace_id, content_type: 'Module', appstore_guids: guids.freeze,
      source_url: "https://marketplace.mendix.com/link/component/#{marketplace_id}",
      evidence_date: '2026-08-02'
    )
  end

  def mod(name:, guid: nil, version: '', **attrs)
    defaults = { name: name, app_store_guid: guid, app_store_version: version,
                 from_app_store: true, export_level: 'Hidden', entities: [], microflows: [] }
    instance_double(Mxrb::Model::Module, **defaults.merge(attrs))
  end

  def project(*modules) = instance_double(Mxrb::Model::Project, modules: modules)

  it 'exposes an immutable registry of connectors with verifiable provenance' do
    expect(described_class.all).to be_frozen
    expect(described_class.all).to all(be_a(described_class::Entry))
    expect(described_class.all.map(&:marketplace_id)).to contain_exactly(
      '119508', '230843', '117391', '105878', '235426', '118800'
    )
    expect(described_class.all.map(&:source_url)).to all(start_with('https://marketplace.mendix.com/'))
  end

  it 'finds registered connectors by protocol and ignores unknown protocols' do
    expect(described_class.find_by_protocol(:opc_ua).map(&:name))
      .to contain_exactly('OPC-UA Connector', 'OPC UA Client Connector')
    expect(described_class.find_by_protocol('MQTT').map(&:name)).to eq(['MQTT'])
    expect(described_class.find_by_protocol(:kafka).map(&:name)).to eq(['Kafka'])
    expect(described_class.find_by_protocol('websocket').map(&:name)).to eq(['WebsocketClient'])
    expect(described_class.find_by_protocol(:amqp).map(&:name)).to eq(['eMagiz Mendix Connector (Legacy)'])
    expect(described_class.find_by_protocol(:modbus)).to be_empty
  end

  it 'previews connector installation without writing and applies only through explicit adapters' do
    package = Mxrb::OfficialMarketplace::OfficialPackage.new(
      'Kafka', '2.12.0', :mendix, 'https://example.test/kafka.mpk', 'content:105878',
      105_878, '123e4567-e89b-12d3-a456-426614174000', 'Module', 'Regular', [], false, true
    )
    api = instance_double(Mxrb::OfficialMarketplace::ContentApi)
    installer = instance_double(Mxrb::OfficialMarketplace::Installer)
    allow(api).to receive(:resolve).with(
      '105878', version: '2.12.0', mendix_version: '10.24.0'
    ).and_return(package)
    allow(installer).to receive(:pull_official).with(
      '105878', version: '2.12.0', mendix_version: '10.24.0', api:
    ).and_return(:installed)

    adapter = described_class.adapter(installer:, api:)
    plan = described_class.plan(:kafka, mendix_version: '10.24.0', version: '2.12.0', adapter:)
    expect(plan).to be_safe
    expect(plan.changes.first).to include(
      action: :install, protocol: :kafka, marketplace_id: '105878', version: '2.12.0'
    )
    expect(plan.apply!).to eq(:installed)
    expect(plan).to be_applied
    expect { plan.apply! }.to raise_error(Mxrb::MarketplaceError, /already applied/)
  end

  it 'fails closed for unverified protocols and adapter-free apply' do
    expect { described_class.plan(:modbus, mendix_version: '10.24.0') }
      .to raise_error(Mxrb::MarketplaceError, /no verified Marketplace connector/)

    plan = described_class.plan(:websocket, mendix_version: '10.24.0', version: '1.0.0')
    expect(plan).not_to be_safe
    expect(plan.changes.first[:version]).to eq('1.0.0')
    expect(plan.blocked_reasons).to include(/adapter was not provided/, /version was not resolved/)
    expect { plan.apply! }.to raise_error(Mxrb::MarketplaceError, /blocked/)

    adapter = described_class.adapter(installer: double, api: nil)
    unresolved = described_class.plan(:kafka, mendix_version: '10.24.0', adapter:)
    expect(unresolved.blocked_reasons).to eq(['official Marketplace version was not resolved'])

    selected = described_class.plan(
      :opc_ua, mendix_version: '10.24.0', marketplace_id: 117_391
    )
    expect(selected.entry.name).to eq('OPC UA Client Connector')
    expect { described_class.plan(:opc_ua, mendix_version: '10.24.0', marketplace_id: 'missing') }
      .to raise_error(Mxrb::MarketplaceError, /no verified Marketplace connector/)
  end

  it 'exposes connector declarations in the Ruby builder without emitting an incomplete MPR' do
    builder = Mxrb::Dsl::Builder.new('/tmp/connector-plan.mpr')
    builder.mendix_version('10.24.0')
    builder.connector(:opc_ua, version: '2.2.0')

    expect(builder.definition[:connectors]).to eq(
      [{ protocol: :opc_ua, version: '2.2.0', marketplace_id: nil }]
    )
    expect(builder.connector_plans.first.entry.marketplace_id).to eq('230843')
    expect { builder.build! }.to raise_error(Mxrb::MarketplaceError, /preview-only/)
    expect(File).not_to exist('/tmp/connector-plan.mpr')
  end

  it 'identifies connectors only by verified GUIDs and fails closed otherwise' do
    verified = entry(protocol: :mqtt, guids: ['real-guid'])
    expect(verified.matches_guid?('real-guid')).to be(true)
    expect(verified.matches_guid?('other')).to be(false)
    expect(verified.matches_guid?('')).to be(false)

    expect(described_class.identify('')).to be_nil
    expect(described_class.identify('unregistered')).to be_nil
    expect(described_class.identify('real-guid', registry: [verified])).to eq(verified)
    expect(described_class.known_guid?('real-guid', registry: [verified])).to be(true)
    expect(described_class.known_guid?('unregistered')).to be(false)
  end

  it 'audits imported marketplace modules and fails closed on unknown GUIDs' do
    verified = entry(protocol: :opc_ua, guids: ['guid-opc'], name: 'OPC-UA Connector', marketplace_id: '230843')
    result = described_class.audit(
      project(
        mod(name: 'OpcConnector', guid: 'guid-opc', version: '1.2.0', export_level: 'Hidden'),
        mod(name: 'ZebraWidgetLib', guid: 'unknown-guid'),
        mod(name: 'AlphaWidgetLib', guid: 'another-unknown'),
        mod(name: 'PlainModule', from_app_store: false)
      ),
      registry: [verified]
    )

    expect(result.connectors.map(&:module_name)).to eq(['OpcConnector'])
    connector = result.connectors.first
    expect(connector).to be_known
    expect(connector.protocol).to eq(:opc_ua)
    expect(connector.appstore_version).to eq('1.2.0')
    expect(connector.protected).to be(true)
    expect(connector.entities).to eq([])
    expect(connector.metadata).to include(marketplace_id: '230843', name: 'OPC-UA Connector')
    expect(result.unknown_marketplace_modules).to eq(%w[AlphaWidgetLib ZebraWidgetLib])
  end

  it 'reports the public surface of a readable connector module' do
    verified = entry(protocol: :mqtt, guids: ['guid-mqtt'], name: 'MQTT', marketplace_id: '119508')
    readable = mod(
      name: 'Mqtt', guid: 'guid-mqtt', export_level: 'Public',
      entities: [instance_double(Mxrb::Model::Entity, name: 'Message'),
                 instance_double(Mxrb::Model::Entity, name: 'Broker')],
      microflows: [instance_double(Mxrb::Model::Microflow, name: 'Publish')]
    )
    connector = described_class.audit(project(readable), registry: [verified]).connectors.first

    expect(connector.protected).to be(false)
    expect(connector.entities).to eq(%w[Broker Message])
    expect(connector.microflows).to eq(['Publish'])
  end

  it 'detects real FromAppStore modules in a live fixture when it is present' do
    fixture = '/home/mykael/Personal_Projects/mxrb-fixtures/ConnectorKitDemo/ConnectorKitDemo.mpr'
    skip 'connector fixture not present in this environment' unless File.exist?(fixture)

    Mxrb.open(fixture) do |project|
      result = described_class.audit(project)
      expect(result.unknown_marketplace_modules).to include('AppCloudServices', 'ObjectHandling')
      expect(result.connectors).to be_empty
    end
  end

  it 'preserves imported modules through export, rebuild, and semantic indexing' do
    fixture = '/home/mykael/Personal_Projects/mxrb-fixtures/ConnectorKitDemo/ConnectorKitDemo.mpr'
    skip 'connector fixture not present in this environment' unless File.exist?(fixture)

    Dir.mktmpdir do |root|
      exported = File.join(root, 'exported')
      rebuilt = File.join(root, 'rebuilt.mpr')
      original_imports = nil
      original_artifacts = nil
      Mxrb.open(fixture) do |project|
        original_imports = imported_modules(project)
        original_artifacts = project.semantic_index.artifacts.map(&:qualified_name).sort
      end

      Mxrb::Exporter.new(fixture, exported).export!(parallel: false)
      begin
        ENV['MXRB_OUTPUT_PATH'] = rebuilt
        load File.join(exported, 'project.rb')
      ensure
        ENV.delete('MXRB_OUTPUT_PATH')
      end

      expect(Mxrb.validate(rebuilt)).to be_valid
      Mxrb.open(rebuilt) do |project|
        expect(imported_modules(project)).to eq(original_imports)
        expect(project.semantic_index.artifacts.map(&:qualified_name).sort).to eq(original_artifacts)
        expect(described_class.audit(project).unknown_marketplace_modules)
          .to include('AppCloudServices', 'ObjectHandling')
      end
    end
  end

  def imported_modules(project)
    project.modules.select(&:from_app_store).to_h do |mod|
      [mod.name, { guid: mod.app_store_guid, version: mod.app_store_version }]
    end
  end
end

RSpec.describe Mxrb::Model::Connector do
  it 'is known only when a protocol is resolved' do
    base = {
      module_name: 'X', appstore_guid: nil, appstore_version: '', entities: [],
      microflows: [], protected: true, metadata: {}
    }
    expect(described_class.new(protocol: :mqtt, **base)).to be_known
    expect(described_class.new(protocol: nil, **base)).not_to be_known
  end
end
# rubocop:enable Metrics/BlockLength
