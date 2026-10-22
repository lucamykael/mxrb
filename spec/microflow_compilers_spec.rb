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

  def model(units)
    Struct.new(:units_by_type) do
      def units_of(type) = units_by_type.fetch(type, [])
      def documents(_type = nil) = []
    end.new(units)
  end

  def unit(module_name, document)
    Mxrb::Compiler::SourceModel::Unit.new(id: Mxrb::IO::BsonCodec.extract_id(document['$ID']), container_id: id(1),
                                          containment: 'Documents', module_name:, document:)
  end

  it 'drops result variables the flow does not use and timeouts a REST call has off' do
    fields = {
      'Microflows$MicroflowCallAction' => %w[$ID $Type ResultVariableName],
      'Microflows$JavaActionCallAction' => %w[$ID $Type ResultVariableName],
      'Microflows$RestCallAction' => %w[$ID $Type RequestTimeOutExpression]
    }
    void = unit('App', node('Microflows$Microflow', 40, Name: 'Fire',
                                                        MicroflowReturnType: node('DataTypes$VoidType', 41)))
    text = unit('App', node('Microflows$Microflow', 42, Name: 'Say',
                                                        MicroflowReturnType: node('DataTypes$StringType', 43)))
    source = model('Microflows$Microflow' => [void, text])
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(schema(fields:, existing: {}), source:)
    call = node('Microflows$MicroflowCallAction', 44, ResultVariableName: 'Result', UseReturnVariable: true,
                                                      MicroflowCall: { 'Microflow' => 'App.Say' })
    expect(compiler.compile(call)).to include('ResultVariableName' => 'Result')
    expect(compiler.compile(call.merge('UseReturnVariable' => false))).to include('ResultVariableName' => '')
    expect(compiler.compile(call.merge('MicroflowCall' => { 'Microflow' => 'App.Fire' })))
      .to include('ResultVariableName' => '')
    java = node('Microflows$JavaActionCallAction', 45, ResultVariableName: 'Result', UseReturnVariable: false,
                                                       JavaAction: 'App.Run')
    expect(compiler.compile(java)).to include('ResultVariableName' => '')
    expect(compiler.compile(java.merge('UseReturnVariable' => true))).to include('ResultVariableName' => 'Result')
    rest = node('Microflows$RestCallAction', 46, TimeOutExpression: '30', UseRequestTimeOut: false)
    expect(compiler.compile(rest)).to include('RequestTimeOutExpression' => '0')
    expect(compiler.compile(rest.merge('UseRequestTimeOut' => true))).to include('RequestTimeOutExpression' => '30')
  end

  it 'retrieves single objects over one-to-one and cross-module associations' do
    fields = { 'Microflows$AssociationRetrieveSource' => %w[$ID $Type Type] }
    account = node('DomainModels$Entity', 50, Name: 'Account')
    region = node('DomainModels$CrossAssociation', 52, Name: 'Account_Region', ParentPointer: account['$ID'],
                                                       Child: 'Geo.Region', Type: 'ReferenceSet', Owner: 'Both')
    profile = node('DomainModels$CrossAssociation', 53, Name: 'Account_Profile', ParentPointer: account['$ID'],
                                                        Child: 'Geo.Profile', Type: 'Reference', Owner: 'Both')
    domain = unit('Admin', node('DomainModels$DomainModel', 51, Entities: [2, account], Associations: [2],
                                                                CrossAssociations: [2, region, profile]))
    source = model('DomainModels$DomainModel' => [domain])
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(schema(fields:, existing: {}), source:)
    compiler.prepare(node('Microflows$Microflow', 54, Objects: [
                            node('Microflows$MicroflowParameter', 55, Name: 'Account',
                                                                      VariableType: { 'Entity' => 'Admin.Account' }),
                            node('Microflows$MicroflowParameter', 56, Name: 'Profile',
                                                                      VariableType: { 'Entity' => 'Geo.Profile' })
                          ]))
    retrieve = node('Microflows$AssociationRetrieveSource', 57, AssociationId: 'Admin.Account_Region',
                                                                StartVariableName: 'Account')
    expect(compiler.compile(retrieve)['Type']).to eq('[Geo.Region]')
    one = retrieve.merge('AssociationId' => 'Admin.Account_Profile')
    expect(compiler.compile(one)['Type']).to eq('Geo.Profile')
    expect(compiler.compile(one.merge('StartVariableName' => 'Profile'))['Type']).to eq('Admin.Account')
  end

  it 'types variables from REST results, code actions and nanoflow calls and settles chains' do
    fields = { 'Microflows$AssociationRetrieveSource' => %w[$ID $Type Type] }
    order = node('DomainModels$Entity', 60, Name: 'Order')
    line = node('DomainModels$Entity', 61, Name: 'Line')
    association = node('DomainModels$Association', 62, Name: 'Line_Order', ParentPointer: line['$ID'],
                                                       ChildPointer: order['$ID'], Type: 'Reference', Owner: 'Default')
    domain = unit('App',
                  node('DomainModels$DomainModel', 63, Entities: [2, order, line], Associations: [2, association]))
    concrete = node('CodeActions$ConcreteEntityType', 65, Entity: 'App.Order')
    java = unit('App', node('JavaActions$JavaAction', 64, Name: 'Load', JavaReturnType: concrete))
    pointer = id(90)
    generic_return = node('CodeActions$ParameterizedEntityType', 92, TypeParameterPointer: pointer)
    holder_type = node('CodeActions$EntityTypeParameterType', 94, TypeParameterPointer: pointer)
    holder = node('JavaActions$JavaActionParameter', 93, Name: 'returnEntity', ParameterType: holder_type)
    generic = unit('App', node('JavaActions$JavaAction', 91, Name: 'Export', JavaReturnType: generic_return,
                                                             Parameters: [2, holder]))
    generic_list = node('CodeActions$ListType', 100, Parameter: generic_return)
    generic_all = unit('App', node('JavaActions$JavaAction', 101, Name: 'ExportAll', JavaReturnType: generic_list,
                                                                  Parameters: [2, holder]))
    loose_return = node('CodeActions$ParameterizedEntityType', 96, TypeParameterPointer: id(97))
    loose = unit('App',
                 node('JavaActions$JavaAction', 95, Name: 'Loose', JavaReturnType: loose_return, Parameters: [2]))
    list = node('CodeActions$ListType', 67, Parameter: node('CodeActions$ConcreteEntityType', 83, Entity: 'App.Order'))
    script = unit('App', node('JavaScriptActions$JavaScriptAction', 66, Name: 'Fetch', ActionReturnType: list))
    object = node('DataTypes$ObjectType', 69, Entity: 'App.Order')
    nano = unit('App', node('Microflows$Nanoflow', 68, Name: 'Pick', MicroflowReturnType: object))
    source = model('DomainModels$DomainModel' => [domain], 'JavaScriptActions$JavaScriptAction' => [script],
                   'JavaActions$JavaAction' => [java, generic, generic_all, loose], 'Microflows$Nanoflow' => [nano])
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(schema(fields:, existing: {}), source:)
    retrieve = lambda { |id, from|
      node('Microflows$RetrieveAction', id, ResultVariableName: "Lines#{id}", RetrieveSource: node(
        'Microflows$AssociationRetrieveSource', id + 100, AssociationId: 'App.Line_Order', StartVariableName: from
      ))
    }
    export_mapping = { 'Parameter' => 'App.Export.returnEntity', 'Value' => { 'Entity' => 'App.Order' } }
    export_all_mapping = { 'Parameter' => 'App.ExportAll.returnEntity', 'Value' => { 'Entity' => 'App.Order' } }
    compiler.prepare(node('Microflows$Microflow', 70, Objects: [
                            retrieve.call(71, 'Rest'), retrieve.call(72, 'Loaded'), retrieve.call(73, 'Picked'),
                            retrieve.call(74, 'Fetched'), retrieve.call(75, 'Lines71'),
                            node('Microflows$RestCallAction', 76, ResultHandling: node(
                              'Microflows$ResultHandling', 77, ResultVariableName: 'Rest',
                                                               VariableType: { 'Entity' => 'App.Order' }
                            )),
                            node('Microflows$JavaActionCallAction', 78, ResultVariableName: 'Loaded',
                                                                        JavaAction: 'App.Load'),
                            node('Microflows$JavaActionCallAction', 98, ResultVariableName: 'Exported',
                                                                        JavaAction: 'App.Export',
                                                                        ParameterMappings: [2, export_mapping]),
                            node('Microflows$JavaActionCallAction', 102, ResultVariableName: 'ExportedAll',
                                                                         JavaAction: 'App.ExportAll',
                                                                         ParameterMappings: [2, export_all_mapping]),
                            node('Microflows$JavaActionCallAction', 99, ResultVariableName: 'Lost',
                                                                        JavaAction: 'App.Loose',
                                                                        ParameterMappings: [2]),
                            node('Microflows$JavaScriptActionCallAction', 79, ResultVariableName: 'Fetched',
                                                                              JavaScriptAction: 'App.Fetch'),
                            node('Microflows$NanoflowCallAction', 80, OutputVariableName: 'Picked',
                                                                      NanoflowCall: { 'Nanoflow' => 'App.Pick' })
                          ]))
    types = compiler.instance_variable_get(:@variable_types)
    expect(types).to include('Rest' => 'App.Order', 'Loaded' => 'App.Order', 'Picked' => 'App.Order',
                             'Fetched' => '[App.Order]', 'Lines71' => '[App.Line]', 'Lines75' => 'Unknown',
                             'Exported' => 'App.Order', 'ExportedAll' => '[App.Order]')
    expect(types).not_to have_key('Lost')
    expect(compiler.compile(retrieve.call(81, 'Fetched')['RetrieveSource'])['Type']).to eq('Unknown')
    expect(compiler.compile(retrieve.call(82, 'Nobody')['RetrieveSource'])['Type']).to eq('App.Order')
  end

  it 'replaces an unconfigured external write with a Runtime no-op action' do
    fields = {
      'Microflows$LogMessageAction' => %w[
        $ID $Type MessageTemplate ErrorHandlingType Level Node IncludeLatestStackTrace
      ],
      'Microflows$StringTemplate' => %w[$ID $Type Parameters Text]
    }
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(schema(fields:, existing: {}))
    connector = instance_double(Mxrb::Compiler::DatabaseConnectorActionCompiler)
    allow(connector).to receive(:unconfigured_write?).and_return(true)
    compiler.instance_variable_set(:@database_connector, connector)
    action = node('DatabaseConnector$ExecuteDatabaseQueryAction', 29,
                  ErrorHandlingType: 'Rollback')

    compiled = compiler.compile(action)
    expect(compiled).to include(
      '$Type' => 'Microflows$LogMessageAction', 'Level' => 'Trace', 'Node' => "'Mxrb'"
    )
    expect(compiled['MessageTemplate']).to include(
      '$Type' => 'Microflows$StringTemplate', 'Parameters' => [], 'Text' => ''
    )
  end

  it 'derives Reference association cardinality from the retrieval direction' do
    fields = { 'Microflows$AssociationRetrieveSource' => %w[$ID $Type Type] }
    parent = node('DomainModels$Entity', 30, QualifiedName: 'App.Cell')
    child = node('DomainModels$Entity', 31, QualifiedName: 'App.Game')
    association = node(
      'DomainModels$Association', 32, QualifiedName: 'App.Cell_Game',
                                      ParentPointer: parent['$ID'], ChildPointer: child['$ID'], Type: 'Reference'
    )
    existing = { id(30) => parent, id(31) => child, 'App.Cell_Game' => association }
    compiler = Mxrb::Compiler::MicroflowNodeCompiler.new(schema(fields:, existing:))
    compiler.prepare(node('Microflows$Microflow', 33, Objects: [
                            node('Microflows$MicroflowParameter', 34, Name: 'Cell',
                                                                      VariableType: { 'Entity' => 'App.Cell' }),
                            node('Microflows$MicroflowParameter', 35, Name: 'Game',
                                                                      VariableType: { 'Entity' => 'App.Game' })
                          ]))

    from_cell = compiler.compile(node('Microflows$AssociationRetrieveSource', 36,
                                      AssociationId: 'App.Cell_Game', StartVariableName: 'Cell'))
    from_game = compiler.compile(node('Microflows$AssociationRetrieveSource', 37,
                                      AssociationId: 'App.Cell_Game', StartVariableName: 'Game'))

    expect(from_cell['Type']).to eq('App.Game')
    expect(from_game['Type']).to eq('[App.Cell]')
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
