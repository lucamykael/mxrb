# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
SEMANTIC_ARTIFACT_TYPES = %w[
  Microflows$Rule Queues$Queue RegularExpressions$RegularExpression
].freeze

RSpec.describe 'semantic artifact documents' do
  it 'round-trips rules, task queues, and regular expressions as typed Ruby' do
    Dir.mktmpdir('mxrb-semantic-artifacts-') do |dir|
      source = File.join(dir, 'Artifacts.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:Operations) {}
      end
      insert_artifacts(source)

      Mxrb::Exporter.new(source, exported).export!
      ruby = Dir[File.join(exported, 'modules', 'Operations', '**', '*.rb')]
             .sort.map { File.read(_1) }.join("\n")
      expect(ruby).to include(
        'rule :CanProceed', 'task_queue :BackgroundWork',
        'parallelism_expression: "4"', 'regular_expression :ReferenceCode'
      )
      expect(ruby).not_to include('native_document', 'deep_structure:', 'bson_binary(')
      native_source = File.read(File.join(exported, '.mxrb', 'native_units.rb'))
      SEMANTIC_ARTIFACT_TYPES.each { expect(native_source).not_to include(_1) }

      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(artifact_documents(rebuilt)).to eq(artifact_documents(source))
    end
  end

  it 'rejects ambiguous task queue parallelism declarations' do
    builder = Mxrb::Dsl::ModuleBuilder.new(:Operations)
    expect { builder.task_queue(:Missing) }.to raise_error(ArgumentError, /exactly one/)
    expect do
      builder.task_queue(:Ambiguous, parallelism: 2, parallelism_expression: '2')
    end.to raise_error(ArgumentError, /exactly one/)
  end

  def insert_artifacts(path)
    mpr = Mxrb::IO::MprFile.open(path)
    module_id = mpr.units_by_containment('Modules').first.fetch('UnitID')
    [rule_document, queue_document, regular_expression_document].each do |document|
      mpr.insert_unit(
        container_uuid: module_id, containment_name: 'Documents', contents_doc: document
      )
    end
  ensure
    mpr&.close
  end

  def rule_document
    start = node('Microflows$StartEvent', 'RelativeMiddlePoint' => '100;100', 'Size' => '20;20')
    finish = node(
      'Microflows$EndEvent', 'Documentation' => '', 'RelativeMiddlePoint' => '300;100',
                             'ReturnValue' => '$Allowed', 'Size' => '20;20'
    )
    parameter = node('Microflows$MicroflowParameter', {
      'DefaultValue' => '', 'Documentation' => '',
      'HasVariableNameBeenChanged' => false,
      'IsRequired' => true, 'Name' => 'Allowed',
      'RelativeMiddlePoint' => '100;180', 'Size' => '30;30',
      'VariableType' => node('DataTypes$BooleanType')
    })
    {
      '$Type' => 'Microflows$Rule', 'ApplyEntityAccess' => false, 'Documentation' => '',
      'Excluded' => false, 'ExportLevel' => 'Hidden',
      'Flows' => Mxrb::IO::BsonCodec.build_array([sequence_flow(start, finish)]),
      'MarkAsUsed' => false, 'MicroflowReturnType' => node('DataTypes$BooleanType'),
      'Name' => 'CanProceed',
      'ObjectCollection' => node(
        'Microflows$MicroflowObjectCollection',
        'Objects' => Mxrb::IO::BsonCodec.build_array([start, parameter, finish])
      ),
      'ReturnVariableName' => ''
    }
  end

  def queue_document
    {
      '$Type' => 'Queues$Queue',
      'Config' => node(
        'Queues$BasicQueueConfig', 'ClusterWide' => false, 'ParallelismExpression' => '4'
      ),
      'Documentation' => 'Background processing', 'Excluded' => false,
      'ExportLevel' => 'Hidden', 'Name' => 'BackgroundWork'
    }
  end

  def regular_expression_document
    {
      '$Type' => 'RegularExpressions$RegularExpression',
      'Documentation' => 'Public reference format', 'Excluded' => false,
      'ExportLevel' => 'Hidden', 'Expression' => '\\A[A-Z]{2}-\\d{4}\\z',
      'Name' => 'ReferenceCode'
    }
  end

  def sequence_flow(origin, destination)
    node(
      'Microflows$SequenceFlow',
      'CaseValues' => Mxrb::IO::BsonCodec.build_array(
        [node('Microflows$NoCase')], marker: 2
      ),
      'DestinationConnectionIndex' => 3, 'DestinationPointer' => destination.fetch('$ID'),
      'IsErrorHandler' => false,
      'Line' => node(
        'Microflows$BezierCurve', 'DestinationControlVector' => '0;0',
                                  'OriginControlVector' => '0;0'
      ),
      'OriginConnectionIndex' => 1, 'OriginPointer' => origin.fetch('$ID')
    )
  end

  def node(type, fields = {})
    { '$ID' => SecureRandom.uuid, '$Type' => type }.merge(fields)
  end

  def artifact_documents(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [[document['$Type'], document['Name']], document] if
          SEMANTIC_ARTIFACT_TYPES.include?(document['$Type'])
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
