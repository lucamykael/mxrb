# frozen_string_literal: true

require 'digest'
require 'sqlite3'

module Mxrb
  module Runtime
    SchemaColumn = Data.define(
      :name, :storage_key, :sql_name, :sql_type, :type, :default, :required, :unique
    )
    EntitySchema = Data.define(:name, :storage_key, :table, :columns, :system_members)
    AssociationSchema = Data.define(
      :name, :qualified_name, :storage_key, :table, :from_entity, :to_entity, :type
    )
    RuntimeSchema = Data.define(:entities, :associations) do
      def entity(name)
        qualified = name.to_s
        exact = entities.find { _1.name == qualified }
        return exact if exact

        matches = entities.select { _1.name.split('.').last == qualified }
        return matches.first if matches.one?

        raise ArgumentError, matches.empty? ? "unknown entity #{name}" : "ambiguous entity #{name}"
      end

      def association(name)
        key = name.to_s
        matches = associations.select do |candidate|
          candidate.qualified_name == key || candidate.name == key ||
            candidate.qualified_name.split('.').last == key
        end
        return matches.first if matches.one?

        raise ArgumentError, matches.empty? ? "unknown association #{name}" : "ambiguous association #{name}"
      end
    end
    MigrationResult = Data.define(:created_tables, :added_columns, :rebuilt_tables)
    SchemaMigrationPlan = Data.define(
      :removed_entities, :removed_attributes, :removed_associations
    ) do
      def destructive?
        removed_entities.any? || removed_attributes.any? || removed_associations.any?
      end

      def changes = [*removed_entities, *removed_attributes, *removed_associations].freeze
    end

    # Raised before DDL when an evolution cannot preserve existing data safely.
    class UnsafeSchemaMigrationError < StandardError
      attr_reader :changes

      def initialize(message, changes: [])
        @changes = changes.freeze
        super(message)
      end
    end

    # Derives a deterministic SQLite schema from a parsed Mendix project and
    # evolves an existing database without relying on the Java Runtime.
    # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
    class SchemaMigrator
      SYSTEM_COLUMNS = {
        owner: %w[__owner_id TEXT],
        created_date: %w[__created_at TEXT],
        changed_date: %w[__changed_at TEXT],
        changed_by: %w[__changed_by_id TEXT]
      }.freeze
      TYPE_MAP = {
        integer: 'INTEGER', long: 'INTEGER', autonumber: 'INTEGER', boolean: 'INTEGER',
        float: 'REAL', decimal: 'REAL', binary: 'BLOB', datetime: 'TEXT', enum: 'TEXT',
        hashstring: 'TEXT', string: 'TEXT'
      }.freeze

      attr_reader :schema, :migration_plan

      def initialize(project, database:, allow_destructive: false)
        @project = project
        @allow_destructive = allow_destructive == true
        @owns_database = !database.is_a?(SQLite3::Database)
        @database = @owns_database ? SQLite3::Database.new(database.to_s) : database
        @schema = self.class.derive(project)
      end

      def self.derive(project)
        entities = []
        associations = []
        project.modules.each do |mod|
          by_id = mod.entities.to_h { [_1.id.to_s, qualified_entity_name(mod, _1)] }
          by_id.merge!(mod.entities.to_h { [qualified_entity_name(mod, _1), qualified_entity_name(mod, _1)] })
          mod.entities.select { _1.persistable != false && !_1.oql_view? }.each do |entity|
            entities << entity_schema(mod, entity)
          end
          mod.associations.each do |association|
            from = by_id[association.from_entity_id.to_s] || association.from_entity_id.to_s
            to = resolve_target(project, association.to_entity_id, by_id)
            next if from.empty? || to.empty?

            qualified = "#{mod.name}.#{association.name}"
            key = association.id.to_s.empty? ? qualified : association.id.to_s
            associations << AssociationSchema.new(
              association.name.to_s, qualified, key, physical_name('association', key),
              from, to, association.association_type.to_sym
            )
          end
        end
        RuntimeSchema.new(entities.freeze, associations.freeze)
      end

      def self.entity_schema(mod, entity)
        qualified = qualified_entity_name(mod, entity)
        key = entity.data_storage_guid.to_s
        key = entity.id.to_s if key.empty?
        key = qualified if key.empty?
        columns = entity.attributes.map do |attribute|
          attribute_key = attribute.data_storage_guid.to_s
          attribute_key = attribute.id.to_s if attribute_key.empty?
          attribute_key = "#{key}:#{attribute.name}" if attribute_key.empty?
          type = attribute.type.to_sym
          SchemaColumn.new(
            attribute.name.to_s, attribute_key, physical_name('attribute', attribute_key),
            TYPE_MAP.fetch(type, 'TEXT'), type, attribute.default_value, attribute.required == true,
            attribute.unique == true || type == :autonumber
          )
        end
        flags = (entity.system_members || {}).to_h.each_with_object({}) do |(name, enabled), selected|
          selected[name.to_sym] = SYSTEM_COLUMNS.fetch(name.to_sym) if enabled && SYSTEM_COLUMNS.key?(name.to_sym)
        end
        EntitySchema.new(qualified, key, physical_name('entity', key), columns.freeze, flags.freeze)
      end

      def self.qualified_entity_name(mod, entity)
        value = entity.qualified_name.to_s
        value.empty? ? "#{mod.name}.#{entity.name}" : value
      end

      def self.resolve_target(project, pointer, local)
        value = pointer.to_s
        return local[value] if local.key?(value)
        return value if value.include?('.')

        project.modules.each do |mod|
          entity = mod.entities.find { _1.id.to_s == value }
          return qualified_entity_name(mod, entity) if entity
        end
        ''
      end

      def self.physical_name(kind, key)
        "mxrb_#{kind}_#{Digest::SHA256.hexdigest(key.to_s)[0, 20]}"
      end

      def migrate!
        created = []
        added = []
        rebuilt = []
        transaction do
          create_metadata_tables
          @migration_plan = build_migration_plan
          reject_destructive_migration! if migration_plan.destructive? && !@allow_destructive
          apply_destructive_migration(rebuilt) if migration_plan.destructive?
          schema.entities.each { migrate_entity(_1, created, added, rebuilt) }
          schema.associations.each { migrate_association(_1, created, rebuilt) }
          synchronize_metadata
          prune_obsolete_metadata
        end
        MigrationResult.new(created.freeze, added.freeze, rebuilt.freeze)
      ensure
        @database.close if @owns_database
      end

      private

      def transaction
        @database.execute('BEGIN IMMEDIATE')
        yield
        @database.execute('COMMIT')
      rescue StandardError
        @database.execute('ROLLBACK') if @database.transaction_active?
        raise
      end

      def create_metadata_tables
        @database.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS mxrb_schema_entities (
            storage_key TEXT PRIMARY KEY, logical_name TEXT NOT NULL, table_name TEXT NOT NULL
          )
        SQL
        @database.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS mxrb_schema_attributes (
            entity_key TEXT NOT NULL, storage_key TEXT NOT NULL, logical_name TEXT NOT NULL,
            column_name TEXT NOT NULL, logical_type TEXT NOT NULL,
            required INTEGER NOT NULL DEFAULT 0, unique_value INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (entity_key, storage_key)
          )
        SQL
        @database.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS mxrb_schema_associations (
            storage_key TEXT PRIMARY KEY, logical_name TEXT NOT NULL, table_name TEXT NOT NULL,
            from_entity TEXT NOT NULL, to_entity TEXT NOT NULL, association_type TEXT NOT NULL
          )
        SQL
        @database.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS mxrb_schema_sequences (
            entity_key TEXT NOT NULL, attribute_key TEXT NOT NULL, next_value INTEGER NOT NULL,
            PRIMARY KEY (entity_key, attribute_key)
          )
        SQL
        ensure_metadata_column('mxrb_schema_attributes', 'required', 'INTEGER NOT NULL DEFAULT 0')
        ensure_metadata_column('mxrb_schema_attributes', 'unique_value', 'INTEGER NOT NULL DEFAULT 0')
      end

      def ensure_metadata_column(table, name, definition)
        return if table_columns(table).key?(name)

        @database.execute("ALTER TABLE #{quote(table)} ADD COLUMN #{quote(name)} #{definition}")
      end

      def build_migration_plan
        current_entities = schema.entities.to_h { [_1.storage_key, _1] }
        current_attributes = schema.entities.flat_map do |entity|
          entity.columns.map { [[entity.storage_key, _1.storage_key], [entity, _1]] }
        end.to_h
        current_associations = schema.associations.to_h { [_1.storage_key, _1] }

        removed_entities = metadata_rows(
          'SELECT storage_key, logical_name, table_name FROM mxrb_schema_entities',
          %w[storage_key logical_name table_name]
        ).filter_map do |key, name, table|
          { kind: :entity, storage_key: key, name:, table: } unless current_entities.key?(key)
        end
        removed_entity_keys = removed_entities.to_h { [_1.fetch(:storage_key), true] }
        removed_attributes = metadata_rows(
          'SELECT entity_key, storage_key, logical_name, column_name FROM mxrb_schema_attributes',
          %w[entity_key storage_key logical_name column_name]
        ).filter_map do |entity_key, key, name, column|
          next if removed_entity_keys.key?(entity_key) || current_attributes.key?([entity_key, key])

          entity = current_entities[entity_key]
          next unless entity

          { kind: :attribute, storage_key: key, entity_key:, name:, table: entity.table, column: }
        end
        removed_associations = metadata_rows(
          'SELECT storage_key, logical_name, table_name FROM mxrb_schema_associations',
          %w[storage_key logical_name table_name]
        ).filter_map do |key, name, table|
          { kind: :association, storage_key: key, name:, table: } unless current_associations.key?(key)
        end
        SchemaMigrationPlan.new(
          removed_entities.freeze, removed_attributes.freeze, removed_associations.freeze
        )
      end

      def metadata_rows(sql, columns)
        @database.execute(sql).map do |row|
          row.is_a?(Hash) ? columns.map { row[_1] } : row
        end
      end

      def reject_destructive_migration!
        descriptions = migration_plan.changes.map do |change|
          "#{change.fetch(:kind)} #{change.fetch(:name)}"
        end
        raise UnsafeSchemaMigrationError.new(
          "schema migration would remove #{descriptions.join(', ')}; " \
          'rerun with allow_destructive: true after backing up the database',
          changes: migration_plan.changes
        )
      end

      def apply_destructive_migration(rebuilt)
        migration_plan.removed_associations.each { drop_managed_table(_1.fetch(:table)) }
        migration_plan.removed_entities.each { drop_managed_table(_1.fetch(:table)) }
        migration_plan.removed_attributes.group_by { _1.fetch(:entity_key) }.each_key do |entity_key|
          entity = schema.entities.find { _1.storage_key == entity_key }
          next unless entity && table?(entity.table)

          rebuild_entity(entity, table_columns(entity.table))
          rebuilt << entity.table unless rebuilt.include?(entity.table)
        end
      end

      def drop_managed_table(table)
        @database.execute("DROP TABLE #{quote(table)}") if table?(table)
      end

      def migrate_entity(entity, created, added, rebuilt)
        unless table?(entity.table)
          @database.execute(create_entity_sql(entity))
          create_entity_indexes(entity)
          created << entity.table
          return
        end

        actual = table_columns(entity.table)
        expected = entity_columns(entity)
        missing = expected.keys - actual.keys
        incompatible = (expected.keys & actual.keys).any? do |name|
          normalize_type(actual.fetch(name).fetch(:type)) != normalize_type(expected.fetch(name)) ||
            required_changed?(name, actual.fetch(name), expected.fetch(name))
        end
        required_missing = missing.any? { required_definition?(expected.fetch(_1)) }
        validate_required_values!(entity, actual, missing) if incompatible || required_missing
        if incompatible || required_missing
          rebuild_entity(entity, actual)
          rebuilt << entity.table
        else
          missing.each do |name|
            @database.execute(
              "ALTER TABLE #{quote(entity.table)} ADD COLUMN #{quote(name)} #{expected.fetch(name)}"
            )
            added << "#{entity.table}.#{name}"
          end
        end
        create_entity_indexes(entity)
      end

      def migrate_association(association, created, rebuilt)
        unless table?(association.table)
          @database.execute(create_association_sql(association))
          created << association.table
          return
        end
        actual = table_columns(association.table)
        required = %w[source_id target_id]
        return if (required - actual.keys).empty?

        temporary = "#{association.table}_new"
        @database.execute("DROP TABLE IF EXISTS #{quote(temporary)}")
        @database.execute(create_association_sql(association, table: temporary))
        source = %w[source_id source owner_id].find { actual.key?(_1) }
        target = %w[target_id target child_id].find { actual.key?(_1) }
        if source && target
          @database.execute(
            "INSERT OR IGNORE INTO #{quote(temporary)} (source_id, target_id) " \
            "SELECT #{quote(source)}, #{quote(target)} FROM #{quote(association.table)} " \
            "WHERE #{quote(source)} IS NOT NULL AND #{quote(target)} IS NOT NULL"
          )
        end
        @database.execute("DROP TABLE #{quote(association.table)}")
        @database.execute("ALTER TABLE #{quote(temporary)} RENAME TO #{quote(association.table)}")
        rebuilt << association.table
      end

      def rebuild_entity(entity, actual)
        temporary = "#{entity.table}_new"
        @database.execute("DROP TABLE IF EXISTS #{quote(temporary)}")
        @database.execute(create_entity_sql(entity, table: temporary))
        copies = copy_expressions(entity, actual)
        unless copies.empty?
          fields = copies.map { quote(_1.first) }.join(', ')
          expressions = copies.map(&:last).join(', ')
          @database.execute(
            "INSERT INTO #{quote(temporary)} (#{fields}) " \
            "SELECT #{expressions} FROM #{quote(entity.table)}"
          )
        end
        @database.execute("DROP TABLE #{quote(entity.table)}")
        @database.execute("ALTER TABLE #{quote(temporary)} RENAME TO #{quote(entity.table)}")
        create_entity_indexes(entity)
      end

      def create_entity_sql(entity, table: entity.table)
        definitions = entity_columns(entity).map do |name, definition|
          suffix = name == 'id' ? ' PRIMARY KEY' : ''
          "#{quote(name)} #{definition}#{suffix}"
        end
        "CREATE TABLE #{quote(table)} (#{definitions.join(', ')})"
      end

      def create_entity_indexes(entity)
        entity.columns.select(&:unique).each do |column|
          index = self.class.physical_name('unique', "#{entity.storage_key}:#{column.storage_key}")
          @database.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS #{quote(index)} " \
            "ON #{quote(entity.table)} (#{quote(column.sql_name)})"
          )
        end
      end

      def create_association_sql(association, table: association.table)
        uniqueness = association.type == :Reference ? ', UNIQUE (source_id)' : ''
        <<~SQL.strip
          CREATE TABLE #{quote(table)} (
            source_id TEXT NOT NULL, target_id TEXT NOT NULL,
            PRIMARY KEY (source_id, target_id)#{uniqueness}
          )
        SQL
      end

      def entity_columns(entity)
        result = { 'id' => 'TEXT' }
        entity.columns.each { result[_1.sql_name] = column_definition(_1) }
        entity.system_members.each_value { |(name, type)| result[name] = type }
        result
      end

      def column_definition(column)
        definition = column.sql_type.dup
        definition << ' NOT NULL' if column.required
        definition << " DEFAULT #{sql_literal(column.default, column.type)}" unless column.default.nil?
        definition
      end

      def required_definition?(definition) = definition.match?(/\bNOT NULL\b/i)

      def required_changed?(name, actual, expected)
        return false if name == 'id'

        actual.fetch(:not_null) != required_definition?(expected)
      end

      def validate_required_values!(entity, actual, missing)
        return unless table_row_count(entity.table).positive?

        entity.columns.select(&:required).each do |column|
          if missing.include?(column.sql_name)
            reject_missing_required!(entity, column) if column.default.nil?
          elsif actual.key?(column.sql_name) && column.default.nil? && null_values?(entity.table, column.sql_name)
            raise UnsafeSchemaMigrationError.new(
              "cannot make #{entity.name}.#{column.name} required while NULL values exist",
              changes: [{ kind: :required, entity: entity.name, attribute: column.name }]
            )
          end
        end
      end

      def reject_missing_required!(entity, column)
        raise UnsafeSchemaMigrationError.new(
          "cannot add required attribute #{entity.name}.#{column.name} to a populated table without a default",
          changes: [{ kind: :required, entity: entity.name, attribute: column.name }]
        )
      end

      def null_values?(table, column)
        @database.get_first_value(
          "SELECT 1 FROM #{quote(table)} WHERE #{quote(column)} IS NULL LIMIT 1"
        ) == 1
      end

      def table_row_count(table)
        @database.get_first_value("SELECT COUNT(*) FROM #{quote(table)}").to_i
      end

      def copy_expressions(entity, actual)
        columns = entity.columns.to_h { [_1.sql_name, _1] }
        entity_columns(entity).filter_map do |name, _definition|
          if actual.key?(name)
            column = columns[name]
            expression = if column&.required && !column.default.nil?
                           "COALESCE(#{quote(name)}, #{sql_literal(column.default, column.type)})"
                         else
                           quote(name)
                         end
            [name, expression]
          elsif columns[name]&.required && !columns[name].default.nil?
            [name, sql_literal(columns[name].default, columns[name].type)]
          end
        end
      end

      def sql_literal(value, type)
        return value ? '1' : '0' if type == :boolean
        return value.to_i.to_s if %i[integer long autonumber].include?(type)
        return value.to_f.to_s if %i[float decimal].include?(type)

        "'#{value.to_s.gsub("'", "''")}'"
      end

      def table?(name)
        !@database.get_first_value(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?", name
        ).nil?
      end

      def table_columns(name)
        @database.execute("PRAGMA table_info(#{quote(name)})").to_h do |row|
          if row.is_a?(Hash)
            [row['name'], { type: row['type'], not_null: row['notnull'].to_i == 1 }]
          else
            [row[1], { type: row[2], not_null: row[3].to_i == 1 }]
          end
        end
      end

      def normalize_type(type)
        type.to_s.upcase.split.first
      end

      def synchronize_metadata
        schema.entities.each do |entity|
          @database.execute(
            'INSERT INTO mxrb_schema_entities VALUES (?, ?, ?) ' \
            'ON CONFLICT(storage_key) DO UPDATE SET logical_name=excluded.logical_name, table_name=excluded.table_name',
            [entity.storage_key, entity.name, entity.table]
          )
          entity.columns.each do |column|
            @database.execute(
              'INSERT INTO mxrb_schema_attributes ' \
              '(entity_key, storage_key, logical_name, column_name, logical_type, required, unique_value) ' \
              'VALUES (?, ?, ?, ?, ?, ?, ?) ' \
              'ON CONFLICT(entity_key, storage_key) DO UPDATE SET ' \
              'logical_name=excluded.logical_name, column_name=excluded.column_name, ' \
              'logical_type=excluded.logical_type, required=excluded.required, ' \
              'unique_value=excluded.unique_value',
              [entity.storage_key, column.storage_key, column.name, column.sql_name,
               column.type.to_s, column.required ? 1 : 0, column.unique ? 1 : 0]
            )
            synchronize_sequence(entity, column) if column.type == :autonumber
          end
        end
        schema.associations.each do |association|
          @database.execute(
            'INSERT INTO mxrb_schema_associations VALUES (?, ?, ?, ?, ?, ?) ' \
            'ON CONFLICT(storage_key) DO UPDATE SET logical_name=excluded.logical_name, ' \
            'table_name=excluded.table_name, from_entity=excluded.from_entity, ' \
            'to_entity=excluded.to_entity, association_type=excluded.association_type',
            [association.storage_key, association.qualified_name, association.table,
             association.from_entity, association.to_entity, association.type.to_s]
          )
        end
      end

      def prune_obsolete_metadata
        entity_keys = schema.entities.map(&:storage_key)
        association_keys = schema.associations.map(&:storage_key)
        attribute_keys = schema.entities.flat_map do |entity|
          entity.columns.map { [entity.storage_key, _1.storage_key] }
        end
        delete_missing_keys('mxrb_schema_associations', 'storage_key', association_keys)
        delete_missing_attribute_keys(attribute_keys)
        delete_missing_keys('mxrb_schema_entities', 'storage_key', entity_keys)
        sequence_keys = schema.entities.flat_map do |entity|
          entity.columns.select { _1.type == :autonumber }.map { [entity.storage_key, _1.storage_key] }
        end
        delete_missing_sequence_keys(sequence_keys)
      end

      def delete_missing_keys(table, column, keys)
        if keys.empty?
          @database.execute("DELETE FROM #{quote(table)}")
          return
        end

        placeholders = Array.new(keys.size, '?').join(', ')
        @database.execute(
          "DELETE FROM #{quote(table)} WHERE #{quote(column)} NOT IN (#{placeholders})", keys
        )
      end

      def delete_missing_attribute_keys(keys)
        current = keys.to_h { [_1, true] }
        metadata_rows(
          'SELECT entity_key, storage_key FROM mxrb_schema_attributes', %w[entity_key storage_key]
        ).each do |entity_key, storage_key|
          next if current.key?([entity_key, storage_key])

          @database.execute(
            'DELETE FROM mxrb_schema_attributes WHERE entity_key = ? AND storage_key = ?',
            [entity_key, storage_key]
          )
        end
      end

      def delete_missing_sequence_keys(attribute_keys)
        current = attribute_keys.to_h { [_1, true] }
        metadata_rows(
          'SELECT entity_key, attribute_key FROM mxrb_schema_sequences', %w[entity_key attribute_key]
        ).each do |entity_key, attribute_key|
          next if current.key?([entity_key, attribute_key])

          @database.execute(
            'DELETE FROM mxrb_schema_sequences WHERE entity_key = ? AND attribute_key = ?',
            [entity_key, attribute_key]
          )
        end
      end

      def synchronize_sequence(entity, column)
        maximum = @database.get_first_value(
          "SELECT COALESCE(MAX(#{quote(column.sql_name)}), 0) FROM #{quote(entity.table)}"
        ).to_i
        @database.execute(
          'INSERT OR IGNORE INTO mxrb_schema_sequences VALUES (?, ?, ?)',
          [entity.storage_key, column.storage_key, maximum + 1]
        )
      end

      def quote(identifier)
        %("#{identifier.to_s.gsub('"', '""')}")
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
