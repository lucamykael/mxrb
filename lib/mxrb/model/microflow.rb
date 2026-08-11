# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    # $Type: Microflows$Microflow
    # ContainmentName: "Documents"
    class Microflow < Unit
      attr_reader :name, :documentation, :return_variable_name,
                  :allow_concurrent_execution, :apply_entity_access, :mark_as_used, :excluded,
                  :allowed_module_roles, :parameters, :return_type,
                  :objects, :flows

      def decode(doc)
        @name                       = doc["Name"] || doc["name"]
        @documentation              = doc["Documentation"] || doc["documentation"] || ""
        @return_variable_name       = doc["ReturnVariableName"] || "ReturnValue"
        @allow_concurrent_execution = doc["AllowConcurrentExecution"] != false
        @apply_entity_access = doc["ApplyEntityAccess"] == true
        @mark_as_used               = doc["MarkAsUsed"] == true
        @excluded                   = doc["Excluded"] == true
        @allowed_module_roles       = parse_array(doc["AllowedModuleRoles"])
        @parameters                 = extract_parameters(doc)
        return_doc                  = doc["MicroflowReturnType"] || doc["ReturnType"]
        @return_type                = return_doc.is_a?(Hash) ? (return_doc["$Type"] || return_doc["Type"]) : return_doc

        obj_col = doc["ObjectCollection"] || {}
        @objects = parse_array(obj_col["Objects"] || obj_col["objects"] || obj_col)
        # Mendix stores all sequence flows (including flows inside looped
        # activities) at document level. Older MXRB-generated documents used
        # ObjectCollection/Flows, so keep that as a compatibility fallback.
        @flows   = parse_array(
          doc["Flows"] || doc["flows"] ||
          obj_col["Flows"] || obj_col["flows"] || []
        )
      end

      def to_bson
        {
          "$ID"                       => @id,
          "$Type"                     => "Microflows$Microflow",
          "Name"                      => @name,
          "Documentation"             => @documentation || "",
          "ReturnVariableName"        => @return_variable_name || "ReturnValue",
          "AllowConcurrentExecution"  => @allow_concurrent_execution != false,
          "ApplyEntityAccess" => @apply_entity_access == true,
          "MarkAsUsed"                => @mark_as_used || false,
          "Excluded"                  => @excluded || false,
          "AllowedModuleRoles"        => IO::BsonCodec.build_array(@allowed_module_roles || [], marker: 1),
          "MicroflowParameterCollection" => serialize_parameters,
          "MicroflowReturnType"       => @return_type || default_void_return,
          "ObjectCollection"          => serialize_object_collection,
          "Flows"                     => IO::BsonCodec.build_array(@flows || []),
        }
      end

      def inspect
        "#<Mxrb::Microflow name=#{@name.inspect} objects=#{@objects.size} flows=#{@flows.size}>"
      end

      private

      def extract_parameters(doc)
        pc = doc["MicroflowParameterCollection"] || doc["Parameters"] || {}
        if pc.is_a?(Hash) && (pc["Parameters"] || !pc.empty?)
          list = parse_array(pc["Parameters"] || [])
          return list unless list.empty?
        end
        # MXRB writer embeds parameters inside ObjectCollection.Objects
        obj_col = doc["ObjectCollection"] || {}
        all_objects = parse_array(obj_col["Objects"] || obj_col["objects"] || obj_col)
        all_objects.select { |o| o.is_a?(Hash) && (o["$Type"] || o["\$Type"]) == "Microflows$MicroflowParameter" }
      end

      def serialize_parameters
        {
          "$ID"        => SecureRandom.uuid,
          "$Type"      => "Microflows$MicroflowParameterCollection",
          "Parameters" => IO::BsonCodec.build_array(@parameters || []),
        }
      end

      def default_void_return
        {
          "$ID"            => SecureRandom.uuid,
          "$Type"          => "Microflows$MicroflowReturnType",
          "Type"           => nil,
          "AllowedModuleRoles" => IO::BsonCodec.build_array([], marker: 1),
        }
      end

      def serialize_object_collection
        {
          "$ID"     => SecureRandom.uuid,
          "$Type"   => "Microflows$MicroflowObjectCollection",
          "Objects" => IO::BsonCodec.build_array(@objects || []),
        }
      end
    end
  end
end
