# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::RuntimeCatalog do
  after { Mxrb::RubyApp::Registry.reset! }

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
end
# rubocop:enable Metrics/BlockLength
