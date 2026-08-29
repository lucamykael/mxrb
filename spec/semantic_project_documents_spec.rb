# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
PROJECT_DOCUMENT_TYPES = %w[
  Settings$ProjectSettings Texts$SystemTextCollection
].freeze

RSpec.describe 'semantic project documents' do
  it 'round-trips project settings and system texts as Ruby trees' do
    Dir.mktmpdir('mxrb-project-documents-') do |dir|
      source = File.join(dir, 'ProjectDocuments.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      Mxrb.define(source) { self.module(:App) {} }
      insert_documents(source)

      Mxrb::Exporter.new(source, exported).export!
      settings = File.read(File.join(exported, 'app', 'settings', 'settings.rb'))
      texts = File.read(File.join(exported, 'app', 'texts', 'system_texts.rb'))
      expect(settings).to include('project_settings_document(', 'Settings$ModelSettings')
      expect(texts).to include('system_text_collection(', 'Texts$SystemText')
      expect(settings + texts).not_to include('native_unit ', 'deep_structure:', 'bson_binary(')
      native_source = File.read(File.join(exported, '.mxrb', 'native_units.rb'))
      PROJECT_DOCUMENT_TYPES.each { expect(native_source).not_to include(_1) }

      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(project_documents(rebuilt)).to eq(project_documents(source))
    end
  end

  def insert_documents(path) # rubocop:disable Metrics/AbcSize
    mpr = Mxrb::IO::MprFile.open(path)
    project_id = mpr.all_units.find do |unit|
      mpr.parse_contents(unit)['$Type'] == 'Projects$Project'
    end.fetch('UnitID')
    settings = {
      '$Type' => 'Settings$ProjectSettings',
      'Settings' => Mxrb::IO::BsonCodec.build_array(
        [node('Settings$ModelSettings', 'UseOQLVersion2' => true)], marker: 2
      )
    }
    system_texts = {
      '$Type' => 'Texts$SystemTextCollection',
      'SystemTexts' => Mxrb::IO::BsonCodec.build_array(
        [node(
          'Texts$SystemText', 'InternalKey' => 'app.welcome',
                              'Text' => node(
                                'Texts$Text',
                                'Items' => Mxrb::IO::BsonCodec.build_array(
                                  [node('Texts$Translation',
                                        'LanguageCode' => 'en_US', 'Text' => 'Welcome')],
                                  marker: 3
                                )
                              )
        )],
        marker: 2
      )
    }
    [settings, system_texts].each do |document|
      mpr.insert_unit(
        container_uuid: project_id, containment_name: 'ProjectDocuments', contents_doc: document
      )
    end
  ensure
    mpr&.close
  end

  def node(type, fields = {})
    { '$ID' => SecureRandom.uuid, '$Type' => type }.merge(fields)
  end

  def project_documents(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [unit['UnitID'], document] if PROJECT_DOCUMENT_TYPES.include?(document['$Type'])
      end.to_h
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
