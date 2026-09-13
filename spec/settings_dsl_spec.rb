# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Settings::MprCodec do
  it 'exports Mendix 11 project settings as clean Ruby and preserves the full BSON document' do
    Dir.mktmpdir('mxrb-typed-settings-') do |root|
      source = File.join(root, 'Settings.mpr')
      exported = File.join(root, 'ruby')
      rebuilt = File.join(root, 'rebuilt', 'Settings.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:App) {}
      end
      install_settings(source, complete_settings)
      original = project_settings(source)

      Mxrb::Exporter.new(source, exported).export!(parallel: false)
      ruby = File.read(File.join(exported, 'app', 'settings', 'settings.rb'))
      expect(ruby).to include(
        'project_settings do', 'web_ui do', 'server do', 'use_oql_version2 true',
        'open_telemetry :open_telemetry_configuration do', 'certificate do',
        'BinaryAsset.read(File.join(__dir__, "certificate-1.bin")'
      )
      expect(ruby).not_to match(Mxrb::PublicSourceAudit::UUID)
      expect(Mxrb::PublicSourceAudit.new(exported).violations.select do |entry|
        entry.subsystem == 'app/settings'
      end).to be_empty

      FileUtils.mkdir_p(File.dirname(rebuilt))
      with_output(rebuilt) { load File.join(exported, 'project.rb') }

      expect(project_settings(rebuilt)).to eq(original)
      expect(File.binread(File.join(exported, 'app', 'settings', 'certificate-1.bin')))
        .to eq("certificate\x00data".b)
    end
  end

  it 'uses deterministic identities for additions while retaining matching baseline identities' do
    baseline = complete_settings
    model = described_class.new.decode(baseline)
    configuration = model.fetch('Settings').items
                         .find { _1.storage_type == 'Settings$ConfigurationSettings' }
    configurations = configuration.fetch('Configurations')
    added = Mxrb::Settings::Node.new('Settings$ServerConfiguration').tap do |node|
      node.set('Name', 'Added')
    end
    configuration.set(
      'Configurations',
      Mxrb::Settings::Collection.new(items: [*configurations.items, added],
                                     marker: configurations.marker)
    )

    first = described_class.new.encode(model, baseline:)
    second = described_class.new.encode(model, baseline:)
    original_ids = nested_ids(baseline)
    rebuilt_ids = nested_ids(first)

    expect(first).to eq(second)
    expect(original_ids - rebuilt_ids).to be_empty
    expect(rebuilt_ids).to all(match(Mxrb::PublicSourceAudit::UUID))
  end

  it 'never reuses a baseline identity after reordering and renaming configurations' do
    baseline = settings_with_servers('A', 'B')
    codec = described_class.new
    model = codec.decode(baseline)
    configuration = model.fetch('Settings').items.first
    first, second = configuration.fetch('Configurations').items
    first.set('Name', 'C')
    configuration.set('Configurations', Mxrb::Settings::Collection.new(items: [second, first]))

    rebuilt = codec.encode(model, baseline:)
    servers = rebuilt.fetch('Settings')[1].fetch('Configurations').drop(1)
    original = baseline.fetch('Settings')[1].fetch('Configurations').drop(1)

    expect(servers.map { _1.fetch('Name') }).to eq(%w[B C])
    expect(servers.first.fetch('$ID')).to eq(original.last.fetch('$ID'))
    expect(nested_ids(rebuilt).uniq).to eq(nested_ids(rebuilt))
  end

  it 'reserves existing identities before inserting a configuration at the start' do
    codec = described_class.new
    baseline = codec.encode(codec.decode(settings_with_servers('A', 'B')))
    model = codec.decode(baseline)
    configuration = model.fetch('Settings').items.first
    original = baseline.fetch('Settings')[1].fetch('Configurations').drop(1)
    added = Mxrb::Settings::Node.new('Settings$ServerConfiguration').set('Name', 'New')
    items = [added, *configuration.fetch('Configurations').items]
    configuration.set('Configurations', Mxrb::Settings::Collection.new(items:))

    rebuilt = codec.encode(model, baseline:)
    servers = rebuilt.fetch('Settings')[1].fetch('Configurations').drop(1)

    expect(servers.drop(1).map { _1.fetch('$ID') }).to eq(original.map { _1.fetch('$ID') })
    expect(nested_ids(rebuilt).uniq).to eq(nested_ids(rebuilt))
    expect(codec.encode(model, baseline:)).to eq(rebuilt)
  end

  def settings_with_servers(*names)
    servers = names.map { node('Settings$ServerConfiguration', 'Name' => _1) }
    configuration = node('Settings$ConfigurationSettings', 'Configurations' => collection(servers, 3))
    node('Settings$ProjectSettings', 'Settings' => collection([configuration], 2))
  end

  it 'canonicalizes Ruby property names before reading or encoding settings' do
    model = Mxrb::Settings::Node.new('Settings$ModelSettings')
    model.set(:java_major_version, '21')
    root = Mxrb::Settings::Node.new('Settings$ProjectSettings')
    root.set(:settings, Mxrb::Settings::Collection.new(items: [model], marker: 2))

    expect(model.fetch('JavaMajorVersion')).to eq('21')
    expect(model.fetch(:java_major_version)).to eq('21')
    expect(model.fields.keys).to eq(['JavaMajorVersion'])
    encoded = described_class.new.encode(root).fetch('Settings')[1]
    expect(encoded.fetch('JavaMajorVersion')).to eq('21')
    expect(encoded).not_to have_key('java_major_version')
  end

  it 'enforces documented setting enums and numeric ranges' do
    model = Mxrb::Settings::Node.new('Settings$ModelSettings')
    expect { model.set(:bcrypt_cost, 3) }.to raise_error(Mxrb::Settings::Error, /outside/)
    expect { model.set(:rounding_mode, 'Sideways') }.to raise_error(Mxrb::Settings::Error, /must be one of/)

    model.set(:bcrypt_cost, 12)
    model.set(:rounding_mode, 'HalfUp')
    expect(model.fetch(:bcrypt_cost)).to eq(12)
  end

  def complete_settings
    parts = [
      web_ui_settings, integration_settings, configuration_settings, model_settings,
      convention_settings, language_settings, certificate_settings, workflow_settings,
      node('Settings$JarDeploymentSettings', 'Exclusions' => collection(['obsolete.jar'], 2)),
      node('Settings$DistributionSettings',
           'BasedOnVersion' => '', 'IsDistributable' => false, 'Version' => ''),
      node('Settings$JavaActionsSettings', 'GeneratePostfixesForParameters' => true)
    ]
    node('Settings$ProjectSettings', 'Settings' => collection(parts, 2))
  end

  def web_ui_settings
    node('Forms$WebUIProjectSettingsPart',
         'EnableDownloadResources' => false, 'EnableMicroflowReachabilityAnalysis' => true,
         'EnableNewStringBehavior' => true, 'EnableNewWidgetGeneration' => true,
         'EnableRspackBundler' => false, 'EnableWidgetBundling' => true,
         'Theme' => '(Default)', 'ThemeModuleName' => 'UI_Resources',
         'ThemeModuleOrder' => collection([
                                            node('Settings$ThemeModuleEntry', 'ModuleName' => 'Atlas_Core')
                                          ], 3), 'UrlPrefix' => 'p', 'UseOptimizedClient' => 'Yes')
  end

  def integration_settings
    node('Settings$IntegrationProjectSettingsPart', 'ObsoleteEnableUrlEncoding' => false)
  end

  def configuration_settings
    node('Settings$ConfigurationSettings',
         'Configurations' => collection([server_configuration], 3))
  end

  def certificate_settings
    certificate = node('Settings$Certificate',
                       'Data' => BSON::Binary.new("certificate\x00data".b, :generic),
                       'Type' => 'Authority')
    node('Settings$CertificateSettings', 'Certificates' => collection([certificate], 3))
  end

  def workflow_settings
    node('Settings$WorkflowsProjectSettingsPart',
         'DefaultTaskParallelism' => 3, 'Groups' => collection([], 2),
         'OnWorkflowEvent' => collection([], 2), 'UserEntity' => 'System.User',
         'UsertaskOnStateChangeEvent' => nil, 'WorkflowEngineParallelism' => 5,
         'WorkflowOnStateChangeEvent' => nil)
  end

  def server_configuration
    custom_settings = [
      node('Settings$CustomSetting', 'Name' => 'sample.setting', 'Value' => 'enabled')
    ]
    node('Settings$ServerConfiguration',
         'ApplicationRootUrl' => 'http://localhost:8080/',
         'ConstantValues' => collection([], 3),
         'CustomSettings' => collection(custom_settings, 3),
         'DatabaseName' => 'default', 'DatabasePassword' => '',
         'DatabaseType' => 'Hsqldb', 'DatabaseUrl' => '',
         'DatabaseUseIntegratedSecurity' => false, 'DatabaseUserName' => '',
         'EmulateCloudSecurity' => true, 'ExtraJvmParameters' => '',
         'HttpPortNumber' => 8080, 'MaxJavaHeapSize' => 0, 'Name' => 'Default',
         'OpenAdminPort' => true, 'OpenHttpPort' => false,
         'OpenTelemetry' => node('Settings$OpenTelemetryConfiguration',
                                 'Enabled' => false, 'Endpoint' => 'http://localhost:4318',
                                 'Logs' => nil, 'ServiceName' => 'MendixApp', 'Traces' => nil),
         'ServerPortNumber' => 8090,
         'Tracing' => node('Settings$TracingConfiguration',
                           'Enabled' => false, 'Endpoint' => 'http://localhost:4318/v1/traces',
                           'ServiceName' => 'MendixApp'))
  end

  def model_settings
    node('Settings$ModelSettings',
         'AfterStartupMicroflow' => '', 'AllowUserMultipleSessions' => true,
         'BcryptCost' => 12, 'BeforeShutdownMicroflow' => '', 'DecimalScale' => 8,
         'DefaultTimeZoneCode' => '', 'EnableDataStorageNewQueryHandling' => false,
         'EnableDataStorageOptimisticLocking' => false,
         'EnforceDataStorageUniqueness' => true, 'FirstDayOfWeek' => 'Default',
         'HashAlgorithm' => 'BCrypt', 'HealthCheckMicroflow' => '',
         'JavaMajorVersion' => '21', 'JavaVersion' => 'Java21', 'RoundingMode' => 'HalfUp',
         'ScheduledEventTimeZoneCode' => 'Etc/UTC', 'SslCertificateAlgorithm' => 'PKIX',
         'UseDatabaseForeignKeyConstraints' => true,
         'UseDeprecatedClientForWebServiceCalls' => false, 'UseOQLVersion2' => true,
         'UseSystemContextForBackgroundTasks' => false)
  end

  def convention_settings
    node('Settings$ConventionSettings',
         'ActionActivityDefaultColors' => collection([
                                                       node('Settings$ActionActivityDefaultColor',
                                                            'ActionActivityType' => 'Microflows$MicroflowCallAction',
                                                            'BackgroundColor' => 'Blue')
                                                     ], 3), 'DefaultAssociationStorage' => 'Table',
         'DefaultSequenceFlowLineType' => 'BezierCurve',
         'LowerCaseMicroflowVariables' => false)
  end

  def language_settings
    language = node('Texts$Language',
                    'CheckCompleteness' => false, 'Code' => 'en_US',
                    'CustomDateFormat' => '', 'CustomDateTimeFormat' => '',
                    'CustomTimeFormat' => '', 'Description' => 'English',
                    'RightToLeft' => false)
    node('Settings$LanguageSettings', 'DefaultLanguageCode' => 'en_US',
                                      'Languages' => collection([language], 3))
  end

  def node(type, fields = {})
    { '$ID' => SecureRandom.uuid, '$Type' => type }.merge(fields)
  end

  def collection(items, marker)
    Mxrb::IO::BsonCodec.build_array(items, marker:)
  end

  def install_settings(path, document)
    mpr = Mxrb::IO::MprFile.open(path)
    unit = mpr.all_units.find { mpr.parse_contents(_1)['$Type'] == 'Settings$ProjectSettings' }
    mpr.update_unit(unit.fetch('UnitID'), document)
  ensure
    mpr&.close
  end

  def project_settings(path)
    Mxrb.open(path) do |project|
      unit = project.all_units.find do |candidate|
        project.parse_bson(candidate)['$Type'] == 'Settings$ProjectSettings'
      end
      [unit.slice('UnitID', 'ContainerID', 'ContainmentName'), project.parse_bson(unit)]
    end
  end

  def nested_ids(value, ids = [])
    case value
    when Hash
      ids << Mxrb::IO::BsonCodec.extract_id(value['$ID']).to_s if value['$ID']
      value.each_value { nested_ids(_1, ids) }
    when Array
      Mxrb::IO::BsonCodec.parse_array(value).fetch(:items).each { nested_ids(_1, ids) }
    end
    ids
  end

  def with_output(path)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = path
    yield
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
