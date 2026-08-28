# frozen_string_literal: true

require_relative "../io/bson_codec"

module Mxrb
  module Model
    # Base for all Mendix artefacts.
    # Each subclass maps to a unit row whose Contents BSON has a specific $Type.
    class Unit
      attr_reader :id, :container_id, :containment_name, :mpr, :bson_type

      def initialize(raw, mpr)
        @id               = raw["UnitID"]
        @container_id     = raw["ContainerID"]
        @containment_name = raw["ContainmentName"]
        @mpr              = mpr
        doc               = mpr.parse_contents(raw)
        @bson_type        = doc["$Type"] || doc["\$Type"]
        decode(doc)
      end

      # Subclasses implement these
      def decode(_doc); end
      def to_bson; raise NotImplementedError, "#{self.class}#to_bson not implemented"; end

      def save!
        doc = to_bson
        if @id
          @mpr.update_unit(@id, doc)
        else
          raise "Cannot insert without container_id" unless @container_id
          @id = @mpr.insert_unit(
            container_uuid:   @container_id,
            containment_name: @containment_name,
            contents_doc:     doc
          )
        end
        self
      end

      protected

      # Helpers for BSON field extraction
      def extract_id(val) = IO::BsonCodec.extract_id(val)
      def parse_array(arr) = IO::BsonCodec.parse_array(arr)[:items]
    end
  end
end
