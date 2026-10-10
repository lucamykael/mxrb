# frozen_string_literal: true

module Mxrb
  module Runtime
    # A subquery inside an OQL expression. It is compiled once with the enclosing
    # query's references; outer columns read the enclosing row being evaluated.
    class OqlSubquery
      # context holds decoder:, decimal:, depth: and sources: of the enclosing query.
      def self.factory(store, **context)
        ->(text, resolve, scopes) { new(text, store, resolve:, scopes:, **context) }
      end

      def initialize(text, store, resolve:, scopes:, **context)
        outer = lambda do |reference|
          type, reader = resolve.call(reference)
          [type, ->(_row) { reader.call(@current) }]
        end
        @table = OqlTable.new(text, store, **context, depth: context.fetch(:depth) + 1, outer:,
                                                      outer_scopes: Array(scopes))
      end

      def columns = @table.definition.columns

      # Mendix accepts a value subquery only when its column is an aggregate function or it
      # has LIMIT 1; grouped aggregates still fail at run time when they yield several rows.
      def single_row?
        query = @table.query
        query.limit == 1 || !query.relational.projections.first.aggregate.nil?
      end

      def rows(current)
        previous = @current
        @current = current
        @table.rows.map(&:values)
      ensure
        @current = previous
      end
    end
  end
end
