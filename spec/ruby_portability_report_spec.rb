# frozen_string_literal: true

require 'open3'
require 'tmpdir'
require 'spec_helper'

RSpec.describe Mxrb::RubyApp::PortabilityReport do # rubocop:disable Metrics/BlockLength
  def write_app(root, coverage:, source: '') # rubocop:disable Metrics/MethodLength
    FileUtils.mkdir_p(File.join(root, '.mxrb'))
    FileUtils.mkdir_p(File.join(root, 'app', 'services'))
    File.write(File.join(root, 'app', 'services', 'artifacts.rb'), source)
    File.write(
      File.join(root, '.mxrb', 'ruby-app.json'),
      JSON.generate(
        format_version: 1, mode: 'ruby', project: { name: 'Audit' }, modules: [],
        coverage:, frontend: { application_owned: ['frontend/src/features'] },
        source: { name: 'Audit.mpr' },
        round_trip: { mendix_project: 'mendix/project.rb' }
      )
    )
  end

  it 'separates native, preserved, and runtime-only artifacts' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir('mxrb-portability-') do |root| # rubocop:disable Metrics/BlockLength
      source = <<~RUBY
        class NativePage < Mxrb::RubyApp::Page
          mendix_name 'App.NativePage'
          native { title 'Native' }
        end

        class RuntimeFlow < Mxrb::RubyApp::Service
          mendix_name 'App.RuntimeFlow'
        end
      RUBY
      coverage = [
        { id: '1', name: 'App.Customer', kind: 'model', ruby_path: 'app/models/customer.rb',
          status: 'executable_bidirectional' },
        { id: '2', name: 'App.NativePage', kind: 'page', ruby_path: 'app/pages/native.rb',
          status: 'native_projection_source_preserved' },
        { id: '3', name: 'App.RuntimeFlow', kind: 'microflow', ruby_path: 'app/services/runtime.rb',
          status: 'runtime_source_preserved' },
        { id: '4', name: 'Settings', kind: 'Settings$ProjectSettings', ruby_path: 'mendix',
          status: 'preserved_native' },
        { id: '5', name: 'SystemTexts', kind: 'Texts$SystemTextCollection', ruby_path: 'mendix',
          status: 'mendix_dsl_bidirectional' }
      ]
      write_app(root, coverage:, source:)
      FileUtils.mkdir_p(File.join(root, 'frontend', 'src', 'features'))
      File.write(File.join(root, 'frontend', 'src', 'features', 'dashboard.tsx'), 'export {};')

      report = described_class.new(root)

      expect(report).not_to be_native
      expect(report.summary).to eq('native' => 3, 'runtime_only' => 2, 'preserved_native' => 1)
      expect(report.entries.find { _1.name == 'App.NativePage' }.status).to eq('native')
      expect(report.entries.find { _1.name == 'App.RuntimeFlow' }.status).to eq('runtime_only')
      expect(report.to_h).to include(root: root, native: false, summary: report.summary)
    end
  end

  it 'provides a machine-readable CLI gate for Mendix-native portability' do
    Dir.mktmpdir('mxrb-portability-cli-') do |root|
      coverage = [{ id: '1', name: 'App.Customer', kind: 'model', ruby_path: 'app/models/customer.rb',
                    status: 'executable_bidirectional' }]
      write_app(root, coverage:)
      command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'portability', root,
                 '--json', '--require-native']

      stdout, stderr, status = Open3.capture3(*command)

      expect(status).to be_success
      expect(stderr).to be_empty
      expect(JSON.parse(stdout)).to include('native' => true)
    end
  end

  it 'uses unit ids to distinguish services with the same Mendix name' do
    Dir.mktmpdir('mxrb-portability-duplicate-services-') do |root|
      source = <<~RUBY
        class NativeDuplicate < Mxrb::RubyApp::Service
          mendix_name 'App.Duplicate', id: 'native-id'
          native(:microflow) { return_type :boolean }
        end

        class RuntimeDuplicate < Mxrb::RubyApp::Service
          mendix_name 'App.Duplicate', id: 'runtime-id'
        end
      RUBY
      coverage = [
        { id: 'native-id', name: 'App.Duplicate', kind: 'microflow',
          ruby_path: 'app/services/native_duplicate.rb', status: 'runtime_source_preserved' },
        { id: 'runtime-id', name: 'App.Duplicate', kind: 'microflow',
          ruby_path: 'app/services/runtime_duplicate.rb', status: 'runtime_source_preserved' }
      ]
      write_app(root, coverage:, source:)

      report = described_class.new(root)

      expect(report.entries.map { [_1.id, _1.status] }).to eq(
        [%w[native-id native], %w[runtime-id runtime_only]]
      )
      expect(report.to_h.fetch(:entries).map { _1.fetch(:id) })
        .to eq(%w[native-id runtime-id])
    end
  end

  it 'omits the frontend entry when the application-owned roots are empty' do
    Dir.mktmpdir('mxrb-portability-no-frontend-') do |root|
      write_app(root, coverage: [])

      expect(described_class.new(root).entries).to be_empty
    end
  end

  it 'audits exported homonymous flows using their private identities and metadata' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir('mxrb-portability-private-identities-') do |directory| # rubocop:disable Metrics/BlockLength
      source = File.join(directory, 'Source.mpr')
      Mxrb.define(source) do
        mendix_version '10.18.0'
        self.module(:App) do
          microflow(:Shared) do
            return_type :string
            return_value "'native'"
          end
          nanoflow(:Shared) do
            return_type :integer
            return_value '42'
          end
        end
      end
      root = File.join(directory, 'ruby-app')
      Mxrb::Exporter.new(source, root, mode: :ruby).export!
      services = Dir.glob(File.join(root, 'app', 'services', '**', '*.rb'))
      expect(services.size).to eq(2)
      services.each { expect(File.read(_1)).not_to match(/mendix_name[^\n]*\bid:/) }

      report = described_class.new(root)
      flows = report.entries.select { _1.name == 'App.Shared' }
      expect(flows.map(&:kind)).to contain_exactly('microflow', 'nanoflow')
      expect(flows.map(&:status)).to eq(%w[native native])
      expect(flows.map(&:id).uniq.size).to eq(2)
      expect(Mxrb::RubyApp::Registry.all(:service)).to be_empty

      metadata = File.join(root, '.mxrb', 'semantic_metadata.json')
      File.delete(metadata)
      File.delete(File.join(root, '.mxrb', 'mendix', '.mxrb', 'semantic_metadata.json'))
      expect { described_class.new(root) }
        .to raise_error(Mxrb::ValidationError, /requires its semantic metadata baseline/)
      expect(Mxrb::RubyApp::Registry.all(:service)).to be_empty
    end
  end

  it 'loads application environment only within the audit and restores it after errors' do
    Dir.mktmpdir('mxrb-portability-environment-') do |root|
      source = <<~RUBY
        raise 'missing audit environment' unless ENV.fetch('MXRB_PORTABILITY_SPEC_VALUE') == 'local'
        class EnvironmentFlow < Mxrb::RubyApp::Service
          mendix_name 'App.EnvironmentFlow'
          native(:microflow) { return_type :boolean }
        end
      RUBY
      coverage = [{ name: 'App.EnvironmentFlow', kind: 'microflow',
                    ruby_path: 'app/services/artifacts.rb', status: 'runtime_source_preserved' }]
      write_app(root, coverage:, source:)
      File.write(File.join(root, '.env'), "MXRB_PORTABILITY_SPEC_VALUE=local\n")

      expect { described_class.new(root) }.not_to(change { ENV['MXRB_PORTABILITY_SPEC_VALUE'] })
      File.write(File.join(root, 'app', 'services', 'artifacts.rb'), "#{source}\nraise 'audit stopped'\n")
      expect { described_class.new(root) }.to raise_error(RuntimeError, 'audit stopped')
      expect(ENV).not_to have_key('MXRB_PORTABILITY_SPEC_VALUE')
      expect(Mxrb::RubyApp::Registry.all(:service)).to be_empty
      expect(Thread.current[Mxrb::RubyApp::SourceIdentity::THREAD_KEY]).to be_nil
      expect(Thread.current[Mxrb::RubyApp::FlowMetadata::THREAD_KEY]).to be_nil
    end
  end
end
