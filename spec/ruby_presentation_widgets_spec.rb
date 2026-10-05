# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Standalone presentation export' do
  it 'exports uncommon layout widgets as editable Forms constructors without opaque fragments' do
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'Layout.mpr')
      target = File.join(directory, 'ruby')
      existing = File.join(target, '.mxrb', 'native_fragments', 'user-owned.bson')
      FileUtils.mkdir_p(File.dirname(existing))
      File.binwrite(existing, 'existing user file')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module :Example do
          native_document :Shell, type: 'Forms$Layout', deep_structure: {
            'Content' => { '$Type' => 'Forms$WebLayoutContent',
                           'Widgets' => [2, { '$Type' => 'Forms$Header', 'Name' => 'heading' }] }
          }
        end
      end
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      expect(Dir[File.join(target, '.mxrb', 'native_fragments', '*.bson')]).to eq([existing])
      expect(File.binread(existing)).to eq('existing user file')
      rebuilt = File.join(directory, 'rebuilt.mpr')
      Mxrb::RubyApp.compile(target, rebuilt)
      expect(Mxrb.compare(source, rebuilt)).to be_identical
      path = File.join(target, 'app', 'presentation', 'example.rb')
      expect(File.read(path)).to include('form_widget(', 'Mxrb::Forms.header')
      expect(Mxrb::PublicSourceAudit.new(target)).to be_clean
      File.write(path, File.read(path).sub('heading', 'editedHeading'))
      expect(Mxrb::Model::Project).not_to receive(:open)
      application = Mxrb::RubyApp::Application.new(target)
      resource = Mxrb::RubyApp::Registry.fetch(:presentation, 'Example.Shell')
      expect(resource.fetch(:widgets).first.fetch('name')).to eq('editedHeading')
      tree = Mxrb::RubyApp::Page::WidgetTree.new
      tree.layout_grid('grid') do
        row do
          column do
            form_widget(Mxrb::Forms.header { name 'nestedHeading' })
          end
        end
      end
      expect(JSON.generate(tree.widgets)).to include('nestedHeading')
    ensure
      application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  it 'exports all ten widget types and reusable resources as editable source and local assets' do
    Dir.mktmpdir('mxrb-presentation-') do |directory|
      source = File.join(directory, 'Source.mpr')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(source)
      load File.expand_path('fixtures/ruby_presentation_widgets/project.rb', __dir__)
      target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      expect(Mxrb::PublicSourceAudit.new(target)).to be_clean
      path = File.join(target, 'app', 'presentation', 'presentation.rb')
      File.write(path, File.read(path).sub('Alternate page', 'Edited menu'))
      application = Mxrb::RubyApp::Application.new(target)
      allow(Mxrb::Model::Project).to receive(:open).and_raise('No MPR at runtime')
      page = application.page('Presentation.Home')
      nodes = lambda do |value|
        case value
        when Hash then [value, *value.values.flat_map { nodes.call(_1) }]
        when Array then value.flat_map { nodes.call(_1) }
        else []
        end
      end
      widgets = nodes.call(page).find { _1['type'] == 'data_view' }.fetch('body')
      expect(widgets.map { _1.fetch('type') }).to contain_exactly(
        *%w[button menu_bar navigation_tree static_image snippet file_manager image_uploader image_viewer
            reference_set_selector scroll_container navigation_list]
      )
      expect(widgets.find { _1['type'] == 'scroll_container' }.dig('regions', 'center').map { _1.fetch('name') })
        .to eq(%w[ToggleRegion RegionName])
      expect(widgets.find { _1['type'] == 'navigation_list' }.dig('children', 0, 'events', 0, 'handler'))
        .to eq('Presentation.Alternate')
      resources = application.schema.fetch(:presentation)
      expect(resources.fetch('Presentation.Main').fetch(:items).first.fetch(:caption)).to eq('Edited menu')
      expect(resources.fetch('Presentation.Main').fetch(:items).last.fetch(:items).first.dig(:action, :handler))
        .to eq('Presentation.Ping')
      expect(resources.fetch('Presentation.Details').fetch(:widgets).first.fetch('type')).to eq('text_box')
      image = File.join(target, 'frontend', 'public', resources.fetch('Presentation.Images.Pixel').fetch(:path))
      expect(File.binread(image)).to start_with("\x89PNG".b)
      document = application.call_service('Presentation.Load')
      expect(document).to include(type: 'Presentation.Document')
      tag = application.records('Presentation.Tag').first
      application.update_record('Presentation.Document', document.fetch(:id), { 'Document_Tags' => [tag] })
      application.close
      application = Mxrb::RubyApp::Application.new(target)
      persisted = application.record('Presentation.Document', document.fetch(:id))
      expect(persisted.dig(:attributes, 'Document_Tags').first.fetch(:id)).to eq(tag.fetch(:id))
    ensure
      application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end
end
# rubocop:enable Metrics/BlockLength
