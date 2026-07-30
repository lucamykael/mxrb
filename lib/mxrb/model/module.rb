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
                   .select { |u| %w[Pages$Page Forms$Page].include?(u[:type]) }
                   .map { Page.new(_1[:raw], @mpr) }
      end

      def microflows
        @microflows ||= document_units
                        .select { |u| u[:type] == "Microflows$Microflow" }
                        .map { Microflow.new(_1[:raw], @mpr) }
      end

      def nanoflows
        @nanoflows ||= document_units
                       .select { |u| u[:type] == "Microflows$Nanoflow" }
                       .map { Microflow.new(_1[:raw], @mpr) }
      end

      def menus
        @menus ||= document_units
                   .select { |u| u[:type] == "Menus$MenuDocument" }
                   .map { Menu.new(_1[:raw], @mpr) }
      end

      def enumerations
        @enumerations ||= document_units
                          .select { |u| u[:type] == "Enumerations$Enumeration" }
                          .map { unit_to_doc(_1) }
      end

      def constants
        @constants ||= document_units
                       .select { |u| u[:type] == "Constants$Constant" }
                       .map { unit_to_doc(_1) }
      end

      def scheduled_events
        @scheduled_events ||= document_units
                              .select { |u| u[:type] == "ScheduledEvents$ScheduledEvent" }
                              .map { unit_to_doc(_1) }
      end

      def module_roles
        @module_roles ||= begin
          raw = @mpr.children_of(@id).find { _1["ContainmentName"] == "ModuleSecurity" }
          if raw
            doc = @mpr.parse_contents(raw)
            parse_array(doc["ModuleRoles"]).map do |role|
              { name: role["Name"], description: role["Description"].to_s }
            end
          else
            []
          end
        end
      end

      def inspect
        "#<Mxrb::Module name=#{@name.inspect} entities=#{entities.size} " \
          "pages=#{pages.size} microflows=#{microflows.size}>"
      end

      private

      def unit_to_doc(unit_hash)
        @mpr.parse_contents(unit_hash[:raw])
      end

      # Documents live in ContainmentName = "Documents" recursively under this module.
      # We do a simple two-pass: direct Documents children + Documents inside Folders.
      def document_units
        @document_units ||= begin
          collect_documents(@id).map do |raw|
            doc  = @mpr.parse_contents(raw)
            type = doc["$Type"]
            { raw: raw, type: type }
          end
        end
      end

      def children_with_containment(name)
        @mpr.units_by_containment(name).select { _1["ContainerID"] == @id }
      end

      def collect_documents(parent_id)
        @mpr.children_of(parent_id).flat_map do |raw|
          case raw["ContainmentName"]
          when "Documents"
            [raw]
          when "Folders"
            collect_documents(raw.fetch("UnitID"))
          else
            []
          end
        end
      end
    end
  end
end
