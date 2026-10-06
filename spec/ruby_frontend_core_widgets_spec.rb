# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Ruby frontend core widget source' do # rubocop:disable Metrics/BlockLength
  before { Mxrb::RubyApp::Registry.reset! }
  after { Mxrb::RubyApp::Registry.reset! }

  it 'serves edited titles, tab captions and enumeration choices directly from public Ruby' do # rubocop:disable Metrics/BlockLength
    Dir.mktmpdir('mxrb-core-widgets-') do |root| # rubocop:disable Metrics/BlockLength
      source = File.join(root, 'Source.mpr')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(source)
      load File.expand_path('fixtures/ruby_frontend_core_widgets/project.rb', __dir__)
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      path = File.join(target, 'app', 'pages', 'core', 'home_page.rb')
      code = File.read(path)
      expect(code).to include('page_title', 'tab_control', 'radio_button_group')
      expect(Mxrb::PublicSourceAudit.new(target)).to be_clean
      File.write(path,
                 code.sub('Ruby core widgets', 'Edited page title').sub('caption: "Progress"', 'caption: "Edited tab"'))
      enumeration_path = File.join(target, 'app', 'enumerations', 'core', 'status.rb')
      File.write(enumeration_path, File.read(enumeration_path).sub('"Completed"', '"Finished in Ruby"'))
      application = Mxrb::RubyApp::Application.new(target)
      page = application.page('Core.Home')
      expect(page.fetch(:title)).to eq('Edited page title')
      layout = page.fetch(:widgets).first
      expect(layout.dig('options', 'class')).to include('mxrb-application-shell')
      content = layout.fetch('children').first.dig('regions', 'center')
      tabs = content.first.fetch('body').find { _1['type'] == 'tab_control' }.dig('options', 'tabs')
      expect(tabs.last.fetch('caption')).to eq('Edited tab')
      expect(tabs.last.fetch('widgets').first).to include('type' => 'radio_button_group')
      enumeration = application.schema.fetch(:modules).first.fetch('enumerations').first
      expect(enumeration.fetch('values').last.fetch('caption')).to eq('Finished in Ruby')
      # The original exported manifest remains untouched; it is not the runtime authority.
      expect(application.manifest.modules.first.fetch('enumerations').first.fetch('values').last.fetch('caption'))
        .to eq('Completed')
    ensure
      application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  it 'projects current enumeration values with localization fallbacks and retains legacy metadata' do
    application = Mxrb::RubyApp::Application.allocate
    definitions = [{ 'name' => 'App.Status', 'values' => [{ 'name' => 'Old' }] }, { 'name' => 'Legacy.Status' }]
    manifest = instance_double(Mxrb::RubyApp::Manifest, data: {}, modules: [{ 'enumerations' => definitions }, {}])
    allow(application).to receive(:manifest).and_return(manifest)
    implementation = double(values: [
                              { name: 'Translated', id: '1', captions: { 'pt_BR' => 'Traduzido' } },
                              { name: 'NoCaption', id: '2', captions: {} }
                            ])
    allow(Mxrb::RubyApp::Registry).to receive(:fetch).with(:enumeration, 'App.Status').and_return(implementation)
    allow(Mxrb::RubyApp::Registry).to receive(:fetch).with(:enumeration, 'Legacy.Status').and_return(nil)
    result = application.send(:runtime_schema_modules)
    expect(result.first.fetch('enumerations').first.fetch('values').map do
      _1['caption']
    end).to eq(%w[Traduzido NoCaption])
    expect(result.first.fetch('enumerations').last).to eq(definitions.last)
    expect(result.last).to eq('enumerations' => [], 'models' => [], 'dtos' => [])
    expect(definitions.first.fetch('values')).to eq([{ 'name' => 'Old' }])
    legacy = { 'name' => 'Legacy.Record', 'attributes' => [{ 'name' => 'Name', 'type' => 'string' }] }
    allow(Mxrb::RubyApp::Registry).to receive(:fetch).with(:record, 'Legacy.Record').and_return(nil)
    expect(application.send(:runtime_model_definition, legacy)).to eq(legacy)
    allow(implementation).to receive(:values).and_return([])
    expect(application.send(:runtime_schema_modules).first.fetch('enumerations').first.fetch('values')).to eq([])
  end
end
