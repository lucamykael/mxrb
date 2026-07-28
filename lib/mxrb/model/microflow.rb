# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    class Microflow < Unit
      unit_type "Mxmodels.Microflows.Microflow"

      attr_accessor :name, :documentation, :return_type, :allowed_roles

      def decode(blob)
        @_raw          = blob
        @name          = "Microflow_#{@id}"
        @documentation = ""
        @return_type   = nil
        @allowed_roles = []
      end

      def encode = @_raw || ""

      def inspect
        "#<Mxrb::Microflow id=#{@id} name=#{@name.inspect}>"
      end
    end
  end
end
