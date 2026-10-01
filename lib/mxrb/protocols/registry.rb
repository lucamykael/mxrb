# frozen_string_literal: true

module Mxrb
  module Protocols
    # Verified against Content API metadata and the downloaded package MPRs.
    REGISTRY = [
      Entry.new(
        protocol: :mqtt, name: 'MQTT Connector', publisher: 'Mendix', category: 'Internet-of-Things',
        marketplace_id: '119508', content_type: 'Service', module_name: 'MqttConnector',
        appstore_guids: [].freeze, certified_version: '3.0.1',
        certified_version_id: '95e177cb-e506-4efa-97ed-a8f291ea5d2b',
        certified_sha256: 'eb357819437acff4a57dbb419e722917b2d3894c4b521b91e668de7b4e67a558',
        certified_model_version: '10.24.11.83811',
        source_url: 'https://marketplace.mendix.com/link/component/119508',
        evidence_date: '2026-09-30'
      ),
      Entry.new(
        protocol: :opc_ua, name: 'OPC UA Connector', publisher: 'Mendix', category: 'Connectors',
        marketplace_id: '230843', content_type: 'Module', module_name: 'OPCUAConnector',
        appstore_guids: [].freeze, certified_version: '2.3.0',
        certified_version_id: '2655d4a6-ce07-4a22-814b-97e199dab5dd',
        certified_sha256: 'e660d207c4089f4af12e3d869661ba98b6c1998d2139118f70fbbeca9adc61f8',
        certified_model_version: '10.24.0.73019',
        source_url: 'https://marketplace.mendix.com/link/component/230843',
        evidence_date: '2026-09-30'
      ),
      Entry.new(
        protocol: :opc_ua, name: 'OPC UA Client Connector', publisher: 'Mendix', category: 'Industrial',
        marketplace_id: '117391', content_type: 'Service', module_name: 'OpcUaClientMx',
        appstore_guids: [].freeze, certified_version: '1.1.0',
        certified_version_id: '8456058e-6231-4e39-a3cc-51088ad7bf3e',
        certified_sha256: 'f9de12154746a83cd284f928e30805315cda65fc05866b3e4a22e05b35c97f73',
        certified_model_version: '9.6.10.40529',
        source_url: 'https://marketplace.mendix.com/link/component/117391',
        evidence_date: '2026-09-30'
      ),
      Entry.new(
        protocol: :kafka, name: 'Kafka', publisher: 'Siemens', category: 'Connectors',
        marketplace_id: '105878', content_type: 'Module', module_name: 'Kafka',
        appstore_guids: [].freeze, certified_version: '2.15.0',
        certified_version_id: '9b047060-6138-4783-abae-1984b452993a',
        certified_sha256: '0602b0e2d3dc16d861c798a3e16e3859f4a89efcfdb01be0ded07a3f569936b7',
        certified_model_version: '10.21.0.64362',
        source_url: 'https://marketplace.mendix.com/link/component/105878',
        evidence_date: '2026-09-30'
      ),
      Entry.new(
        protocol: :websocket, name: 'WebsocketClient', publisher: 'Siemens', category: 'Communication',
        marketplace_id: '235426', content_type: 'Module', module_name: 'WebsocketClient',
        appstore_guids: [].freeze, certified_version: '1.1.0',
        certified_version_id: '97662900-661f-471e-becc-585c1d9c898d',
        certified_sha256: '73d9797a5c4487069f11e0c1313bd2b67e8e3b93107f398ae5d7844878b19fa6',
        certified_model_version: '11.12.2',
        source_url: 'https://marketplace.mendix.com/link/component/235426',
        evidence_date: '2026-09-30'
      )
    ].freeze
  end
end
