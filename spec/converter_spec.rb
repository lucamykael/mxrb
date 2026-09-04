# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Converter do
  it 'exports editable Ruby and materializes an integrity-valid MPR for the requested Studio version' do
    Dir.mktmpdir('mxrb-convert-') do |dir|
      source = File.join(dir, 'Sales.mpr')
      ruby_root = File.join(dir, 'sales-ruby')
      Mxrb.define(source) do
        mendix_version '10.18.0'
        self.module :Sales do
          entity :Order do
            string :Number
          end
          dataset :Orders do
            oql 'SELECT O.Number FROM Sales.Order O'
          end
        end
      end

      result = described_class.new(
        source, ruby_root, studio_version: '10.19.0'
      ).convert!

      expect(result).to have_attributes(
        source_version: '10.18.0', studio_version: '10.19.0', generated_version: '10.19.0'
      )
      expect(result.ruby_root).to eq(ruby_root)
      expect(result.mpr).to eq(File.join(ruby_root, 'build', 'Sales.mpr'))
      expect(result.ruby_artifacts).to be_positive
      expect(result.generated_units).to be >= result.source_units
      expect(result.source_sha256).to match(/\A[0-9a-f]{64}\z/)
      expect(result.generated_sha256).to match(/\A[0-9a-f]{64}\z/)
      expect(Mxrb.validate(result.mpr)).to be_valid
      expect(File.read(File.join(ruby_root, 'project.rb'))).to include('10.19.0')
      Mxrb.open(result.mpr) do |project|
        datasets = project.all_units.filter_map do |unit|
          document = project.parse_bson(unit)
          [unit, document] if document['$Type'] == 'DataSets$DataSet'
        end
        expect(datasets.size).to eq(1)
        unit, document = datasets.first
        expect(Mxrb::IO::BsonCodec.extract_id(document['$ID'])).to eq(unit.fetch('UnitID'))
      end
    end
  end

  it 'accepts a build-qualified Mendix 10 Studio Pro version' do
    Dir.mktmpdir('mxrb-convert-build-version-') do |dir|
      source = File.join(dir, 'Source.mpr')
      Mxrb.define(source) { mendix_version '10.24.18.103793' }

      result = described_class.new(
        source, File.join(dir, 'ruby'), studio_version: '10.24.0.73019'
      ).convert!

      expect(result.generated_version).to eq('10.24.0.73019')
      Mxrb.open(result.mpr) do |project|
        expect(project.mendix_version).to eq('10.24.0.73019')
      end
    end
  end

  it 'rejects ambiguous versions and unknown presets before exporting' do
    expect do
      described_class.new('/missing.mpr', '/tmp/output', studio_version: '11.12').convert!
    end.to raise_error(ArgumentError, /MPR not found/)

    Dir.mktmpdir('mxrb-convert-options-') do |dir|
      source = File.join(dir, 'empty.mpr')
      File.write(source, '')
      expect do
        described_class.new(source, File.join(dir, 'out'), studio_version: '11.12', stack: :unknown).convert!
      end.to raise_error(ArgumentError, /Studio Pro version/)
    end
  end

  it 'replays exported project settings while changing the Studio version' do
    Dir.mktmpdir('mxrb-convert-settings-') do |dir|
      source = File.join(dir, 'SettingsApp.mpr')
      project_id = '20000000-0000-0000-0000-000000000001'
      settings_id = '20000000-0000-0000-0000-000000000002'
      model_settings_id = '20000000-0000-0000-0000-000000000003'
      Mxrb.define(source) do
        mendix_version '10.18.0'
        mendix_project_id project_id
        project_settings_document(
          unit_id: settings_id, container_id: project_id,
          settings: {
            collection: [{
              node_type: 'Settings$ModelSettings', id: model_settings_id,
              fields: { 'JavaVersion' => 'Java17' }
            }],
            marker: 2
          }
        )
      end

      result = described_class.new(
        source, File.join(dir, 'ruby'), studio_version: '10.19.0'
      ).convert!

      Mxrb.open(result.mpr) do |project|
        settings = project.all_units.map { project.parse_bson(_1) }
                          .find { _1['$Type'] == 'Settings$ProjectSettings' }
        model = settings.fetch('Settings').drop(1)
                        .find { _1['$Type'] == 'Settings$ModelSettings' }
        expect(model.fetch('JavaVersion')).to eq('Java17')
      end
    end
  end

  it 'converts the audited Mendix 9.6.1 to 11.12.1 route' do
    Dir.mktmpdir('mxrb-convert-cross-major-') do |dir|
      source = File.join(dir, 'Source.mpr')
      Mxrb.define(source) do
        mendix_version '9.6.1.29396'
        self.module(:App) { entity(:Entry) { string :Title } }
      end

      upgraded = described_class.new(
        source, File.join(dir, 'up-ruby'), studio_version: '11.12.1'
      ).convert!
      upgraded_mpr = Mxrb::IO::MprFile.open(upgraded.mpr, readonly: true)
      expect(upgraded).to have_attributes(
        source_version: '9.6.1.29396', generated_version: '11.12.1',
        source_units: upgraded.generated_units
      )
      expect(upgraded_mpr.format_version).to eq(:v2)
    ensure
      upgraded_mpr&.close
    end
  end

  it 'rejects the pending 11.12.1 to 9.6.1 route without leaving partial output' do
    Dir.mktmpdir('mxrb-convert-pending-downgrade-') do |dir|
      source = File.join(dir, 'Source.mpr')
      ruby_root = File.join(dir, 'ruby')
      output = File.join(dir, 'build', 'Downgraded.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:App) { page(:Home) }
      end

      expect do
        described_class.new(
          source, ruby_root, studio_version: '9.6.1.29396', output:
        ).convert!
      end.to raise_error(
        Mxrb::UnsupportedVersion,
        /11\.12\.1.*9\.6\.1\.29396.*available routes: 9\.6\.1\.29396 -> 11\.12\.1/m
      )
      expect(File).not_to exist(ruby_root)
      expect(File).not_to exist(output)
    end
  end

  it 'fails before export when a cross-major metamodel route was not audited' do
    Dir.mktmpdir('mxrb-convert-unsupported-route-') do |dir|
      source = File.join(dir, 'Source.mpr')
      ruby_root = File.join(dir, 'ruby')
      Mxrb.define(source) { mendix_version '9.24.0' }

      expect do
        described_class.new(source, ruby_root, studio_version: '11.12.1').convert!
      end.to raise_error(
        Mxrb::UnsupportedVersion,
        /9\.24\.0.*11\.12\.1.*available routes: 9\.6\.1\.29396 -> 11\.12\.1/m
      )
      expect(File).not_to exist(ruby_root)
    end
  end
end
# rubocop:enable Metrics/BlockLength
