# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::KnownMxModelReflectionActions do
  # The MxModelReflection domain model the module's Java code writes to.
  def reflection_module(builder) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    builder.module :MxModelReflection do
      enumeration(:PersistenceType) { %i[Persistable Non_persistent].each { value _1 } }
      enumeration(:PrimitiveTypes) do
        %i[AutoNumber BooleanType Currency DateTime EnumType FloatType HashString IntegerType LongType StringType
           ObjectType ObjectList Decimal].each { value _1 }
      end
      enumeration(:ReferenceType) { %i[Reference ReferenceSet].each { value _1 } }
      enumeration(:AssociationOwner) { %i[_Default Both].each { value _1 } }
      entity :Module do
        string :ModuleName
        boolean :SynchronizeObjectsWithinModule
      end
      entity :MxObjectType do
        %i[CompleteName Name Module].each { string _1 }
        enum :PersistenceType, enumeration: 'MxModelReflection.PersistenceType'
        association 'MxModelReflection.MxObjectType', name: :MxObjectType_SubClassOf_MxObjectType,
                                                      cardinality: :many_to_many
        association 'MxModelReflection.Module', name: :MxObjectType_Module, cardinality: :many_to_one
      end
      entity :ValueType do
        string :Name
        enum :TypeEnum, enumeration: 'MxModelReflection.PrimitiveTypes'
        association 'MxModelReflection.MxObjectType', name: :ValueType_MxObjectType, cardinality: :many_to_one
      end
      entity :MxObjectMember do
        %i[AttributeName AttributeType].each { string _1 }
        enum :AttributeTypeEnum, enumeration: 'MxModelReflection.PrimitiveTypes'
        integer :FieldLength
        boolean :IsVirtual
        association 'MxModelReflection.MxObjectType', name: :MxObjectMember_MxObjectType, cardinality: :many_to_one
        association 'MxModelReflection.ValueType', name: :MxObjectMember_Type, cardinality: :many_to_one
      end
      entity :MxObjectEnumCaptions do
        %i[Caption LanguageCode].each { string _1 }
      end
      entity :MxObjectEnumValue do
        string :Name
        association 'MxModelReflection.MxObjectEnumCaptions', name: :Captions, cardinality: :many_to_many
      end
      entity :MxObjectEnum do
        generalizes 'MxModelReflection.MxObjectMember'
        association 'MxModelReflection.MxObjectEnumValue', name: :Values, cardinality: :many_to_many
      end
      entity :MxObjectReference do
        %i[CompleteName ParentEntity Name Module].each { string _1 }
        enum :ReferenceType, enumeration: 'MxModelReflection.ReferenceType'
        enum :AssociationOwner, enumeration: 'MxModelReflection.AssociationOwner'
        %w[MxObjectReference_MxObjectType MxObjectReference_MxObjectType_Child
           MxObjectReference_MxObjectType_Parent].each do |name|
          association 'MxModelReflection.MxObjectType', name: name.to_sym, cardinality: :many_to_many
        end
        association 'MxModelReflection.Module', name: :MxObjectReference_Module, cardinality: :many_to_one
      end
      entity :Parameter do
        string :Name
        association 'MxModelReflection.ValueType', name: :Parameter_ValueType, cardinality: :many_to_one
        association 'MxModelReflection.MxObjectType', name: :Parameter_MxObjectType, cardinality: :many_to_one
      end
      entity :Microflows do
        %i[Name Module CompleteName].each { string _1 }
        association 'MxModelReflection.Module', name: :Microflows_Module, cardinality: :many_to_one
        association 'MxModelReflection.ValueType', name: :Microflows_Output_Type, cardinality: :many_to_one
        association 'MxModelReflection.Parameter', name: :Microflows_InputParameter, cardinality: :many_to_many
      end
    end
  end

  around do |example|
    Dir.mktmpdir('mxrb-reflection-') do |root|
      @root = root
      source = File.join(root, 'project', 'Reflect.mpr')
      spec = self
      Mxrb.define(source) do
        mendix_version '11.12.1'
        spec.reflection_module(self)
        self.module :Shop do
          enumeration(:Size) do
            value :Small, captions: { 'en_US' => 'Small', 'nl_NL' => 'Klein' }
            value :Large, caption: 'Large'
          end
          entity :Base do
            string :Name, length: 50
          end
          entity :Item do
            generalizes 'Shop.Base'
            enum :Size, enumeration: 'Shop.Size'
            decimal :Price
            association 'Shop.Base', name: :Item_Origin, cardinality: :one_to_one
          end
          entity :Account do
            generalizes 'System.User'
          end
          microflow :Price do
            parameter :Item, type: object_of('Shop.Item')
            parameter :Size, type: enum_of('Shop.Size')
            return_type list_of('Shop.Item')
            return_value 'empty'
          end
        end
      end
      @target = File.join(root, 'ruby')
      Mxrb::Exporter.new(source, @target, mode: :ruby).export!
      @application = Mxrb::RubyApp::Application.new(@target, process: { 'MXRB_DATABASE_PATH' => ':memory:' })
      example.run
    ensure
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def bridge = @application.send(:bridge)
  def store = bridge.store
  def all(entity) = store.retrieve("MxModelReflection.#{entity}")

  def sync
    context = bridge.interpreter.send(:java_action_context)
    described_class::SyncObjects.new(context).run
  end

  def find(entity, attribute, value) = all(entity).find { _1.members[attribute] == value }

  def mark(name, synchronize: true)
    store.commit(store.create('MxModelReflection.Module').tap do
      _1.members.merge!('ModuleName' => name, 'SynchronizeObjectsWithinModule' => synchronize)
    end)
  end

  it 'only records the modules on a first synchronization, as the module does' do
    language = store.create('System.Language').tap { _1.members['Code'] = 'en_US' }
    store.commit(language)
    expect(sync).to be(true)
    expect(all('Module').map { _1.members.slice('ModuleName', 'SynchronizeObjectsWithinModule') })
      .to include({ 'ModuleName' => 'Shop', 'SynchronizeObjectsWithinModule' => false })
    expect(all('MxObjectType')).to eq([])
  end

  it 'synchronizes the marked modules and keeps the result on a second run' do
    %w[en_US nl_NL].each { |code| store.commit(store.create('System.Language').tap { _1.members['Code'] = code }) }
    mark('Shop')
    mark('System')
    mark('Gone')
    expect(sync).to be(true)
    expect(find('Module', 'ModuleName', 'Gone')).to be_nil

    item = find('MxObjectType', 'CompleteName', 'Shop.Item')
    base = find('MxObjectType', 'CompleteName', 'Shop.Base')
    expect(item.members.slice('Name', 'Module', 'PersistenceType'))
      .to eq('Name' => 'Item', 'Module' => 'Shop', 'PersistenceType' => 'Persistable')
    expect(item.members['MxObjectType_SubClassOf_MxObjectType']).to eq([base])
    expect(find('MxObjectType', 'CompleteName', 'Shop.Account').members['MxObjectType_SubClassOf_MxObjectType']
             .map { _1.members['CompleteName'] }).to eq(['System.User'])

    members = all('MxObjectMember').select do
      _1.entity == 'MxModelReflection.MxObjectMember' && _1.members['MxObjectMember_MxObjectType'] == item
    end
    price = members.find { _1.members['AttributeName'] == 'Price' }
    expect(price.members.slice('AttributeType', 'AttributeTypeEnum', 'FieldLength', 'IsVirtual'))
      .to eq('AttributeType' => 'Decimal', 'AttributeTypeEnum' => 'Decimal', 'FieldLength' => 8, 'IsVirtual' => false)
    expect(price.members['MxObjectMember_Type'].members['Name']).to eq('Decimal')
    expect(members.map { _1.members['AttributeName'] }).to eq(%w[Name Price])
    size = all('MxObjectEnum').find { _1.members['MxObjectMember_MxObjectType'] == item }
    expect(size.members.slice('AttributeName', 'AttributeType', 'AttributeTypeEnum'))
      .to eq('AttributeName' => 'Size', 'AttributeType' => 'Enum', 'AttributeTypeEnum' => 'EnumType')
    captions = size.members['Values'].to_h do |value|
      [value.members['Name'], value.members['Captions'].to_h { [_1.members['LanguageCode'], _1.members['Caption']] }]
    end
    expect(captions).to eq('Small' => { 'en_US' => 'Small', 'nl_NL' => 'Klein' },
                           'Large' => { 'en_US' => 'Large', 'nl_NL' => 'Large' })

    origin = find('MxObjectReference', 'CompleteName', 'Shop.Item_Origin')
    expect(origin.members.slice('Name', 'Module', 'ParentEntity', 'ReferenceType', 'AssociationOwner'))
      .to eq('Name' => 'Item_Origin', 'Module' => 'Shop', 'ParentEntity' => 'Shop.Item',
             'ReferenceType' => 'Reference', 'AssociationOwner' => 'Both')
    expect(origin.members['MxObjectReference_MxObjectType_Child']).to contain_exactly(base, item)
    expect(origin.members['MxObjectReference_MxObjectType_Parent']).to eq([item])

    flow = find('Microflows', 'CompleteName', 'Shop.Price')
    expect(flow.members['Microflows_Output_Type'].members.slice('Name', 'TypeEnum'))
      .to eq('Name' => 'List of type: Shop.Item', 'TypeEnum' => 'ObjectList')
    expect(flow.members['Microflows_Output_Type'].members['ValueType_MxObjectType']).to eq(item)
    parameters = flow.members['Microflows_InputParameter'].to_h do
      [_1.members['Name'], [_1.members['Parameter_ValueType'].members['Name'], _1.members['Parameter_MxObjectType']]]
    end
    expect(parameters).to eq('Item' => ['Object of type: Shop.Item', item], 'Size' => ['Enum', nil])
    expect(find('Microflows', 'CompleteName', 'System.ShowHomePage').members['Microflows_Output_Type']
             .members['Name']).to eq('Nothing')

    counts = %w[MxObjectType MxObjectMember MxObjectEnum MxObjectEnumValue MxObjectEnumCaptions MxObjectReference
                ValueType Microflows Parameter].to_h { [_1, all(_1).size] }
    stale = store.create('MxModelReflection.MxObjectType').tap { _1.members['CompleteName'] = 'Shop.Removed' }
    store.commit(stale)
    store.delete([price, size])
    retyped = store.create('MxModelReflection.MxObjectEnum')
    retyped.members.merge!('AttributeName' => 'Price', 'MxObjectMember_MxObjectType' => item)
    plain = store.create('MxModelReflection.MxObjectMember')
    plain.members.merge!('AttributeName' => 'Size', 'MxObjectMember_MxObjectType' => item)
    store.commit([retyped, plain])
    expect(sync).to be(true)
    expect(find('MxObjectType', 'CompleteName', 'Shop.Removed')).to be_nil
    expect(all('MxObjectEnum').find { _1.members['AttributeName'] == 'Price' }).to be_nil
    expect(all('MxObjectEnum').find { _1.members['AttributeName'] == 'Size' }.members['Values'].size).to eq(2)
    expect(%w[MxObjectType MxObjectMember MxObjectReference ValueType Microflows Parameter].to_h { [_1, all(_1).size] })
      .to eq(counts.slice('MxObjectType', 'MxObjectMember', 'MxObjectReference', 'ValueType', 'Microflows',
                          'Parameter'))
  end

  it 'synchronizes every module when types exist but no module was recorded' do
    store.commit(store.create('MxModelReflection.MxObjectType').tap { _1.members['CompleteName'] = 'Shop.Old' })
    expect(sync).to be(true)
    expect(all('Module').map { _1.members['SynchronizeObjectsWithinModule'] }.uniq).to eq([true])
    expect(find('MxObjectType', 'CompleteName', 'Shop.Old')).to be_nil
    expect(find('MxObjectType', 'CompleteName', 'Shop.Item')).to be_nil
    expect(sync).to be(true)
    expect(find('MxObjectType', 'CompleteName', 'Shop.Item').members['MxObjectType_Module'].members['ModuleName'])
      .to eq('Shop')
  end

  it 'links supers of modules it does not synchronize without their module' do
    mark('Shop')
    orphan = store.create('MxModelReflection.MxObjectMember').tap { _1.members['AttributeName'] = 'Lost' }
    store.commit(orphan)
    expect(sync).to be(true)
    expect(find('MxObjectType', 'CompleteName', 'Shop.Account')).not_to be_nil
    expect(find('MxObjectType', 'CompleteName', 'System.User')).to be_nil
    expect(all('MxObjectMember').map { _1.members['AttributeName'] }).to include('Lost')
    size = all('MxObjectEnum').find { _1.members['AttributeName'] == 'Size' }
    stale = store.create('MxModelReflection.MxObjectEnumValue').tap { _1.members['Name'] = 'Medium' }
    store.commit(stale)
    size.members['Values'] += [stale]
    store.commit(size)
    expect(sync).to be(true)
    expect(find('MxObjectEnumValue', 'Name', 'Medium')).to be_nil
    adapter = described_class.register('6.2.0')
    expect(adapter.handler.call({}, context: bridge.interpreter.send(:java_action_context))).to be(true)
  end

  it 'runs only in an exported application and from audited sources' do
    model = Mxrb::Model::Project.open(File.join(@root, 'project', 'Reflect.mpr'))
    context = Struct.new(:project, :store).new(model, store)
    expect { described_class::SyncObjects.new(context) }
      .to raise_error(Mxrb::NativeRuntimeError, 'MxModelReflection.SyncObjects needs an exported Ruby application')
    model.close
    Dir.mktmpdir do |directory|
      expect(described_class.registrations(directory)).to eq('')
      root = File.join(directory, 'javasource', 'mxmodelreflection')
      x = Digest::SHA256.hexdigest("x\n")
      stub_const("#{described_class}::RELEASES", '1' => { 'actions/SyncObjects' => x })
      FileUtils.mkdir_p(File.join(root, 'actions'))
      File.write(File.join(root, 'actions', 'SyncObjects.java'), "x\r\n")
      expect(described_class.registrations(directory))
        .to eq('Mxrb::RubyApp::KnownMxModelReflectionActions.register("1")')
    end
  end

  it 'registers the adapter for an audited release' do
    described_class.register('8.0.2')
    expect(Mxrb::RubyApp::Registry.java_custom_actions.fetch('MxModelReflection.SyncObjects'))
      .to be_a(Mxrb::Runtime::Native::ContextJavaAction)
    expect { described_class.register('1.0.0') }.to raise_error(KeyError)
  end
end
# rubocop:enable Metrics/BlockLength
