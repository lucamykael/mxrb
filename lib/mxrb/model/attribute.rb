# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    class Attribute < Unit
      unit_type "Mxmodels.DomainModels.Attribute"

      TYPES = %i[AutoNumber Boolean Currency DateTime Decimal
                 Enum Float HashString Integer Long String].freeze

      attr_accessor :name, :type, :required, :default_value, :length, :enumeration

      def decode(blob)
        @_raw          = blob
        @name          = "Attribute_#{@id}"
        @type          = :String
        @required      = false
        @default_value = nil
        @length        = nil
        @enumeration   = nil
      end

      def encode
        @_raw || ""
      end

      def inspect
        "#<Mxrb::Attribute name=#{@name.inspect} type=#{@type}>"
      end
    end
  end
end
