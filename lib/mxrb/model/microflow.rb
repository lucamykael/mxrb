# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    # $Type: Microflows$Microflow
    # ContainmentName: "Documents"
    class Microflow < Unit
      attr_reader :name, :documentation, :return_variable_name,
                  :allow_concurrent_execution, :mark_as_used, :excluded,
                  :allowed_module_roles, :parameters, :return_type,
                  :objects, :flows

      def decode(doc)
        @name                       = doc["Name"] || doc["name"]
        @documentation              = doc["Documentation"] || doc["documentation"] || ""
        @return_variable_name       = doc["ReturnVariableName"] || "ReturnValue"
        @allow_concurrent_execution = doc["AllowConcurrentExecution"] != false
        @mark_as_used               = doc["MarkAsUsed"] == true
        @excluded                   = doc["Excluded"] == true
        @allowed_module_roles       = parse_array(doc["AllowedModuleRoles"])
        @parameters                 = extract_parameters(doc)
        @return_type                = doc["MicroflowReturnType"] || doc["ReturnType"]

        obj_col = doc["ObjectCollection"] || {}
        @objects = parse_array(obj_col["Objects"] || obj_col["objects"] || obj_col)
        @flows   = parse_array(obj_col["Flows"]   || obj_col["flows"]   || [])
      end

      def to_bson
        {
          "$ID"                       => @id,
          "$Type"                     => "Microflows$Microflow",
          "Name"                      => @name,
          "Documentation"             => @documentation || "",
          "ReturnVariableName"        => @return_variable_name || "ReturnValue",
          "AllowConcurrentExecution"  => @allow_concurrent_execution != false,
          "MarkAsUsed"                => @mark_as_used || false,
          "Excluded"                  => @excluded || false,
          "AllowedModuleRoles"        => IO::BsonCodec.build_array(@allowed_module_roles || [], marker: 1),
          "MicroflowParameterCollection" => serialize_parameters,
          "MicroflowReturnType"       => @return_type || default_void_return,
          "ObjectCollection"          => serialize_object_collection,
        }
      end

      def inspect
        "#<Mxrb::Microflow name=#{@name.inspect} objects=#{@objects&.size} flows=#{@flows&.size}>"
      end

      private

      def extract_parameters(doc)
        pc = doc["MicroflowParameterCollection"] || doc["Parameters"] || {}
        pc.is_a?(Hash) ? parse_array(pc["Parameters"] || []) : []
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
          "Flows"   => IO::BsonCodec.build_array(@flows   || []),
        }
      end
    end
  end
end
