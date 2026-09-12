# frozen_string_literal: true

module Mxrb
  module Dsl
    # Keeps locale presence and expression values separate from presentation
    # defaults. An empty block is an explicitly empty translation collection.
    class FlowTextBuilder
      def initialize
        @translations = {}
        @parameters = []
      end

      def translation(language, text)
        unless language.is_a?(String) || language.is_a?(Symbol)
          raise TypeError, 'translation language requires a String or Symbol'
        end

        name = language.to_s.dup.freeze
        raise ArgumentError, 'duplicate flow translation language' if @translations.key?(name)

        @translations[name] = scalar(text)
        self
      end

      def parameter(value)
        @parameters << scalar(value)
        self
      end

      def evaluate(&block)
        previous_translations = @translations.dup
        previous_parameters = @parameters.dup
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      rescue StandardError
        @translations = previous_translations
        @parameters = previous_parameters
        raise
      end

      def translations = @translations.dup.freeze
      def parameters = @parameters.dup.freeze

      private

      def scalar(value)
        case value
        when String then value.dup.freeze
        when Symbol, Numeric, TrueClass, FalseClass, NilClass then value
        else raise TypeError, 'flow text values require scalar text or expressions'
        end
      end
    end
  end
end
