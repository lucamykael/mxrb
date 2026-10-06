# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Standalone Ruby runtime' do
  it 'executes edited flow sources and persists records without opening an MPR' do
    Dir.mktmpdir('mxrb-standalone-') do |directory|
      source = File.join(directory, 'Standalone.mpr')
      target = File.join(directory, 'app')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module :Standalone do
          entity(:Item) { string :Name }
          microflow(:Answer) do
            return_type :String
            return_value "'Original'"
          end
          microflow(:Nested) do
            return_type :String
            call_microflow 'Standalone.Answer', as: :answer
            return_value '$answer'
          end
          page(:Home) { text 'message', caption: 'Editable' }
        end
      end
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      flow_path = File.join(target, 'app', 'services', 'standalone', 'answer.rb')
      File.write(flow_path, File.read(flow_path).sub('Original', 'Edited Ruby'))
      manifest = Mxrb::RubyApp::Manifest.load(target)
      FileUtils.mv(manifest.absolute_path('runtime_mpr'), File.join(directory, 'detached.mpr'))
      allow(Mxrb::Model::Project).to receive(:open).and_raise('Runtime attempted to open an MPR')
      application = Mxrb::RubyApp::Application.new(target)
      expect(application.call_service('Standalone.Answer')).to eq('Edited Ruby')
      expect(application.call_service('Standalone.Nested')).to eq('Edited Ruby')
      record = application.create_record('Standalone.Item', { 'Name' => 'Persisted' })
      layout = application.page('Standalone.Home').fetch(:widgets).first
      expect(layout.dig('options', 'class')).to include('mxrb-application-shell')
      expect(layout.fetch('children').first.fetch('type')).to eq('scroll_container')
      expect(JSON.generate(application.page('Standalone.Home'))).to include('Editable')
      application.close
      application = Mxrb::RubyApp::Application.new(target)
      expect(application.record('Standalone.Item', record.fetch(:id)).fetch(:attributes))
        .to include('Name' => 'Persisted')
      implementation = Mxrb::RubyApp::Registry.fetch(:service, 'Standalone.Answer')
      implementation.send(:remove_method, :call)
      implementation.define_method(:call) { 'Ordinary Ruby override' }
      expect(application.call_service('Standalone.Nested')).to eq('Ordinary Ruby override')
    ensure
      application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end
end
# rubocop:enable Metrics/BlockLength
