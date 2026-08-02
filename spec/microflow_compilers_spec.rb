# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Runtime microflow compilers' do
  def schema(fields:, existing:)
    Struct.new(:fields, :existing) do
      def fields_for(source) = fields.fetch(source.fetch('$Type'))
      def counterpart(source) = existing[Mxrb::IO::BsonCodec.extract_id(source['$ID'])]
      def counterpart_id(id) = existing[Mxrb::IO::BsonCodec.extract_id(id)]
      def named(name) = existing[name]
    end.new(fields, existing)
  end

  def source(security)
    Struct.new(:security) do
      def documents(type) = type == 'Security$ProjectSecurity' && security ? [security] : []
    end.new(security)
  end

  def id(number) = format('00000000-0000-4000-8000-%012d', number)

  def node(type, number, **fields)
    { '$ID' => id(number), '$Type' => type }.merge(fields.transform_keys(&:to_s))
  end

  it 'recursively compiles renamed, derived, default, and preserved node fields' do
    fields = {
      'Microflows$CreateVariableAction' => %w[$ID $Type Type],
      'Microflows$BasicCodeActionParameterValue' => %w[$ID $Type ValueExpression],
      'Microflows$MappingRequestHandling' => %w[$ID $Type ContentTypeRuntime],
      'Microflows$RestCallAction' => %w[$ID $Type RequestTimeOutExpression],
      'Microflows$ResultHandling' => %w[$ID $Type VariableDataType],
      'Microflows$ActionActivity' => %w[$ID $Type Caption Disabled],
      'Microflows$NoCase' => %w[$ID $Type StringRepresentation],
      'Microflows$InheritanceCase' => %w[$ID $Type StringRepresentation],
      'Test$Value' => %w[$ID $Type QueueSettings StringRepresentation IsRequired Disabled DefaultValue],
      'Test$Existing' => %w[$ID $Type Preserved]
    }
    activity = node('Microflows$ActionActivity', 6, Disabled: false)
    runtime_schema = schema(fields:, existing: { id(6) => activity.merge('Caption' => 'Compiled caption') })
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(runtime_schema)

    expect(compiler.compile('plain' => [3, 'value'])).to eq('plain' => ['value'])
    expect(compiler.compile(node('Microflows$CreateVariableAction', 1,
                                 VariableType: node('DataTypes$ObjectType', 11, Entity: 'App.Item'))))
      .to include('Type' => 'App.Item')
    expect(compiler.compile(node('Microflows$BasicCodeActionParameterValue', 2, Argument: '42')))
      .to include('ValueExpression' => '42')
    expect(compiler.compile(node('Microflows$MappingRequestHandling', 3, ContentType: 'JSON')))
      .to include('ContentTypeRuntime' => 'JSON')
    expect(compiler.compile(node('Microflows$RestCallAction', 4, TimeOutExpression: '30')))
      .to include('RequestTimeOutExpression' => '30')
    expect(compiler.compile(node('Microflows$ResultHandling', 5,
                                 VariableType: node('DataTypes$EnumerationType', 12,
                                                    Enumeration: 'App.State'))))
      .to include('VariableDataType' => '#App.State')
    expect(compiler.compile(activity)).to include('Caption' => 'Compiled caption')
    expect(compiler.compile(node('Microflows$NoCase', 7))).to include('StringRepresentation' => '')
    expect(compiler.compile(node('Microflows$InheritanceCase', 70, Value: '')))
      .to include('StringRepresentation' => '(empty)')
    expect(compiler.compile(node('Test$Value', 8, Value: 7))).to include(
      'QueueSettings' => nil, 'StringRepresentation' => '7',
      'IsRequired' => false, 'Disabled' => false, 'DefaultValue' => ''
    )
    preserved = node('Test$Existing', 9)
    runtime_schema.existing[id(9)] = preserved.merge('Preserved' => 'runtime')
    expect(compiler.compile(preserved)).to include('Preserved' => 'runtime')
  end

  it 'compiles custom ranges and derives database and association retrieve types' do
    fields = {
      'Microflows$DatabaseRetrieveSource' => %w[$ID $Type Type],
      'Microflows$AssociationRetrieveSource' => %w[$ID $Type Type],
      'Test$Retrieve' => %w[$ID $Type Type]
    }
    parent = node('DomainModels$Entity', 10, QualifiedName: 'App.Parent')
    child = node('DomainModels$Entity', 11, QualifiedName: 'App.Item')
    association_model = node(
      'DomainModels$Association', 12, QualifiedName: 'App.Parent_Item',
                                      ParentPointer: parent['$ID'], ChildPointer: child['$ID'], Type: 'ReferenceSet'
    )
    existing = { id(10) => parent, id(11) => child, 'App.Parent_Item' => association_model }
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(schema(fields:, existing:))
    compiler.prepare(node('Microflows$Microflow', 20, Objects: [
                            node('Microflows$MicroflowParameter', 21, Name: 'Parent',
                                                                      VariableType: { 'Entity' => 'App.Parent' })
                          ]))
    custom = compiler.compile(node('Microflows$CustomRange', 1, SingleObject: true))
    single = compiler.compile(node('Microflows$DatabaseRetrieveSource', 2, Entity: 'App.Item',
                                                                           Range: { 'SingleObject' => true }))
    list = compiler.compile(node('Microflows$DatabaseRetrieveSource', 3, Entity: 'App.Item', Range: {}))
    association = compiler.compile(node('Microflows$AssociationRetrieveSource', 4,
                                        AssociationId: 'App.Parent_Item', StartVariableName: 'Parent'))

    expect(custom).to include('$Type' => 'Microflows$ConstantRange', 'SingleObject' => true)
    expect(custom['$ID']).to match(/\A[0-9a-f-]{36}\z/)
    expect(single['Type']).to eq('App.Item')
    expect(list['Type']).to eq('[App.Item]')
    expect(association['Type']).to eq('[App.Item]')
    expect { compiler.compile(node('Test$Retrieve', 5)) }
      .to raise_error(Mxrb::CompilationError, /cannot derive Runtime retrieve type/)
  end

  it 'rejects fields and data types that cannot be derived' do
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(
      schema(fields: { 'Test$Node' => %w[$ID $Type Missing],
                       'Microflows$CreateVariableAction' => %w[$ID $Type Type] }, existing: {})
    )
    expect { compiler.compile(node('Test$Node', 1)) }
      .to raise_error(Mxrb::CompilationError, /cannot derive Runtime field/)
    expect do
      compiler.compile(node('Microflows$CreateVariableAction', 2,
                            VariableType: node('DataTypes$BinaryType', 3)))
    end.to raise_error(Mxrb::CompilationError, /unsupported Runtime data type/)
  end

  it 'compiles root defaults, existing values, roles, and all supported scalar types' do
    root_fields = %w[$ID $Type ObjectCollection SequenceFlows ConcurrenyErrorMessage UrlSegments
                     Name QualifiedName ReturnType ApplyEntityAccess ModelerAllowedUserRoles
                     AllowConcurrentExecution ConcurrencyErrorMicroflow Url UrlSearchParameters Existing]
    node_fields = {
      'Microflows$MicroflowObjectCollection' => %w[$ID $Type Objects],
      'Microflows$StartEvent' => %w[$ID $Type]
    }
    role = { 'Name' => 'User', 'ModuleRoles' => ['App.User'] }
    security = { 'UserRoles' => [role] }
    unit = Mxrb::Compiler::SourceModel::Unit.new(
      id: id(1), container_id: id(1), containment: 'Documents', module_name: 'App',
      document: node('Microflows$Microflow', 1, Name: 'Run',
                                                ObjectCollection: node('Microflows$MicroflowObjectCollection', 2,
                                                                       Objects: [node('Microflows$StartEvent', 3)]),
                                                Flows: [], MicroflowReturnType: node('DataTypes$StringType', 4),
                                                AllowedModuleRoles: ['App.User'])
    )
    existing = { id(1) => { 'Existing' => 'kept' } }
    runtime_schema = schema(fields: node_fields.merge('Microflows$Microflow' => root_fields), existing:)
    compiled = Mxrb::Compiler::MicroflowDocumentCompiler.new(source(security), runtime_schema).compile(unit)

    expect(compiled).to include(
      'QualifiedName' => 'App.Run', 'ReturnType' => 'String', 'ApplyEntityAccess' => false,
      'ModelerAllowedUserRoles' => ['User'], 'AllowConcurrentExecution' => false,
      'ConcurrencyErrorMicroflow' => '', 'Url' => '', 'UrlSearchParameters' => [], 'Existing' => 'kept'
    )
    expect(compiled['ConcurrenyErrorMessage']).to include('$Type' => 'Texts$Text')
  end

  it 'handles absent security and rejects unsupported roots and root fields' do
    runtime_schema = schema(fields: {
      'Microflows$Rule' => %w[$ID $Type ModelerAllowedUserRoles Unknown],
      'Other$Flow' => %w[$ID $Type]
    }, existing: {})
    compiler = Mxrb::Compiler::MicroflowDocumentCompiler.new(source(nil), runtime_schema)
    rule = Mxrb::Compiler::SourceModel::Unit.new(
      id: id(1), container_id: id(1), containment: 'Documents', module_name: 'App',
      document: node('Microflows$Rule', 1, AllowedModuleRoles: [])
    )
    expect { compiler.compile(rule) }.to raise_error(Mxrb::CompilationError, /cannot derive Runtime root field/)
    other = rule.with(document: node('Other$Flow', 2))
    expect { compiler.compile(other) }.to raise_error(Mxrb::CompilationError, /unsupported flow root/)
  end
end
# rubocop:enable Metrics/BlockLength
