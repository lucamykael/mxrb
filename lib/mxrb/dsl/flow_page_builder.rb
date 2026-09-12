# frozen_string_literal: true

module Mxrb
  module Dsl
    # Ordered page arguments and a localized title, collected before installing
    # the activity so a failed block cannot leave a partial flow declaration.
    class FlowPageBuilder
      def mappings = snapshot(@mappings)
      def title_translations = snapshot(@title_translations)

      def initialize
        @mappings = []
        @title_translations = nil
      end

      def argument(parameter, value)
        @mappings << { parameter: parameter.to_s, value: }
      end

      def title(&block)
        raise ArgumentError, 'page title requires a translation block' unless block
        raise ArgumentError, 'page title is already declared' unless @title_translations.nil?

        builder = TitleBuilder.new
        block.arity == 1 ? block.call(builder) : builder.instance_eval(&block)
        @title_translations = builder.translations
      end

      # A localized title with an explicit empty/absent distinction.
      class TitleBuilder
        attr_reader :translations

        def initialize
          @translations = {}
        end

        def translation(language, text)
          name = language.to_s
          raise ArgumentError, 'duplicate page title language' if @translations.key?(name)

          @translations[name] = text
        end
      end
      private_constant :TitleBuilder

      private

      def snapshot(value)
        case value
        when Hash then value.to_h { |key, child| [snapshot(key), snapshot(child)] }.freeze
        when Array then value.map { snapshot(_1) }.freeze
        when String then value.dup.freeze
        else value
        end
      end
    end
  end
end
