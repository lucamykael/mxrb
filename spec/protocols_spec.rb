# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Protocols do
  def entry(protocol:, guids: [], name: 'Test', marketplace_id: '1')
    described_class::Entry.new(
      protocol: protocol, name: name, publisher: 'Mendix', category: 'Messaging',
      marketplace_id: marketplace_id, appstore_guids: guids.freeze,
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
    expect(described_class.all.map(&:marketplace_id)).to contain_exactly('119508', '230843', '117391')
    expect(described_class.all.map(&:source_url)).to all(start_with('https://marketplace.mendix.com/'))
  end

  it 'finds registered connectors by protocol and ignores unknown protocols' do
    expect(described_class.find_by_protocol(:opc_ua).map(&:name))
      .to contain_exactly('OPC-UA Connector', 'OPC UA Client Connector')
    expect(described_class.find_by_protocol('MQTT').map(&:name)).to eq(['MQTT'])
    expect(described_class.find_by_protocol(:modbus)).to be_empty
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
