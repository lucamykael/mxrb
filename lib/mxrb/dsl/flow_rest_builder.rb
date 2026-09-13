# frozen_string_literal: true

module Mxrb
  module Dsl
    # HTTP permits repeated header names. Keep those ordered entries rather
    # than silently collapsing them into the legacy hash representation.
    class FlowRestBuilder
      def initialize
        @headers = []
      end

      def header(name, expression)
        raise TypeError, 'REST header name requires a String or Symbol' unless name.is_a?(String) || name.is_a?(Symbol)

        value = case expression
                when String then expression.dup.freeze
                when Symbol, Numeric, TrueClass, FalseClass, NilClass then expression
                else raise TypeError, 'REST header expression requires a scalar value'
                end
        @headers << [name.to_s.dup.freeze, value].freeze
        self
      end

      def evaluate(&block)
        previous = @headers.dup
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      rescue StandardError
        @headers = previous
        raise
      end

      def headers
        return @headers.dup.freeze if @headers.map(&:first).uniq.size != @headers.size

        @headers.to_h.freeze
      end
    end
  end
end
