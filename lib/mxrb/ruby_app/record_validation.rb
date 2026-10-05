# frozen_string_literal: true

require 'bigdecimal'

module Mxrb
  module RubyApp
    # Keeps all failed rules in declaration order, including inherited rules.
    class RecordValidationError < ValidationError
      attr_reader :errors

      def initialize(errors)
        @errors = errors.freeze
        super(errors.map { _1.fetch(:message) }.join('; '))
      end
    end

    # Commit-time validation for the standalone Ruby runtime. JVM-only regular
    # expressions require an explicit adapter rather than a different regex engine.
    class RecordValidation
      def initialize(records, store)
        @records = records
        @store = store
      end

      def call(value)
        implementation = @records[value.entity]
        return unless implementation && implementation.persistable != false

        owners = [*implementation.runtime_ancestors.reverse, value.entity].filter_map { @records[_1] }
        errors = owners.flat_map { validate_owner(_1, value) }
        raise RecordValidationError, errors unless errors.empty?
      end

      private

      def validate_owner(owner, value)
        Array(owner.validation_rules).filter_map do |rule|
          member = validation_member(owner, rule.fetch(:attribute))
          next if ValidationCondition.new(@store, owner, member, value).valid?(rule)

          { entity: value.entity, attribute: member.fetch(:mendix_name), kind: rule.fetch(:kind),
            message: message(rule, member) }
        end
      end

      def validation_member(owner, name)
        owner.runtime_attributes.find do |attribute|
          [attribute.fetch(:name).to_s, attribute.fetch(:mendix_name)].include?(name)
        end || raise(ValidationError, "unknown validation attribute #{name}")
      end

      def message(rule, member)
        translations = rule.fetch(:translations)
        translation = translations.find { _1[:language_code] == 'en_US' } || translations.first
        translation ? translation.fetch(:text) : "#{member.fetch(:mendix_name)}: #{rule.fetch(:kind)}"
      end
    end

    # Evaluates typed native rule options without depending on an MPR at runtime.
    class ValidationCondition
      # Character.isWhitespace: Unicode separators except nonbreaking spaces,
      # plus Java's control whitespace. Verified against the native client.
      JAVA_BLANK = /\A[\p{Z}\t-\r\u001c-\u001f&&[^\u00a0\u2007\u202f]]*\z/
      private_constant :JAVA_BLANK

      def initialize(store, owner, member, object)
        @store = store
        @owner = owner
        @member = member
        @object = object
        @value = object.members[member.fetch(:mendix_name)]
      end

      CHECKS = { 'required' => :required?, 'unique' => :unique?, 'equals' => :equals?, 'equalsto' => :equals?,
                 'range' => :in_range?, 'maxlength' => :max_length?, 'regex' => :regular_expression? }.freeze
      private_constant :CHECKS

      def valid?(rule)
        kind = rule.fetch(:kind).to_s.delete_prefix('DomainModels$').delete_suffix('RuleInfo').downcase
        method = CHECKS.fetch(kind) do
          raise ValidationError, "unsupported runtime validation rule #{rule.fetch(:kind)}"
        end
        send(method, rule.fetch(:rule_info))
      end

      private

      def required?(_info) = !@value.nil? && !(@value.is_a?(String) && @value.match?(JAVA_BLANK))

      def unique?(_info)
        @store.unique_value?(@owner.mendix_name, @member.fetch(:mendix_name), @value, @object.id)
      end

      def equals?(info) = typed(@value) == operand(info, 'EqualsTo', 'UseValue', value_key: 'Value')

      def max_length?(info)
        @value.nil? || @value.to_s.encode('UTF-16LE').bytesize / 2 <= Integer(info.fetch('MaxLength'))
      end

      def in_range?(info)
        return true if @value.nil?

        type = info.fetch('TypeOfRange')
        unless %w[Between GreaterThanOrEqualTo SmallerThanOrEqualTo].include?(type)
          raise ValidationError, "unsupported range type #{type}"
        end

        minimum = operand(info, 'Min', 'UseMinValue') unless type == 'SmallerThanOrEqualTo'
        maximum = operand(info, 'Max', 'UseMaxValue') unless type == 'GreaterThanOrEqualTo'
        value = typed(@value)
        above_minimum?(value, minimum) && below_maximum?(value, maximum)
      end

      def above_minimum?(value, minimum) = minimum.nil? || value >= minimum
      def below_maximum?(value, maximum) = maximum.nil? || value <= maximum

      def operand(info, prefix, flag, value_key: "#{prefix}Value")
        value = if info.fetch(flag)
                  info.fetch(value_key)
                else
                  @object.members.fetch(info.fetch("#{prefix}Attribute").split('.').last)
                end
        typed(value)
      end

      def typed(value)
        return nil if value.nil?

        case @member.fetch(:type).to_sym
        when :integer, :long, :autonumber then Integer(value)
        when :float, :decimal then BigDecimal(value.to_s)
        when :datetime then timestamp(value)
        when :boolean then boolean(value)
        else value.to_s
        end
      end

      def timestamp(value)
        return Time.iso8601(value.iso8601) if value.respond_to?(:iso8601)
        return nil if value == ''

        text = value.to_s
        if text.match?(/\A\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2}(?::\d{2})?)?\z/)
          return Time.utc(*text.scan(/\d+/).map(&:to_i))
        end

        Time.iso8601(text)
      end

      def boolean(value)
        return true if [true, 'true'].include?(value)
        return false if [false, 'false'].include?(value)

        raise ValidationError, "invalid Boolean validation operand #{value.inspect}"
      end

      def regular_expression?(info)
        return true if @value.nil?

        name = info.fetch('RegExIdentifier')
        expression = Registry.fetch(:regular_expression, name)
        raise ValidationError, "unknown regular expression #{name}" unless expression

        adapter = Registry.adapters[:regular_expression]
        raise ValidationError, 'regular_expression adapter is required for JVM validation expressions' unless adapter

        adapter.call(expression: expression.expression, value: @value.to_s) == true
      end
    end
  end
end
