# frozen_string_literal: true

require "securerandom"

module Mxrb
  module Model
    # Associations are embedded in DomainModel BSON — NOT separate Unit rows.
    # $Type: DomainModels$Association
    #
    # CRITICAL GOTCHA (from reverse engineering):
    #   ParentID = entity FROM (the one with the FK) — counter-intuitive naming!
    #   ChildID  = entity TO  (the referenced entity)
    # MemberAccess should be added ONLY to the FROM entity (ParentPointer), not ChildID.
    class Association
      attr_accessor :id, :name, :documentation,
                    :from_entity_id,   # ParentID in BSON (FROM entity — has the FK)
                    :to_entity_id,     # ChildID  in BSON (TO entity — referenced)
                    :association_type, :owner, :storage_format,
                    :delete_behavior, :export_level

      TYPES         = %i[Reference ReferenceSet].freeze
      OWNERS        = %i[Default Both].freeze
      STORAGE_FMTS  = %i[Column Table].freeze

      def self.from_bson(doc, _domain_model_id = nil, _mpr = nil)
        a                  = new
        a.id               = IO::BsonCodec.extract_id(doc["$ID"] || doc["\$ID"])
        a.name             = doc["Name"] || doc["name"]
        a.documentation    = doc["Documentation"] || doc["documentation"] || ""
        # ParentID = FROM entity (counter-intuitive — see class comment)
        a.from_entity_id   = IO::BsonCodec.extract_id(doc["ParentID"] || doc["parentId"])
        a.to_entity_id     = IO::BsonCodec.extract_id(doc["ChildID"]  || doc["childId"])
        a.association_type = (doc["Type"] || doc["type"] || "Reference").to_sym
        a.owner            = (doc["Owner"] || doc["owner"] || "Default").to_sym
        a.storage_format   = (doc["StorageFormat"] || "Column").to_sym
        a.delete_behavior  = doc["DeleteBehavior"] || doc["deleteBehavior"]
        a.export_level     = doc["ExportLevel"] || "Hidden"
        a
      end

      def to_bson
        {
          "$ID"           => @id || SecureRandom.uuid,
          "$Type"         => "DomainModels$Association",
          "Name"          => @name,
          "Documentation" => @documentation || "",
          # ParentID = FROM entity (the one that carries the FK)
          "ParentID"      => @from_entity_id,
          "ChildID"       => @to_entity_id,
          "Type"          => (@association_type || :Reference).to_s,
          "Owner"         => (@owner || :Default).to_s,
          "StorageFormat" => (@storage_format || :Column).to_s,
          "DeleteBehavior" => @delete_behavior || default_delete_behavior,
          "ExportLevel"   => @export_level || "Hidden",
        }
      end

      def inspect
        "#<Mxrb::Association name=#{@name.inspect} type=#{@association_type} " \
          "from=#{@from_entity_id.to_s.slice(0, 8)} to=#{@to_entity_id.to_s.slice(0, 8)}>"
      end

      private

      def default_delete_behavior
        {
          "$ID"   => SecureRandom.uuid,
          "$Type" => "DomainModels$DeleteBehavior",
          "parentDeleteBehavior" => "NoAction",
          "childDeleteBehavior"  => "NoAction",
          "parentErrorMessage"   => nil,
          "childErrorMessage"    => nil,
        }
      end
    end
  end
end
