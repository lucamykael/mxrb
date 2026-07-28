# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    class Association < Unit
      unit_type "Mxmodels.DomainModels.Association"

      TYPES        = %i[Reference ReferenceSet].freeze
      OWNERS       = %i[Default Both].freeze
      DELETE_RULES = %i[NoAction DeleteMeAndReferences DeleteReferences].freeze

      attr_accessor :name, :type, :owner, :child_entity, :parent_entity,
                    :child_delete_rule, :parent_delete_rule

      def decode(blob)
        @_raw             = blob
        @name             = "Association_#{@id}"
        @type             = :Reference
        @owner            = :Default
        @child_delete_rule  = :NoAction
        @parent_delete_rule = :NoAction
      end

      def encode = @_raw || ""

      def inspect
        "#<Mxrb::Association name=#{@name.inspect} type=#{@type}>"
      end
    end
  end
end
