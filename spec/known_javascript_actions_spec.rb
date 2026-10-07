# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::KnownJavaScriptActions do
  it 'keeps Commons and Feedback namespaces separate during registration' do
    Dir.mktmpdir do |root|
      directory = File.join(root, 'javascriptsource', 'nanoflowcommons', 'actions')
      FileUtils.mkdir_p(directory)
      source = '// verified commons fixture'
      digest = Digest::SHA256.hexdigest(source)
      stub_const('Mxrb::RubyApp::KnownJavaScriptActions::COMMONS_SOURCES', 'GetPlatform' => digest)
      File.write(File.join(directory, 'GetPlatform.js'), source)
      expect(described_class.matching(root)).to eq([])
      expect(described_class.matching(root, sources: described_class::COMMONS_SOURCES,
                                            module_name: 'nanoflowcommons')).to eq(['GetPlatform'])
      project = File.join(root, 'App.mpr')
      Mxrb.define(project) { self.module(:App) { entity(:Item) { string :Name } } }
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(project, target, mode: :ruby).export!
      generated = File.read(File.join(target, 'frontend', 'src', 'generated', 'nanoflows.ts'))
      expect(generated).to include('...nanoflowCommonsActions(["GetPlatform"])', '...feedbackStorageActions([])')
      expect(generated.scan('registerJavaScriptActions({').length).to eq(1)
    end
  end

  it 'emits only source-verified registrations and normalizes Windows newlines' do
    Dir.mktmpdir do |root|
      directory = File.join(root, 'javascriptsource', 'feedbackmodule', 'actions')
      FileUtils.mkdir_p(directory)
      source = "// fixture\n"
      name = 'JS_SetSingleLocalStorageObjectItem'
      stub_const('Mxrb::RubyApp::KnownJavaScriptActions::SOURCES', name => Digest::SHA256.hexdigest(source))
      expect(described_class.matching(root)).to eq([])
      File.binwrite(File.join(directory, "#{name}.js"), source.gsub("\n", "\r\n"))
      expect(described_class.matching(root)).to eq([name])
      project = File.join(root, 'App.mpr')
      Mxrb.define(project) { self.module(:App) { entity(:Item) { string :Name } } }
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(project, target, mode: :ruby).export!
      generated = File.read(File.join(target, 'frontend', 'src', 'generated', 'nanoflows.ts'))
      expect(generated).to include("...feedbackStorageActions([\"#{name}\"])")
      File.write(File.join(directory, "#{name}.js"), '// customized action')
      expect(described_class.matching(root)).to eq([])
    end
  end
end
# rubocop:enable Metrics/BlockLength
