# frozen_string_literal: true

require 'bigdecimal'
require 'time'

module Mxrb
  module Runtime
    # $Name parameters of OQL text, typed by their values. An object parameter
    # is passed as Identifier, the way Mendix binds an object's ID.
    module OqlParameters
      Identifier = Data.define(:id)

      module_function

      # [kind, type, value, scale] of a parameter value.
      KINDS = { NilClass => :null, String => :string, TrueClass => :boolean, FalseClass => :boolean,
                Time => :datetime }.freeze

      def typed(value)
        return [:identifier, :identifier, value.id, 0] if value.is_a?(Identifier)
        return [:number, OqlScalar::INTEGER_RANGE.cover?(value) ? :integer : :long, value, 0] if value.is_a?(Integer)

        kind = KINDS[value.class]
        if kind
          [kind, kind == :null ? nil : kind, value, 0]
        else
          decimal(value)
        end
      end

      def decimal(value)
        number = BigDecimal(value.to_s)
        fraction = number.to_s('F').split('.').last
        [:number, :decimal, number, fraction == '0' ? 0 : fraction.length]
      rescue ArgumentError, TypeError
        raise NativeRuntimeError, "Unsupported OQL parameter value #{value.class}"
      end
    end
  end
end
