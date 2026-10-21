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

  it 'describes each language as the MxBuild of the version does' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    settings = Mxrb::Compiler::ModelPackage.read(result.model_path).documents.first
    languages = settings['Settings'].find { _1['$Type'] == 'Settings$LanguageSettings' }

    expect(languages['Languages'].first).to include(
      'Code' => 'en_US', 'Description' => 'English, United States', 'RightToLeft' => false
    )
    expect(languages['Languages'].first.keys).to eq(
      %w[$ID $Type Code Description RightToLeft CheckCompleteness CustomDateFormat CustomTimeFormat
         CustomDateTimeFormat]
    )

    schema = Struct.new(:fields, :existing) do
      def fields_for(_source) = fields
      def counterpart(_source) = existing
    end
    fields = %w[$ID $Type Code Description RightToLeft CustomDateFormat]
    language = { '$ID' => 'lang', '$Type' => 'Texts$Language', 'Code' => 'ar_SA' }
    bare = Mxrb::Compiler::SettingsDocumentCompiler.new(schema.new(fields, nil), version: '11.12.1')
    expect(bare.send(:compile_node, language)).to eq(
      '$ID' => 'lang', '$Type' => 'Texts$Language', 'Code' => 'ar_SA', 'Description' => 'Arabic, Saudi Arabia',
      'RightToLeft' => true, 'CustomDateFormat' => nil
    )
    seeded = Mxrb::Compiler::SettingsDocumentCompiler.new(schema.new(fields, { 'CustomDateFormat' => 'dd' }),
                                                          version: '11.12.1')
    expect(seeded.send(:compile_node, language)).to include('CustomDateFormat' => 'dd')
    expect(seeded.send(:compile_node, '$ID' => 'part', '$Type' => 'Settings$ModelSettings'))
      .to include('CustomDateFormat' => 'dd', 'Code' => nil)
    expect { bare.send(:compile_node, language.merge('Code' => 'xx_XX')) }
      .to raise_error(Mxrb::CompilationError, /language xx_XX is not one MxBuild 11.12.1 accepts/)
  end

  it 'knows the languages each MxBuild accepts and their writing direction' do
    languages = Mxrb::Compiler::Languages
    expect(languages.entry('ar_SA', '11.12.1')).to eq('description' => 'Arabic, Saudi Arabia', 'rtl' => true)
    expect(languages.entry('pt_BR', '10.24.0.73019')).to eq('description' => 'Portuguese, Brazil', 'rtl' => false)
    expect(languages.table('9.24.0')).to equal(languages.table('10.24.0.73019'))
    expect(languages.table('11.12.1').keys - languages.table('10.24.0.73019').keys).to eq(%w[he_IL id_ID ka_GE])
    expect { languages.entry('he_IL', '10.24.0.73019') }
      .to raise_error(Mxrb::CompilationError, /language he_IL is not one MxBuild 10.24.0.73019 accepts/)
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
