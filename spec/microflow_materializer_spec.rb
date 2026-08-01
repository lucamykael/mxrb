# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Compiler::MicroflowMaterializer do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'App.mpr')
      @deployment = File.join(root, 'deployment')
      define_project
      prepare_model
      example.run
    end
  end

  def define_project
    Mxrb.define(@mpr) do
      mendix_version '11.12.1'
      security do
        user_role :User, module_roles: ['App.User']
      end
      self.module(:App) do
        module_role :User
        microflow(:Count, public: true) do
          allowed_roles 'App.User'
          return_type :Integer
          return_value '1'
        end
      end
    end
  end

  def prepare_model
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    @flow = source.units_of('Microflows$Microflow').first.document
    collection = @flow.fetch('ObjectCollection')
    start_event, end_event = collection.fetch('Objects').drop(1)
    sequence = @flow.fetch('Flows').drop(1).first
    runtime = {
      '$ID' => @flow['$ID'], '$Type' => @flow['$Type'],
      'ObjectCollection' => {
        '$ID' => collection['$ID'], '$Type' => collection['$Type'],
        'Objects' => [
          { '$ID' => start_event['$ID'], '$Type' => start_event['$Type'] },
          { '$ID' => end_event['$ID'], '$Type' => end_event['$Type'], 'ReturnValue' => 'stale' }
        ]
      },
      'SequenceFlows' => [{
        '$ID' => sequence['$ID'], '$Type' => sequence['$Type'],
        'CaseValues' => [{ '$ID' => sequence.dig('CaseValues', 1, '$ID'),
                           '$Type' => 'Microflows$NoCase', 'StringRepresentation' => '' }],
        'OriginPointer' => sequence['OriginPointer'],
        'DestinationPointer' => sequence['DestinationPointer'], 'IsErrorHandler' => false
      }],
      'ConcurrenyErrorMessage' => { '$ID' => '22222222-2222-4222-8222-222222222222',
                                    '$Type' => 'Texts$Text' },
      'UrlSegments' => [], 'Name' => 'Stale', 'QualifiedName' => 'Stale.Count',
      'ReturnType' => 'Void', 'ApplyEntityAccess' => false, 'ModelerAllowedUserRoles' => [],
      'AllowConcurrentExecution' => false, 'ConcurrencyErrorMicroflow' => '', 'Url' => '',
      'UrlSearchParameters' => []
    }
    path = File.join(@deployment, 'model', 'model.mdp')
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, Mxrb::IO::BsonCodec.serialize(runtime))
  end

  it 'compiles ordered flow graphs, return types, names, and project roles' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    flow = Mxrb::Compiler::ModelPackage.read(result.model_path).find(
      Mxrb::IO::BsonCodec.extract_id(@flow['$ID'])
    ).document

    expect(result).to have_attributes(microflows: 1, nanoflows: 0, rules: 0)
    expect(flow.keys).to eq(
      %w[$ID $Type ObjectCollection SequenceFlows ConcurrenyErrorMessage UrlSegments Name
         QualifiedName ReturnType ApplyEntityAccess ModelerAllowedUserRoles AllowConcurrentExecution
         ConcurrencyErrorMicroflow Url UrlSearchParameters]
    )
    expect(flow).to include(
      'Name' => 'Count', 'QualifiedName' => 'App.Count', 'ReturnType' => 'Integer',
      'ModelerAllowedUserRoles' => ['User'], 'AllowConcurrentExecution' => true
    )
    expect(flow.dig('ObjectCollection', 'Objects', 1, 'ReturnValue')).to eq('1')
    expect(flow.dig('SequenceFlows', 0, 'CaseValues', 0, 'StringRepresentation')).to eq('')
  end

  it 'uses the built-in Runtime schema for a fresh model package' do
    File.binwrite(File.join(@deployment, 'model', 'model.mdp'),
                  Mxrb::IO::BsonCodec.serialize('$ID' => 'missing', '$Type' => 'Projects$Project'))
    result = described_class.new(@mpr, deployment: @deployment).materialize
    expect(result.microflows).to eq(1)
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
