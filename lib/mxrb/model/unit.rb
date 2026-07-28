# frozen_string_literal: true

module Mxrb
  module Model
    # Base class for all Mendix artefacts backed by a Unit row.
    # Subclasses declare their UnitType and implement #decode / #encode
    # to convert the raw Contents blob to/from Ruby attributes.
    class Unit
      attr_reader :id, :container_id, :containment_name, :mpr

      def self.unit_type(name = nil)
        @unit_type = name if name
        @unit_type
      end

      def initialize(raw, mpr)
        @id               = raw["UnitID"]
        @container_id     = raw["ContainerID"]
        @containment_name = raw["ContainmentName"]
        @mpr              = mpr
        @contents_raw     = raw["Contents"]
        decode(@contents_raw) if @contents_raw
      end

      # Subclasses override this to parse the blob
      def decode(_blob); end

      # Subclasses override this to produce the blob
      def encode
        raise NotImplementedError, "#{self.class}#encode not implemented"
      end

      def save!
        blob = encode
        if @id
          @mpr.update_unit(@id, blob)
        else
          @id = @mpr.insert_unit(
            container_id:     @container_id,
            containment_name: @containment_name,
            type_name:        self.class.unit_type,
            contents:         blob
          )
        end
        self
      end
    end
  end
end
