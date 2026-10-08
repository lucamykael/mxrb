# frozen_string_literal: true

module Mxrb
  module Runtime
    # Parses source entities, association paths and explicit join conditions.
    class OqlJoinSources
      WORD = /\A[A-Za-z_][A-Za-z0-9_]*\z/
      JOIN_WORDS = %w[JOIN INNER LEFT RIGHT FULL OUTER].freeze
      Source = Data.define(:entity, :scope, :join, :origin, :association, :condition)
      attr_reader :sources

      def initialize(tokens)
        @sources = parse_sources(tokens)
      end

      private

      def parse_sources(tokens)
        @tokens = tokens
        result = [source(nil)]
        result << source(join_kind) until peek.empty?
        invalid!('duplicate source alias') unless result.map(&:scope).uniq.length == result.length
        result
      end

      def join_kind
        kind = %w[INNER LEFT RIGHT FULL].include?(peek) ? @tokens.shift.upcase : 'INNER'
        take('OUTER') unless kind == 'INNER'
        expect('JOIN')
        kind
      end

      def source(kind)
        origin, association = association_path(kind)
        entity = entity_name
        scope = source_alias(entity)
        condition = take('ON') ? join_condition : nil
        invalid!('entity joins require ON') if kind && !association && !condition
        Source.new(entity, scope, kind, origin, association, condition)
      end

      def association_path(kind)
        return [nil, nil] unless @tokens.reject { _1.strip.empty? }[1] == '/'

        invalid!('association paths require JOIN') unless kind
        origin = identifier
        expect('/')
        association = entity_name
        expect('/')
        [origin, association]
      end

      def source_alias(entity)
        return identifier if take('AS')
        return entity.split('.').last if peek.empty? || JOIN_WORDS.include?(peek) || peek == 'ON'

        identifier
      end

      def join_condition
        parts = []
        parts << @tokens.shift until @tokens.empty? || JOIN_WORDS.include?(@tokens.first.upcase)
        invalid!('empty JOIN condition') if parts.join.strip.empty?
        parts.join
      end

      def entity_name
        mod = identifier
        expect('.')
        "#{mod}.#{identifier}"
      end

      def identifier
        skip_spaces
        value = @tokens.shift.to_s
        invalid!('expected an identifier') unless WORD.match?(value)
        value
      end

      def skip_spaces
        @tokens.shift while @tokens.first&.strip == ''
      end

      def peek
        skip_spaces
        @tokens.first.to_s.upcase
      end

      def take(value)
        return false unless peek == value

        @tokens.shift
        true
      end

      def expect(value)
        invalid!("expected #{value}") unless take(value)
      end

      def invalid!(message)
        raise NativeRuntimeError, "Unsupported relational OQL view: #{message}"
      end
    end
  end
end
