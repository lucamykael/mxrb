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
          status: 'preserved_native' }
      ]
      write_app(root, coverage:, source:)
      FileUtils.mkdir_p(File.join(root, 'frontend', 'src', 'features'))
      File.write(File.join(root, 'frontend', 'src', 'features', 'dashboard.tsx'), 'export {};')

      report = described_class.new(root)

      expect(report).not_to be_native
      expect(report.summary).to eq('native' => 2, 'runtime_only' => 2, 'preserved_native' => 1)
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

  it 'omits the frontend entry when the application-owned roots are empty' do
    Dir.mktmpdir('mxrb-portability-no-frontend-') do |root|
      write_app(root, coverage: [])

      expect(described_class.new(root).entries).to be_empty
    end
  end
end
