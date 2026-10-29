# frozen_string_literal: true

require 'json'
require_relative '../domain_diagram'
require_relative '../runtime/database_workspace'
require_relative '../oql/server'

module Mxrb
  module Studio
    # Studio's logical ER and database APIs. A model declaration never confirms a
    # physical table or foreign key: only a live PostgreSQL catalog can do that.
    # rubocop:disable Metrics/ClassLength
    class DataExplorer
      # pg_constraint.conkey/confkey and pg_index.indkey preserve declared order.
      # PostgreSQL 13: /docs/13/catalog-pg-{constraint,index,attribute}.html.
      # One statement gives columns, constraints and indexes a consistent snapshot.
      SCHEMA_SQL = <<~SQL
        WITH relations AS (
          SELECT c.oid, n.nspname AS schema_name, c.relname AS table_name,
                 CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned_table'
                   WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized_view'
                   WHEN 'f' THEN 'foreign_table' END AS kind
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
          WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
            AND n.nspname <> 'information_schema'
            AND n.nspname !~ '^pg_'
            AND pg_catalog.has_schema_privilege(n.oid, 'USAGE')
            AND pg_catalog.has_table_privilege(c.oid, 'SELECT')
        )
        SELECT COALESCE(json_agg(json_build_object(
          'schema', r.schema_name, 'name', r.table_name, 'kind', r.kind,
          'columns', (
            SELECT COALESCE(json_agg(json_build_object(
              'name', a.attname, 'ordinal', a.attnum,
              'type', pg_catalog.format_type(a.atttypid, a.atttypmod),
              'nullable', NOT a.attnotnull, 'identity', a.attidentity,
              'generated', a.attgenerated,
              'default', pg_catalog.pg_get_expr(d.adbin, d.adrelid)
            ) ORDER BY a.attnum), '[]'::json)
            FROM pg_catalog.pg_attribute a
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped
          ),
          'constraints', (
            SELECT COALESCE(json_agg(json_build_object(
              'name', co.conname, 'type', co.contype, 'validated', co.convalidated,
              'deferrable', co.condeferrable, 'initially_deferred', co.condeferred,
              'definition', pg_catalog.pg_get_constraintdef(co.oid, true),
              'columns', (
                SELECT COALESCE(json_agg(a.attname ORDER BY k.ordinal), '[]'::json)
                FROM unnest(co.conkey) WITH ORDINALITY AS k(attnum, ordinal)
                JOIN pg_catalog.pg_attribute a ON a.attrelid = co.conrelid AND a.attnum = k.attnum
              ),
              'target_schema', tn.nspname, 'target_table', tc.relname,
              'target_columns', (
                SELECT COALESCE(json_agg(a.attname ORDER BY k.ordinal), '[]'::json)
                FROM unnest(co.confkey) WITH ORDINALITY AS k(attnum, ordinal)
                JOIN pg_catalog.pg_attribute a ON a.attrelid = co.confrelid AND a.attnum = k.attnum
              ),
              'on_update', co.confupdtype, 'on_delete', co.confdeltype, 'match', co.confmatchtype
            ) ORDER BY co.conname, co.oid), '[]'::json)
            FROM pg_catalog.pg_constraint co
            LEFT JOIN pg_catalog.pg_class tc ON tc.oid = co.confrelid
            LEFT JOIN pg_catalog.pg_namespace tn ON tn.oid = tc.relnamespace
            WHERE co.conrelid = r.oid
          ),
          'indexes', (
            SELECT COALESCE(json_agg(json_build_object(
              'schema', ns.nspname, 'name', ic.relname, 'method', am.amname,
              'unique', i.indisunique, 'primary', i.indisprimary, 'valid', i.indisvalid,
              'key_count', i.indnkeyatts,
              'definition', pg_catalog.pg_get_indexdef(i.indexrelid),
              'predicate', pg_catalog.pg_get_expr(i.indpred, i.indrelid),
              'columns', (
                SELECT COALESCE(json_agg(json_build_object(
                  'ordinal', k.ordinal, 'name', a.attname,
                  'expression', pg_catalog.pg_get_indexdef(i.indexrelid, k.ordinal::integer, true),
                  'included', k.ordinal > i.indnkeyatts
                ) ORDER BY k.ordinal), '[]'::json)
                FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ordinal)
                LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
              )
            ) ORDER BY ic.relname, ic.oid), '[]'::json)
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
            JOIN pg_catalog.pg_namespace ns ON ns.oid = ic.relnamespace
            JOIN pg_catalog.pg_am am ON am.oid = ic.relam
            WHERE i.indrelid = r.oid
          )
        ) ORDER BY r.schema_name, r.table_name), '[]'::json)::text AS tables_json
        FROM relations r
      SQL

      def initialize(project_path, workspace: nil, modules: [], database_port: 55_432)
        @path = File.expand_path(project_path)
        @workspace = workspace
        @modules = Array(modules).map(&:to_s)
        @database_port = database_port
      end

      def to_h(include_physical: false)
        {
          version: 1, backend: 'mxrb', logical:,
          physical: include_physical ? physical : physical_state('not_requested'),
          queries: { languages: %w[sql oql], read_only: true, parameters: true,
                     explain: true, analyze_default: false }
        }
      end

      def logical # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        document = DomainDiagram::Document.new(@path, modules: @modules).to_h
        details = entity_details
        entities = document.fetch(:modules).flat_map do |mod|
          mod.fetch(:entities).map { enrich_entity(_1, details) }
        end
        associations = document.fetch(:modules).flat_map { _1.fetch(:associations) }
                               .map { _1.merge(kind: 'association', source: 'model', physical: false) }
        inheritances = entities.filter_map do |entity|
          target = entity[:generalization]
          next if target.to_s.empty?

          { id: "inheritance:#{entity[:id]}", kind: 'inheritance', from: entity[:qualified_name],
            to: target, cross_module: entity[:module] != target.split('.').first,
            target_resolved: details.key?(target), source: 'model', physical: false }
        end
        relationships = associations + inheritances
        visible = entities.map { _1[:qualified_name] }
        enriched = entities.to_h { [_1.fetch(:qualified_name), _1] }
        document.merge(
          source: 'model', physical_schema_confirmed: false,
          modules: document.fetch(:modules).map do |mod|
            mod.merge(entities: mod.fetch(:entities).map { enriched.fetch(_1.fetch(:qualified_name)) })
          end,
          entities:, relationships:,
          external_entities: relationships.flat_map { [_1[:from], _1[:to]] }.uniq.reject { visible.include?(_1) }
        )
      end

      def physical
        tables = catalog_tables
        tables.each { normalize_table(_1) }
        physical_state('available').merge(
          confirmed: true, visibility: 'reader_accessible_relations', tables:,
          relationships: tables.flat_map { |table| foreign_keys(table) }
        )
      rescue StandardError => e
        physical_state('unavailable').merge(error: { code: 'physical_schema_unavailable', message: e.message })
      end

      def query(payload)
        Oql::Server.new(@path, workspace:).execute(payload)
      rescue StandardError => e
        { ok: false, error: { code: 'query_failed', message: e.message } }
      end

      def explain(payload)
        sql, params, warnings = explain_query(payload)
        analyze = payload.fetch('analyze', false)
        raise ArgumentError, 'analyze must be a boolean' unless [true, false].include?(analyze)

        report = workspace.explain(sql, params:, analyze:)
        { ok: true, read_only: true, analyzed: analyze, warnings:, sql:, plan: json_safe(report.to_h) }
      rescue ArgumentError => e
        { ok: false, error: { code: 'invalid_request', message: e.message } }
      rescue StandardError => e
        { ok: false, error: { code: 'explain_failed', message: e.message } }
      end

      private

      def workspace
        @workspace ||= Runtime::DatabaseWorkspace.new(@path, port: @database_port)
      end

      def physical_state(status)
        { status:, source: 'postgresql_catalog', confirmed: false, tables: [], relationships: [] }
      end

      def catalog_tables
        rows = workspace.query_rows(SCHEMA_SQL)
        raise ToolchainError, 'PostgreSQL returned no schema catalog result' unless rows.size == 1

        tables = JSON.parse(rows.first.fetch('tables_json'), symbolize_names: true)
        raise ToolchainError, 'PostgreSQL returned an invalid schema catalog' unless tables.is_a?(Array)

        tables
      end

      def entity_details # rubocop:disable Metrics/MethodLength
        project = Model::Project.open(@path)
        project.modules.each_with_object({}) do |mod, result|
          mod.entities.each do |entity|
            name = entity.qualified_name || "#{mod.name}.#{entity.name}"
            result[name] = { generalization: entity.generalization_target,
                             declared_persistent: entity.persistable == true,
                             indexes: entity.indexes, system_members: entity.system_members }
          end
        end
      ensure
        project&.close
      end

      def enrich_entity(entity, details)
        detail = details.fetch(entity.fetch(:qualified_name), {})
        persistent = inherited_persistence(entity.fetch(:qualified_name), details, [])
        kind = entity[:kind]
        kind = 'dto' if persistent == false && kind != 'oql_view'
        entity.merge(detail).merge(
          kind:, persistent:, persistence_resolved: !persistent.nil?,
          physical_mapping: { status: kind == 'entity' ? 'unmapped' : 'not_applicable' }
        )
      end

      def inherited_persistence(name, details, seen)
        return if seen.include?(name)

        detail = details[name]
        return unless detail

        parent = detail[:generalization].to_s
        return detail[:declared_persistent] if parent.empty?

        inherited_persistence(parent, details, seen + [name])
      end

      def normalize_table(table)
        # No entity/table or junction-table semantics are inferred from names.
        keys = table.fetch(:constraints).select { _1[:type] == 'f' }
        table.merge!(
          id: relation_id(table.fetch(:schema), table.fetch(:name)), confirmed: true,
          primary_key: table.fetch(:constraints).find { _1[:type] == 'p' },
          foreign_keys: keys, foreign_key_count: keys.size, logical_mapping: { status: 'unmapped' }
        )
      end

      def foreign_keys(table)
        table.fetch(:foreign_keys).map do |key|
          pairs = key.fetch(:columns).zip(key.fetch(:target_columns)).each_with_index.map do |pair, index|
            { from: pair[0], to: pair[1], ordinal: index + 1 }
          end
          key.merge(kind: 'foreign_key', source: 'postgresql_catalog', confirmed: true,
                    from: table[:id], to: relation_id(key.fetch(:target_schema), key.fetch(:target_table)),
                    column_pairs: pairs)
        end
      end

      def relation_id(schema, table)
        [schema, table].map { %("#{_1.to_s.gsub('"', '""')}") }.join('.')
      end

      def json_safe(value)
        case value
        when Hash then value.transform_values { json_safe(_1) }
        when Array then value.map { json_safe(_1) }
        when Data then json_safe(value.to_h)
        else value
        end
      end

      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/PerceivedComplexity
      def explain_query(payload)
        raise ArgumentError, 'JSON body must be an object' unless payload.is_a?(Hash)

        sql = payload['sql']
        oql = payload['oql']
        raise ArgumentError, 'provide exactly one of sql or oql' if sql.to_s.empty? == oql.to_s.empty?

        params = payload.fetch('params', {})
        raise ArgumentError, 'params must be a JSON object' unless params.is_a?(Hash)

        return [sql, params, []] unless sql.to_s.empty?

        view = Oql::Translator.new(dialect: :postgresql).translate_source(oql)
        raise ArgumentError, view.warnings.join('; ') unless view.supported?
        unless params.keys.map(&:to_s).sort == view.parameters.map(&:to_s).sort
          raise ArgumentError, "params must match OQL parameters: #{view.parameters.join(', ')}"
        end

        [view.sql, params, view.warnings]
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/PerceivedComplexity
    end
    # rubocop:enable Metrics/ClassLength
  end
end
