# frozen_string_literal: true

require 'date'
require 'securerandom'
require 'time'
require_relative 'native'
require_relative 'schema_migrator'

module Mxrb
  module Runtime
    # SQLite-backed replacement for Runtime::Native::Store. ObjectValue stays
    # the public value type, so the native microflow interpreter can use this
    # store without a persistence-specific object abstraction.
    # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
    class SQLiteStore
      EVENTS = %i[
        before_create after_create before_update after_update
        before_commit after_commit before_delete after_delete
      ].freeze
      SYSTEM_MEMBERS = {
        owner: %w[Owner __owner_id], created_date: %w[createdDate __created_at],
        changed_date: %w[changedDate __changed_at], changed_by: %w[changedBy __changed_by_id]
      }.freeze

      attr_reader :database, :schema

      def initialize(project, path: ':memory:', defaults: {}, hooks: {}, allow_destructive: false)
        @database = SQLite3::Database.new(path.to_s)
        @database.results_as_hash = true
        @database.execute('PRAGMA foreign_keys = ON')
        @database.busy_timeout = 5_000
        @schema = SchemaMigrator.new(
          project, database: @database, allow_destructive:
        ).tap(&:migrate!).schema
        @defaults = defaults.transform_keys(&:to_s)
        transient_defaults = project.modules.flat_map do |mod|
          mod.entities.select { _1.persistable == false }.map do |entity|
            ["#{mod.name}.#{entity.name}", defaults.fetch("#{mod.name}.#{entity.name}", {})]
          end
        end.to_h
        @transient_entities = transient_defaults.keys.freeze
        @transient = Native::Store.new(defaults: transient_defaults)
        @hooks = Hash.new { |values, event| values[event] = [] }
        @identity = {}
        @persisted = {}
        @staged_new = {}
        @sequence_values = {}
        @manual_transaction = false
        hooks.each { |event, callbacks| Array(callbacks).each { on(event, &_1) } }
      end

      def on(event_or_entity, positional_event = nil, entity: nil, &block)
        entity ||= event_or_entity if positional_event
        event = positional_event || event_or_entity
        key = event.to_sym
        raise ArgumentError, "unsupported lifecycle event #{event}" unless EVENTS.include?(key)
        raise ArgumentError, 'lifecycle hook requires a block' unless block

        @hooks[key] << [entity&.to_s, block]
        @transient.on(transient_name(entity), key) { |value| block.call(value, self) } if entity && transient?(entity)
        unless entity
          @transient_entities.each do |name|
            @transient.on(name, key) { |value| block.call(value, self) }
          end
        end
        self
      end

      def create(entity, events: true)
        return @transient.create(transient_name(entity), events:) if transient?(entity)

        definition = schema.entity(entity)
        value = nil
        atomic do
          members = defaults_for(definition)
          value = Native::ObjectValue.new(entity: definition.name, id: SecureRandom.uuid, members:)
          run_hooks(:before_create, value) if events
          stage(value)
          run_hooks(:after_create, value) if events
        end
        value
      rescue StandardError
        @identity.delete(value&.id)
        @persisted.delete(value&.id)
        @staged_new.delete(value&.id)
        raise
      end

      def retrieve(entity)
        return @transient.retrieve(transient_name(entity)) if transient?(entity)

        definition = schema.entity(entity)
        rows = database.execute("SELECT * FROM #{quote(definition.table)} ORDER BY rowid")
        values = rows.map { materialize(definition, _1) }
        values.concat(@staged_new.values.select { _1.entity == definition.name })
        load_direct_associations(values)
        values.uniq(&:id)
      end

      def retrieve_association(association, start)
        return [] unless start

        definition = begin
          schema.association(association)
        rescue ArgumentError
          return @transient.retrieve_association(association, start) if transient?(start.entity)

          raise
        end
        return volatile_association_values(definition, association, start) if hybrid_association?(definition)

        return @transient.retrieve_association(association, start) if transient?(start.entity)

        if start.entity == definition.from_entity
          ids = database.execute(
            "SELECT target_id FROM #{quote(definition.table)} WHERE source_id = ? ORDER BY rowid", [start.id]
          ).map { _1['target_id'] }
          materialize_ids(definition.to_entity, ids)
        elsif start.entity == definition.to_entity
          ids = database.execute(
            "SELECT source_id FROM #{quote(definition.table)} WHERE target_id = ? ORDER BY rowid", [start.id]
          ).map { _1['source_id'] }
          materialize_ids(definition.from_entity, ids)
        else
          []
        end
      end

      def delete(value, events: true)
        transient, persistent = Array(value).compact.partition { transient?(_1.entity) }
        @transient.delete(transient, events:) unless transient.empty?
        persistent.each { delete_one(_1, events:) }
        nil
      end

      def count(entity, predicate = nil)
        return @transient.count(transient_name(entity), predicate) if transient?(entity)

        return retrieve(entity).count { predicate.call(_1) } if predicate

        definition = schema.entity(entity)
        durable = database.get_first_value("SELECT COUNT(*) FROM #{quote(definition.table)}").to_i
        durable + @staged_new.values.count { _1.entity == definition.name }
      end

      def commit(value = nil, events: true)
        values = value.nil? ? dirty_values : Array(value)
        transient, persistent = values.compact.partition { transient?(_1.entity) }
        @transient.commit(transient, events:) unless transient.empty?
        atomic { persistent.each { persist_update(_1, events:) } }
        finish_manual_transaction if value.nil? && @manual_transaction
        value
      end

      def begin_transaction
        raise SQLite3::SQLException, 'transaction already active' if @manual_transaction

        @manual_snapshot = snapshot
        database.execute('BEGIN IMMEDIATE')
        @manual_transaction = true
        self
      end

      def transaction
        state = snapshot
        begin_transaction
        result = yield self
        finish_manual_transaction
        detach_uncommitted
        result
      rescue Exception # rubocop:disable Lint/RescueException
        rollback if @manual_transaction
        restore(state)
        raise
      end

      def rollback(value = nil)
        return rollback_values(value) unless value.nil?

        state = @manual_snapshot
        database.execute('ROLLBACK') if database.transaction_active?
        @manual_transaction = false
        @manual_snapshot = nil
        clear_cache
        restore(state) if state
        self
      end

      def snapshot
        result = schema.entities.to_h do |entity|
          [entity.name, retrieve(entity.name).map { duplicate_value(_1) }]
        end
        result['__mxrb_transient__'] = @transient.snapshot
        result['__mxrb_uow__'] = {
          persisted: @persisted.transform_values(&:dup),
          staged_ids: @staged_new.keys,
          associations: association_snapshot
        }
        result
      end

      def restore(snapshot)
        unit_of_work = snapshot['__mxrb_uow__']
        atomic do
          schema.associations.each { database.execute("DELETE FROM #{quote(_1.table)}") }
          schema.entities.each { database.execute("DELETE FROM #{quote(_1.table)}") }
          clear_cache
          if unit_of_work
            restore_unit_of_work(snapshot, unit_of_work)
          else
            restore_legacy_snapshot(snapshot)
          end
        end
        @transient.restore(snapshot.fetch('__mxrb_transient__', @transient.snapshot))
        self
      end

      def close
        rollback if @manual_transaction
        database.close unless database.closed?
      end

      private

      def restore_legacy_snapshot(snapshot)
        snapshot.each do |entity, values|
          next if entity.start_with?('__mxrb_')

          definition = schema.entity(entity)
          Array(values).each do |value|
            copy = duplicate_value(value)
            insert_value(copy, definition, associations: false)
            cache(copy)
          end
        end
        @identity.each_value { persist_associations(_1, schema.entity(_1.entity)) }
      end

      def restore_unit_of_work(snapshot, unit_of_work)
        working = snapshot.each_with_object({}) do |(entity, values), records|
          next if entity.start_with?('__mxrb_')

          Array(values).each { records[_1.id] = duplicate_value(_1) }
        end
        persisted = unit_of_work.fetch(:persisted, unit_of_work.fetch('persisted', {}))
        persisted.each do |id, members|
          current = working[id]
          next unless current

          definition = schema.entity(current.entity)
          durable = Native::ObjectValue.new(entity: current.entity, id:, members: members.dup)
          insert_value(durable, definition, associations: false)
        end
        restore_associations(unit_of_work.fetch(:associations, unit_of_work.fetch('associations', {})))
        working.each_value do |value|
          @identity[value.id] = value
          if persisted.key?(value.id)
            @persisted[value.id] = persisted.fetch(value.id).dup
          else
            @staged_new[value.id] = value
          end
        end
      end

      def delete_one(value, events: true)
        definition = schema.entity(value.entity)
        atomic do
          run_hooks(:before_delete, value) if events
          schema.associations.each do |association|
            next unless [association.from_entity, association.to_entity].include?(definition.name)

            database.execute(
              "DELETE FROM #{quote(association.table)} WHERE source_id = ? OR target_id = ?", [value.id, value.id]
            )
          end
          database.execute("DELETE FROM #{quote(definition.table)} WHERE id = ?", [value.id])
          @identity.delete(value.id)
          @persisted.delete(value.id)
          @staged_new.delete(value.id)
          run_hooks(:after_delete, value) if events
        end
      end

      def persist_update(value, events: true)
        definition = schema.entity(value.entity)
        previous = @persisted[value.id]
        return persist_new(value, definition, events:) if @staged_new.key?(value.id)
        raise ArgumentError, "object #{value.id} is not persisted" unless previous

        return value if comparable_members(value.members) == comparable_members(previous)

        original = previous.dup
        run_hooks(:before_update, value) if events
        run_hooks(:before_commit, value) if events
        update_system_members(value, definition)
        fields, values = persisted_fields(value, definition)
        assignments = fields.map { "#{quote(_1)} = ?" }.join(', ')
        unless fields.empty?
          database.execute(
            "UPDATE #{quote(definition.table)} SET #{assignments} WHERE id = ?", [*values, value.id]
          )
        end
        persist_associations(value, definition)
        @persisted[value.id] = value.members.dup
        run_hooks(:after_commit, value) if events
        run_hooks(:after_update, value) if events
        value
      rescue StandardError
        value.members.replace(original) if original
        raise
      end

      def persist_new(value, definition, events: true)
        run_hooks(:before_commit, value) if events
        insert_value(value, definition)
        advance_sequences(value, definition)
        @staged_new.delete(value.id)
        cache(value)
        run_hooks(:after_commit, value) if events
        value
      rescue StandardError
        @identity[value.id] = value
        @staged_new[value.id] = value
        @persisted.delete(value.id)
        raise
      end

      def insert_value(value, definition, associations: true)
        set_creation_system_members(value, definition)
        fields, values = persisted_fields(value, definition)
        fields.unshift('id')
        values.unshift(value.id)
        placeholders = Array.new(fields.size, '?').join(', ')
        database.execute(
          "INSERT INTO #{quote(definition.table)} (#{fields.map { quote(_1) }.join(', ')}) " \
          "VALUES (#{placeholders})", values
        )
        persist_associations(value, definition) if associations
      end

      def persisted_fields(value, definition)
        fields = []
        values = []
        definition.columns.each do |column|
          fields << column.sql_name
          values << serialize(value.members[column.name], column.type)
        end
        definition.system_members.each do |name, (sql_name, _type)|
          fields << sql_name
          values << serialize_system(value.members[SYSTEM_MEMBERS.fetch(name).first])
        end
        [fields, values]
      end

      def persist_associations(value, entity)
        schema.associations.select { _1.from_entity == entity.name }.each do |association|
          next if hybrid_association?(association)

          database.execute("DELETE FROM #{quote(association.table)} WHERE source_id = ?", [value.id])
          targets = Array(value.members[association.name]).compact
          targets = targets.first(1) if association.type == :Reference
          targets.each do |target|
            target_id = target.respond_to?(:id) ? target.id : target.to_s
            database.execute(
              "INSERT OR IGNORE INTO #{quote(association.table)} (source_id, target_id) VALUES (?, ?)",
              [value.id, target_id]
            )
          end
        end
      end

      def materialize(definition, row)
        cached = @identity[row['id']]
        return cached if cached

        members = definition.columns.to_h do |column|
          [column.name, deserialize(row[column.sql_name], column.type)]
        end
        definition.system_members.each_key do |name|
          logical, sql_name = SYSTEM_MEMBERS.fetch(name)
          members[logical] = deserialize_system(row[sql_name], name)
        end
        value = Native::ObjectValue.new(entity: definition.name, id: row['id'], members:)
        cache(value)
        value
      end

      def materialize_ids(entity, ids)
        return [] if ids.empty?

        definition = schema.entity(entity)
        placeholders = Array.new(ids.size, '?').join(', ')
        rows = database.execute(
          "SELECT * FROM #{quote(definition.table)} WHERE id IN (#{placeholders})", ids
        ).to_h { [_1['id'], _1] }
        ids.filter_map { |id| rows[id] && materialize(definition, rows[id]) }
      end

      def load_direct_associations(values)
        values.each do |value|
          schema.associations.select { _1.from_entity == value.entity }.each do |association|
            related = retrieve_association(association.qualified_name, value)
            value.members[association.name] = association.type == :Reference ? related.first : related
            @persisted[value.id] = value.members.dup unless @staged_new.key?(value.id)
          end
        end
      end

      def cache(value)
        @identity[value.id] = value
        @persisted[value.id] = value.members.dup
        @staged_new.delete(value.id)
      end

      def stage(value)
        @identity[value.id] = value
        @staged_new[value.id] = value
      end

      def clear_cache
        @identity.clear
        @persisted.clear
        @staged_new.clear
      end

      def dirty_values
        @staged_new.values + @identity.values.reject do |value|
          next true if @staged_new.key?(value.id)

          comparable_members(value.members) == comparable_members(@persisted.fetch(value.id, {}))
        end
      end

      def comparable_members(members)
        members.transform_values do |value|
          case value
          when Array then value.map { _1.respond_to?(:id) ? _1.id : _1 }
          else value.respond_to?(:id) ? value.id : value
          end
        end
      end

      def defaults_for(entity)
        generated = entity.columns.to_h do |column|
          default = column.type == :autonumber ? next_autonumber(entity, column) : column.default
          [column.name, cast_default(default, column.type)]
        end
        generated.merge(@defaults.fetch(entity.name, @defaults.fetch(entity.name.split('.').last, {})).dup)
      end

      def next_autonumber(entity, column)
        key = [entity.storage_key, column.storage_key]
        stored = database.get_first_value(
          'SELECT next_value FROM mxrb_schema_sequences WHERE entity_key = ? AND attribute_key = ?', key
        )
        raise "missing AutoNumber sequence for #{entity.name}.#{column.name}" unless stored

        value = [stored.to_i, @sequence_values.fetch(key, stored).to_i].max
        @sequence_values[key] = value.to_i + 1
        value.to_i
      end

      def advance_sequences(value, entity)
        entity.columns.select { _1.type == :autonumber }.each do |column|
          next_value = value.members[column.name].to_i + 1
          database.execute(
            'UPDATE mxrb_schema_sequences SET next_value = MAX(next_value, ?) ' \
            'WHERE entity_key = ? AND attribute_key = ?',
            [next_value, entity.storage_key, column.storage_key]
          )
        end
      end

      def cast_default(value, type)
        return nil if value.nil? || value == ''
        return value == true || value.to_s.casecmp?('true') if type == :boolean
        return value.to_i if %i[integer long autonumber].include?(type)
        return value.to_f if %i[float decimal].include?(type)

        value
      end

      def set_creation_system_members(value, entity)
        now = Time.now.utc
        value.members['createdDate'] ||= now if entity.system_members.key?(:created_date)
        value.members['changedDate'] ||= now if entity.system_members.key?(:changed_date)
      end

      def update_system_members(value, entity)
        value.members['changedDate'] = Time.now.utc if entity.system_members.key?(:changed_date)
      end

      def serialize(value, type)
        return nil if value.nil?
        return value ? 1 : 0 if type == :boolean
        return value.utc.iso8601(6) if type == :datetime && value.respond_to?(:utc)
        return value.iso8601 if type == :datetime && value.respond_to?(:iso8601)

        value
      end

      def deserialize(value, type)
        return nil if value.nil?
        return value.to_i != 0 if type == :boolean
        return Time.parse(value) if type == :datetime

        value
      rescue ArgumentError
        value
      end

      def serialize_system(value)
        return value.id if value.respond_to?(:id)
        return value.utc.iso8601(6) if value.respond_to?(:utc)

        value
      end

      def deserialize_system(value, name)
        return nil if value.nil?
        return Time.parse(value) if %i[created_date changed_date].include?(name)

        value
      rescue ArgumentError
        value
      end

      def duplicate_value(value)
        Native::ObjectValue.new(entity: value.entity, id: value.id, members: value.members.dup)
      end

      def rollback_values(values)
        transient, persistent = Array(values).compact.partition { transient?(_1.entity) }
        @transient.rollback(transient) unless transient.empty?
        persistent.each do |value|
          if @staged_new.delete(value.id)
            @identity.delete(value.id)
            next
          end

          definition = schema.entity(value.entity)
          row = database.get_first_row("SELECT * FROM #{quote(definition.table)} WHERE id = ?", value.id)
          next unless row

          @identity.delete(value.id)
          persisted = materialize(definition, row)
          load_direct_associations([persisted])
          value.members.replace(persisted.members)
          @identity[value.id] = value
          @persisted[value.id] = value.members.dup
        end
        values
      end

      def transient?(entity)
        !transient_name(entity).nil?
      end

      def transient_name(entity)
        name = entity.to_s
        return name if @transient_entities.include?(name)

        matches = @transient_entities.select { _1.split('.').last == name }
        matches.first if matches.one?
      end

      def hybrid_association?(association)
        transient?(association.from_entity) || transient?(association.to_entity)
      end

      def volatile_association_values(definition, requested_name, start)
        keys = [definition.name, definition.qualified_name, requested_name.to_s].uniq
        direct = keys.flat_map { |key| Array(start.members[key]) }
        candidates = @identity.values + @transient_entities.flat_map { @transient.retrieve(_1) }
        inverse = candidates.select do |object|
          keys.any? { |key| Array(object.members[key]).include?(start) }
        end
        (direct + inverse).uniq
      end

      def association_snapshot
        schema.associations.to_h do |association|
          rows = database.execute(
            "SELECT source_id, target_id FROM #{quote(association.table)} ORDER BY rowid"
          )
          [association.storage_key, rows.map { [_1['source_id'], _1['target_id']] }]
        end
      end

      def restore_associations(snapshot)
        schema.associations.each do |association|
          rows = snapshot.fetch(association.storage_key, snapshot.fetch(association.storage_key.to_s, []))
          rows.each do |source, target|
            database.execute(
              "INSERT OR IGNORE INTO #{quote(association.table)} (source_id, target_id) VALUES (?, ?)",
              [source, target]
            )
          end
        end
      end

      def detach_uncommitted
        dirty_values.each do |value|
          @identity.delete(value.id)
          @persisted.delete(value.id)
          @staged_new.delete(value.id)
        end
      end

      def run_hooks(event, value)
        @hooks[event].each do |entity, callback|
          next if entity && entity != value.entity && entity != value.entity.split('.').last

          callback.call(value, self)
        end
      end

      def atomic
        state = memory_state
        nested = @manual_transaction
        if nested
          begin
            return yield
          rescue Exception # rubocop:disable Lint/RescueException
            rollback
            raise
          end
        end

        database.execute('BEGIN IMMEDIATE')
        result = yield
        database.execute('COMMIT')
        result
      rescue Exception # rubocop:disable Lint/RescueException
        database.execute('ROLLBACK') if database.transaction_active?
        reset_after_atomic_failure(state) unless nested
        raise
      end

      def memory_state
        { sequence_values: @sequence_values.dup }
      end

      def reset_after_atomic_failure(state)
        @identity = @staged_new.dup
        @persisted = {}
        @sequence_values = state.fetch(:sequence_values)
      end

      def finish_manual_transaction
        database.execute('COMMIT')
        @manual_transaction = false
        @manual_snapshot = nil
      end

      def quote(identifier)
        %("#{identifier.to_s.gsub('"', '""')}")
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
