# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Ruby-first native materialization' do
  def define_source(path)
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:App) do
        module_role :User
        microflow(:Existing)
        page(:Home) do
          allowed_roles :User
          text :Heading, caption: 'Home'
        end
      end
      navigation do
        profile :Responsive, home_page: 'App.Home' do
          item 'Home', page: 'App.Home', icon: 'home'
        end
      end
    end
  end

  def write_ruby_feature(root)
    service_root = File.join(root, 'app', 'services', 'app')
    page_root = File.join(root, 'app', 'pages', 'app')
    FileUtils.mkdir_p(service_root)
    FileUtils.mkdir_p(page_root)
    File.write(File.join(service_root, 'act_launch.rb'), <<~RUBY)
      module App
        class ActLaunch < Mxrb::RubyApp::Service
          mendix_name 'App.ACT_Launch'
          native :microflow do
            allowed_roles 'App.User'
            return_type :String
            show_message 'Ruby reached Mendix', type: :success
            return_value "'ready'"
          end
        end
      end
    RUBY
    File.write(File.join(service_root, 'nan_launch.rb'), <<~RUBY)
      module App
        class NanLaunch < Mxrb::RubyApp::Service
          mendix_name 'App.NAN_Launch'
          native :nanoflow do
            allowed_roles 'App.User'
            call_microflow 'App.ACT_Launch', as: :status
            show_message '{1}', type: :information, parameters: ['$status']
            return_value :status
          end
        end
      end
    RUBY
    File.write(File.join(page_root, 'launchpad.rb'), <<~RUBY)
      module App
        class Launchpad < Mxrb::RubyApp::Page
          mendix_name 'App.Launchpad'
          native do
            layout 'Atlas_Default'
            title 'Ruby Launchpad'
            allowed_roles 'App.User'
            text :Heading, caption: 'Ruby to Mendix'
            button :Launch, caption: 'Launch' do
              on_click nanoflow: 'App.NAN_Launch'
            end
          end
          navigation caption: 'Ruby Launchpad', profile: 'Responsive', icon: 'home'
        end
      end
    RUBY
  end

  def document_ids(path)
    Mxrb.open(path) do |project|
      mod = project.modules.find { _1.name == 'App' }
      {
        microflow: mod.microflows.find { _1.name == 'ACT_Launch' }.id,
        nanoflow: mod.nanoflows.find { _1.name == 'NAN_Launch' }.id,
        page: mod.pages.find { _1.name == 'Launchpad' }.id
      }
    end
  end

  def define_domain_source(path)
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:App) do
        entity(:Customer) { string :Name }
        entity(:Order) do
          string :Number
          association 'App.Customer', name: :Order_Customer, cardinality: :many_to_one,
                                      documentation: 'Original relation'
        end
      end
      self.module(:Shared) do
        entity(:Tag) { string :Name }
      end
    end
  end

  def associations(path)
    Mxrb.open(path) do |project|
      project.modules.find { _1.name == 'App' }.associations
    end
  end

  it 'materializes new Ruby flows, a connected page, navigation, and a stable round trip' do
    Dir.mktmpdir('mxrb-ruby-native-') do |dir|
      source = File.join(dir, 'Source.mpr')
      ruby_root = File.join(dir, 'ruby-app')
      compiled = File.join(dir, 'Compiled.mpr')
      round_trip = File.join(dir, 'round-trip')
      recompiled = File.join(dir, 'Recompiled.mpr')
      define_source(source)
      Mxrb::Exporter.new(source, ruby_root, mode: :ruby).export!
      write_ruby_feature(ruby_root)

      expect(Mxrb::RubyApp.compile(ruby_root, compiled)).to eq(compiled)
      first_ids = document_ids(compiled)
      expect(first_ids.values).to all(match(/\A[0-9a-f-]{36}\z/))

      Mxrb.open(compiled) do |project|
        mod = project.modules.find { _1.name == 'App' }
        microflow = mod.microflows.find { _1.name == 'ACT_Launch' }
        nanoflow = mod.nanoflows.find { _1.name == 'NAN_Launch' }
        page = mod.pages.find { _1.name == 'Launchpad' }

        expect(microflow.allowed_module_roles).to include('App.User')
        expect(microflow.objects.map { _1.dig('Action', '$Type') }).to include(
          'Microflows$ShowMessageAction'
        )
        expect(nanoflow.objects.map { _1.dig('Action', '$Type') }).to include(
          'Microflows$MicroflowCallAction', 'Microflows$ShowMessageAction'
        )
        expect(page.title).to eq('Ruby Launchpad')
        expect(page.widgets).to include(include(name: 'Launch', events: include(
          include(kind: :nanoflow, handler: 'NAN_Launch')
        )))
        expect(project.navigation.profiles.first.menu_items).to include(
          include(page: 'App.Launchpad')
        )
      end

      Mxrb::Exporter.new(compiled, round_trip, mode: :ruby).export!
      expect(File.read(File.join(round_trip, 'app', 'services', 'app', 'act_launch.rb')))
        .to include('native :microflow', "show_message 'Ruby reached Mendix'")
      expect(File).to exist(File.join(
                              round_trip, 'frontend', 'src', 'generated', 'nanoflows',
                              'app', 'nan_launch.ts'
                            ))
      expect(File.read(File.join(
                         round_trip, 'frontend', 'src', 'generated', 'nanoflows',
                         'app', 'nan_launch.ts'
                       ))).to include('runtime.string(["$status"][Number(rawIndex) - 1])')
      Mxrb::RubyApp.compile(round_trip, recompiled)
      expect(document_ids(recompiled)).to eq(first_ids)
    end
  end

  it 'edits local and cross-module associations authoritatively with stable native ids' do
    Dir.mktmpdir('mxrb-ruby-associations-') do |dir|
      source = File.join(dir, 'Source.mpr')
      ruby_root = File.join(dir, 'ruby-app')
      compiled = File.join(dir, 'Compiled.mpr')
      round_trip = File.join(dir, 'round-trip')
      recompiled = File.join(dir, 'Recompiled.mpr')
      define_domain_source(source)
      Mxrb::Exporter.new(source, ruby_root, mode: :ruby).export!

      model_path = File.join(ruby_root, 'app', 'models', 'app', 'order.rb')
      model_source = File.read(model_path)
      expect(model_source).to include(
        'association "App.Customer", name: "Order_Customer"',
        'documentation: "Original relation"'
      )
      model_source = model_source.sub(
        'documentation: "Original relation"', 'documentation: "Ruby relation"'
      ).sub(
        "  end\nend\n",
        <<~RUBY
              association "Shared.Tag", name: "Order_Tags", type: :ReferenceSet,
                          owner: :Default, documentation: "Cross relation",
                          parent_delete: :NoAction, child_delete: :NoAction,
                          storage_format: :Table
            end
          end
        RUBY
      )
      File.write(model_path, model_source)

      Mxrb::RubyApp.compile(ruby_root, compiled)
      compiled_associations = associations(compiled)
      original = compiled_associations.find { _1.name == 'Order_Customer' }
      cross = compiled_associations.find { _1.name == 'Order_Tags' }
      expect(original.documentation).to eq('Ruby relation')
      expect(cross).to have_attributes(
        association_type: :ReferenceSet, storage_format: :Table, to_entity_id: 'Shared.Tag'
      )

      Mxrb::Exporter.new(compiled, round_trip, mode: :ruby).export!
      round_trip_source = File.read(File.join(round_trip, 'app', 'models', 'app', 'order.rb'))
      expect(round_trip_source).to include('name: "Order_Tags"')
      Mxrb::RubyApp.compile(round_trip, recompiled)
      expect(associations(recompiled).to_h { [_1.name, _1.id] }).to eq(
        compiled_associations.to_h { [_1.name, _1.id] }
      )

      without_original = round_trip_source.lines.reject { _1.include?('name: "Order_Customer"') }.join
      File.write(File.join(round_trip, 'app', 'models', 'app', 'order.rb'), without_original)
      Mxrb::RubyApp.compile(round_trip, recompiled)
      expect(associations(recompiled).map(&:name)).to eq(['Order_Tags'])
    end
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
