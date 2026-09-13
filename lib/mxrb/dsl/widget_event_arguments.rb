# frozen_string_literal: true

module Mxrb
  module Dsl
    # A block means an explicitly present argument collection, even if empty.
    # Preserve values rather than evaluating expressions or guessing variables.
    class WidgetEventArguments
      def initialize
        @arguments = {}
      end

      def argument(name, value)
        unless name.is_a?(String) || name.is_a?(Symbol)
          raise TypeError, 'widget argument name requires a String or Symbol'
        end

        key = name.to_s
        raise ArgumentError, 'widget argument name cannot be empty' if key.empty?

        raise ArgumentError, "duplicate widget argument #{key}" if @arguments.key?(key)

        @arguments[key] = self.class.snapshot(value)
        self
      end

      def page_variable(...)
        WidgetSlotBuilder.new.page_variable(...)
      end

      def evaluate(&block)
        previous = @arguments.dup
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      rescue StandardError
        @arguments = previous
        raise
      end

      def arguments = self.class.snapshot(@arguments)

      def self.snapshot(value)
        case value
        when Hash then value.to_h { |key, item| [snapshot(key), snapshot(item)] }.freeze
        when Array then value.map { snapshot(_1) }.freeze
        when String then value.dup.freeze
        when Symbol, Numeric, TrueClass, FalseClass, NilClass then value
        else raise TypeError, 'widget argument values require serializable values or variable references'
        end
      end
    end
  end
end
