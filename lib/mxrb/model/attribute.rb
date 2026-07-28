# frozen_string_literal: true

require "securerandom"

module Mxrb
  module Model
    # Attributes are embedded in Entity BSON — NOT separate Unit rows.
    # $Type: DomainModels$Attribute (read) / DomainModels$AttributeImpl (write)
    class Attribute
      # Maps DSL symbol → Mendix storage type name
      TYPE_MAP = {
        string:      "DomainModels$StringAttributeType",
        integer:     "DomainModels$IntegerAttributeType",
        long:        "DomainModels$LongAttributeType",
        decimal:     "DomainModels$DecimalAttributeType",
        boolean:     "DomainModels$BooleanAttributeType",
        datetime:    "DomainModels$DateTimeAttributeType",
        autonumber:  "DomainModels$AutoNumberAttributeType",
        hashstring:  "DomainModels$HashedStringAttributeType",
        binary:      "DomainModels$BinaryAttributeType",
        enum:        "DomainModels$EnumerationAttributeType",
      }.freeze

      REVERSE_TYPE_MAP = TYPE_MAP.invert.freeze

      attr_accessor :id, :name, :documentation, :type, :default_value,
                    :data_storage_guid, :export_level, :raw_type_doc, :raw_value_doc

      def self.from_bson(doc)
        a                   = new
        a.id                = IO::BsonCodec.extract_id(doc["$ID"] || doc["\$ID"])
        a.name              = doc["name"]  || doc["Name"]
        a.documentation     = doc["documentation"] || doc["Documentation"] || ""
        a.data_storage_guid = doc["dataStorageGuid"] || doc["DataStorageGuid"]
        a.export_level      = doc["exportLevel"] || doc["ExportLevel"] || "Hidden"

        type_doc = doc["type"] || doc["Type"] || doc["newType"] || doc["NewType"]
        a.raw_type_doc = type_doc
        if type_doc.is_a?(Hash)
          storage_type = type_doc["$Type"] || type_doc["\$Type"]
          a.type = REVERSE_TYPE_MAP[storage_type] || :string
        end

        a.raw_value_doc = doc["value"] || doc["Value"]
        a.default_value = extract_default(a.raw_value_doc)
        a
      end

      def to_bson
        {
          "$ID"             => @id || SecureRandom.uuid,
          "$Type"           => "DomainModels$AttributeImpl",
          "name"            => @name,
          "documentation"   => @documentation || "",
          "dataStorageGuid" => @data_storage_guid || SecureRandom.uuid,
          "exportLevel"     => @export_level || "Hidden",
          "type"            => serialize_type,
          "value"           => serialize_value,
        }
      end

      def inspect
        "#<Mxrb::Attribute name=#{@name.inspect} type=#{@type}>"
      end

      private

      def self.extract_default(value_doc)
        return nil unless value_doc.is_a?(Hash)
        value_doc["defaultValue"] || value_doc["DefaultValue"]
      end

      def serialize_type
        storage_type = TYPE_MAP[@type] || TYPE_MAP[:string]
        base = { "$ID" => SecureRandom.uuid, "$Type" => storage_type }
        base["localizeDate"] = true if @type == :datetime
        base
      end

      def serialize_value
        {
          "$ID"          => SecureRandom.uuid,
          "$Type"        => "DomainModels$StoredValue",
          "defaultValue" => @default_value.to_s,
        }
      end
    end
  end
end
