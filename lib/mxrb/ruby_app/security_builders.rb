# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Nil means unspecified, so editing one requirement never supplies defaults
    # for the other native fields. False remains an explicit requirement value.
    PasswordPolicy = Data.define(:minimum_length, :require_mixed_case, :require_symbol, :require_digit) do
      def initialize(minimum_length: nil, require_mixed_case: nil, require_symbol: nil, require_digit: nil)
        unless minimum_length.nil? || (minimum_length.is_a?(Integer) && !minimum_length.negative?)
          raise TypeError, 'minimum_length must be a nonnegative Integer or unspecified'
        end
        [require_mixed_case, require_symbol, require_digit].each do |value|
          unless value.nil? || value.equal?(true) || value.equal?(false)
            raise TypeError, 'password requirements must be true, false, or unspecified'
          end
        end
        super
      end

      def properties
        {
          'MinimumLength' => minimum_length,
          'RequireMixedCase' => require_mixed_case,
          'RequireSymbol' => require_symbol,
          'RequireDigit' => require_digit
        }.compact.freeze
      end
    end

    # Closed representation of the password-policy fields already present in
    # the Mendix 9, 10 and 11 runtime schemas. Extension fields are not inferred.
    class PasswordPolicyBuilder
      PROPERTY_NAMES = {
        'MinimumLength' => :minimum_length,
        'RequireMixedCase' => :require_mixed_case,
        'RequireSymbol' => :require_symbol,
        'RequireDigit' => :require_digit
      }.freeze
      BOOLEAN_PROPERTIES = %i[require_mixed_case require_symbol require_digit].freeze
      private_constant :PROPERTY_NAMES, :BOOLEAN_PROPERTIES

      def initialize(properties = {})
        @policy = PasswordPolicy.new
        assigned = {}
        properties.to_h.each do |key, value|
          property = property_name(key)
          raise ArgumentError, "duplicate password policy property #{property}" if assigned.key?(property)

          public_send(property, value)
          assigned[property] = true
        end
      end

      def minimum_length(value)
        raise TypeError, 'minimum_length requires an Integer' unless value.is_a?(Integer)
        raise ArgumentError, 'minimum_length cannot be negative' if value.negative?

        @policy = @policy.with(minimum_length: value)
        self
      end

      BOOLEAN_PROPERTIES.each do |property|
        define_method(property) do |value = true|
          unless value.equal?(true) || value.equal?(false)
            raise TypeError, "#{property} requires true or false"
          end

          @policy = @policy.with(**{ property => value })
          self
        end
      end

      def evaluate(&block)
        previous = @policy
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      rescue StandardError
        @policy = previous
        raise
      end

      def build = @policy
      def properties = @policy.properties

      private

      def property_name(key)
        name = key.to_s
        return PROPERTY_NAMES.fetch(name) if PROPERTY_NAMES.key?(name)

        semantic = name.to_sym
        return semantic if PROPERTY_NAMES.value?(semantic)

        raise ArgumentError, "unsupported password policy property #{key.inspect}"
      end
    end
  end
end
