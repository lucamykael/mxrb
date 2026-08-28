# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'semantic integration documents' do # rubocop:disable Metrics/BlockLength
  it 'round-trips JSON structures and mappings as typed Ruby without opaque BSON' do
    Dir.mktmpdir('mxrb-semantic-integrations-') do |dir|
      source = File.join(dir, 'Semantic.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      build_source(source)

      Mxrb::Exporter.new(source, exported).export!
      ruby_files = Dir[File.join(exported, 'modules', 'Integration', 'infrastructure',
                                 'mappings', '**', '*.rb')]
      ruby = ruby_files.map { File.read(_1) }.join("\n")
      expect(ruby).to include('json_structure :Payload', 'import_mapping :ReadPayload',
                              'export_mapping :WritePayload')
      expect(ruby).not_to include('native_document', 'deep_structure:', 'bson_binary(')

      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(integration_documents(rebuilt)).to eq(integration_documents(source))
    end
  end

  def build_source(path) # rubocop:disable Metrics/MethodLength
    value = {
      id: SecureRandom.uuid, kind: :value, name: 'Code', path: '(Object)|code',
      primitive: :string, original: '"A-1"', min_occurs: 0, max_occurs: 1,
      nillable: true, max_length: 20
    }
    mapped_value = {
      id: SecureRandom.uuid, kind: :value, name: 'Code', json_path: '(Object)|code',
      attribute: 'Integration.Payload.Code', type: :string, type_id: SecureRandom.uuid,
      primitive: :string, min_occurs: 0, max_occurs: 1, nillable: true, max_length: 20
    }
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Integration) do
        json_structure :Payload, snippet: '{"code":"A-1"}', elements: [{
          id: SecureRandom.uuid, kind: :object, name: 'Root', path: '(Object)',
          primitive: :unknown, min_occurs: 1, max_occurs: 1, children: [value]
        }]
        import_mapping :ReadPayload, json_structure: 'Integration.Payload', elements: [{
          id: SecureRandom.uuid, kind: :object, name: 'Root', json_path: '(Object)',
          entity: 'Integration.Payload', min_occurs: 1, object_handling: :create,
          children: [mapped_value]
        }]
        export_mapping :WritePayload, json_structure: 'Integration.Payload', elements: [{
          id: SecureRandom.uuid, kind: :object, name: 'Root', json_path: '(Object)',
          entity: 'Integration.Payload', min_occurs: 1, object_handling: :parameter,
          backup_handling: :error, children: [mapped_value]
        }]
      end
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end

  def integration_documents(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [[document['$Type'], document['Name']], document] if semantic_types.include?(document['$Type'])
      end.to_h
    end
  end

  def semantic_types
    %w[JsonStructures$JsonStructure ImportMappings$ImportMapping ExportMappings$ExportMapping]
  end
end
