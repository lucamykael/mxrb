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
end
