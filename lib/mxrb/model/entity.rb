# frozen_string_literal: true

require_relative "attribute"

module Mxrb
  module Model
    # Entities are embedded in the DomainModel BSON — NOT separate Unit rows.
    # $Type: DomainModels$Entity (read) / DomainModels$EntityImpl (write)
    class Entity
      attr_accessor :id, :name, :qualified_name, :documentation,
                    :persistable, :location, :data_storage_guid,
                    :export_level, :generalization

      # Build from a BSON hash (embedded in DomainModel's "entities" array).
      def self.from_bson(doc, _domain_model_id, mpr)
        e                    = new
        e.id                 = IO::BsonCodec.extract_id(doc["$ID"] || doc["\$ID"])
        e.name               = doc["name"]  || doc["Name"]
        e.qualified_name     = doc["$QualifiedName"] || doc["\$QualifiedName"]
        e.documentation      = doc["documentation"] || doc["Documentation"] || ""
        e.data_storage_guid  = doc["dataStorageGuid"] || doc["DataStorageGuid"]
        e.export_level       = doc["exportLevel"] || doc["ExportLevel"] || "Hidden"
        e.location           = parse_location(doc["location"] || doc["Location"])

        # Persistable lives inside generalization.NoGeneralization.persistable
        gen = doc["generalization"] || doc["Generalization"] || doc["maybeGeneralization"]
        e.generalization = gen
        e.persistable = gen.is_a?(Hash) ? (gen["persistable"] != false) : true

        # Attributes (embedded array with marker)
        attr_arr   = IO::BsonCodec.parse_array(doc["attributes"] || doc["Attributes"])[:items]
        e.instance_variable_set(:@attributes, attr_arr.map { Attribute.from_bson(_1) })

        e
      end

      def attributes = @attributes || []

      def to_bson
        {
          "$ID"             => @id,
          "$Type"           => "DomainModels$EntityImpl",
          "$QualifiedName"  => @qualified_name,
          "name"            => @name,
          "documentation"   => @documentation || "",
          "dataStorageGuid" => @data_storage_guid || SecureRandom.uuid,
          "location"        => serialize_location(@location),
          "generalization"  => serialize_generalization,
          "attributes"      => IO::BsonCodec.build_array(@attributes.map(&:to_bson)),
          "validationRules" => IO::BsonCodec.build_array([]),  # must come after attributes
          "eventHandlers"   => IO::BsonCodec.build_array([]),
          "indexes"         => IO::BsonCodec.build_array([]),
          "accessRules"     => IO::BsonCodec.build_array([]),
          "source"          => nil,
          "exportLevel"     => @export_level || "Hidden",
          "image"           => "",
          "imageData"       => "",
        }
      end

      def inspect
        "#<Mxrb::Entity name=#{@name.inspect} attrs=#{attributes.size} persistable=#{@persistable}>"
      end

      private

      def self.parse_location(loc)
        return { x: 0, y: 0 } unless loc.is_a?(Hash)
        { x: loc["x"] || loc[:x] || 0, y: loc["y"] || loc[:y] || 0 }
      end

      def serialize_location(loc)
        return { "x" => 0, "y" => 0 } unless loc
        { "x" => loc[:x] || 0, "y" => loc[:y] || 0 }
      end

      def serialize_generalization
        @generalization || {
          "$ID"             => SecureRandom.uuid,
          "$Type"           => "DomainModels$NoGeneralization",
          "persistable"     => @persistable != false,
          "hasChangedDate"  => false,
          "hasCreatedDate"  => false,
          "hasOwner"        => false,
          "hasChangedBy"    => false,
        }
      end
    end
  end
end
