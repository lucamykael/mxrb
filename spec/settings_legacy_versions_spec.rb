# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'typed project settings across Mendix 5 through 10' do
  it 'roundtrips the available 6, 7, 9, and 10 project templates semantically' do
    versions = %w[6.10.8 7.5.0 7.17.0 9.6.1.29396 10.24.0.73019]
    Dir.mktmpdir('mxrb-legacy-settings-') do |directory|
      versions.each do |version|
        source = File.join(directory, version, 'source.mpr')
        exported = File.join(directory, version, 'ruby')
        rebuilt = File.join(directory, version, 'rebuilt.mpr')
        FileUtils.mkdir_p(File.dirname(source))
        Mxrb.define(source) do
          mendix_version version
          self.module(:App) {}
        end
        original = project_settings(source)

        Mxrb::Exporter.new(source, exported).export!(parallel: false)
        ruby = File.read(File.join(exported, 'app', 'settings', 'settings.rb'))
        expect(ruby).to include('project_settings do', 'web_ui do')
        expect(ruby).not_to include('project_settings_document', 'deep_structure:')
        with_output(rebuilt) { load File.join(exported, 'project.rb') }

        expect(project_settings(rebuilt)).to eq(original)
      end
    end
  end

  it 'supports the flat Mendix 5 settings shape without invoking Studio Pro' do
    baseline = legacy_five_settings
    codec = Mxrb::Settings::MprCodec.new
    model = codec.decode(baseline)
    source = Mxrb::Settings::SourceEmitter.new.emit(model)
    builder = Mxrb::Dsl::Builder.new('/tmp/legacy-settings.mpr')
    builder.instance_eval(source)
    rebuilt = codec.encode(builder.definition.fetch(:project_settings_model), baseline:)

    expect(source).to include(
      'project_languages do', 'web_ui do', 'feedback_widget_updated true',
      'configurations do', 'project_certificates', 'hash_algorithm "SSHA256"'
    )
    expect(rebuilt).to eq(baseline)
  end

  it 'creates typed settings without a template baseline and rejects unsupported majors' do
    Dir.mktmpdir('mxrb-settings-eight-') do |directory|
      path = File.join(directory, 'app.mpr')
      Mxrb.define(path) do
        mendix_version '8.18.0'
        project_settings do
          model do
            hash_algorithm 'SHA256'
            rounding_mode 'HalfUp'
          end
        end
        self.module(:App) {}
      end
      expect(project_settings(path)).to include('$Type' => 'Settings$ProjectSettings')
    end

    root = Mxrb::Settings::ProjectBuilder.new
    root.model do
      hash_algorithm 'SHA256'
      rounding_mode 'HalfUp'
    end
    writer = Mxrb::Writer.new('/tmp/settings-version-gate.mpr', version: '12.0.0', modules: [])
    writer.instance_variable_set(:@definition, { version: '12.0.0', project_settings_model: root.to_model })
    expect { writer.send(:write_typed_project_settings, Object.new, 'root') }
      .to raise_error(Mxrb::ValidationError, /Mendix 5 through 11/)
  end

  it 'keeps the native fallback for future settings versions' do
    Dir.mktmpdir('mxrb-future-settings-') do |directory|
      unit = {
        'UnitID' => SecureRandom.uuid, 'ContainerID' => SecureRandom.uuid,
        'ContainmentName' => 'ProjectDocuments'
      }
      document = legacy_five_settings
      project = double(mendix_version: '12.0.0', all_units: [unit])
      allow(project).to receive(:parse_bson).with(unit).and_return(document)
      exporter = Mxrb::Exporter.allocate
      exporter.instance_variable_set(:@output_dir, directory)
      allow(exporter).to receive(:system_text_declarations).and_return([])

      exporter.send(:export_global_documents, project)

      source = File.read(File.join(directory, 'app', 'settings', 'settings.rb'))
      expect(source).to include('project_settings_document(', 'Forms$WebUIProjectSettingsPart')
    end
  end

  def legacy_five_settings
    web = node(
      'Forms$WebUIProjectSettingsPart', {
        'Theme' => '(Default)', 'FeedbackWidgetUpdated' => true,
        'UseModernUI' => false, 'EnableWidgetBundling' => false
      }
    )
    integration = node('Settings$IntegrationProjectSettingsPart')
    server = node(
      'Settings$ServerConfiguration', {
        'CustomSettings' => collection([]), 'ConstantValues' => collection([]),
        'Name' => 'Default', 'ApplicationRootUrl' => 'http://localhost:8080/',
        'OpenHttpPort' => true, 'OpenAdminPort' => true, 'HttpPortNumber' => 8080,
        'ServerPortNumber' => 8090, 'MaxJavaHeapSize' => 0,
        'EmulateCloudSecurity' => false, 'ExtraJvmParameters' => '',
        'DatabaseType' => 'Hsqldb', 'DatabaseUrl' => '', 'DatabaseName' => 'default',
        'DatabaseUseIntegratedSecurity' => false, 'DatabaseUserName' => '',
        'DatabasePassword' => ''
      }
    )
    language = node(
      'Texts$Language', {
        'Code' => 'en_US', 'CheckCompleteness' => false, 'CustomDateFormat' => '',
        'CustomTimeFormat' => '', 'CustomDateTimeFormat' => ''
      }
    )
    node(
      'Settings$ProjectSettings', {
        'Languages' => collection([language]), 'Settings' => collection([web, integration], 2),
        'Configurations' => collection([server]), 'Certificates' => collection([]),
        'HashAlgorithm' => 'SSHA256', 'RoundingMode' => 'HalfUp',
        'ConversionState' => 'Finished', 'SkipJarAnalyzerStep' => false,
        'AfterStartupMicroflow' => '', 'BeforeShutdownMicroflow' => '',
        'HealthCheckMicroflow' => '', 'DefaultLanguageCode' => 'en_US',
        'FirstDayOfWeek' => 'Default', 'DefaultTimeZoneCode' => '',
        'ScheduledEventTimeZoneCode' => 'Etc/UTC', 'AllowUserMultipleSessions' => false,
        'LowerCaseMicroflowVariables' => false
      }
    )
  end

  def node(type, fields = {})
    { '$ID' => SecureRandom.uuid, '$Type' => type }.merge(fields)
  end

  def collection(items, marker = 3)
    Mxrb::IO::BsonCodec.build_array(items, marker:)
  end

  def project_settings(path)
    Mxrb.open(path) do |project|
      raw = project.all_units.find do |unit|
        project.parse_bson(unit)['$Type'] == 'Settings$ProjectSettings'
      end
      project.parse_bson(raw)
    end
  end

  def with_output(path)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = path
    yield
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
