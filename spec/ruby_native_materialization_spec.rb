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

  def define_enumeration_source(path)
    Mxrb.define(path) do
      mendix_version '10.18.0'
      self.module(:App) do
        enumeration(:OrderStatus) do
          documentation 'Original statuses'
          value :New, caption: 'New order'
          value :Done, caption: 'Completed'
        end
        entity(:Order) do
          enum :Status, enumeration: 'App.OrderStatus'
        end
      end
    end
  end

  def native_enumeration(path, name)
    Mxrb.open(path) do |project|
      project.modules.find { _1.name == 'App' }.enumerations.find { _1['Name'] == name }
    end
  end

  def native_enumeration_ids(path, name)
    enumeration = native_enumeration(path, name)
    values = Mxrb::IO::BsonCodec.parse_array(enumeration.fetch('Values'))[:items]
    {
      document: Mxrb::IO::BsonCodec.extract_id(enumeration.fetch('$ID')),
      values: values.to_h do |value|
        [value.fetch('Name'), Mxrb::IO::BsonCodec.extract_id(value.fetch('$ID'))]
      end
    }
  end

  def enrich_native_enumeration(path) # rubocop:disable Metrics/AbcSize
    mpr = Mxrb::IO::MprFile.open(path, readonly: false)
    raw = mpr.units_by_containment('Documents').find do |unit|
      document = mpr.parse_contents(unit)
      document['$Type'] == 'Enumerations$Enumeration' && document['Name'] == 'OrderStatus'
    end
    document = mpr.parse_contents(raw)
    document['VendorMetadata'] = { 'Keep' => true }
    value = Mxrb::IO::BsonCodec.parse_array(document.fetch('Values'))[:items].first
    value['RemoteValue'] = 'native-new'
    caption = value.fetch('Caption')
    items = Mxrb::IO::BsonCodec.parse_array(caption.fetch('Items'))
    items[:items] << {
      '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Translation',
      'LanguageCode' => 'pt_BR', 'Text' => 'Novo pedido'
    }
    items[:items] << {
      '$ID' => SecureRandom.uuid, '$Type' => 'Vendor$CaptionExtension', 'Payload' => 'keep'
    }
    caption['Items'] = Mxrb::IO::BsonCodec.build_array(items[:items], marker: items[:marker])
    mpr.transaction { mpr.update_unit(raw.fetch('UnitID'), document) }
  ensure
    mpr&.close
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

  it 'creates, renames, localizes, and safely removes Ruby-native enumerations with stable ids' do
    Dir.mktmpdir('mxrb-ruby-enumerations-') do |dir|
      source = File.join(dir, 'Source.mpr')
      ruby_root = File.join(dir, 'ruby-app')
      compiled = File.join(dir, 'Compiled.mpr')
      round_trip = File.join(dir, 'round-trip')
      recompiled = File.join(dir, 'Recompiled.mpr')
      define_enumeration_source(source)
      enrich_native_enumeration(source)
      original_ids = native_enumeration_ids(source, 'OrderStatus')
      Mxrb::Exporter.new(source, ruby_root, mode: :ruby).export!

      enumeration_path = File.join(ruby_root, 'app', 'enumerations', 'app', 'order_status.rb')
      source_text = File.read(enumeration_path)
      expect(source_text).to include(
        'class OrderStatus < Mxrb::RubyApp::Enumeration',
        '"pt_BR" => "Novo pedido"'
      )
      source_text = source_text.sub('App.OrderStatus', 'App.FulfillmentStatus')
                               .sub('Original statuses', 'Ruby statuses')
                               .sub(
                                 /value "New".*$/,
                                 "value \"Open\", id: #{original_ids.dig(:values, 'New').inspect}, " \
                                 'captions: {"en_US"=>"Open order", "pt_BR"=>"Pedido aberto"}'
                               )
                               .lines.reject { _1.include?('value "Done"') }.join
      source_text = source_text.sub(
        "  end\nend\n",
        "    value \"Pending\", captions: {\"en_US\"=>\"Pending\"}\n  end\nend\n"
      )
      File.write(enumeration_path, source_text)
      model_path = File.join(ruby_root, 'app', 'models', 'app', 'order.rb')
      File.write(model_path, File.read(model_path).sub('App.OrderStatus', 'App.FulfillmentStatus'))
      priority_path = File.join(ruby_root, 'app', 'enumerations', 'app', 'priority.rb')
      File.write(priority_path, <<~RUBY)
        module App
          class Priority < Mxrb::RubyApp::Enumeration
            mendix_name 'App.Priority', id: '11111111-1111-4111-8111-111111111111'
            documentation 'Created in Ruby'
            value 'High', id: '22222222-2222-4222-8222-222222222222',
                          captions: { en_US: 'High', pt_BR: 'Alta' }
          end
        end
      RUBY
      File.write(File.join(ruby_root, 'app', 'enumerations', 'app', 'tier.rb'), <<~RUBY)
        module App
          class Tier < Mxrb::RubyApp::Enumeration
            mendix_name 'App.Tier'
            value 'Standard'
          end
        end
      RUBY

      Mxrb::RubyApp.compile(ruby_root, compiled)
      changed = native_enumeration(compiled, 'FulfillmentStatus')
      changed_values = Mxrb::IO::BsonCodec.parse_array(changed.fetch('Values'))[:items]
      open_value = changed_values.find { _1['Name'] == 'Open' }
      open_captions = Mxrb::IO::BsonCodec.parse_array(open_value.dig('Caption', 'Items'))[:items]
      expect(Mxrb::IO::BsonCodec.extract_id(changed['$ID'])).to eq(original_ids[:document])
      expect(changed).to include('Documentation' => 'Ruby statuses',
                                 'VendorMetadata' => { 'Keep' => true })
      expect(changed_values.map { _1['Name'] }).to eq(%w[Open Pending])
      expect(Mxrb::IO::BsonCodec.extract_id(open_value['$ID'])).to eq(original_ids.dig(:values, 'New'))
      expect(open_value['RemoteValue']).to eq('native-new')
      expect(open_captions).to include(
        include('LanguageCode' => 'en_US', 'Text' => 'Open order'),
        include('LanguageCode' => 'pt_BR', 'Text' => 'Pedido aberto'),
        include('$Type' => 'Vendor$CaptionExtension', 'Payload' => 'keep')
      )
      expect(native_enumeration(compiled, 'Priority')).to include('Documentation' => 'Created in Ruby')

      Mxrb::Exporter.new(compiled, round_trip, mode: :ruby).export!
      round_trip_manifest = JSON.parse(File.read(File.join(round_trip, '.mxrb', 'ruby-app.json')))
      enumeration_paths = round_trip_manifest.fetch('modules').first.fetch('enumerations').to_h do |entry|
        [entry.fetch('name'), File.join(round_trip, entry.fetch('path'))]
      end
      Mxrb::RubyApp.compile(round_trip, recompiled)
      expect(native_enumeration_ids(recompiled, 'FulfillmentStatus')).to eq(
        native_enumeration_ids(compiled, 'FulfillmentStatus')
      )

      File.delete(enumeration_paths.fetch('App.Priority'))
      Mxrb::RubyApp.compile(round_trip, recompiled)
      expect(native_enumeration(recompiled, 'Priority')).to be_nil

      File.delete(enumeration_paths.fetch('App.FulfillmentStatus'))
      expect { Mxrb::RubyApp.compile(round_trip, recompiled) }
        .to raise_error(Mxrb::ValidationError, /cannot remove enumeration.*incoming reference/)
    end
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
