# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative '../../lib/mxrb/runtime/schema_migrator'
require_relative '../../lib/mxrb/runtime/sqlite_store'

# rubocop:disable Metrics/BlockLength, Metrics/ParameterLists
RSpec.describe Mxrb::Runtime::SchemaMigrator do
  def schema_attribute(name, guid:, type: :string, unique: false, required: false, default: nil, id: guid)
    Mxrb::Model::Attribute.new.tap do |attribute|
      attribute.id = id
      attribute.name = name
      attribute.type = type
      attribute.data_storage_guid = guid
      attribute.unique = unique
      attribute.required = required
      attribute.default_value = default
    end
  end

  def schema_entity(name, attributes, id: 'pet', guid: 'entity-pet', persistable: true, qualified: nil)
    Mxrb::Model::Entity.new.tap do |entity|
      entity.id = id
      entity.name = name
      entity.qualified_name = qualified || "Store.#{name}"
      entity.data_storage_guid = guid
      entity.persistable = persistable
      entity.system_members = { changed_date: true }
      entity.instance_variable_set(:@attributes, attributes)
    end
  end

  def schema_association(name, id:, from:, to:, type: :Reference)
    Mxrb::Model::Association.new.tap do |association|
      association.id = id
      association.name = name
      association.from_entity_id = from
      association.to_entity_id = to
      association.association_type = type
    end
  end

  def schema_project(name: 'Pet', weight: false)
    attributes = [schema_attribute('Name', guid: 'pet-name')]
    attributes << schema_attribute('Weight', guid: 'pet-weight', type: :decimal) if weight
    mod = Struct.new(:name, :entities, :associations).new(
      'Store', [schema_entity(name, attributes)], []
    )
    Struct.new(:modules).new([mod])
  end

  it 'migrates idempotently and preserves storage-guid columns across logical renames' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'schema.sqlite3')
      initial_project = schema_project
      initial = described_class.new(initial_project, database: path).migrate!
      repeated = described_class.new(initial_project, database: path).migrate!
      expect(initial.created_tables.size).to eq(1)
      expect(repeated).to have_attributes(created_tables: [], added_columns: [], rebuilt_tables: [])

      store = Mxrb::Runtime::SQLiteStore.new(initial_project, path: path)
      pet = store.create('Store.Pet')
      pet.members['Name'] = 'preserved'
      store.commit(pet)
      store.close

      renamed = schema_project(name: 'Animal', weight: true)
      migration = described_class.new(renamed, database: path).migrate!
      weight_column = described_class.physical_name('attribute', 'pet-weight')
      expect(migration.added_columns.one? { _1.end_with?(".#{weight_column}") }).to be(true)
      migrated = Mxrb::Runtime::SQLiteStore.new(renamed, path: path)
      expect(migrated.retrieve('Store.Animal').first.members['Name']).to eq('preserved')
      expect(migrated.retrieve('Store.Animal').first.members).to have_key('Weight')
      migrated.close
    end
  end

  it 'resolves short names and rejects unknown or ambiguous schema artifacts' do
    first = Mxrb::Runtime::EntitySchema.new('A.Item', 'a', 'a', [], {})
    second = Mxrb::Runtime::EntitySchema.new('B.Item', 'b', 'b', [], {})
    link_a = Mxrb::Runtime::AssociationSchema.new('Link', 'A.Link', 'a', 'a', 'A.Item', 'B.Item', :Reference)
    link_b = Mxrb::Runtime::AssociationSchema.new('Link', 'B.Link', 'b', 'b', 'B.Item', 'A.Item', :Reference)
    single = Mxrb::Runtime::RuntimeSchema.new([first], [link_a])
    ambiguous = Mxrb::Runtime::RuntimeSchema.new([first, second], [link_a, link_b])

    expect(single.entity('Item')).to eq(first)
    expect(single.association('Link')).to eq(link_a)
    expect { single.entity('Missing') }.to raise_error(ArgumentError, /unknown entity/)
    expect { ambiguous.entity('Item') }.to raise_error(ArgumentError, /ambiguous entity/)
    expect { single.association('Missing') }.to raise_error(ArgumentError, /unknown association/)
    expect { ambiguous.association('Link') }.to raise_error(ArgumentError, /ambiguous association/)
  end

  it 'derives cross-module and qualified targets and skips unresolved and transient entities' do
    source = schema_entity('Source', [], id: 'source', guid: '', qualified: '')
    transient = schema_entity('Scratch', [], id: 'scratch', guid: '', persistable: false)
    view = schema_entity('Report', [], id: 'view', guid: '')
    view.oql_query = 'SELECT 1'
    target = schema_entity('Target', [], id: 'target', guid: '', qualified: 'Remote.Target')
    links = [
      schema_association('Qualified', id: nil, from: 'source', to: 'External.Target'),
      schema_association('Cross', id: 'cross', from: 'source', to: 'target'),
      schema_association('Missing', id: 'missing', from: 'source', to: 'missing-target')
    ]
    first = Struct.new(:name, :entities, :associations).new('Local', [source, transient, view], links)
    second = Struct.new(:name, :entities, :associations).new('Remote', [target], [])
    derived = described_class.derive(Struct.new(:modules).new([first, second]))

    expect(derived.entities.map(&:name)).to contain_exactly('Local.Source', 'Remote.Target')
    expect(derived.associations.map(&:to_entity)).to contain_exactly('External.Target', 'Remote.Target')
    expect(derived.associations.first.storage_key).to eq('Local.Qualified')
  end

  it 'falls back from storage GUIDs to IDs and logical names and ignores disabled system flags' do
    columns = [
      schema_attribute('ById', guid: '', id: 'attribute-id'),
      schema_attribute('ByName', guid: '', id: '')
    ]
    fallback = schema_entity('Fallback', columns, id: '', guid: '', qualified: '')
    fallback.system_members = { owner: false, unsupported: true, created_date: true }
    mod = Struct.new(:name, :entities, :associations).new('Fallbacks', [fallback], [])
    definition = described_class.derive(Struct.new(:modules).new([mod])).entities.first

    expect(definition.storage_key).to eq('Fallbacks.Fallback')
    expect(definition.columns.map(&:storage_key)).to eq(
      ['attribute-id', 'Fallbacks.Fallback:ByName']
    )
    expect(definition.system_members.keys).to eq([:created_date])
  end

  it 'rebuilds incompatible entity and legacy association tables while preserving compatible rows' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'legacy.sqlite3')
      initial_project = schema_project
      described_class.new(initial_project, database: path).migrate!
      old_schema = described_class.derive(initial_project)
      entity = old_schema.entities.first
      name_column = entity.columns.first.sql_name
      database = SQLite3::Database.new(path)
      database.execute("INSERT INTO \"#{entity.table}\" (id, \"#{name_column}\") VALUES ('one', '7')")
      database.close

      integer = Struct.new(:name, :entities, :associations).new(
        'Store', [schema_entity('Pet', [schema_attribute('Name', guid: 'pet-name', type: :integer)])], []
      )
      changed = Struct.new(:modules).new([integer])
      result = described_class.new(changed, database: path).migrate!
      expect(result.rebuilt_tables).to eq([entity.table])
      expect(SQLite3::Database.new(path).get_first_value("SELECT \"#{name_column}\" FROM \"#{entity.table}\""))
        .to eq(7)

      owner = schema_entity('Owner', [], id: 'owner', guid: 'owner')
      pet = schema_entity('Pet', [], id: 'pet', guid: 'pet')
      link = schema_association('Pet_Owner', id: 'legacy-link', from: 'pet', to: 'owner')
      mod = Struct.new(:name, :entities, :associations).new('Store', [owner, pet], [link])
      legacy_project = Struct.new(:modules).new([mod])
      association_table = described_class.derive(legacy_project).associations.first.table
      legacy_path = File.join(dir, 'association.sqlite3')
      legacy_db = SQLite3::Database.new(legacy_path)
      legacy_db.execute("CREATE TABLE \"#{association_table}\" (source TEXT, target TEXT)")
      legacy_db.execute("INSERT INTO \"#{association_table}\" VALUES ('pet-1', 'owner-1')")
      legacy_db.close
      association_result = described_class.new(legacy_project, database: legacy_path).migrate!
      rows = SQLite3::Database.new(legacy_path).execute("SELECT source_id, target_id FROM \"#{association_table}\"")
      expect(association_result.rebuilt_tables).to eq([association_table])
      expect(rows).to eq([%w[pet-1 owner-1]])

      junk_path = File.join(dir, 'junk-association.sqlite3')
      junk_db = SQLite3::Database.new(junk_path)
      junk_db.execute("CREATE TABLE \"#{association_table}\" (legacy TEXT)")
      junk_db.close
      junk_result = described_class.new(legacy_project, database: junk_path).migrate!
      expect(junk_result.rebuilt_tables).to eq([association_table])
    end
  end

  it 'rolls the migration transaction back when a new uniqueness rule conflicts with data' do
    database = SQLite3::Database.new(':memory:')
    initial_project = schema_project
    described_class.new(initial_project, database: database).migrate!
    entity = described_class.derive(initial_project).entities.first
    column = entity.columns.first.sql_name
    database.execute("INSERT INTO \"#{entity.table}\" (id, \"#{column}\") VALUES ('1', 'same'), ('2', 'same')")
    unique_entity = schema_entity('Pet', [schema_attribute('Name', guid: 'pet-name', unique: true)])
    unique_project = Struct.new(:modules).new([
                                                Struct.new(:name, :entities, :associations).new('Store',
                                                                                                [unique_entity], [])
                                              ])

    expect { described_class.new(unique_project, database: database).migrate! }
      .to raise_error(SQLite3::ConstraintException)
    expect(database.transaction_active?).to be(false)
    expect(database.get_first_value("SELECT COUNT(*) FROM \"#{entity.table}\"")).to eq(2)
    database.close
  end

  it 'handles a migration failure before SQLite opens a transaction' do
    database = SQLite3::Database.new(':memory:')
    migrator = described_class.new(schema_project, database: database)
    failed_database = instance_double(SQLite3::Database, transaction_active?: false)
    allow(failed_database).to receive(:execute).with('BEGIN IMMEDIATE').and_raise(SQLite3::BusyException)
    migrator.instance_variable_set(:@database, failed_database)

    expect { migrator.migrate! }.to raise_error(SQLite3::BusyException)
    database.close
  end

  it 'can rebuild an entity with no compatible legacy columns' do
    database = SQLite3::Database.new(':memory:')
    migration_project = schema_project
    definition = described_class.derive(migration_project).entities.first
    database.execute("CREATE TABLE \"#{definition.table}\" (legacy TEXT)")
    migrator = described_class.new(migration_project, database: database)
    migrator.send(:rebuild_entity, definition, {})

    columns = database.execute("PRAGMA table_info(\"#{definition.table}\")").map { _1[1] }
    expect(columns).to include('id', definition.columns.first.sql_name)
    database.close
  end

  it 'enforces required columns and safely backfills a new required default' do
    database = SQLite3::Database.new(':memory:')
    initial = schema_project
    described_class.new(initial, database: database).migrate!
    definition = described_class.derive(initial).entities.first
    name_column = definition.columns.first.sql_name
    database.execute(
      "INSERT INTO \"#{definition.table}\" (id, \"#{name_column}\") VALUES ('one', NULL)"
    )

    required_name = schema_entity(
      'Pet', [schema_attribute('Name', guid: 'pet-name', required: true)]
    )
    unsafe = Struct.new(:modules).new([
                                        Struct.new(:name, :entities, :associations).new(
                                          'Store', [required_name], []
                                        )
                                      ])
    expect { described_class.new(unsafe, database: database).migrate! }
      .to raise_error(Mxrb::Runtime::UnsafeSchemaMigrationError, /NULL values exist/)
    nullable = database.execute("PRAGMA table_info(\"#{definition.table}\")").find { _1[1] == name_column }
    expect(nullable[3]).to eq(0)

    defaulted_name = schema_entity(
      'Pet', [schema_attribute('Name', guid: 'pet-name', required: true, default: 'unknown')]
    )
    safe = Struct.new(:modules).new([
                                      Struct.new(:name, :entities, :associations).new(
                                        'Store', [defaulted_name], []
                                      )
                                    ])
    result = described_class.new(safe, database: database).migrate!
    required = database.execute("PRAGMA table_info(\"#{definition.table}\")").find { _1[1] == name_column }
    expect(result.rebuilt_tables).to eq([definition.table])
    expect(required[3]).to eq(1)
    expect(database.get_first_value("SELECT \"#{name_column}\" FROM \"#{definition.table}\""))
      .to eq('unknown')
    database.close
  end

  it 'refuses a required addition without a default on populated data but permits empty tables' do
    database = SQLite3::Database.new(':memory:')
    initial = schema_project
    described_class.new(initial, database: database).migrate!
    definition = described_class.derive(initial).entities.first
    database.execute("INSERT INTO \"#{definition.table}\" (id) VALUES ('one')")
    required = schema_entity(
      'Pet', [
        schema_attribute('Name', guid: 'pet-name'),
        schema_attribute('Code', guid: 'pet-code', required: true)
      ]
    )
    evolved = Struct.new(:modules).new([
                                         Struct.new(:name, :entities, :associations).new(
                                           'Store', [required], []
                                         )
                                       ])
    expect { described_class.new(evolved, database: database).migrate! }
      .to raise_error(Mxrb::Runtime::UnsafeSchemaMigrationError, /without a default/)
    expect(database.execute("PRAGMA table_info(\"#{definition.table}\")").map { _1[1] })
      .not_to include(described_class.physical_name('attribute', 'pet-code'))
    database.execute("DELETE FROM \"#{definition.table}\"")
    expect(described_class.new(evolved, database: database).migrate!.rebuilt_tables)
      .to eq([definition.table])
    code = described_class.physical_name('attribute', 'pet-code')
    expect(database.execute("PRAGMA table_info(\"#{definition.table}\")").find { _1[1] == code }[3]).to eq(1)
    database.close
  end

  it 'refuses obsolete artifacts by default and removes only managed artifacts when explicitly allowed' do
    database = SQLite3::Database.new(':memory:')
    initial = schema_project(weight: true)
    described_class.new(initial, database: database).migrate!
    definition = described_class.derive(initial).entities.first
    name_column = definition.columns.find { _1.name == 'Name' }.sql_name
    weight_column = definition.columns.find { _1.name == 'Weight' }.sql_name
    database.execute(
      "INSERT INTO \"#{definition.table}\" (id, \"#{name_column}\", \"#{weight_column}\") " \
      "VALUES ('one', 'kept', 12.5)"
    )
    evolved = schema_project
    migrator = described_class.new(evolved, database: database)
    expect { migrator.migrate! }
      .to raise_error(Mxrb::Runtime::UnsafeSchemaMigrationError, /allow_destructive/)
    expect(migrator.migration_plan.removed_attributes.map { _1.fetch(:name) }).to eq(['Weight'])
    expect(database.get_first_value("SELECT \"#{weight_column}\" FROM \"#{definition.table}\""))
      .to eq(12.5)

    result = described_class.new(evolved, database: database, allow_destructive: true).migrate!
    expect(result.rebuilt_tables).to eq([definition.table])
    columns = database.execute("PRAGMA table_info(\"#{definition.table}\")").map { _1[1] }
    expect(columns).not_to include(weight_column)
    expect(database.get_first_value("SELECT \"#{name_column}\" FROM \"#{definition.table}\""))
      .to eq('kept')
    expect(database.get_first_value('SELECT COUNT(*) FROM mxrb_schema_attributes')).to eq(1)
    database.close
  end

  it 'removes managed entity and association tables transactionally in destructive mode' do
    database = SQLite3::Database.new(':memory:')
    owner = schema_entity('Owner', [], id: 'owner', guid: 'owner')
    pet = schema_entity('Pet', [schema_attribute('Name', guid: 'pet-name')], id: 'pet', guid: 'pet')
    link = schema_association('Pet_Owner', id: 'pet-owner', from: 'pet', to: 'owner')
    initial = Struct.new(:modules).new([
                                         Struct.new(:name, :entities, :associations).new(
                                           'Store', [owner, pet], [link]
                                         )
                                       ])
    described_class.new(initial, database: database).migrate!
    old_schema = described_class.derive(initial)
    owner_table = old_schema.entity('Owner').table
    association_table = old_schema.association('Pet_Owner').table
    evolved = Struct.new(:modules).new([
                                         Struct.new(:name, :entities, :associations).new(
                                           'Store', [pet], []
                                         )
                                       ])
    migrator = described_class.new(evolved, database: database, allow_destructive: true)
    migrator.migrate!
    tables = database.execute("SELECT name FROM sqlite_master WHERE type = 'table'").flatten
    expect(tables).not_to include(owner_table, association_table)
    expect(tables).to include(old_schema.entity('Pet').table)
    expect(migrator.migration_plan.removed_entities.map { _1.fetch(:name) }).to eq(['Store.Owner'])
    expect(migrator.migration_plan.removed_associations.map { _1.fetch(:name) }).to eq(['Store.Pet_Owner'])
    database.close
  end

  it 'upgrades legacy migration metadata and covers safe default and sequence evolution paths' do
    database = SQLite3::Database.new(':memory:')
    database.execute(<<~SQL)
      CREATE TABLE mxrb_schema_attributes (
        entity_key TEXT NOT NULL, storage_key TEXT NOT NULL, logical_name TEXT NOT NULL,
        column_name TEXT NOT NULL, logical_type TEXT NOT NULL,
        PRIMARY KEY (entity_key, storage_key)
      )
    SQL
    initial = schema_project
    described_class.new(initial, database: database).migrate!
    metadata_columns = database.execute('PRAGMA table_info(mxrb_schema_attributes)').map { _1[1] }
    expect(metadata_columns).to include('required', 'unique_value')
    definition = described_class.derive(initial).entities.first
    database.execute("INSERT INTO \"#{definition.table}\" (id) VALUES ('one')")

    with_default = schema_entity(
      'Pet', [
        schema_attribute('Name', guid: 'pet-name'),
        schema_attribute('Code', guid: 'pet-code', required: true, default: 'new')
      ]
    )
    evolved = Struct.new(:modules).new([
                                         Struct.new(:name, :entities, :associations).new(
                                           'Store', [with_default], []
                                         )
                                       ])
    described_class.new(evolved, database: database).migrate!
    code = described_class.physical_name('attribute', 'pet-code')
    expect(database.get_first_value("SELECT \"#{code}\" FROM \"#{definition.table}\""))
      .to eq('new')

    auto = schema_entity(
      'Counter', [schema_attribute('Number', guid: 'counter-number', type: :autonumber)],
      id: 'counter', guid: 'counter'
    )
    auto_modules = [
      Struct.new(:name, :entities, :associations).new('Store', [with_default, auto], [])
    ]
    auto_project = Struct.new(:modules).new(auto_modules)
    described_class.new(auto_project, database: database).migrate!
    described_class.new(auto_project, database: database).migrate!
    integer = schema_entity(
      'Counter', [schema_attribute('Number', guid: 'counter-number', type: :integer)],
      id: 'counter', guid: 'counter'
    )
    integer_modules = [
      Struct.new(:name, :entities, :associations).new('Store', [with_default, integer], [])
    ]
    integer_project = Struct.new(:modules).new(integer_modules)
    described_class.new(integer_project, database: database).migrate!
    expect(database.get_first_value('SELECT COUNT(*) FROM mxrb_schema_sequences')).to eq(0)
    database.close
  end

  it 'handles orphaned managed metadata defensively and formats every SQL default family' do
    database = SQLite3::Database.new(':memory:')
    migration_project = schema_project
    migrator = described_class.new(migration_project, database: database, allow_destructive: true)
    migrator.send(:create_metadata_tables)
    database.execute(
      'INSERT INTO mxrb_schema_attributes ' \
      '(entity_key, storage_key, logical_name, column_name, logical_type) VALUES (?, ?, ?, ?, ?)',
      %w[orphan orphan-attribute Orphan orphan_column string]
    )
    plan = migrator.send(:build_migration_plan)
    expect(plan.removed_attributes).to be_empty

    missing_table_change = {
      kind: :attribute, storage_key: 'old', entity_key: 'entity-pet',
      name: 'Old', table: 'missing', column: 'missing'
    }
    migrator.instance_variable_set(
      :@migration_plan,
      Mxrb::Runtime::SchemaMigrationPlan.new([], [missing_table_change], [])
    )
    rebuilt = [described_class.derive(migration_project).entities.first.table]
    expect { migrator.send(:apply_destructive_migration, rebuilt) }.not_to change(rebuilt, :size)
    migrator.migrate!
    migrator.instance_variable_set(
      :@migration_plan,
      Mxrb::Runtime::SchemaMigrationPlan.new([], [missing_table_change], [])
    )
    expect { migrator.send(:apply_destructive_migration, rebuilt) }.not_to change(rebuilt, :size)
    expect { migrator.send(:drop_managed_table, 'absent') }.not_to raise_error
    expect(migrator.send(:sql_literal, true, :boolean)).to eq('1')
    expect(migrator.send(:sql_literal, false, :boolean)).to eq('0')
    expect(migrator.send(:sql_literal, 7, :integer)).to eq('7')
    expect(migrator.send(:sql_literal, 1.5, :decimal)).to eq('1.5')
    expect(migrator.send(:sql_literal, "O'Brien", :string)).to eq("'O''Brien'")
    database.close
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/ParameterLists
