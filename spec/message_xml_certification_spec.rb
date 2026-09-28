# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative 'fixtures/message_xml/project'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'message-backed XML certification' do
  it 'keeps definitions, mappings, and XML actions stable for two Ruby cycles' do
    Dir.mktmpdir('mxrb-message-xml-certification-') do |dir|
      current = File.join(dir, 'source.mpr')
      MessageXmlFixture.build(current)
      baseline_ids = integration_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        sources = certified_sources(exported)
        expect(sources).to include(
          'message_definition_collection :Contacts', 'entity_message :Contact',
          'import_mapping :ReadContact', 'export_mapping :WriteContact',
          'message_definition: "MessageXml.Contacts.Contact"',
          ':xml_path => "Contacts|Contact"',
          'import_xml :Xml', 'export_xml :Contact'
        )
        expect(sources).not_to include(
          'native_document', 'deep_structure:', 'bson_binary(', 'native_fragment('
        )

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(integration_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
  end

  def certified_sources(exported)
    patterns = [
      File.join(exported, 'modules', 'MessageXml', 'application', 'use_cases', '*.rb'),
      File.join(exported, 'modules', 'MessageXml', 'infrastructure', 'mappings', '**', '*.rb')
    ]
    files = patterns.flat_map { Dir[_1] }
    files.sort.map { File.read(_1) }.join("\n")
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end

  def integration_ids(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        next unless integration_type?(document['$Type'])

        [document['$Type'], document['Name'], unit['UnitID'].to_s]
      end.sort
    end
  end

  def integration_type?(type)
    %w[
      MessageDefinitions$MessageDefinitionCollection ImportMappings$ImportMapping
      ExportMappings$ExportMapping Microflows$Microflow
    ].include?(type)
  end
end
# rubocop:enable Metrics/BlockLength
