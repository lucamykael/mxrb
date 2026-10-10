# frozen_string_literal: true

require_relative 'oql_table_query'
require_relative 'oql_relations'
require_relative 'oql_selection'

module Mxrb
  module Runtime
    # A compiled, typed result table. Compilation validates outer and inner
    # queries before either reads durable rows; no OQL text is executed as SQL.
    class OqlTable
      Definition = Data.define(:name, :columns)
      Column = Data.define(:name, :type)
      attr_reader :definition

      def initialize(text, store, decoder:, decimal:, depth: 0)
        parse_query(text, depth)
        bind_selection(store, decoder, decimal, depth)
        @orders = @query.orders.map { [order_column(_1.reference), _1.descending] }
      end

      def rows
        values = @selection.each.map { |_identity, row| row }
        values.sort! { |left, right| compare(left, right) } unless @orders.empty?
        values = values.drop(@query.offset || 0)
        @query.limit&.positive? ? values.take(@query.limit) : values
      end

      private

      def parse_query(text, depth)
        invalid!('subquery nesting exceeds 16') if depth > 16
        @query = OqlTableQuery.new(text)
        return unless depth.positive? && !@query.orders.empty? && @query.limit.nil? && @query.offset.nil?

        invalid!('ordered subqueries require LIMIT or OFFSET')
      end

      def bind_selection(store, decoder, decimal, depth)
        tables = derived_tables(store, decoder, decimal, depth)
        @relations = OqlRelations.new(@query.relational, store, decoder:, tables:)
        @selection = OqlSelection.new(@query.relational, @relations, decimal:)
        @definition = Definition.new(OqlTableQuery::DERIVED_ENTITY,
                                     @selection.columns.map { |name, type| Column.new(name, type) })
      end

      def derived_tables(store, decoder, decimal, depth)
        return {} unless @query.derived

        table = self.class.new(@query.derived, store, decoder:, decimal:, depth: depth + 1)
        { OqlTableQuery::DERIVED_ENTITY => table }
      end

      def order_column(reference)
        found = ordered_projection(reference)
        invalid!('ORDER BY must refer to a projected column or alias') unless found
        type = @selection.columns.fetch(found.name)
        invalid!("ORDER BY does not support #{type}") unless OqlSelection::ORDERED.include?(type)
        found.name
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
        @orders.each do |name, descending|
          first = left[name]
          second = right[name]
          next if first == second
          return -1 if first.nil?
          return 1 if second.nil?

          result = first <=> second
          return descending ? -result : result
        end
        0
      end

      def invalid!(message)
        raise NativeRuntimeError, "Unsupported tabular OQL: #{message}"
      end
    end
  end
end
