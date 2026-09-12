# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::SystemTexts do
  let(:codec) { described_class::MprCodec.new }

  it 'models languages, keyword translations and arbitrary language codes without storage fields' do
    collection = described_class::Collection.build do
      languages :en_US, 'zh-Hans'
      text 'welcome', en_US: 'Welcome'
      text 'duplicated' do
        translation 'zh-Hans', '欢迎'
        translation 'zh-Hans', '歡迎'
      end
    end

    source = described_class::SourceEmitter.new.emit(collection)
    expect(source).to include(
      'languages :en_US, "zh-Hans"',
      'text "welcome", en_US: "Welcome"',
      'translation "zh-Hans", "欢迎"'
    )
    expect(source).not_to match(/\$ID|\$Type|node_type|collection:|marker:|[0-9a-f]{8}-/i)

    rebuilt = codec.decode(codec.encode(collection))
    expect(rebuilt).to eq(collection)
  end

  it 'preserves every BSON identity by semantic key and language occurrence' do
    original = system_text_document
    model = codec.decode(original)
    rebuilt = codec.encode(model, baseline: original)

    expect(rebuilt).to eq(original)
  end

  it 'round-trips a Mendix 11 collection through clean exported Ruby' do
    Dir.mktmpdir('mxrb-system-texts-') do |dir|
      source_dir = File.join(dir, 'original')
      rebuilt_dir = File.join(dir, 'rebuilt')
      FileUtils.mkdir_p([source_dir, rebuilt_dir])
      source = File.join(source_dir, 'SystemTexts.mpr')
      rebuilt = File.join(rebuilt_dir, 'SystemTexts.mpr')
      exported = File.join(dir, 'ruby')
      Mxrb.define(source) do
        mendix_version '11.0.0'
        self.module(:App) {}
      end
      insert_system_texts(source, system_text_document)

      Mxrb::Exporter.new(source, exported).export!
      public_source = File.read(File.join(exported, 'app', 'texts', 'system_texts.rb'))
      expect(public_source).to include('system_text_collection do', 'languages :en_US, :nl_NL')
      violations = Mxrb::PublicSourceAudit.new(exported).violations.select do |entry|
        entry.subsystem == 'app/texts'
      end
      expect(violations).to be_empty

      generate(exported, rebuilt)
      expect(system_texts_from(rebuilt)).to eq(system_texts_from(source))

      edited_dir = File.join(dir, 'edited')
      FileUtils.mkdir_p(edited_dir)
      edited = File.join(edited_dir, 'SystemTexts.mpr')
      File.write(
        File.join(exported, 'app', 'texts', 'system_texts.rb'),
        public_source.sub('en_US: "Welcome"', 'en_US: "Hello from Ruby"')
      )
      generate(exported, edited)
      original_document = system_texts_from(source).last
      edited_document = system_texts_from(edited).last
      expect(node_ids(edited_document)).to eq(node_ids(original_document))
      expect(translation_value(edited_document, 'app.welcome', 'en_US')).to eq('Hello from Ruby')
    end
  end

  def system_text_document # rubocop:disable Metrics/MethodLength
    {
      '$ID' => '10000000-0000-4000-8000-000000000001',
      '$Type' => 'Texts$SystemTextCollection',
      'SystemTexts' => Mxrb::IO::BsonCodec.build_array(
        [
          system_text(
            '20000000-0000-4000-8000-000000000001', 'app.welcome',
            [
              translation('40000000-0000-4000-8000-000000000001', 'en_US', 'Welcome'),
              translation('40000000-0000-4000-8000-000000000002', 'nl_NL', 'Welkom')
            ]
          ),
          system_text(
            '20000000-0000-4000-8000-000000000002', 'app.empty', []
          )
        ],
        marker: 2
      )
    }
  end

  def system_text(id, key, translations)
    {
      '$ID' => id, '$Type' => 'Texts$SystemText', 'InternalKey' => key,
      'Text' => {
        '$ID' => id.sub('20000000', '30000000'), '$Type' => 'Texts$Text',
        'Items' => Mxrb::IO::BsonCodec.build_array(translations, marker: 3)
      }
    }
  end

  def translation(id, language, value)
    {
      '$ID' => id, '$Type' => 'Texts$Translation',
      'LanguageCode' => language, 'Text' => value
    }
  end

  def insert_system_texts(path, document)
    mpr = Mxrb::IO::MprFile.open(path, apply_studio_compatibility: false)
    root_id = mpr.root_unit.fetch('UnitID')
    mpr.insert_unit(
      container_uuid: root_id, containment_name: 'ProjectDocuments', contents_doc: document
    )
  ensure
    mpr&.close
  end

  def system_texts_from(path)
    Mxrb.open(path) do |project|
      unit = project.all_units.find do |candidate|
        project.parse_bson(candidate)['$Type'] == 'Texts$SystemTextCollection'
      end
      [unit.slice('UnitID', 'ContainerID', 'ContainmentName'), project.parse_bson(unit)]
    end
  end

  def node_ids(value)
    case value
    when Hash
      [value['$ID'], *value.values.flat_map { node_ids(_1) }].compact
    when Array
      value.flat_map { node_ids(_1) }
    else
      []
    end
  end

  def translation_value(document, key, language)
    entries = Mxrb::IO::BsonCodec.parse_array(document.fetch('SystemTexts')).fetch(:items)
    entry = entries.find { _1.fetch('InternalKey') == key }
    translations = Mxrb::IO::BsonCodec.parse_array(entry.dig('Text', 'Items')).fetch(:items)
    translations.find { _1.fetch('LanguageCode') == language }.fetch('Text')
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end
end
# rubocop:enable Metrics/BlockLength
