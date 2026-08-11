# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'sqlite3'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'round-trip demand regressions' do
  def rebuild_export(exported, target)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = target
    load File.join(exported, 'project.rb')
  ensure
    if previous
      ENV['MXRB_OUTPUT_PATH'] = previous
    else
      ENV.delete('MXRB_OUTPUT_PATH')
    end
  end

  it 'accepts gallery projections inside exported nested containers' do
    page = Mxrb::Dsl::PageBuilder.new(:Dashboard)
    page.instance_eval do
      container :Chart do
        gallery :Recent, entity: 'Sales.Order'
      end
    end

    gallery = page.to_h.fetch(:widgets).first.fetch(:children).first
    expect(gallery).to include(type: :gallery, name: 'Recent')
    expect(gallery.dig(:options, :entity)).to eq('Sales.Order')
  end

  it 'preserves qualified page data sources and infers public native targets' do
    Dir.mktmpdir do |dir|
      original = File.join(dir, 'cross-module.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')

      Mxrb.define(original) do
        mendix_version '10.18.0'
        self.module(:Core) { microflow(:LoadCurrentAccount, public: true) }
        self.module(:Portal) do
          page(:Dashboard) do
            data_source microflow: 'Core.LoadCurrentAccount'
          end
        end
      end
      SQLite3::Database.open(original) { _1.execute('DROP TABLE _MxrbArchitecture') }

      Mxrb::Exporter.new(original, exported).export!
      page_source = Dir[File.join(exported, 'modules', 'Portal', '**', '*.rb')]
                    .map { File.read(_1) }.find { _1.include?('page :Dashboard') }
      flow_source = Dir[File.join(exported, 'modules', 'Core', '**', '*.rb')]
                    .map { File.read(_1) }.find { _1.include?('microflow :LoadCurrentAccount') }

      expect(page_source).to include(
        'data_source microflow: "Core.LoadCurrentAccount"'
      )
      expect(flow_source).to include(
        'microflow :LoadCurrentAccount, public: true'
      )

      rebuild_export(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
    end
  end

  it 'warns for an exact preserved legacy identity mismatch but rejects a new one' do
    Dir.mktmpdir do |dir|
      original = File.join(dir, 'legacy.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      legacy_content_id = SecureRandom.uuid

      Mxrb.define(original) do
        mendix_version '10.18.0'
        self.module(:Legacy) do
          microflow(:Preserved)
          microflow(:Healthy)
        end
      end

      legacy_unit_id = nil
      Mxrb.open(original, readonly: false) do |project|
        flow = project.microflows.find { _1.name == 'Preserved' }
        legacy_unit_id = flow.id
        document = project.parse_bson(project.raw_unit(flow.id))
        document['$ID'] = legacy_content_id
        project.mpr.update_unit(flow.id, document)
      end
      expect(Mxrb.validate(original).errors).to include(
        "unit #{legacy_unit_id} content $ID mismatch #{legacy_content_id}"
      )

      Mxrb::Exporter.new(original, exported).export!
      rebuild_export(exported, rebuilt)

      preserved = Mxrb.validate(rebuilt)
      expect(preserved).to be_valid
      expect(preserved.warnings).to include(
        "unit #{legacy_unit_id} preserves legacy content $ID mismatch #{legacy_content_id}"
      )

      Mxrb.open(rebuilt, readonly: false) do |project|
        healthy = project.microflows.find { _1.name == 'Healthy' }
        document = project.parse_bson(project.raw_unit(healthy.id))
        document['$ID'] = SecureRandom.uuid
        project.mpr.update_unit(healthy.id, document)
      end
      regressed = Mxrb.validate(rebuilt)
      expect(regressed).not_to be_valid
      expect(regressed.errors).to include(a_string_matching(/content \$ID mismatch/))
      expect(regressed.warnings).to include(a_string_matching(/preserves legacy content \$ID mismatch/))
    end
  end

  it 'does not announce generate success when the resulting MPR is invalid' do
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'invalid.mpr')
      definition = File.join(dir, 'project.rb')
      File.write(definition, <<~RUBY)
        Mxrb.define(#{target.inspect}) do
          mendix_version '10.18.0'
          self.module(:M) { microflow(:Broken) }
        end
        Mxrb.open(#{target.inspect}, readonly: false) do |project|
          flow = project.microflows.first
          document = project.parse_bson(project.raw_unit(flow.id))
          document['$ID'] = SecureRandom.uuid
          project.mpr.update_unit(flow.id, document)
        end
      RUBY

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__),
        'generate', definition
      )

      expect(status).not_to be_success
      expect(stderr).to include('content $ID mismatch', 'Generated MPR failed validation')
      expect(stdout).not_to include('[mxrb] Generated')
    end
  end
end
# rubocop:enable Metrics/BlockLength
