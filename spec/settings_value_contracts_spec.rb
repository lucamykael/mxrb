# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Mxrb::Settings::Node do # rubocop:disable Metrics/BlockLength
  def node(type) = described_class.new("Settings$#{type}")
  def collection(*items) = Mxrb::Settings::Collection.new(items:)

  it 'rejects invalid scalar types at the Ruby assignment boundary' do
    model = node('ModelSettings')
    expect { model.set(:use_oql_version2, 'true') }.to raise_error(Mxrb::Settings::Error, /expects boolean/)
    expect { model.set(:bcrypt_cost, '12') }.to raise_error(Mxrb::Settings::Error, /expects Integer/)
    expect { model.set(:java_major_version, 21) }.to raise_error(Mxrb::Settings::Error, /expects String/)
    expect { model.set(:java_major_version, {}) }.to raise_error(Mxrb::Settings::Error, /got Hash/)
    expect { model.set(:bcrypt_cost, nil) }.to raise_error(Mxrb::Settings::Error, /got NilClass/)
    expect(model.fields).to be_empty
  end

  it 'preserves evidenced nullable components and checks assigned component types' do
    server = node('ServerConfiguration')
    server.set(:open_telemetry, nil).set(:tracing, nil)
    telemetry = node('OpenTelemetryConfiguration').set(:logs, nil).set(:traces, nil)
    server.set(:open_telemetry, telemetry)
    workflow = node('WorkflowsProjectSettingsPart')
    workflow.set(:usertask_on_state_change_event, nil).set(:workflow_on_state_change_event, nil)

    expect(server.fetch(:open_telemetry)).to equal(telemetry)
    expect(server.fetch(:tracing)).to be_nil
    expect { server.set(:open_telemetry, node('ModelSettings')) }
      .to raise_error(Mxrb::Settings::Error, /expects Settings\$OpenTelemetryConfiguration/)
    expect { telemetry.set(:logs, Object.new) }.to raise_error(Mxrb::Settings::Error, /typed_value/)
  end

  it 'checks collection containers, component types, and scalar element types' do
    root = node('ProjectSettings')
    configuration = node('ConfigurationSettings')
    configuration.set(:configurations, collection(node('ServerConfiguration')))
    root.set(:settings, collection(configuration))

    expect { root.set(:settings, [configuration]) }.to raise_error(Mxrb::Settings::Error, /Collection/)
    expect { root.set(:settings, collection(node('ServerConfiguration'))) }
      .to raise_error(Mxrb::Settings::Error, /settings\[0\]/)
    expect { configuration.set(:configurations, collection('server')) }
      .to raise_error(Mxrb::Settings::Error, /configurations\[0\]/)
    expect { node('JarDeploymentSettings').set(:exclusions, collection(123)) }
      .to raise_error(Mxrb::Settings::Error, /exclusions\[0\]/)
    expect { node('ServerConfiguration').set(:constant_values, collection({})) }
      .to raise_error(Mxrb::Settings::Error, /constant_values\[0\]/)
    constant = node('ConstantValue').set(:constant_id, 'App.Endpoint')
    constant.set(:shared_or_private_value, node('SharedValue').set(:value, 'https://example.test'))
    expect { constant.set(:shared_or_private_value, node('CustomSetting')) }
      .to raise_error(Mxrb::Settings::Error, /shared_or_private_value/)
    node('ServerConfiguration').set(:constant_values, collection(constant))
    expect { Mxrb::Settings::Collection.new(items: [], marker: 0) }
      .to raise_error(Mxrb::Settings::Error, /marker/)
  end

  it 'requires binary assets for certificates and prevents bypassing assignment validation' do
    certificate = node('Certificate')
    certificate.set(:data, Mxrb::Settings::BinaryAsset.empty)
    expect { certificate.set(:data, 'bytes') }.to raise_error(Mxrb::Settings::Error, /BinaryAsset/)
    expect { certificate.fields['Data'] = 'bytes' }.to raise_error(FrozenError)
  end

  it 'copies caller-owned scalar and collection strings without freezing their inputs' do
    name = +'Local'
    server = node('ServerConfiguration').set(:name, name)
    exclusion = +'old.jar'
    inputs = [exclusion]
    jars = node('JarDeploymentSettings').set(:exclusions, Mxrb::Settings::Collection.new(items: inputs))
    name.replace('Changed')
    exclusion.replace('new.jar')
    inputs.clear

    expect(server.fetch(:name)).to eq('Local')
    expect(jars.fetch(:exclusions).items).to eq(['old.jar'])
  end

  it 'round-trips the shipped Studio 11 template including absent telemetry settings' do
    path = File.expand_path('../lib/mxrb/templates/project/11.12.1.json', __dir__)
    unit = JSON.parse(File.read(path)).fetch('units').find { _1.fetch('type') == 'Settings$ProjectSettings' }
    document = Mxrb::IO::BsonCodec.parse(Base64.strict_decode64(unit.fetch('contents')))
    codec = Mxrb::Settings::MprCodec.new

    rebuilt = codec.encode(codec.decode(document), baseline: document)

    expect(Mxrb::IO::BsonCodec.serialize(rebuilt)).to eq(Mxrb::IO::BsonCodec.serialize(document))
  end

  it 'fails closed for unknown builder components, fields, and malformed nesting' do
    collection_builder = Mxrb::Settings::CollectionBuilder.new
    expect(collection_builder).to respond_to(:server)
    expect(collection_builder).not_to respond_to(:unknown_component)
    expect { collection_builder.server }.to raise_error(NoMethodError)
    expect { collection_builder.unknown_component {} }
      .to raise_error(Mxrb::Settings::Error, /unsupported project-settings component/)
    expect { Mxrb::Settings::Catalog.type_for_method(:unknown) }
      .to raise_error(Mxrb::Settings::Error, /unsupported project-settings component/)

    model = node('ServerConfiguration')
    builder = Mxrb::Settings::NodeBuilder.new(model)
    expect(builder).to respond_to(:open_telemetry)
    expect(builder).not_to respond_to(:unknown_field)
    expect { builder.open_telemetry {} }.to raise_error(Mxrb::Settings::Error, /requires a component type/)
    expect { builder.open_telemetry(:tracing_configuration, :extra) {} }
      .to raise_error(Mxrb::Settings::Error, /accepts one component type/)
    expect { builder.constant_values(:extra) {} }
      .to raise_error(Mxrb::Settings::Error, /does not accept arguments/)
    expect { builder.name }.to raise_error(Mxrb::Settings::Error, /exactly one value/)
    expect { builder.name('one', 'two') }.to raise_error(Mxrb::Settings::Error, /exactly one value/)

    project_builder = Mxrb::Settings::ProjectBuilder.new
    expect(project_builder).to respond_to(:model)
    expect(project_builder).not_to respond_to(:server)
    expect { project_builder.server {} }.to raise_error(NoMethodError)
  end

  it 'rejects invalid codec roots and ambiguous or malformed baselines' do
    codec = Mxrb::Settings::MprCodec.new
    expect { codec.decode('$ID' => SecureRandom.uuid, '$Type' => 'Settings$ModelSettings') }
      .to raise_error(Mxrb::Settings::Error, /root must be/)
    expect { codec.encode(node('ModelSettings')) }
      .to raise_error(Mxrb::Settings::Error, /model must be/)
    expect(codec.send(:bson_items, 'not an array')).to be_empty
    expect(codec.send(:bson_items, [0])).to be_empty

    candidate = node('ServerConfiguration')
    previous = [
      { '$Type' => 'Settings$ServerConfiguration' },
      { '$Type' => 'Settings$ServerConfiguration' }
    ]
    expect { codec.send(:positional_node_index, candidate, previous, {}, 0) }
      .to raise_error(Mxrb::Settings::Error, /ambiguous settings identity/)
    expect(codec.send(:positional_node_index, 'scalar', previous, {}, 0)).to be_nil
    expect(codec.send(:positional_node_index, candidate, [], {}, 0)).to be_nil
    expect { codec.send(:decode_value, {}) }
      .to raise_error(Mxrb::Settings::Error, /untyped maps/)

    allow(Mxrb::IO::BsonCodec).to receive(:parse_array).with([:malformed]).and_raise(ArgumentError, 'bad')
    expect { codec.send(:decode_value, [:malformed]) }
      .to raise_error(Mxrb::Settings::Error, /invalid project-settings collection: bad/)
    expect(codec.send(:bson_items, [:malformed])).to be_empty
  end

  it 'renders scalar settings values and rejects unsafe source representations' do
    emitter = Mxrb::Settings::SourceEmitter.new
    expect { emitter.emit(Object.new) }.to raise_error(Mxrb::Settings::Error, /Node root/)
    expect { emitter.emit(node('ProjectSettings')) }.to raise_error(KeyError)
    invalid_collection = node('ProjectSettings')
    invalid_collection.define_singleton_method(:fetch) { |_field| 'not a collection' }
    expect { emitter.emit(invalid_collection) }
      .to raise_error(Mxrb::Settings::Error, /must contain a Settings collection/)

    lines = []
    mixed = Mxrb::Settings::Collection.new(items: [node('PrivateValue'), 'mixed'])
    expect { emitter.send(:emit_collection, :constant_values, mixed, lines, 1) }
      .to raise_error(Mxrb::Settings::Error, /mixes scalar and component/)
    expect(emitter.send(:literal, Time.utc(2026, 9, 13))).to eq('Time.iso8601("2026-09-13T00:00:00.000000000Z")')
    expect(emitter.send(:literal, Mxrb::Settings::BinaryAsset.empty)).to include('BinaryAsset.empty')
    expect { emitter.send(:literal, Mxrb::Settings::BinaryAsset.from_bytes('secret')) }
      .to raise_error(Mxrb::Settings::Error, /was not externalized/)
  end

  it 'accepts typed values in open setting collections and rejects opaque objects' do
    workflow = node('WorkflowsProjectSettingsPart')
    nested = collection('group', collection(1, true, Time.utc(2026, 9, 13)))
    workflow.set(:groups, nested)
    expect(workflow.fetch(:groups)).to equal(nested)
    expect { workflow.set(:groups, collection(Object.new)) }
      .to raise_error(Mxrb::Settings::Error, /incompatible value/)
  end
end
