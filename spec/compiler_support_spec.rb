# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Compiler support branches' do
  def source(security = nil)
    Struct.new(:security) do
      def documents(type = nil)
        return security ? [security] : [] if type == 'Security$ProjectSecurity'

        []
      end
    end.new(security)
  end

  def id(number) = format('00000000-0000-4000-8000-%012d', number)

  it 'normalizes nil, scalar, hash, and array model values' do
    values = Class.new do
      include Mxrb::Compiler::ModelValues
      def normalize(value) = plain_document(value)
      def normalize_array(value) = plain_array(value)
    end.new

    expect(values.normalize(nil)).to be_nil
    expect(values.normalize_array(nil)).to eq([])
    expect(values.normalize_array([3, 'item'])).to eq(['item'])
    expect(values.normalize('Value' => [3, { 'Nested' => [1, 'item'] }]))
      .to eq('Value' => [{ 'Nested' => ['item'] }])
  end

  it 'maps a nil Runtime return type and rejects module-less constants' do
    types = Class.new do
      include Mxrb::Compiler::RuntimeDataTypes
      def convert(value) = data_type(value)
    end.new
    expect(types.convert(nil)).to eq('Void')

    unit = Mxrb::Compiler::SourceModel::Unit.new(
      id: id(1), container_id: id(1), containment: 'Documents', module_name: nil,
      document: { '$ID' => id(1), '$Type' => 'Constants$Constant', 'Name' => 'Orphan' }
    )
    constants_source = Struct.new(:unit) { def units_of(_type) = [unit] }.new(unit)
    compiler = Mxrb::Compiler::ConstantsMaterializer.new('/tmp/unused', deployment: '/tmp/unused')
    expect { compiler.send(:compile, constants_source) }
      .to raise_error(Mxrb::CompilationError, /outside a module/)
  end

  it 'compiles both association shapes, delete behaviors, and absent project security' do
    compiler = Mxrb::Compiler::DomainSecurityCompiler.new(source)
    base = {
      '$ID' => id(1), '$Type' => 'DomainModels$Association', 'Name' => 'Owner_Items',
      'DeleteBehavior' => {
        '$ID' => id(2), '$Type' => 'DomainModels$DeleteBehavior',
        'ParentErrorMessage' => nil, 'ChildErrorMessage' => nil,
        'ParentDeleteBehavior' => 'NoAction', 'ChildDeleteBehavior' => 'DeleteMe'
      },
      'Source' => 'App.Owner', 'GUID' => id(3), 'Type' => 'ReferenceSet', 'Owner' => 'Default',
      'StorageFormat' => 'Table', 'ParentPointer' => id(4), 'ChildPointer' => id(5)
    }
    association = compiler.association(base, 'App')
    cross_source = base.merge('$Type' => 'DomainModels$CrossAssociation', 'Child' => 'App.Item')
    cross = compiler.association(cross_source, 'App')

    expect(association).to include('QualifiedName' => 'App.Owner_Items', 'ChildPointer' => id(5))
    expect(cross).to include('Child' => 'App.Item')
    expect(association.dig('DeleteBehavior', 'ParentDeleteBehavior')).to eq('DeleteMeAndReferences')
    expect(association.dig('DeleteBehavior', 'ChildDeleteBehavior')).to eq('DeleteMe')
  end

  it 'compiles association lists and generalized entity flags' do
    compiler = Mxrb::Compiler::DomainDocumentCompiler.new(source)
    security = Mxrb::Compiler::DomainSecurityCompiler.new(source)
    allow(compiler).to receive(:compile_entity).and_return('entity')
    allow(security).to receive(:association).and_return('association')
    compiler.instance_variable_set(:@security, security)
    unit = Mxrb::Compiler::SourceModel::Unit.new(
      id: id(1), container_id: id(1), containment: 'DomainModel', module_name: 'App',
      document: {
        '$ID' => id(1), '$Type' => 'DomainModels$DomainModel', 'Entities' => [Object.new],
        'Associations' => [Object.new], 'CrossAssociations' => [Object.new]
      }
    )

    expect(compiler.compile(unit)).to include(
      'Entities' => ['entity'], 'Associations' => ['association'],
      'CrossAssociations' => ['association']
    )
    generalization = compiler.send(
      :compile_generalization,
      '$ID' => id(2), '$Type' => 'DomainModels$Generalization', 'Generalization' => 'System.User'
    )
    expect(generalization).not_to have_key('Key')
    expect(generalization).to include('Persistable' => true, 'HasOwnerAttr' => true)
  end

  it 'compiles OQL view sources and inherits local, System, and unknown parent flags' do
    view = Mxrb::Compiler::SourceModel::Unit.new(
      id: id(8), container_id: id(1), containment: 'Documents', module_name: 'App',
      document: { '$ID' => id(8), '$Type' => 'DomainModels$ViewEntitySourceDocument',
                  'Name' => 'Users', 'Oql' => 'SELECT Name FROM App.User' }
    )
    parent = {
      'Name' => 'Parent', 'MaybeGeneralization' => {
        '$Type' => 'DomainModels$Generalization', 'Generalization' => 'System.User'
      }
    }
    domain = Mxrb::Compiler::SourceModel::Unit.new(
      id: id(9), container_id: id(1), containment: 'DomainModel', module_name: 'App',
      document: { '$Type' => 'DomainModels$DomainModel', 'Entities' => [2, parent] }
    )
    indexed = Struct.new(:units) do
      def units_of(_type) = [units.last]
      def documents(_type = nil) = []
    end.new([view, domain])
    compiler = Mxrb::Compiler::DomainDocumentCompiler.new(indexed)

    expect(compiler.send(:compile_entity_source, nil)).to be_nil
    expect(compiler.send(:compile_entity_source, '$Type' => 'DomainModels$StoredEntitySource'))
      .to include('$Type' => 'DomainModels$StoredEntitySource')
    result = compiler.send(
      :compile_entity_source,
      '$ID' => id(10), '$Type' => 'DomainModels$OqlViewEntitySource', 'SourceDocument' => 'App.Users'
    )
    expect(result).to include('OqlRuntime' => 'SELECT Name FROM App.User', 'SourceType' => 'OQL')
    expect do
      compiler.send(:compile_entity_source, '$Type' => 'DomainModels$OqlViewEntitySource',
                                            'SourceDocument' => 'App.Missing')
    end
      .to raise_error(Mxrb::CompilationError, /OQL view source/)
    expect(compiler.send(:inherited_flags, 'System.User')).to include('Persistable' => true)
    expect(compiler.send(:inherited_flags, 'App.Parent')).to include('HasOwnerAttr' => true)
    expect(compiler.send(:inherited_flags, 'App.Unknown')).to include('Persistable' => true)
  end

  it 'covers view artifacts, nullable association messages, and database action dispatch' do
    unit = Mxrb::Compiler::SourceModel::Unit.new(
      id: id(11), container_id: id(1), containment: 'Documents', module_name: 'App',
      document: { '$ID' => id(11), '$Type' => 'DomainModels$ViewEntitySourceDocument', 'Name' => 'View' }
    )
    expect(Mxrb::Compiler::ArtifactDocumentCompiler.new.compile(unit))
      .to include('QualifiedName' => 'App.View')

    security = Mxrb::Compiler::DomainSecurityCompiler.new(source)
    expect(security.send(:text_reference, nil)).to be_nil
    expect(security.send(:text_reference, '$ID' => id(12), '$Type' => 'Texts$Text', 'Items' => []))
      .to eq('$ID' => id(12), '$Type' => 'Texts$Text')

    node = Mxrb::Compiler::MicroflowNodeCompiler.allocate
    database = instance_double(Mxrb::Compiler::DatabaseConnectorActionCompiler)
    allow(database).to receive_messages(compile: { 'Lowered' => true }, unconfigured_write?: false)
    node.instance_variable_set(:@database_connector, database)
    expect(node.send(:compile_hash, '$Type' => 'DatabaseConnector$ExecuteDatabaseQueryAction'))
      .to eq('Lowered' => true)
  end

  it 'selects a learned schema when a counterpart type differs and indexes untyped values' do
    target = { '$ID' => id(1), '$Type' => 'Test$Type', 'Value' => 'old' }
    duplicate = { '$ID' => id(3), '$Type' => 'Test$Type', 'Value' => 'second' }
    without_id = { '$Type' => 'Test$Type', 'Value' => 'anonymous' }
    stale_show_form = { '$ID' => id(4), '$Type' => 'Microflows$ShowFormAction',
                        'FormSettings' => {}, 'ErrorHandlingType' => 'Rollback' }
    nested = { '$ID' => id(2), '$Type' => 'Test$Container',
               'Children' => [{ 'Untyped' => true }, target, duplicate, without_id, stale_show_form, 7] }
    package = Mxrb::Compiler::ModelPackage.new([
                                                 Mxrb::Compiler::ModelPackage::Entry.new(offset: 0, size: 1,
                                                                                         document: nested)
                                               ])
    schema = Mxrb::Compiler::RuntimeModelSchema.new(package)
    source_document = { '$ID' => id(1), '$Type' => 'Test$Type' }
    mismatched = { '$ID' => id(2), '$Type' => 'Test$Type' }

    expect(schema.fields_for(source_document)).to eq(%w[$ID $Type Value])
    expect(schema.fields_for(mismatched)).to eq(%w[$ID $Type Value])
    expect(schema.fields_for('$Type' => 'Microflows$ExclusiveMerge')).to eq(%w[$ID $Type])
    expect(schema.counterpart({ '$ID' => id(99) })).to be_nil
    expect { schema.fields_for('$Type' => 'Unknown$Type') }
      .to raise_error(Mxrb::CompilationError, /no Runtime schema/)

    versioned = Mxrb::Compiler::RuntimeModelSchema.new(package, version: '9.6.1.29396')
    expect(versioned.fields_for(stale_show_form)).to include('FormObjectVariable', 'NumberOfPagesToClose')
    modern = Mxrb::Compiler::RuntimeModelSchema.new(package, version: '11.12.1')
    expect(modern.fields_for('$Type' => 'DatabaseConnector$ExecuteDatabaseQueryAction'))
      .to include('Query', 'ParameterMappings', 'ConnectionParameterMappings')
    expect(modern.fields_for('$Type' => 'Microflows$FindByExpression'))
      .to eq(%w[$ID $Type Expression ListName])
    expect(modern.fields_for('$Type' => 'Microflows$ImportXmlAction'))
      .to eq(%w[$ID $Type ResultHandling IsValidationRequired XmlDocumentVariableName ErrorHandlingType])
    expect(modern.fields_for('$Type' => 'Microflows$MicroflowParameterValue'))
      .to eq(%w[$ID $Type Microflow ValueExpression])
    parameter_value = { '$ID' => id(20), '$Type' => 'Microflows$MicroflowParameterValue',
                        'Microflow' => 'App.Handle' }
    expect(Mxrb::Compiler::MicroflowNodeCompiler.new(modern).send(:compile_hash, parameter_value))
      .to include('Microflow' => 'App.Handle', 'ValueExpression' => "'App.Handle'")
    legacy_microflow_fields = {
      'Microflows$DownloadFileAction' => %w[$ID $Type FileDocumentVariableName ShowFileInBrowser ErrorHandlingType],
      'Microflows$CustomRequestHandling' => %w[$ID $Type Template],
      'Microflows$ListOperationsAction' => %w[$ID $Type NewOperation ResultVariableName ErrorHandlingType],
      'Microflows$RetrieveSorting' => %w[$ID $Type AttributePath SortOrder],
      'Microflows$RuleCall' => %w[$ID $Type ParameterMappings Microflow],
      'Microflows$RuleCallParameterMapping' => %w[$ID $Type Parameter Argument],
      'Microflows$RuleSplitCondition' => %w[$ID $Type RuleCall],
      'Microflows$Sort' => %w[$ID $Type Sortings ListName],
      'Microflows$Subtract' => %w[$ID $Type SecondListOrObjectName ListName]
    }
    legacy_microflow_fields.each do |type, fields|
      expect(modern.fields_for('$Type' => type)).to eq(fields)
    end
  end

  it 'reads all source documents and closes safely when opening fails' do
    Dir.mktmpdir do |root|
      path = File.join(root, 'App.mpr')
      Mxrb.define(path) { mendix_version '11.12.1' }
      expect(Mxrb::Compiler::SourceModel.read(path).documents).not_to be_empty
      expect { Mxrb::Compiler::SourceModel.read(File.join(root, 'missing.mpr')) }.to raise_error(StandardError)
    end
  end
end
# rubocop:enable Metrics/BlockLength
