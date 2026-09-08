# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::StudioCompatibility do
  subject(:compatibility) { described_class.new('10.24.0.73019') }

  it 'provides the exact Studio Pro metamodel schema hash' do
    expect(described_class.new('9.6.1.29396').schema_hash).to eq(
      '{SHA256}eucGg8X+FuNNZefjgsxntSNkZtIlobdKepWWPXO2rEY='
    )
    expect(compatibility.schema_hash).to eq(
      '{SHA256}byCy5wQuf+bf8dMw0DjAfhv6C0uybmGxwdmtwuZDPkQ='
    )
    expect(described_class.new('11.12.1').schema_hash).to eq(
      '{SHA256}ex8TFkjI5tikVWCC05OxODFVHlheQtT9XpJxPAwVGY0='
    )
    expect(described_class.new('99.0.0').schema_hash).to eq('')
  end

  it 'projects newer Mendix 10 fields onto the exact Studio Pro build schema' do
    entity = {
      'IsRemote' => false, 'RemoteSource' => '', 'EventHandlers' => [3],
      'Indexes' => [3, { 'Attributes' => [3, { 'AssociationPointer' => 'id' }] }]
    }
    units = [
      unit('DomainModels$DomainModel', 'Entities' => [3, entity]),
      unit('Enumerations$Enumeration', 'Values' => [3, { 'ExportLevel' => 'Hidden' }]),
      unit('ImportMappings$ImportMapping', 'MessageDefinition2' => ''),
      unit('ExportMappings$ExportMapping', 'MessageDefinition2' => ''),
      unit('Microflows$Nanoflow', 'UseListParameterByReference' => true),
      unit('Rest$PublishedRestService', 'PublicDocumentation' => '')
    ]

    compatibility.apply!(units)

    entity = units[0].dig('doc', 'Entities', 1)
    expect(entity).not_to include('IsRemote', 'RemoteSource', 'EventHandlers')
    expect(entity.dig('Indexes', 1, 'Attributes', 1)).not_to include('AssociationPointer')
    expect(units[1].dig('doc', 'Values', 1)).not_to include('ExportLevel')
    expect(units.drop(2).map { _1.fetch('doc').keys }).to all(
      satisfy { |keys| (keys & %w[MessageDefinition2 UseListParameterByReference PublicDocumentation]).empty? }
    )
  end

  it 'projects modern project settings and module metadata onto Studio Pro 9.6.1' do
    settings = unit(
      'Settings$ProjectSettings',
      'Settings' => [2,
                     { '$Type' => 'Forms$WebUIProjectSettingsPart',
                       'EnableNewStringBehavior' => true, 'EnableRspackBundler' => true },
                     { '$Type' => 'Settings$ModelSettings',
                       'DecimalScale' => 8, 'JavaMajorVersion' => '21' },
                     { '$Type' => 'Settings$JarDeploymentSettings', 'Exclusions' => [2] },
                     { '$Type' => 'Settings$DistributionSettings', 'Version' => '' }]
    )
    module_impl = unit('Projects$ModuleImpl', 'AppStorePackageIdString' => '117187')

    described_class.new('9.6.1.29396').apply!([settings, module_impl])

    parts = settings.dig('doc', 'Settings').drop(1)
    expect(parts.map { _1['$Type'] }).not_to include(
      'Settings$JarDeploymentSettings', 'Settings$DistributionSettings'
    )
    expect(parts[0]).not_to include('EnableNewStringBehavior', 'EnableRspackBundler')
    expect(parts[1]).not_to include('DecimalScale', 'JavaMajorVersion')
    expect(module_impl.fetch('doc')).to include('AppStorePackageId' => 117_187)
    expect(module_impl.fetch('doc')).not_to include('AppStorePackageIdString')
  end

  it 'uses the target template as the authoritative one-time conversion set' do
    conversion = unit(
      'Projects$ProjectConversion',
      'OneTimeConversions' => [3,
                               { '$Type' => 'Projects$OneTimeConversion', 'Name' => 'PageUrlConversion' },
                               { '$Type' => 'Projects$OneTimeConversion', 'Name' => 'FutureConversion' }]
    )

    compatibility.apply!([conversion])

    names = conversion.dig('doc', 'OneTimeConversions').drop(1).map { _1.fetch('Name') }
    expect(names).to include('PageUrlConversion', 'CustomWidgetResetHiddenPropertiesConversion')
    expect(names).not_to include('FutureConversion')
    expect(names.size).to eq(104)
  end

  it 'projects embedded 10.24 model elements onto the Studio Pro 11.12.1 schema' do
    page = unit(
      'Forms$Page',
      'ExportLevel' => 'Public',
      'Children' => [3,
                     { '$Type' => 'CustomWidgets$WidgetValueType' },
                     { '$Type' => 'Forms$PageVariable' },
                     { '$Type' => 'Forms$PageParameter' },
                     { '$Type' => 'Forms$MicroflowSettings' },
                     { '$Type' => 'Forms$CallNanoflowClientAction' }]
    )

    described_class.new('11.12.1').apply!([page])

    document = page.fetch('doc')
    expect(document).to include('Autofocus' => 'Off', 'ExportLevel' => 'Hidden')
    widget_type, variable, parameter, microflow, nanoflow = document.fetch('Children').drop(1)
    expect(widget_type).to include('AllowUpload' => false)
    expect(variable).to include('SubKey' => '')
    expect(parameter).to include('DefaultValue' => '', 'IsRequired' => true)
    expect(microflow).to include(
      'Asynchronous' => false, 'FormValidations' => 'All',
      'OutputMappings' => [3], 'ParameterMappings' => [2], 'ProgressBar' => 'None'
    )
    expect(nanoflow).to include(
      'DisabledDuringExecution' => true, 'Nanoflow' => '',
      'OutputMappings' => [3], 'ParameterMappings' => [2], 'ProgressBar' => 'None'
    )
  end

  it 'projects modules, nanoflows, domain entities, and settings onto 11.12.1' do
    nodes = [
      unit('Projects$ModuleImpl', 'AppStorePackageId' => 12),
      unit('Projects$ModuleSettings'),
      unit('Microflows$Nanoflow', 'ApplyEntityAccess' => false),
      unit('DomainModels$EntityImpl', 'EventHandlers' => [3], 'IsRemote' => false, 'RemoteSource' => ''),
      unit('Settings$ModelSettings', 'JavaVersion' => 'Java11'),
      unit(
        'Settings$ServerConfiguration', 'Tracing' => {
          '$ID' => '99999999-9999-4999-8999-999999999999',
          '$Type' => 'Settings$TracingConfiguration',
          'Enabled' => false,
          'Endpoint' => 'http://localhost:4318/v1/traces',
          'ServiceName' => 'MendixApp'
        }
      ),
      unit('Settings$WorkflowsProjectSettingsPart',
           'UsertaskOnStateChangeEvent' => nil, 'WorkflowOnStateChangeEvent' => nil)
    ]

    described_class.new('11.12.1').apply!(nodes)

    expect(nodes[0].fetch('doc')).to include('AppStorePackageIdString' => '')
    expect(nodes[0].fetch('doc')).not_to include('AppStorePackageId')
    expect(nodes[1].fetch('doc')).to include(
      'Checksum' => '', 'ConvertedChecksum' => '', 'EnableDetailedTroubleshooting' => true,
      'ModuleDependencies' => nil, 'OriginalPackageId' => '', 'PackageId' => ''
    )
    expect(nodes[2].fetch('doc')).to include('UseListParameterByReference' => true)
    expect(nodes[2].fetch('doc')).not_to include('ApplyEntityAccess')
    expect(nodes[3].fetch('doc')).not_to include('EventHandlers', 'IsRemote', 'RemoteSource')
    expect(nodes[4].fetch('doc')).to include('DecimalScale' => 8, 'JavaMajorVersion' => '21')
    expect(nodes[4].fetch('doc')).not_to include('JavaVersion')
    expect(nodes[5].fetch('doc')).to include(
      'OpenTelemetry' => include(
        '$Type' => 'Settings$OpenTelemetryConfiguration',
        'Enabled' => false,
        'Endpoint' => 'http://localhost:4318',
        'Logs' => nil,
        'ServiceName' => 'MendixApp',
        'Traces' => nil
      )
    )
    expect(nodes[5].dig('doc', 'OpenTelemetry', '$ID')).not_to eq(
      '99999999-9999-4999-8999-999999999999'
    )
    expect(nodes[5].fetch('doc')).not_to include('Tracing')
    expect(nodes[6].fetch('doc')).to include('Groups' => [2])
    expect(nodes[6].fetch('doc')).not_to include(
      'UsertaskOnStateChangeEvent', 'WorkflowOnStateChangeEvent'
    )
  end

  it 'adds the project settings parts required by Studio Pro 11 builds' do
    settings = unit(
      'Settings$ProjectSettings',
      'Settings' => [2, { '$ID' => SecureRandom.uuid, '$Type' => 'Settings$ModelSettings' }]
    )

    described_class.new('11.12.1').apply!([settings])

    parts = settings.dig('doc', 'Settings').drop(1)
    expect(parts.find { _1['$Type'] == 'Settings$JarDeploymentSettings' }).to include(
      '$ID' => match(/\A[0-9a-f-]{36}\z/), 'Exclusions' => [2]
    )
    expect(parts.find { _1['$Type'] == 'Settings$DistributionSettings' }).to include(
      '$ID' => match(/\A[0-9a-f-]{36}\z/),
      'BasedOnVersion' => '', 'IsDistributable' => false, 'Version' => ''
    )
  end

  it 'merges the exact 11.12.1 system texts from the target template' do
    texts = unit('Texts$SystemTextCollection', 'SystemTexts' => [3])

    described_class.new('11.12.1').apply!([texts])

    items = texts.dig('doc', 'SystemTexts').drop(1)
    expect(items.size).to eq(120)
    expect(items.map { _1.fetch('InternalKey') }).to include(
      'mxui.sys.UI.background_synchronization_error',
      'mxui.sys.UI.concurrent_data_modification'
    )
  end

  it 'supports deferring projection until source-schema integrity checks finish' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'Deferred.mpr')
      Mxrb.define(path) { mendix_version '11.12.1' }
      mpr = Mxrb::IO::MprFile.open(path, apply_studio_compatibility: false)
      page_id = mpr.insert_unit(
        container_uuid: mpr.root_unit.fetch('UnitID'),
        containment_name: 'ProjectDocuments',
        contents_doc: { '$Type' => 'Forms$Page', 'ExportLevel' => 'Public' }
      )

      expect(mpr.parse_contents(mpr.unit(page_id))).not_to include('Autofocus')
      mpr.apply_studio_compatibility!
      expect(mpr.parse_contents(mpr.unit(page_id))).to include(
        'Autofocus' => 'Off', 'ExportLevel' => 'Hidden'
      )
    ensure
      mpr&.close
    end
  end

  it 'writes the Studio 11 v2 transaction marker and exact MPR filename sidecar' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'Compatible.mpr')
      manifest = File.join(directory, 'native_units.json')
      File.write(manifest, JSON.generate(
                             'format_version' => 'v2', 'source_filename' => 'Compatible.mpr',
                             'units' => []
                           ))

      Mxrb::Writer.new(
        path,
        version: '11.12.1', project_id: SecureRandom.uuid, modules: [],
        native_units_path: manifest, native_unit_overrides: []
      ).write!

      transaction = SQLite3::Database.open(path) do |database|
        database.get_first_value('SELECT LastTransactionID FROM _Transaction LIMIT 1')
      end
      expect(transaction).to match(/\A[0-9a-f-]{36}\z/)
      expect(File.binread(File.join(directory, 'mprcontents', 'mprname'))).to eq('Compatible.mpr')
    end
  end

  it 'upgrades physical storage to Studio Pro 11 and rejects lossy downgrade before rewriting' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'StorageMigration.mpr')
      Mxrb.define(path) do
        mendix_version '9.6.1.29396'
        self.module(:App) { entity(:Entry) { string :Title } }
      end

      Mxrb.open(path, readonly: false) { _1.migrate_to!('11.12.1') }
      upgraded = Mxrb::IO::MprFile.open(path)
      expect(upgraded.format_version).to eq(:v2)
      expect(upgraded.content_files.size).to eq(upgraded.all_units.size)
      expect(upgraded.all_units).to all(satisfy { _1['Contents'].nil? })
      expect(File.binread(File.join(directory, 'mprcontents', 'mprname'))).to eq(
        'StorageMigration.mpr'
      )
      upgraded.close

      before_mpr = File.binread(path)
      before_contents = Dir[File.join(directory, 'mprcontents', '**', '*')]
                        .select { File.file?(_1) }.to_h { [_1, File.binread(_1)] }
      expect do
        Mxrb.open(path, readonly: false) { _1.migrate_to!('9.6.1.29396') }
      end.to raise_error(Mxrb::UnsupportedVersion, /would remove.*semantic equivalence is not established/)
      expect(File.binread(path)).to eq(before_mpr)
      after_contents = Dir[File.join(directory, 'mprcontents', '**', '*')]
                       .select { File.file?(_1) }.to_h { [_1, File.binread(_1)] }
      expect(after_contents).to eq(before_contents)
    ensure
      upgraded&.close
    end
  end

  it 'uses Studio 11 BSON widths for model integers while retaining int32 array markers' do
    document = {
      '$Type' => 'Vendor$Document',
      'Count' => 7,
      'Children' => [3, { '$Type' => 'Vendor$Child', 'Count' => 8 }]
    }

    bytes = Mxrb::IO::BsonCodec.serialize(document, int64_properties: true)
    buffer = BSON::ByteBuffer.new(bytes)
    decoded = BSON::Document.from_bson(buffer, mode: :bson).to_h

    expect(decoded.fetch('Count')).to be_a(BSON::Int64)
    expect(decoded.fetch('Count').value).to eq(7)
    expect(decoded.dig('Children', 0)).to eq(3)
    expect(decoded.dig('Children', 1, 'Count')).to be_a(BSON::Int64)
    expect(decoded.dig('Children', 1, 'Count').value).to eq(8)
  end

  it 'uses the target BSON schema while upgrading an existing project' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'Upgrade.mpr')
      Mxrb.define(path) do
        mendix_version '10.24.0.73019'
        self.module(:App) { page(:Home) }
      end
      source = Mxrb::IO::MprFile.open(path)
      source.insert_unit(
        container_uuid: source.root_unit.fetch('UnitID'),
        containment_name: 'ProjectDocuments',
        contents_doc: { '$Type' => 'Vendor$Document', 'Count' => 7 }
      )
      source.close

      Mxrb.open(path, readonly: false) { _1.migrate_to!('11.12.1') }
      mpr = Mxrb::IO::MprFile.open(path)
      raw = mpr.all_units.find do |unit|
        Mxrb::IO::BsonCodec.parse(mpr.content_bytes(unit))['$Type'] == 'Vendor$Document'
      end
      buffer = BSON::ByteBuffer.new(mpr.content_bytes(raw))
      document = BSON::Document.from_bson(buffer, mode: :bson).to_h

      expect(mpr.mendix_version).to eq('11.12.1')
      expect(document.fetch('Count')).to be_a(BSON::Int64)
    ensure
      mpr&.close
    end
  end

  def unit(type, fields = {})
    { 'doc' => { '$ID' => '10000000-0000-0000-0000-000000000001', '$Type' => type }.merge(fields) }
  end
end
# rubocop:enable Metrics/BlockLength
