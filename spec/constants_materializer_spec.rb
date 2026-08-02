# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::ConstantsMaterializer do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'App.mpr')
      @deployment = File.join(root, 'deployment')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module(:App) do
          constant :RetryCount, type: :integer, value: 3 do
            documentation 'Maximum retries'
          end
          constant :ClientKey, type: :string, value: 'browser-key'
        end
      end
      add_client_reference
      prepare_deployment
      example.run
    end
  end

  def source_constants
    model = Mxrb::Compiler::SourceModel.read(@mpr)
    model.units_of('Constants$Constant').to_h { [_1.document['Name'], _1.document] }
  end

  def add_client_reference
    mpr = Mxrb::IO::MprFile.open(@mpr)
    mod = mpr.all_units.find { mpr.parse_contents(_1)['$Type'] == 'Projects$ModuleImpl' }
    mpr.insert_unit(
      container_uuid: mod.fetch('UnitID'), containment_name: 'Documents',
      contents_doc: {
        '$ID' => '33333333-3333-4333-8333-333333333333', '$Type' => 'Microflows$Nanoflow',
        'Name' => 'UseClientKey', 'Expression' => 'prefix @App.ClientKey suffix @App.ClientKeyboard'
      }
    )
    mpr.close
  end

  def prepare_deployment
    FileUtils.mkdir_p(File.join(@deployment, 'model'))
    source = source_constants
    old = {
      '$ID' => source.fetch('ClientKey')['$ID'], '$Type' => 'Constants$Constant',
      'Name' => 'Stale', 'QualifiedName' => 'Stale.ClientKey',
      'DataType' => 'String', 'ExposedToClient' => false
    }
    sentinel = { '$ID' => '44444444-4444-4444-8444-444444444444', '$Type' => 'Projects$Project' }
    write_model_fixture(sentinel, old)
    write_metadata_fixture
  end

  def write_metadata_fixture
    File.write(File.join(@deployment, 'model', 'metadata.json'),
               JSON.generate('RuntimeVersion' => '11.12.1', 'Constants' => [{ 'Name' => 'Stale' }]))
  end

  def write_model_fixture(*documents)
    bytes = documents.map { Mxrb::IO::BsonCodec.serialize(_1) }.join
    File.binwrite(File.join(@deployment, 'model', 'model.mdp'), bytes)
  end

  it 'materializes Runtime constants, client exposure, defaults, and missing documents' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    package = Mxrb::Compiler::ModelPackage.read(result.model_path)
    documents = package.documents.select { _1['$Type'] == 'Constants$Constant' }
    constants = documents.to_h { [_1['Name'], _1] }
    expect(constants.fetch('ClientKey')).to include(
      'QualifiedName' => 'App.ClientKey', 'DataType' => 'String', 'ExposedToClient' => true
    )
    expect(constants.fetch('RetryCount')).to include(
      'QualifiedName' => 'App.RetryCount', 'DataType' => 'Integer', 'ExposedToClient' => false
    )
    metadata = JSON.parse(File.read(result.metadata_path))
    expect(metadata['Constants']).to eq(
      [
        { 'Name' => 'App.ClientKey', 'Type' => 'String', 'Description' => '',
          'DefaultValue' => 'browser-key' },
        { 'Name' => 'App.RetryCount', 'Type' => 'Integer', 'Description' => 'Maximum retries',
          'DefaultValue' => '3' }
      ]
    )
    expect(result.constants).to eq(metadata['Constants'])
  end

  it 'rejects unsupported constant types explicitly' do
    mpr = Mxrb::IO::MprFile.open(@mpr)
    raw = mpr.all_units.find { mpr.parse_contents(_1)['Name'] == 'RetryCount' }
    document = mpr.parse_contents(raw)
    document['Type']['$Type'] = 'DataTypes$ObjectType'
    mpr.update_unit(raw.fetch('UnitID'), document)
    mpr.close

    expect { described_class.new(@mpr, deployment: @deployment).materialize }
      .to raise_error(Mxrb::CompilationError, /unsupported constant type.*App\.RetryCount/)
  end
end
# rubocop:enable Metrics/BlockLength
