# frozen_string_literal: true

module Mxrb
  module RubyApp
    IndexMember = Data.define(:id, :name, :ascending, :type)
    ValidationTranslation = Data.define(:id, :language_code, :text)

    # Builds one ordered index before Record publishes its declaration.
    class IndexBuilder
      MEMBER_TYPES = %i[Normal CreatedDate ChangedDate Owner ChangedBy].freeze
      TYPE_ALIASES = {
        normal: :Normal, created_date: :CreatedDate, changed_date: :ChangedDate,
        owner: :Owner, changed_by: :ChangedBy
      }.freeze
      private_constant :MEMBER_TYPES, :TYPE_ALIASES

      def initialize(members = [])
        @members = Array(members).map do |member|
          declaration = member.to_h.transform_keys(&:to_sym)
          build_member(declaration.fetch(:name), id: declaration[:id],
                       ascending: declaration.fetch(:ascending, true),
                       type: declaration.fetch(:type, :Normal))
        end
      end

      def member(name, id: nil, ascending: true, type: :Normal)
        declaration = build_member(name, id:, ascending:, type:)
        @members << declaration
        self
      end

      def evaluate(&block)
        previous = @members.dup
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      rescue StandardError
        @members = previous
        raise
      end

      def members = @members.dup.freeze

      private

      def build_member(name, id:, ascending:, type:)
        name = name.to_s.dup.freeze
        raise ArgumentError, 'index member requires a name' if name.empty?

        type = TYPE_ALIASES.fetch(type.to_sym, type.to_sym)
        raise ArgumentError, "unsupported index member type #{type.inspect}" unless MEMBER_TYPES.include?(type)
        if type != :Normal && name != type.to_s
          raise ArgumentError, "indexed system member #{type} must be named #{type}"
        end

        IndexMember.new(id: id.to_s.dup.freeze, name:, ascending: ascending == true, type:)
      end
    end

    # Adds localized messages and named rule options without exposing storage
    # maps in authored Ruby. Existing option maps remain accepted at import.
    class ValidationRuleBuilder
      attr_reader :kind

      def initialize(kind:, translations: [], rule_info: {})
        @kind = kind.to_s == 'regular_expression' ? 'DomainModels$RegExRuleInfo' : kind.to_s.dup.freeze
        @translations = Array(translations).map do |translation|
          declaration = translation.to_h.transform_keys(&:to_sym)
          build_translation(declaration.fetch(:language_code, declaration[:language]),
                            declaration.fetch(:text), id: declaration[:id])
        end
        @rule_info = copy_legacy_value(rule_info.to_h.transform_keys(&:to_s))
      end

      def translation(language, text, id: nil)
        declaration = build_translation(language, text, id:)
        @translations << declaration
        self
      end

      def regular_expression(identifier)
        unless kind == 'DomainModels$RegExRuleInfo'
          raise ArgumentError, 'regular_expression requires a regular-expression validation rule'
        end

        value = identifier.to_s.dup.freeze
        @rule_info = @rule_info.merge('RegExIdentifier' => value).freeze
        self
      end

      def evaluate(&block)
        previous_translations = @translations.dup
        previous_info = @rule_info
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      rescue StandardError
        @translations = previous_translations
        @rule_info = previous_info
        raise
      end

      def translations = @translations.dup.freeze
      def rule_info = @rule_info

      private

      def build_translation(language, text, id:)
        ValidationTranslation.new(
          id: id.to_s.dup.freeze, language_code: language.to_s.dup.freeze,
          text: text.to_s.dup.freeze
        )
      end

      def copy_legacy_value(value)
        case value
        when Hash
          value.to_h { |key, item| [copy_legacy_value(key), copy_legacy_value(item)] }.freeze
        when Array then value.map { copy_legacy_value(_1) }.freeze
        when String then value.dup.freeze
        when Symbol, Numeric, TrueClass, FalseClass, NilClass then value
        else value.dup.freeze
        end
      end
    end
  end
end
