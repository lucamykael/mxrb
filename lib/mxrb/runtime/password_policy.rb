# frozen_string_literal: true

require_relative 'system_domain'

module Mxrb
  module Runtime
    # The project password policy, checked when a user's password changes, with the
    # Mendix 11.12.1 default system texts. Symbols are the Runtime's fixed set.
    class PasswordPolicy
      SYMBOLS = %q(`~!@#$%^&*()-_=+[{]}\|;:'"<,>./?)
      HEADER = 'Password does not meet password policy criteria:'

      def self.from_security(settings)
        settings ||= {}
        new(minimum_length: settings.fetch('MinimumLength', 0).to_i, digit: settings['RequireDigit'] == true,
            mixed_case: settings['RequireMixedCase'] == true, symbol: settings['RequireSymbol'] == true)
      end

      def initialize(minimum_length:, digit:, mixed_case:, symbol:)
        @minimum_length = minimum_length
        @digit = digit
        @mixed_case = mixed_case
        @symbol = symbol
      end

      # The failed criteria in Runtime order, each as its system text.
      def failures(password)
        text = password.to_s
        criteria.filter_map { |enabled, met, message| message unless !enabled || met.call(text) }
      end

      def criteria
        [
          [true, ->(text) { text.encode('UTF-16LE').bytesize / 2 >= @minimum_length },
           "Password should be at least #{@minimum_length} characters."],
          [@digit, ->(text) { text.match?(/\p{Nd}/) }, 'Password should contain a digit.'],
          [@mixed_case, ->(text) { text.match?(/\p{Lu}/) }, 'Password should contain an uppercase character.'],
          [@mixed_case, ->(text) { text.match?(/\p{Ll}/) }, 'Password should contain a lowercase character.'],
          [@symbol, ->(text) { text.chars.any? { SYMBOLS.include?(_1) } },
           "Password should contain at least one of the following symbols: #{SYMBOLS}"]
        ]
      end

      def message(failures) = ([HEADER] + failures).join("\n - ")

      # The validation error of a user whose new (not yet hashed) password breaks the policy.
      def violation(value, schema)
        return unless schema.assignable?(value.entity, SystemDomain::USER)

        password = value.members['Password']
        return if password.to_s.match?(SystemDomain::BCRYPT)

        failed = failures(password)
        { entity: value.entity, attribute: 'Password', kind: :password_policy, message: message(failed) } unless
          failed.empty?
      end
    end
  end
end
