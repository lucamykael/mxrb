# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Mxrb::RubyApp::KnownJavaScriptActions do
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
      expect(generated).to include("registerJavaScriptActions(feedbackStorageActions([\"#{name}\"]))")
      File.write(File.join(directory, "#{name}.js"), '// customized action')
      expect(described_class.matching(root)).to eq([])
    end
  end
end
