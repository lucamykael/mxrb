# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Compiler::CodeActionMaterializer do
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
      self.module(:App) do
        native_document :Select, type: 'JavaActions$JavaAction', deep_structure: {
          'Parameters' => Mxrb::IO::BsonCodec.build_array([
                                                            {
                                                              '$ID' => '11111111-1111-4111-8111-111111111111',
                                                              '$Type' => 'JavaActions$JavaActionParameter',
                                                              'Name' => 'Items', 'ParameterType' => {
                                                                '$Type' => 'CodeActions$BasicParameterType',
                                                                'Type' => {
                                                                  '$Type' => 'CodeActions$ListType',
                                                                  'Parameter' => {
                                                                    '$Type' => 'CodeActions$ConcreteEntityType',
                                                                    'Entity' => 'App.Item'
                                                                  }
                                                                }
                                                              }
                                                            },
                                                            {
                                                              '$ID' => '22222222-2222-4222-8222-222222222222',
                                                              '$Type' => 'JavaActions$JavaActionParameter',
                                                              'Name' => 'Callback', 'ParameterType' => {
                                                                '$Type' =>
                                                                  'JavaActions$MicroflowJavaActionParameterType'
                                                              }
                                                            }
                                                          ]),
          'JavaReturnType' => { '$Type' => 'CodeActions$EnumerationType',
                                'Enumeration' => 'App.State' }
        }
        native_document :Notify, type: 'JavaScriptActions$JavaScriptAction', deep_structure: {
          'Parameters' => Mxrb::IO::BsonCodec.build_array([
                                                            {
                                                              '$ID' => '33333333-3333-4333-8333-333333333333',
                                                              '$Type' => 'JavaScriptActions$JavaScriptActionParameter',
                                                              'Name' => 'Message'
                                                            }
                                                          ])
        }
      end
    end
  end

  def prepare_model
    project = Mxrb::Compiler::SourceModel.read(@mpr).units_of('Projects$Project').first.document
    path = File.join(@deployment, 'model', 'model.mdp')
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, Mxrb::IO::BsonCodec.serialize('$ID' => project['$ID'], '$Type' => project['$Type']))
  end

  it 'materializes Java and JavaScript action signatures' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    documents = Mxrb::Compiler::ModelPackage.read(result.model_path).documents
    java = documents.find { _1['$Type'] == 'JavaActions$JavaAction' }
    javascript = documents.find { _1['$Type'] == 'JavaScriptActions$JavaScriptAction' }

    expect(result).to have_attributes(java_actions: 1, javascript_actions: 1)
    expect(java).to include('QualifiedName' => 'App.Select', 'ReturnType' => '#App.State')
    expect(java['Parameters'].map { _1['Type'] }).to eq(['[App.Item]', 'String'])
    expect(javascript).to include('QualifiedName' => 'App.Notify')
    expect(javascript['Parameters'].first.keys).to eq(%w[$ID $Type Name])
  end

  it 'maps all structural code-action types and rejects unsupported ones' do
    types = Class.new do
      include Mxrb::Compiler::CodeActionTypeCompiler
      def compile(value) = code_action_type(value)
    end.new

    expect(types.compile(nil)).to eq('Void')
    expect(types.compile('$Type' => 'CodeActions$BooleanType')).to eq('Boolean')
    expect(types.compile('$Type' => 'CodeActions$ConcreteEntityType', 'Entity' => 'App.Item')).to eq('App.Item')
    expect(types.compile('$Type' => 'CodeActions$EnumerationType', 'Enumeration' => 'App.State')).to eq('#App.State')
    expect(types.compile('$Type' => 'CodeActions$ParameterizedEntityType')).to eq('Unknown')
    expect(types.compile('$Type' => 'CodeActions$ListType',
                         'Parameter' => { '$Type' => 'CodeActions$ParameterizedEntityType' })).to eq('[Unknown]')
    expect { types.compile('$Type' => 'CodeActions$BinaryType') }
      .to raise_error(Mxrb::CompilationError, /unsupported code-action type/)
  end

  it 'rejects unsupported and module-less code actions' do
    compiler = Mxrb::Compiler::CodeActionDocumentCompiler.new
    unit = Mxrb::Compiler::SourceModel::Unit.new(
      id: 'test', container_id: 'test', containment: 'Documents', module_name: 'App',
      document: { '$ID' => 'test', '$Type' => 'Test$Action', 'Name' => 'Unknown' }
    )
    expect { compiler.compile(unit) }.to raise_error(Mxrb::CompilationError, /unsupported code action/)
    java = unit.with(module_name: nil, document: {
      '$ID' => 'test', '$Type' => 'JavaActions$JavaAction', 'Name' => 'Orphan',
      'Parameters' => [], 'JavaReturnType' => nil
    })
    expect { compiler.compile(java) }.to raise_error(Mxrb::CompilationError, /outside a module/)
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
