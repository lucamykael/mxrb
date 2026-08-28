# frozen_string_literal: true

require_relative "unit"
require_relative "entity"
require_relative "association"

module Mxrb
  module Model
    # $Type: DomainModels$DomainModel
    # ContainmentName: "DomainModel"
    # Unlike entities/attributes, DomainModel IS its own Unit row.
    # Entities and Attributes are embedded inside the DomainModel BSON (not separate Unit rows).
    class DomainModel < Unit
      attr_reader :documentation, :annotations

      def decode(doc)
        @documentation = doc["documentation"] || doc["Documentation"] || ""
        @annotations   = parse_array(doc["annotations"] || doc["Annotations"])

        entity_docs = parse_array(doc["entities"] || doc["Entities"])
        @entities   = entity_docs.map { Entity.from_bson(_1, @id, @mpr) }
        qualify_entities

        assoc_docs   = parse_array(doc["associations"] || doc["Associations"])
        @associations = assoc_docs.map { Association.from_bson(_1, @id, @mpr) }
        cross_docs = parse_array(doc["crossAssociations"] || doc["CrossAssociations"])
        @cross_associations = cross_docs.map { Association.from_bson(_1, @id, @mpr) }
      end

      def entities     = @entities     || []
      def local_associations = @associations || []
      def cross_associations = @cross_associations || []
      def associations = local_associations + cross_associations

      def to_bson
        {
          "$ID"           => @id,
          "$Type"         => "DomainModels$DomainModel",
          "entities"      => IO::BsonCodec.build_array(@entities.map(&:to_bson)),
          "associations"  => IO::BsonCodec.build_array(local_associations.map(&:to_bson)),
          "crossAssociations" => IO::BsonCodec.build_array(cross_associations.map(&:to_bson)),
          "annotations"   => IO::BsonCodec.build_array([]),
          "documentation" => @documentation || "",
        }
      end

      def inspect
        "#<Mxrb::DomainModel entities=#{entities.size} associations=#{associations.size}>"
      end

      private

      def parent_module_name
        return unless @container_id && @mpr.respond_to?(:unit)

        raw = @mpr.unit(@container_id)
        raw && @mpr.parse_contents(raw)["Name"]
      end

      def qualify_entities
        module_name = parent_module_name
        return unless module_name

        @entities.each { _1.qualified_name ||= "#{module_name}.#{_1.name}" }
      end
    end
  end
end
