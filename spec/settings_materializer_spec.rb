# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::SettingsMaterializer do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'App.mpr')
      @deployment = File.join(root, 'deployment')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module(:App) { microflow :Run }
      end
      set_after_startup
      prepare_model
      example.run
    end
  end

  def set_after_startup
    mpr = Mxrb::IO::MprFile.open(@mpr)
    raw = mpr.all_units.find { mpr.parse_contents(_1)['$Type'] == 'Settings$ProjectSettings' }
    document = mpr.parse_contents(raw)
    settings = Mxrb::IO::BsonCodec.parse_array(document['Settings'])[:items]
    settings.find { _1['$Type'] == 'Settings$ModelSettings' }['AfterStartupMicroflow'] = 'App.Run'
    mpr.update_unit(raw.fetch('UnitID'), document)
    mpr.close
  end

  def plain(value)
    case value
    when Hash then value.transform_values { plain(_1) }
    when Array then Mxrb::IO::BsonCodec.parse_array(value)[:items].map { plain(_1) }
    else value
    end
  end

  def prepare_model
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    settings = source.units_of('Settings$ProjectSettings').first.document
    runtime = plain(settings)
    model = runtime['Settings'].find { _1['$Type'] == 'Settings$ModelSettings' }
    model['RuntimeOnly'] = 'preserved'
    path = File.join(@deployment, 'model', 'model.mdp')
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, Mxrb::IO::BsonCodec.serialize(runtime))
  end

  it 'synchronizes lifecycle settings using ordered Runtime schemas' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    settings = Mxrb::Compiler::ModelPackage.read(result.model_path).documents.first
    model = settings['Settings'].find { _1['$Type'] == 'Settings$ModelSettings' }

    expect(result.documents).to eq(1)
    expect(model).to include('AfterStartupMicroflow' => 'App.Run')
    expect(model).not_to have_key('RuntimeOnly')
    expect(settings['Settings']).not_to include(Integer)
  end

  it 'rejects non-settings roots and fills schema fields without counterparts' do
    schema = Struct.new(:fields) do
      def fields_for(_source) = fields
      def counterpart(_source) = nil
    end.new(%w[$ID $Type Missing])
    compiler = Mxrb::Compiler::SettingsDocumentCompiler.new(schema)
    expect(compiler.send(:compile_value, { 'Nested' => [3, 'value'] }))
      .to eq('Nested' => ['value'])
    unit = Mxrb::Compiler::SourceModel::Unit.new(
      id: 'settings', container_id: 'settings', containment: 'Settings', module_name: nil,
      document: { '$ID' => 'settings', '$Type' => 'Settings$ProjectSettings',
                  'Settings' => [{ '$ID' => 'part', '$Type' => 'Settings$ModelSettings' }] }
    )
    expect(compiler.compile(unit).dig('Settings', 0, 'Missing')).to be_nil
    expect { compiler.compile(unit.with(document: unit.document.merge('$Type' => 'Test$Settings'))) }
      .to raise_error(Mxrb::CompilationError, /unsupported settings root/)
  end
end
# rubocop:enable Metrics/BlockLength
