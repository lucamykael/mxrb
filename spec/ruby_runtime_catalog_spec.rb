# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::RuntimeCatalog do
  before { Mxrb::RubyApp::Registry.reset! }
  after { Mxrb::RubyApp::Registry.reset! }

  it 'includes page parameters and popup contracts in the discovery schema' do
    page = Class.new(Mxrb::RubyApp::Page) do
      mendix_name 'App.Edit'
      native do
        parameter :Item, entity: 'App.Item'
        popup! mode: :modal
      end
    end
    definition = described_class.new([]).modules.first.fetch('pages').first
    expect(definition.fetch('parameters')).to eq(page.presentation_contract.fetch(:parameters))
    expect(definition.fetch('popup')).to include(mode: 'modal')
  end

  it 'discovers newly added Ruby documents during reload without editing the manifest or opening MPR' do
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'Catalog.mpr')
      target = File.join(directory, 'app')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module :Catalog do
          entity(:Item) { string :Name }
          page(:Home) { text :Hello, caption: 'Home' }
        end
      end
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      original = File.binread(File.join(target, '.mxrb/ruby-app.json'))
      allow(Mxrb::Model::Project).to receive(:open).and_raise('MPR is unavailable')
      application = Mxrb::RubyApp::Application.new(target, reload: true)
      application.records('Catalog.Item')
      File.write(File.join(target, 'app/models/additions.rb'), <<~RUBY)
        class AddedItem < Mxrb::RubyApp::Record
          mendix_name 'NewModule.Item'
          persistence true
          attribute :name, type: :string, mendix_name: 'Name'
          association 'Catalog.Item', name: 'NewModule.Item_Parent'
        end
        class AddedPage < Mxrb::RubyApp::Page
          mendix_name 'NewModule.Home'
          configure(title: 'Added from Ruby') { text :Greeting, caption: 'New page' }
        end
        class AddedState < Mxrb::RubyApp::Enumeration
          mendix_name 'NewModule.State'
          value :Ready, caption: 'Ready'
        end
        class AddedFlow < Mxrb::RubyApp::Service
          mendix_name 'NewModule.Answer'
          flow { return_type :String; return_value "'New flow'" }
        end
      RUBY
      expect(application.reload_if_changed!).to be(true)
      mod = application.schema.fetch(:modules).find { _1['name'] == 'NewModule' }
      expect(mod.fetch('models').first.fetch('attributes')).to include(include('name' => 'Name'))
      expect(mod.fetch('pages').first.fetch('title')).to eq('Added from Ruby')
      expect(mod.fetch('enumerations').first.fetch('values')).to include(include('name' => 'Ready'))
      expect(mod.fetch('services').first.fetch('name')).to eq('NewModule.Answer')
      expect(mod.fetch('associations').first).to include('to_entity' => 'Catalog.Item')
      expect(application.call_service('NewModule.Answer')).to eq('New flow')
      expect(application.create_record('NewModule.Item', { 'Name' => 'Persisted' }))
        .to include(attributes: include('Name' => 'Persisted'))
      expect(application.page('NewModule.Home')).to include(title: 'Added from Ruby')
      expect(File.binread(File.join(target, '.mxrb/ruby-app.json'))).to eq(original)
    ensure
      application&.close
    end
  end
  it 'removes deleted and renamed documents after reload without changing the manifest or stored rows' do
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'Catalog.mpr')
      target = File.join(directory, 'app')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module :Catalog do
          entity(:Item) { string :Name }
          entity(:Removed) do
            non_persistent!
            string :Name
          end
          page(:Home) { text :Hello, caption: 'Home' }
          microflow(:Answer) do
            return_type :String
            return_value "'answer'"
          end
          enumeration(:State) { value :Ready, caption: 'Ready' }
        end
      end
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      original = File.binread(File.join(target, '.mxrb/ruby-app.json'))
      allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR is unavailable')
      application = Mxrb::RubyApp::Application.new(target, reload: true)
      id = application.create_record('Catalog.Item', { 'Name' => 'Retained' }).fetch(:id)
      manifest = application.manifest
      mod = manifest.modules.find { _1['name'] == 'Catalog' }
      %w[models dtos pages services enumerations].each do |collection|
        mod.fetch(collection).each do |entry|
          path = File.join(target, entry.fetch('path'))
          if entry.fetch('name') == 'Catalog.Item'
            File.write(path,
                       File.read(path).sub('mendix_name "Catalog.Item"',
                                           "mendix_name 'Catalog.Renamed', renamed_from: 'Catalog.Item'"))
          else
            File.unlink(path)
          end
        end
      end
      expect(application.reload_if_changed!).to be(true)
      catalog = application.schema.fetch(:modules).find { _1['name'] == 'Catalog' }
      expect(catalog.fetch('models').map { _1.fetch('name') }).to eq(['Catalog.Renamed'])
      expect(catalog.values_at('pages', 'services', 'enumerations')).to eq([[], [], []])
      expect(application.record('Catalog.Renamed', id)).to include(attributes: include('Name' => 'Retained'))
      expect(File.binread(File.join(target, '.mxrb/ruby-app.json'))).to eq(original)
    ensure
      application&.close
    end
  end

  it 'retains undeclared legacy documents when the native bridge supplies the model' do
    modules = [{ 'name' => 'Legacy', 'pages' => [{ 'name' => 'Legacy.Home' }] }]
    expect(described_class.new(modules).modules).to eq(modules)
  end
end
# rubocop:enable Metrics/BlockLength
