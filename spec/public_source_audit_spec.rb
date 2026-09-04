# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::PublicSourceAudit do
  it 'classifies public opacity without treating keyword arguments as hashes' do
    Dir.mktmpdir('mxrb-public-source-audit-') do |root|
      FileUtils.mkdir_p(File.join(root, 'modules', 'Sales', 'presentation'))
      FileUtils.mkdir_p(File.join(root, '.mxrb'))
      File.write(
        File.join(root, 'project.rb'),
        <<~RUBY
          configure(enabled: true)
          native_fragments File.join(__dir__, ".mxrb", "native_fragments")
        RUBY
      )
      File.write(
        File.join(root, 'modules', 'Sales', 'presentation', 'orders.rb'),
        <<~RUBY
          page :Orders, unit_id: "81d4e56a-7e5e-4a8c-9042-78a42a6df249" do
            native_widget({"$Type" => "Forms$TextBox", :fields => {}})
          end
        RUBY
      )
      File.write(File.join(root, '.mxrb', 'native_units.rb'), 'native_unit "hidden"')

      report = described_class.new(root)

      expect(report).not_to be_clean
      expect(report.to_h).to include(files: 2, total: report.violations.size)
      expect(report.summary).to include(
        hash_literal: 2, hash_rocket: 2, opaque_api: 2,
        sidecar_reference: 1, storage_schema: 2, unit_identity: 1, uuid: 1
      )
      expect(report.by_subsystem.keys).to contain_exactly('modules/presentation', 'project')
      expect(report.violations).not_to include(have_attributes(path: '.mxrb/native_units.rb'))
    end
  end

  it 'can include the internal sidecar in a diagnostic audit' do
    Dir.mktmpdir('mxrb-public-source-internal-audit-') do |root|
      FileUtils.mkdir_p(File.join(root, '.mxrb'))
      File.write(File.join(root, '.mxrb', 'native_units.rb'), 'native_unit "hidden"')

      report = described_class.new(root, include_internal: true)

      expect(report.to_h).to include(files: 1, total: 1)
      expect(report.by_subsystem).to eq('internal_sidecar' => { opaque_api: 1 })
    end
  end

  it 'reports invalid generated Ruby as a distinct violation' do
    Dir.mktmpdir('mxrb-public-source-syntax-audit-') do |root|
      File.write(File.join(root, 'project.rb'), 'broken {')

      report = described_class.new(root)

      expect(report.summary).to eq(syntax_error: 1)
    end
  end

  it 'keeps project-security identities in the MPR baseline, not its public Ruby API' do
    Dir.mktmpdir('mxrb-public-security-identity-') do |root|
      source = File.join(root, 'Security.mpr')
      exported = File.join(root, 'ruby')
      rebuilt = File.join(root, 'Rebuilt.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:App) { module_role :User }
        security do
          user_role :User, module_roles: ['App.User']
          demo_user 'developer', entity: 'System.User', roles: ['User'], password: 'local-test'
          password_policy minimum_length: 12, require_digit: true
        end
      end
      original = project_security(source)

      Mxrb::Exporter.new(source, exported).export!
      public_security = File.read(File.join(exported, 'app', 'security', 'security.rb'))
      security_violations = described_class.new(exported).violations.select do |entry|
        entry.subsystem == 'app/security'
      end
      expect(public_security).to include('password_policy(minimum_length: 12, require_digit: true,')
      expect(public_security).not_to match(described_class::UUID)
      expect(security_violations).to be_empty

      with_output(rebuilt) { load File.join(exported, 'project.rb') }

      expect(project_security(rebuilt)).to eq(original)
    end
  end

  def project_security(path)
    Mxrb.open(path) do |project|
      unit = project.all_units.find do |candidate|
        project.parse_bson(candidate)['$Type'] == 'Security$ProjectSecurity'
      end
      [unit.fetch('UnitID'), project.parse_bson(unit)]
    end
  end

  def with_output(path)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = path
    yield
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end
end
# rubocop:enable Metrics/BlockLength
