# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    # $Type: Projects$Module
    # ContainmentName: "Modules"
    class Module < Unit
      attr_reader :name, :sort_index, :from_app_store,
                  :app_store_guid, :app_store_version, :export_level

      def decode(doc)
        @name              = doc["Name"]
        @sort_index        = doc["SortIndex"]
        @from_app_store    = doc["FromAppStore"] == true
        @app_store_guid    = doc["AppStoreGuid"]
        @app_store_version = doc["AppStoreVersion"]
        @export_level      = doc["ExportLevel"] || "Hidden"
      end

      def to_bson
        {
          "$ID"          => @id,
          "$Type"        => "Projects$Module",
          "Name"         => @name,
          "SortIndex"    => @sort_index || 0,
          "FromAppStore" => @from_app_store || false,
          "ExportLevel"  => @export_level || "Hidden",
        }
      end

      # ── Children (resolved from Unit table by ContainerID) ────────────

      def domain_model
        @domain_model ||= begin
          raws = @mpr.units_by_containment("DomainModel").select { _1["ContainerID"] == @id }
          raws.empty? ? nil : DomainModel.new(raws.first, @mpr)
        end
      end

      def entities    = domain_model&.entities    || []
      def associations = domain_model&.associations || []

      def pages
        @pages ||= document_units
                   .select { |u| u[:type]&.start_with?("Pages$") }
                   .map { Page.new(_1[:raw], @mpr) }
      end

      def microflows
        @microflows ||= document_units
                        .select { |u| u[:type] == "Microflows$Microflow" }
                        .map { Microflow.new(_1[:raw], @mpr) }
      end

      def inspect
        "#<Mxrb::Module name=#{@name.inspect} entities=#{entities.size} " \
          "pages=#{pages.size} microflows=#{microflows.size}>"
      end

      private

      # Documents live in ContainmentName = "Documents" recursively under this module.
      # We do a simple two-pass: direct Documents children + Documents inside Folders.
      def document_units
        @document_units ||= begin
          direct    = children_with_containment("Documents")
          folders   = children_with_containment("Folders")
          in_folder = folders.flat_map { children_by_parent_id(_1["UnitID"], "Documents") }
          (direct + in_folder).map do |raw|
            doc  = @mpr.parse_contents(raw)
            type = doc["$Type"]
            { raw: raw, type: type }
          end
        end
      end

      def children_with_containment(name)
        @mpr.units_by_containment(name).select { _1["ContainerID"] == @id }
      end

      def children_by_parent_id(parent_id, containment)
        @mpr.children_of(parent_id).select { _1["ContainmentName"] == containment }
      end
    end
  end
end
