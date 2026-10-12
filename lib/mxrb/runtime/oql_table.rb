# frozen_string_literal: true

require_relative 'oql_table_query'
require_relative 'oql_relations'
require_relative 'oql_selection'
require_relative 'oql_subquery'

module Mxrb
  module Runtime
    # A compiled, typed result table. Compilation validates outer and inner
    # queries before either reads durable rows; no OQL text is executed as SQL.
    class OqlTable
      Definition = Data.define(:name, :columns)
      Column = Data.define(:name, :type)
      attr_reader :definition, :query

      # context may hold depth: and outer:, outer_scopes:, sources: for OqlRelations.
      def initialize(text, store, decoder:, decimal:, **context)
        depth = context.delete(:depth) || 0
        parse_query(text, depth)
        bind_selection(store, decoder, decimal, depth, context)
        @source_order = context.key?(:outer)
        @orders = @query.orders.map { [order_key(_1.reference), _1.descending] }
      end

      def rows
        values = ordered.drop(@query.offset || 0)
        @query.limit&.positive? ? values.take(@query.limit) : values
      end

      private

      def ordered
        entries = @selection.entries.map do |_identity, values, group|
          [values, @orders.map { |key, _descending| key.call(values, group) }]
        end
        entries.sort! { |left, right| compare(left.last, right.last) } unless @orders.empty?
        entries.map(&:first)
      end

      def parse_query(text, depth)
        invalid!('subquery nesting exceeds 16') if depth > 16
        @query = OqlTableQuery.new(text)
        return unless depth.positive? && !@query.orders.empty? && @query.limit.nil? && @query.offset.nil?

        invalid!('ordered subqueries require LIMIT or OFFSET')
      end

      def bind_selection(store, decoder, decimal, depth, context)
        tables = derived_tables(store, decoder, decimal, depth, context.slice(:sources, :parameters))
        subquery = OqlSubquery.factory(store, decoder:, decimal:, depth:, **context.slice(:sources, :parameters))
        @relations = OqlRelations.new(@query.relational, store, decoder:, tables:, subquery:, **context)
        @selection = OqlSelection.new(@query.relational, @relations, decimal:)
        @definition = Definition.new(OqlTableQuery::DERIVED_ENTITY,
                                     @selection.columns.map { |name, type| Column.new(name, type) })
      end

      def derived_tables(store, decoder, decimal, depth, shared)
        return {} unless @query.derived

        table = self.class.new(@query.derived, store, decoder:, decimal:, depth: depth + 1, **shared)
        { OqlTableQuery::DERIVED_ENTITY => table }
      end

      # A projected column or alias; subqueries may also order by an ungrouped source column.
      def order_key(reference)
        found = ordered_projection(reference)
        return source_order_key(reference) if !found && @source_order

        invalid!('ORDER BY must refer to a projected column or alias') unless found
        ordered!(@selection.columns.fetch(found.name))
        ->(values, _group) { values[found.name] }
      end

      def source_order_key(reference)
        column = @relations.column(reference)
        invalid!('ORDER BY of a grouped subquery must use its projections') if @query.relational.grouped?
        ordered!(column.type)
        ->(_values, group) { column.read(group.first) }
      end

      def ordered!(type)
        invalid!("ORDER BY does not support #{type}") unless OqlSelection::ORDERED.include?(type)
      end

      def ordered_projection(reference)
        found = @query.relational.projections.find { _1.name == reference }
        unless found
          column = @relations.column(reference)
          found = @selection.projections.find { |projection, value| !projection.aggregate && value == column }&.first
        end
        found
      end

      def compare(left, right)
        @orders.each_with_index do |(_key, descending), index|
          first = sortable(left[index])
          second = sortable(right[index])
          next if first == second
          return -1 if first.nil?
          return 1 if second.nil?

          result = first <=> second
          return descending ? -result : result
        end
        0
      end

      # Mendix 11.12.1 orders strings case-insensitively.
      def sortable(value) = value.is_a?(String) ? value.downcase : value

      def invalid!(message)
        raise NativeRuntimeError, "Unsupported tabular OQL: #{message}"
      end
    end
  end
end
