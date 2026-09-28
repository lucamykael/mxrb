# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative 'fixtures/menu_documents/project'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'semantic menu documents' do
  it 'adds, changes, and removes menu documents and items with stable native identities' do
    Dir.mktmpdir('mxrb-semantic-menus-') do |dir|
      source = File.join(dir, 'Menus.mpr')
      first_export = File.join(dir, 'ruby-one')
      first_rebuild = File.join(dir, 'rebuilt-one.mpr')
      second_export = File.join(dir, 'ruby-two')
      second_rebuild = File.join(dir, 'rebuilt-two.mpr')
      build_project(source)
      original = menu_documents(source)
      original_main = original.fetch('Main')

      Mxrb::Exporter.new(source, first_export).export!
      presentation = File.join(first_export, 'modules', 'Menus', 'presentation')
      main_path = File.join(presentation, 'menus', 'main.rb')
      main_source = File.read(main_path)
      expect(main_source).to include(
        'baseline_menu unit_id:', 'documentation "Primary menu"',
        'translations: {"pt_BR" => "Início"}', 'microflow: "Menus.Ping"', 'icon: 57369'
      )
      expect(main_source).not_to include('deep_structure', '$ID', 'bson_binary')

      changed = main_source
                .sub('documentation "Primary menu"', 'documentation "Changed menu"')
                .sub('page: "Menus.Home"', 'page: "Menus.Alternate"')
                .lines.reject { _1.include?('item "Run"') }.join
      changed = changed.sub("end\n", "  item \"Added\", page: \"Menus.Home\"\nend\n")
      File.write(main_path, changed)

      obsolete_path = File.join(presentation, 'menus', 'obsolete.rb')
      FileUtils.rm(obsolete_path)
      added_path = File.join(presentation, 'menus', 'added_menu.rb')
      File.write(added_path, <<~RUBY)
        # frozen_string_literal: true

        menu :AddedMenu do
          item "Home", page: "Menus.Home"
        end
      RUBY
      aggregator = File.join(presentation, 'presentation.rb')
      lines = File.read(aggregator).lines.reject { _1.include?('obsolete.rb') }
      lines << "evaluate File.join(__dir__, \"menus\", \"added_menu.rb\")\n"
      File.write(aggregator, lines.join)

      generate(first_export, first_rebuild)
      expect(Mxrb.validate(first_rebuild)).to be_valid
      rebuilt = menu_documents(first_rebuild)
      expect(rebuilt.keys).to contain_exactly('Main', 'AddedMenu')
      expect(rebuilt.fetch('Main')).to include('Documentation' => 'Changed menu')
      expect(menu_item(rebuilt.fetch('Main'), 'Home').dig('Action', 'FormSettings', 'Form'))
        .to eq('Menus.Alternate')
      expect(menu_item(rebuilt.fetch('Main'), 'Run')).to be_nil
      expect(menu_item(rebuilt.fetch('Main'), 'Added')).not_to be_nil
      expect(native_id(rebuilt.fetch('Main'))).to eq(native_id(original_main))
      expect(native_id(menu_item(rebuilt.fetch('Main'), 'Home')))
        .to eq(native_id(menu_item(original_main, 'Home')))
      expect(native_ids(menu_item(rebuilt.fetch('Main'), 'Home')))
        .to contain_exactly(*native_ids(menu_item(original_main, 'Home')))
      expect(native_id(menu_item(rebuilt.fetch('Main'), 'More')))
        .to eq(native_id(menu_item(original_main, 'More')))

      Mxrb::Exporter.new(first_rebuild, second_export).export!
      generate(second_export, second_rebuild)
      expect(Mxrb.validate(second_rebuild)).to be_valid
      expect(menu_documents(second_rebuild)).to eq(rebuilt)
    end
  end

  it 'falls back to a lossless native declaration for unsupported menu actions' do
    Dir.mktmpdir('mxrb-opaque-menu-') do |dir|
      source = File.join(dir, 'Menus.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      build_project(source)
      replace_action(source, 'Main', 'Forms$FutureMenuAction')
      original = menu_documents(source).fetch('Main')

      Mxrb::Exporter.new(source, exported).export!
      ruby = File.read(File.join(exported, 'modules', 'Menus', 'presentation', 'menus', 'main.rb'))
      expect(ruby).to include('deep_structure', 'Forms$FutureMenuAction')

      generate(exported, rebuilt)
      expect(menu_documents(rebuilt).fetch('Main')).to eq(original)
    end
  end

  def build_project(path)
    MenuDocumentsFixture.build(path)
  end

  def menu_documents(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [document.fetch('Name'), document] if document['$Type'] == 'Menus$MenuDocument'
      end.to_h
    end
  end

  def menu_item(document, caption)
    items = Mxrb::IO::BsonCodec.parse_array(document.dig('ItemCollection', 'Items')).fetch(:items)
    find_item(items, caption)
  end

  def find_item(items, caption)
    items.each do |item|
      text = Mxrb::IO::BsonCodec.parse_array(item.dig('Caption', 'Items')).fetch(:items)
                                .find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', nil)
      return item if text == caption

      found = find_item(Mxrb::IO::BsonCodec.parse_array(item['Items']).fetch(:items), caption)
      return found if found
    end
    nil
  end

  def replace_action(path, menu_name, type)
    mpr = Mxrb::IO::MprFile.open(path)
    raw = mpr.all_units.find do |unit|
      document = mpr.parse_contents(unit)
      document['$Type'] == 'Menus$MenuDocument' && document['Name'] == menu_name
    end
    document = mpr.parse_contents(raw)
    menu_item(document, 'Home')['Action'] = { '$ID' => SecureRandom.uuid, '$Type' => type }
    mpr.update_unit(raw.fetch('UnitID'), document)
  ensure
    mpr&.close
  end

  def native_id(value) = Mxrb::IO::BsonCodec.extract_id(value.fetch('$ID'))

  def native_ids(value)
    case value
    when Hash
      identity = value['$ID'] && native_id(value)
      [identity, *value.values.flat_map { native_ids(_1) }].compact
    when Array then value.drop(value.first.is_a?(Integer) ? 1 : 0).flat_map { native_ids(_1) }
    else []
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/BlockLength
