# frozen_string_literal: true

module Mxrb
  module Runtime
    # Splits structural keywords without treating words inside string literals as clauses.
    class OqlViewQuery
      WORD = '[A-Za-z_][A-Za-z0-9_]*'
      SOURCE = /\A(?<entity>#{WORD}\.#{WORD})(?:\s+(?:AS\s+)?(?<scope>#{WORD}))?\z/i
      COLUMN = %r{\A(?:(?<scope>#{WORD})[/.])?(?<column>#{WORD})(?:\s+AS\s+(?<alias>#{WORD}))?\z}i
      ORDERS = [%w[FROM SELECT], %w[SELECT FROM], %w[FROM WHERE SELECT], %w[SELECT FROM WHERE]].freeze

      attr_reader :source, :columns, :filter, :scope

      def initialize(text)
        parts = clauses(text)
        match = SOURCE.match(parts.fetch('FROM').strip)
        invalid! unless match
        @source = match[:entity]
        @scope = match[:scope] || @source.split('.').last
        @columns = parts.fetch('SELECT').split(',', -1).map { parse_column(_1) }
        @filter = parts['WHERE']
      end

      private

      def clauses(text)
        tokens = Oql::Translator.tokens(text.to_s.strip)
        starts = clause_starts(tokens)
        order = starts.map { tokens[_1].text.upcase }
        invalid! unless starts.first.to_i.zero? && ORDERS.include?(order)

        clause_values(tokens, starts, order)
      end

      def clause_values(tokens, starts, order)
        starts.each_with_index.to_h do |start, index|
          finish = starts.fetch(index + 1, tokens.length)
          [order[index], tokens[(start + 1)...finish].map(&:text).join]
        end
      end

      def clause_starts(tokens)
        tokens.each_index.select do |index|
          tokens[index].type == :word && %w[SELECT FROM WHERE].include?(tokens[index].text.upcase)
        end
      end

      def parse_column(value)
        column = COLUMN.match(value.strip)
        unless column && (column[:scope].nil? || column[:scope] == scope)
          raise NativeRuntimeError, "Unsupported OQL view projection: #{value.strip}"
        end

        [column[:column], column[:alias] || column[:column]]
      end

      def invalid!
        raise NativeRuntimeError, 'Unsupported OQL view query: expected a single-entity projection'
      end
    end
  end
end
