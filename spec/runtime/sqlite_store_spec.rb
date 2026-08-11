# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative '../../lib/mxrb/runtime/sqlite_store'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength, Metrics/ParameterLists
RSpec.describe Mxrb::Runtime::SQLiteStore do
  def attribute(name, type: :string, guid: nil, default: nil, required: false, unique: false)
    Mxrb::Model::Attribute.new.tap do |value|
      value.id = "attribute-#{name}"
      value.name = name
      value.type = type
      value.data_storage_guid = guid || "storage-#{name}"
      value.default_value = default
      value.required = required
      value.unique = unique
    end
  end

  def entity(name, id:, guid:, attributes:, system_members: {}, persistable: true)
    Mxrb::Model::Entity.new.tap do |value|
      value.id = id
      value.name = name
      value.qualified_name = "Store.#{name}"
      value.data_storage_guid = guid
      value.persistable = persistable
      value.system_members = system_members
      value.source = nil
      value.oql_query = nil
      value.instance_variable_set(:@attributes, attributes)
    end
  end

  def association(name, id:, from:, to:, type: :Reference)
    Mxrb::Model::Association.new.tap do |value|
      value.id = id
      value.name = name
      value.from_entity_id = from
      value.to_entity_id = to
      value.association_type = type
    end
  end

  def project(extra_pet_attributes: [], pet_name: 'Pet', extra_entities: [])
    owner = entity(
      'Owner', id: 'owner', guid: 'entity-owner',
               attributes: [attribute('Name', guid: 'owner-name')]
    )
    pet = entity(
      pet_name, id: 'pet', guid: 'entity-pet',
                attributes: [
                  attribute('Name', guid: 'pet-name', default: 'unnamed'),
                  attribute('Number', type: :autonumber, guid: 'pet-number'),
                  attribute('Active', type: :boolean, guid: 'pet-active', default: 'true'),
                  attribute('BornAt', type: :datetime, guid: 'pet-born'),
                  *extra_pet_attributes
                ],
                system_members: { owner: true, created_date: true, changed_date: true }
    )
    links = [
      association('Pet_Owner', id: 'pet-owner', from: 'pet', to: 'owner'),
      association('Pet_Friends', id: 'pet-friends', from: 'pet', to: 'pet', type: :ReferenceSet)
    ]
    mod = Struct.new(:name, :entities, :associations).new('Store', [owner, pet, *extra_entities], links)
    Struct.new(:modules).new([mod])
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @database_path = File.join(dir, 'runtime.sqlite3')
      example.run
    end
  end

  it 'persists typed attributes, system members, references, and reference sets' do
    store = described_class.new(project, path: @database_path)
    owner = store.create('Store.Owner')
    owner.members['Name'] = 'Ada'
    store.commit(owner)
    first = store.create('Store.Pet')
    second = store.create('Store.Pet')
    first.members.merge!(
      'Name' => 'Bento', 'BornAt' => Time.utc(2024, 1, 2),
      'Owner' => owner, 'Pet_Owner' => owner, 'Pet_Friends' => [second]
    )
    store.commit(first)
    store.commit(second)
    id = first.id
    store.close

    reopened = described_class.new(project, path: @database_path)
    restored = reopened.retrieve('Store.Pet').find { _1.id == id }
    expect(restored.members).to include('Name' => 'Bento', 'Active' => true)
    expect(reopened.retrieve('Store.Pet').map { _1.members['Number'] }).to eq([1, 2])
    expect(restored.members['BornAt']).to eq(Time.utc(2024, 1, 2))
    expect(restored.members['createdDate']).to be_a(Time)
    expect(restored.members['Pet_Owner'].members['Name']).to eq('Ada')
    expect(restored.members['Pet_Friends'].map(&:id)).to eq([second.id])
    expect(reopened.retrieve_association('Pet_Owner', restored.members['Pet_Owner']).map(&:id)).to include(id)
    reopened.close
  end

  it 'runs lifecycle hooks in transaction order and rolls database state back on failure' do
    events = []
    store = described_class.new(project, path: @database_path)
    described_class::EVENTS.each do |event|
      store.on(event, entity: 'Store.Pet') { |object| events << [event, object.members['Name']] }
    end
    pet = store.create('Store.Pet')
    pet.members['Name'] = 'Milo'
    store.commit(pet)
    store.delete(pet)

    expect(events.map(&:first)).to eq(
      %i[before_create after_create before_commit after_commit before_delete after_delete]
    )

    failing = described_class.new(project, path: ':memory:')
    failing.on(:before_commit) { raise 'invalid object' }
    object = failing.create('Store.Pet')
    object.members['Name'] = 'changed'
    expect { failing.commit(object) }.to raise_error(RuntimeError, 'invalid object')
    expect(failing.retrieve('Store.Pet').first.members['Name']).to eq('changed')
    failing.close
    store.close
  end

  it 'supports explicit transactions, object rollback, snapshots, restore, count, and delete' do
    store = described_class.new(project, path: @database_path)
    pet = store.create('Store.Pet')
    pet.members['Name'] = 'saved'
    store.commit(pet)
    pet.members['Name'] = 'discarded'
    store.rollback(pet)
    expect(pet.members['Name']).to eq('saved')

    snapshot = store.snapshot
    expect do
      store.transaction do
        store.create('Store.Pet')
        raise 'stop'
      end
    end.to raise_error(RuntimeError, 'stop')
    expect(store.count('Store.Pet')).to eq(1)
    store.delete(store.retrieve('Store.Pet'))
    expect(store.count('Store.Pet')).to eq(0)
    store.restore(snapshot)
    expect(store.count('Store.Pet', ->(item) { item.members['Name'] == 'saved' })).to eq(1)
    store.close
  end

  it 'covers transient and mixed persistence paths, global hooks, and disabled events' do
    scratch = entity(
      'Scratch', id: 'scratch', guid: 'scratch',
                 attributes: [attribute('Value', guid: 'scratch-value')], persistable: false
    )
    runtime_project = project(extra_entities: [scratch])
    events = []
    store = described_class.new(
      runtime_project, path: @database_path,
                       defaults: { 'Store.Scratch' => { 'Value' => 'temporary' } },
                       hooks: { after_commit: ->(value, *) { events << [:global, value.entity] } }
    )
    store.on('Store.Scratch', :before_commit) { |value, owner| events << [value.members['Value'], owner.class] }
    transient = store.create('Scratch')
    persistent = store.create('Store.Pet', events: false)
    expect(store.retrieve('Scratch')).to eq([transient])
    expect(store.count('Scratch')).to eq(1)
    store.commit([transient, persistent])
    expect(events).to include(['temporary', described_class], [:global, 'Store.Scratch'])

    transient.members['Value'] = 'dirty'
    store.rollback(transient)
    expect(transient.members['Value']).to eq('temporary')
    snapshot = store.snapshot
    store.delete([transient, persistent], events: false)
    expect(store.count('Scratch')).to eq(0)
    store.restore(snapshot)
    expect(store.count('Scratch')).to eq(1)
    store.close
  end

  it 'keeps hybrid associations bidirectional and volatile' do
    scratch = entity(
      'Scratch', id: 'scratch', guid: 'scratch', attributes: [], persistable: false
    )
    hybrid = association('Scratch_Pet', id: 'scratch-pet', from: 'scratch', to: 'pet')
    inverse_hybrid = association('Pet_Scratch', id: 'pet-scratch', from: 'pet', to: 'scratch')
    runtime_project = project(extra_entities: [scratch])
    runtime_project.modules.first.associations.concat([hybrid, inverse_hybrid])
    store = described_class.new(runtime_project, path: @database_path)
    scratch_value = store.create('Scratch')
    pet = store.create('Store.Pet')
    scratch_value.members['Scratch_Pet'] = pet
    pet.members['Pet_Scratch'] = scratch_value
    store.commit([scratch_value, pet])

    expect(store.retrieve_association('Scratch_Pet', scratch_value)).to eq([pet])
    expect(store.retrieve_association('Store.Scratch_Pet', pet)).to eq([scratch_value])
    definition = store.schema.association('Scratch_Pet')
    expect(store.database.get_first_value("SELECT COUNT(*) FROM \"#{definition.table}\"")).to eq(0)
    store.close

    reopened = described_class.new(runtime_project, path: @database_path)
    persisted = reopened.retrieve('Store.Pet').find { _1.id == pet.id }
    expect(reopened.retrieve_association('Scratch_Pet', persisted)).to eq([])
    reopened.close
  end

  it 'cleans failed creates and rolls back an active transaction when a hook raises' do
    store = described_class.new(project, path: @database_path)
    store.on(:before_create, entity: 'Store.Pet') { raise 'create rejected' }
    expect { store.create('Store.Pet') }.to raise_error(RuntimeError, 'create rejected')
    expect(store.count('Store.Pet')).to eq(0)
    store.close

    transactional = described_class.new(project, path: @database_path)
    pet = transactional.create('Store.Pet')
    transactional.on(:before_commit, entity: 'Store.Pet') { raise 'commit rejected' }
    transactional.begin_transaction
    pet.members['Name'] = 'not saved'
    expect { transactional.commit(pet) }.to raise_error(RuntimeError, 'commit rejected')
    expect(transactional.database.transaction_active?).to be(false)
    expect(transactional.retrieve('Store.Pet').first.members['Name']).to eq('unnamed')
    transactional.close
  end

  it 'handles unrelated associations and generic or malformed serialized system values' do
    store = described_class.new(project, path: @database_path)
    unrelated = Mxrb::Runtime::Native::ObjectValue.new(entity: 'Store.Unrelated', id: 'x', members: {})
    expect(store.retrieve_association('Pet_Owner', unrelated)).to eq([])

    pet = store.create('Store.Pet')
    pet.members['Owner'] = 'user-1'
    pet.members['Name'] = 'serialized'
    store.commit(pet)
    definition = store.schema.entity('Store.Pet')
    datetime = definition.columns.find { _1.name == 'BornAt' }
    store.database.execute(
      "UPDATE \"#{definition.table}\" SET \"#{datetime.sql_name}\" = ?, __created_at = ? WHERE id = ?",
      ['invalid-date', 'also-invalid', pet.id]
    )
    store.close

    reopened = described_class.new(project, path: @database_path)
    restored = reopened.retrieve('Store.Pet').first
    expect(restored.members).to include(
      'Owner' => 'user-1', 'BornAt' => 'invalid-date', 'createdDate' => 'also-invalid'
    )
    reopened.close
  end

  it 'validates hooks and covers association and transaction boundary cases' do
    scratch = entity(
      'Scratch', id: 'scratch', guid: 'scratch', attributes: [], persistable: false
    )
    store = described_class.new(project(extra_entities: [scratch]), path: @database_path)
    expect { store.on(:unknown) {} }.to raise_error(ArgumentError, /unsupported lifecycle/)
    expect { store.on(:before_commit) }.to raise_error(ArgumentError, /requires a block/)
    expect(store.retrieve_association('Pet_Owner', nil)).to eq([])

    transient = store.create('Scratch')
    other = store.create('Scratch')
    transient.members['Scratch_Link'] = other
    expect(store.retrieve_association('Scratch_Link', transient)).to eq([other])
    expect(store.retrieve_association('Pet_Owner', transient)).to eq([])
    persistent_start = Mxrb::Runtime::Native::ObjectValue.new(
      entity: 'Store.Unrelated', id: 'unknown', members: {}
    )
    expect { store.retrieve_association('Missing', persistent_start) }
      .to raise_error(ArgumentError, /unknown association/)

    pet = store.create('Store.Pet')
    pet.members['Name'] = 'dirty commit'
    store.commit
    expect(store.retrieve('Store.Pet').first.members['Name']).to eq('dirty commit')
    expect(store.transaction { |_current| :completed }).to eq(:completed)
    store.begin_transaction
    expect { store.begin_transaction }.to raise_error(SQLite3::SQLException, /already active/)
    store.rollback
    expect(store.rollback).to eq(store)
    staged = store.create('Store.Pet')
    staged.members['Name'] = 'flush all explicitly'
    store.begin_transaction
    expect(store.commit).to be_nil
    expect(store.retrieve('Store.Pet').map { _1.members['Name'] }).to include('flush all explicitly')
    store.begin_transaction
    store.close
    store.close
  end

  it 'covers event suppression, empty records, primitive links, missing rows, and serializers' do
    bare = entity('Bare', id: 'bare', guid: 'bare', attributes: [])
    decimal = attribute('Ratio', type: :decimal, guid: 'ratio', default: '1.25')
    store = described_class.new(
      project(extra_pet_attributes: [decimal], extra_entities: [bare]), path: @database_path
    )
    events = []
    store.on(:before_update) { events << :before_update }
    store.on(:before_commit) { events << :before_commit }
    store.on(:after_commit) { events << :after_commit }
    store.on(:after_update) { events << :after_update }
    store.on(:after_update, entity: 'Store.Owner') { events << :wrong_entity }
    empty = store.create('Store.Bare', events: false)
    empty.members['TransientOnly'] = 'changed'
    store.commit(empty, events: false)
    store.delete(empty, events: false)
    pet = store.create('Store.Pet')
    pet.members.merge!(
      'Active' => false, 'BornAt' => Date.new(2024, 2, 3),
      'Pet_Owner' => 'owner-id', 'Pet_Friends' => ['friend-id']
    )
    store.commit(pet, events: false)
    expect(events).to be_empty
    expect(pet.members['Ratio']).to eq(1.25)
    pet.members['Name'] = 'run matching hooks'
    store.commit(pet)
    expect(events).not_to include(:wrong_entity)

    missing = Mxrb::Runtime::Native::ObjectValue.new(
      entity: 'Store.Pet', id: 'missing', members: pet.members.dup
    )
    expect(store.rollback(missing)).to eq(missing)
    expect { store.commit(missing) }.to raise_error(ArgumentError, /not persisted/)

    auto = store.schema.entity('Store.Pet').columns.find { _1.type == :autonumber }
    store.database.execute(
      'DELETE FROM mxrb_schema_sequences WHERE entity_key = ? AND attribute_key = ?',
      [store.schema.entity('Store.Pet').storage_key, auto.storage_key]
    )
    expect { store.create('Store.Pet') }.to raise_error(RuntimeError, /missing AutoNumber sequence/)
    store.close
  end

  it 'restores transient state when a transactional hook fails after starting the transaction' do
    scratch = entity(
      'Scratch', id: 'scratch', guid: 'scratch', attributes: [], persistable: false
    )
    store = described_class.new(project(extra_entities: [scratch]), path: @database_path)
    transient = store.create('Scratch')
    store.commit(transient)
    pet = store.create('Store.Pet')
    store.on(:before_commit, entity: 'Store.Pet') { raise 'transaction event failed' }

    expect do
      store.transaction do
        transient.members['Changed'] = true
        pet.members['Name'] = 'rejected'
        store.commit(pet)
      end
    end.to raise_error(RuntimeError, 'transaction event failed')
    expect(store.count('Scratch')).to eq(1)
    expect(store.retrieve('Store.Pet').first.members['Name']).to eq('unnamed')
    store.close
  end

  it 'keeps the outer atomic rescue safe when rollback itself fails' do
    store = described_class.new(project, path: @database_path)
    pet = store.create('Store.Pet')
    store.on(:before_commit, entity: 'Store.Pet') { raise 'hook failure' }
    pet.members['Name'] = 'dirty'
    store.begin_transaction
    allow(store).to receive(:rollback).and_raise('rollback failure')

    expect { store.commit(pet) }.to raise_error(RuntimeError, 'rollback failure')
    expect(store.database.transaction_active?).to be(false)
    allow(store).to receive(:rollback).and_call_original
    store.rollback
    store.close
  end

  it 'restores legacy and durable association snapshots and staged rollbacks' do
    store = described_class.new(project, path: @database_path)
    owner = store.create('Store.Owner')
    pet = store.create('Store.Pet')
    store.commit(owner)
    pet.members['Pet_Owner'] = owner
    store.commit(pet)
    snapshot = store.snapshot
    store.delete([owner, pet])
    store.restore(snapshot)
    restored_pet = store.retrieve('Store.Pet').first
    expect(store.retrieve_association('Pet_Owner', restored_pet).map(&:id)).to eq([owner.id])

    legacy = snapshot.reject { |key, _value| key == '__mxrb_uow__' }
    store.restore(legacy)
    expect(store.count('Store.Pet')).to eq(1)

    with_orphan_metadata = store.snapshot
    with_orphan_metadata['__mxrb_uow__'][:persisted]['missing-id'] = {}
    store.restore(with_orphan_metadata)
    staged = store.create('Store.Pet')
    expect(store.rollback(staged)).to eq(staged)
    expect(store.retrieve('Store.Pet').map(&:id)).not_to include(staged.id)

    bare = entity('Bare', id: 'bare', guid: 'bare', attributes: [])
    no_fields = described_class.new(project(extra_entities: [bare]), path: ':memory:')
    empty = no_fields.create('Store.Bare')
    no_fields.commit(empty)
    empty.members['RuntimeOnly'] = true
    no_fields.commit(empty, events: false)
    no_fields.close

    unchanged = store.retrieve('Store.Pet').first
    expect(store.commit(unchanged)).to eq(unchanged)
    unchanged.members['Name'] = 'will be restored'
    store.on(:before_commit, entity: 'Store.Pet') { raise 'reject existing update' }
    expect { store.commit(unchanged) }.to raise_error(RuntimeError, 'reject existing update')
    expect(unchanged.members['Name']).not_to eq('will be restored')
    expect(store.send(:comparable_members, 'values' => [owner, 'raw'], 'owner' => owner)).to eq(
      'values' => [owner.id, 'raw'], 'owner' => owner.id
    )
    store.close
  end

  it 'honors explicit commit boundaries in real MPR microflows' do
    Dir.mktmpdir('mxrb-sqlite-uow-') do |dir|
      mpr_path = File.join(dir, 'UnitOfWork.mpr')
      database_path = File.join(dir, 'runtime.sqlite3')
      Mxrb.define(mpr_path) do
        mendix_version '11.12.1'
        self.module :Audit do
          entity(:Thing) { string :Name }
          microflow :CreateWithoutCommit do
            create_object 'Audit.Thing', as: :thing, set: { Name: "'transient'" }
            return_value :thing
          end
          microflow :CreateWithCommit do
            create_object 'Audit.Thing', as: :thing, set: { Name: "'durable'" }, commit: true
            return_value :thing
          end
          microflow :ChangeWithoutCommit do
            parameter :Thing, type: 'Audit.Thing'
            change_object :Thing, set: { Name: "'detached'" }
            return_value :Thing
          end
          microflow :ChangeWithCommit do
            parameter :Thing, type: 'Audit.Thing'
            change_object :Thing, set: { Name: "'updated'" }, commit: true
            return_value :Thing
          end
          microflow :DeleteThing do
            parameter :Thing, type: 'Audit.Thing'
            delete :Thing
            end_flow
          end
          microflow :CreateThenFail do
            create_object 'Audit.Thing', as: :thing, set: { Name: "'rejected'" }, commit: true
            error_event
          end
        end
      end

      project = Mxrb::Model::Project.open(mpr_path)
      store = described_class.new(project, path: database_path)
      interpreter = Mxrb::Runtime::Native::Interpreter.new(project, store:)
      detached = interpreter.call('Audit.CreateWithoutCommit')
      expect(detached.members['Name']).to eq('transient')
      expect(store.count('Audit.Thing')).to eq(0)

      durable = interpreter.call('Audit.CreateWithCommit')
      expect(store.count('Audit.Thing')).to eq(1)
      changed = interpreter.call('Audit.ChangeWithoutCommit', 'Thing' => durable)
      expect(changed.members['Name']).to eq('detached')
      expect(store.retrieve('Audit.Thing').first.members['Name']).to eq('durable')
      persisted = store.retrieve('Audit.Thing').first
      interpreter.call('Audit.ChangeWithCommit', 'Thing' => persisted)
      expect(store.retrieve('Audit.Thing').first.members['Name']).to eq('updated')
      expect { interpreter.call('Audit.CreateThenFail') }.to raise_error(Mxrb::NativeRuntimeError)
      expect(store.count('Audit.Thing')).to eq(1)
      interpreter.call('Audit.DeleteThing', 'Thing' => store.retrieve('Audit.Thing').first)
      expect(store.count('Audit.Thing')).to eq(0)
      store.close

      reopened = described_class.new(project, path: database_path)
      expect(reopened.count('Audit.Thing')).to eq(0)
      reopened.close
      project.close
    end
  end

  it 'keeps destructive schema evolution fail-closed unless explicitly enabled' do
    legacy = project(extra_pet_attributes: [attribute('Legacy', guid: 'legacy-column')])
    store = described_class.new(legacy, path: @database_path)
    pet = store.create('Store.Pet')
    pet.members['Legacy'] = 'preserve until approved'
    store.commit(pet)
    store.close

    expect { described_class.new(project, path: @database_path) }
      .to raise_error(Mxrb::Runtime::UnsafeSchemaMigrationError, /allow_destructive/)
    migrated = described_class.new(project, path: @database_path, allow_destructive: true)
    expect(migrated.retrieve('Store.Pet').first.members['Name']).to eq('unnamed')
    expect(migrated.schema.entity('Store.Pet').columns.map(&:name)).not_to include('Legacy')
    migrated.close
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength, Metrics/ParameterLists
