# frozen_string_literal: true

module Mxrb
  module Runtime
    # Materializes durable snapshots and joins them without consulting dirty object caches.
    class OqlRelations # rubocop:disable Metrics/ClassLength
      Column = Data.define(:scope, :name, :type, :entity) do
        def read(row) = row.dig(scope, name)
      end

      # OQL sees an enumeration value by its key; records may hold the qualified literal.
      def self.value(decoded, type) = type == :enum && decoded.is_a?(String) ? decoded.split('.').last : decoded

      # outer resolves the enclosing query's references inside a subquery, sources supplies
      # view entities as tables and subquery compiles nested SELECTs (see OqlSubquery).
      def initialize(query, store, decoder:, tables: {}, **context)
        @query = query
        @store = store
        @decoder = decoder
        @tables = tables.dup
        @outer, @sources, @subquery, @parameters = context.values_at(:outer, :sources, :subquery, :parameters)
        @outer_scopes = context.fetch(:outer_scopes, [])
        @definitions = {}
        @records = {}
        @joins = query.sources.map { compile_join(_1) }
      end

      attr_reader :subquery

      # Subqueries and parameters shared by every expression of this query.
      def expression_options = { subquery: @subquery, parameters: @parameters }

      def column(reference)
        scope, name = resolve_scope(reference)
        definition = @definitions[scope]
        invalid!("unknown scope #{scope}") unless definition
        return Column.new(scope, 'ID', :identifier, definition.name) if entity_identifier?(name, definition)

        attribute = definition.columns.find { _1.name == name }
        invalid!("unknown column #{reference}") unless attribute
        Column.new(scope, name, attribute.type, definition.name)
      end

      def scopes = @definitions.keys + @outer_scopes

      def predicate(text)
        OqlPredicate.new(text, scopes, **expression_options) { term(_1) }
      end

      # [type, reader] of a column, or of the enclosing query's column inside a subquery.
      def term(reference)
        return @outer.call(reference) if outer?(reference)

        value = column(reference)
        [value.type, value.method(:read)]
      end

      def outer?(reference)
        scope = reference.split('.', 2).first
        @outer && reference.include?('.') && !@definitions.key?(scope) && @outer_scopes.include?(scope)
      end

      def rows
        first = @query.sources.first
        result = records(first).map { { first.scope => _1 } }
        @joins.drop(1).each do |source, condition, links|
          result = join(result, source, condition, links)
        end
        result
      end

      private

      def entity_identifier?(name, definition)
        name.casecmp?('ID') && !@tables.key?(definition.name)
      end

      def compile_join(source)
        register_view(source.entity)
        @definitions[source.scope] = @tables[source.entity]&.definition || @store.schema.entity(source.entity)
        condition = source.condition && predicate(source.condition)
        links = source.association && association(source)
        [source, condition, links]
      end

      def register_view(entity)
        view = @sources&.call(entity) unless @tables.key?(entity)
        @tables[entity] = view if view
      end

      def resolve_scope(reference)
        scope, name = reference.split('.', 2)
        return [scope, name] if name

        name = scope
        matches = @definitions.select { |_key, value| name.casecmp?('ID') || value.columns.any? { _1.name == name } }
        invalid!("ambiguous or unknown column #{name}") unless matches.one?
        [matches.keys.first, name]
      end

      # Read once per compiled query, so correlated subqueries do not rescan durable rows.
      def records(source)
        @records[source.entity] ||= read_records(source)
      end

      def read_records(source)
        return @tables.fetch(source.entity).rows if @tables.key?(source.entity)

        @store.schema.concrete_entities(source.entity).flat_map do |definition|
          @store.database.execute("SELECT * FROM #{quote(definition.table)} ORDER BY rowid").map do |row|
            snapshot(definition, row)
          end
        end
      end

      def snapshot(definition, row)
        values = definition.columns.to_h do |column|
          [column.name, self.class.value(@decoder.call(row[column.sql_name], column.type), column.type)]
        end
        values.merge('ID' => row.fetch('id'), '__entity' => definition.name)
      end

      def association(source)
        origin = @definitions[source.origin]
        invalid!("unknown association origin #{source.origin}") unless origin && source.origin != source.scope
        link = @store.schema.association(source.association)
        [link, association_direction(origin.name, source.entity, link)]
      end

      def association_direction(origin, target, link)
        return true if endpoints?(origin, target, link.from_entity, link.to_entity)
        return false if endpoints?(origin, target, link.to_entity, link.from_entity)

        invalid!('association endpoints do not match the joined entities')
      end

      def endpoints?(left, right, from, to)
        @store.schema.assignable?(left, from) && @store.schema.assignable?(right, to)
      end

      def join(left, source, condition, links)
        right = records(source)
        pairs = links && association_pairs(*links)
        matcher = join_matcher(source, condition, pairs)
        matched = {}
        result = left.flat_map { |row| join_row(row, right, source, matcher, matched) }
        if %w[RIGHT FULL].include?(source.join)
          right.each { |row| result << { source.scope => row } unless matched[row.fetch('ID')] }
        end
        result
      end

      def join_matcher(source, condition, pairs)
        lambda do |row, other|
          linked = !pairs || pairs.include?([row.dig(source.origin, 'ID'), other.fetch('ID')])
          linked && (!condition || condition.call(row.merge(source.scope => other)))
        end
      end

      def join_row(row, right, source, matcher, matched)
        joined = right.filter_map do |other|
          next unless matcher.call(row, other)

          matched[other.fetch('ID')] = true
          row.merge(source.scope => other)
        end
        joined << row.merge(source.scope => nil) if joined.empty? && %w[LEFT FULL].include?(source.join)
        joined
      end

      def association_pairs(link, forward)
        @store.database.execute("SELECT source_id, target_id FROM #{quote(link.table)}").to_set do |row|
          pair = [row.fetch('source_id'), row.fetch('target_id')]
          forward ? pair : pair.reverse
        end
      end

      def quote(value) = %("#{value.gsub('"', '""')}")

      def invalid!(message)
        raise NativeRuntimeError, "Unsupported relational OQL view: #{message}"
      end
    end
  end
end
