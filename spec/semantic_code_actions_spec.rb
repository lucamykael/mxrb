# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'semantic code action documents' do
  it 'round-trips Java and JavaScript action contracts as typed Ruby' do
    Dir.mktmpdir('mxrb-code-actions-') do |dir|
      source = File.join(dir, 'Actions.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:Actions) {}
      end
      insert_actions(source)

      Mxrb::Exporter.new(source, exported).export!
      ruby = Dir[File.join(exported, 'modules', 'Actions', 'application', 'actions', '**', '*.rb')]
             .sort.map { File.read(_1) }.join("\n")
      expect(ruby).to include(
        'java_action :Normalize', 'javascript_action :Notify',
        ':kind => :entity_type_parameter', ':kind => :list',
        ':kind => :string_template', 'platform: "Web"'
      )
      expect(ruby).not_to include('native_document', 'deep_structure:', 'bson_binary(')
      native_source = File.read(File.join(exported, '.mxrb', 'native_units.rb'))
      expect(native_source).not_to include('JavaActions$JavaAction', 'JavaScriptActions$JavaScriptAction')

      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(action_documents(rebuilt)).to eq(action_documents(source))
    end
  end

  def insert_actions(path) # rubocop:disable Metrics/AbcSize
    mpr = Mxrb::IO::MprFile.open(path)
    module_id = mpr.units_by_containment('Modules').first.fetch('UnitID')
    type_parameter_id = SecureRandom.uuid
    mpr.insert_unit(
      container_uuid: module_id, containment_name: 'Documents',
      contents_doc: action_document(
        'JavaActions$JavaAction', 'Normalize',
        parameters: [{
          '$ID' => SecureRandom.uuid, '$Type' => 'JavaActions$JavaActionParameter',
          'Category' => 'Input', 'Description' => 'Value to normalize', 'IsRequired' => true,
          'Name' => 'input', 'ParameterType' => {
            '$ID' => SecureRandom.uuid, '$Type' => 'CodeActions$EntityTypeParameterType',
            'TypeParameterPointer' => type_parameter_id
          }
        }],
        return_type: {
          '$ID' => SecureRandom.uuid, '$Type' => 'CodeActions$ListType',
          'Parameter' => {
            '$ID' => SecureRandom.uuid, '$Type' => 'CodeActions$ParameterizedEntityType',
            'TypeParameterPointer' => type_parameter_id
          }
        },
        type_parameters: [{
          '$ID' => type_parameter_id, '$Type' => 'CodeActions$TypeParameter', 'Name' => 'Entity'
        }]
      )
    )
    javascript = action_document(
      'JavaScriptActions$JavaScriptAction', 'Notify',
      parameters: [{
        '$ID' => SecureRandom.uuid, '$Type' => 'JavaScriptActions$JavaScriptActionParameter',
        'Category' => '', 'Description' => '', 'IsRequired' => false, 'Name' => 'message',
        'ParameterType' => {
          '$ID' => SecureRandom.uuid, '$Type' => 'CodeActions$StringTemplateParameterType',
          'Grammar' => 'Text'
        }
      }],
      return_type: { '$ID' => SecureRandom.uuid, '$Type' => 'CodeActions$VoidType' }
    )
    javascript['Platform'] = 'Web'
    mpr.insert_unit(
      container_uuid: module_id, containment_name: 'Documents', contents_doc: javascript
    )
  ensure
    mpr&.close
  end

  def action_document(type, name, parameters:, return_type:, type_parameters: [])
    {
      '$Type' => type, 'ActionDefaultReturnName' => 'ReturnValueName',
      'Documentation' => 'Contract documentation', 'Excluded' => false,
      'ExportLevel' => 'Hidden', 'JavaReturnType' => return_type,
      'MicroflowActionInfo' => {
        '$ID' => SecureRandom.uuid, '$Type' => 'CodeActions$MicroflowActionInfo',
        'Caption' => name, 'Category' => 'Tests',
        'IconData' => BSON::Binary.new('icon'), 'IconDataDark' => BSON::Binary.new('dark'),
        'ImageData' => BSON::Binary.new('image'), 'ImageDataDark' => BSON::Binary.new('dark-image')
      },
      'Name' => name,
      'Parameters' => Mxrb::IO::BsonCodec.build_array(parameters, marker: 2),
      'TypeParameters' => Mxrb::IO::BsonCodec.build_array(type_parameters, marker: 2)
    }
  end

  def action_documents(path)
    Mxrb.open(path) do |project|
      documents = project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        document if %w[JavaActions$JavaAction JavaScriptActions$JavaScriptAction].include?(document['$Type'])
      end
      documents.sort_by { _1['Name'] }
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
