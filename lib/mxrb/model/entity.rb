# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    class Entity < Unit
      unit_type "Mxmodels.DomainModels.Entity"

      attr_accessor :name, :persistable, :documentation

      PERSISTABILITY = { 0 => :persistent, 1 => :non_persistent, 2 => :external }.freeze

      def decode(blob)
        @_raw  = blob
        # Placeholder: will use ContentSerializer once blob format is mapped
        @name         = "Entity_#{@id}"
        @persistable  = true
        @documentation = ""
      end

      def encode
        @_raw || ""
      end

      def attributes
        @attributes ||= @mpr.units_of_type("Mxmodels.DomainModels.Attribute")
                            .select { _1["ContainerID"] == @id }
                            .map { Attribute.new(_1, @mpr) }
      end

      def associations
        @associations ||= @mpr.units_of_type("Mxmodels.DomainModels.Association")
                              .select { _1["ContainerID"] == @id }
                              .map { Association.new(_1, @mpr) }
      end

      def inspect
        "#<Mxrb::Entity id=#{@id} name=#{@name.inspect} attrs=#{attributes.size}>"
      end
    end
  end
end
