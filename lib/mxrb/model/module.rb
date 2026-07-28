# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    class Module < Unit
      unit_type "Mxmodels.Projects.Module"

      attr_accessor :name

      def decode(blob)
        # Contents blob for a Module is a binary structure.
        # For now we extract the name from a known offset pattern.
        # Will be replaced with full deserializer once format is mapped.
        @name = extract_string(blob) || "UnknownModule"
        @_raw = blob
      end

      def encode
        @_raw || ""
      end

      # ── Children ────────────────────────────────────────────────────────

      def entities
        @entities ||= @mpr.units_of_type("Mxmodels.DomainModels.Entity")
                          .select { _1["ContainerID"] == @id }
                          .map { Entity.new(_1, @mpr) }
      end

      def pages
        @pages ||= @mpr.units_of_type("Mxmodels.Pages.Page")
                       .select { _1["ContainerID"] == @id }
                       .map { Page.new(_1, @mpr) }
      end

      def microflows
        @microflows ||= @mpr.units_of_type("Mxmodels.Microflows.Microflow")
                            .select { _1["ContainerID"] == @id }
                            .map { Microflow.new(_1, @mpr) }
      end

      def inspect
        "#<Mxrb::Module id=#{@id} name=#{@name.inspect} " \
          "entities=#{entities.size} pages=#{pages.size} microflows=#{microflows.size}>"
      end

      private

      # Heuristic: UTF-8 strings in Mendix blobs are often preceded by
      # a 2-byte little-endian length. This is a best-effort extractor
      # for exploration; proper decoding comes from the serializer layer.
      def extract_string(blob)
        return nil unless blob.is_a?(String) && blob.length > 4

        # Try to find a length-prefixed UTF-8 string in the first 128 bytes
        slice = blob.b[0, 128]
        slice.scan(/\x00{0,3}([\x20-\x7e]{3,64})/).flatten.first
      end
    end
  end
end
