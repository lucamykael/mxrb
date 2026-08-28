# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    # $Type: Projects$Module
    # ContainmentName: "Modules"
    class Module < Unit
      INFRASTRUCTURE_DOCUMENT_ROUTES = {
        'ExportMappings$ExportMapping' => 'mappings/exports',
        'ImportMappings$ImportMapping' => 'mappings/imports',
        'JsonStructures$JsonStructure' => 'mappings/json_structures',
        'MessageDefinitions$MessageDefinitionCollection' => 'mappings/message_definitions',
        'MessageDefinitions$MessageDefinition2' => 'mappings/message_definitions',
        'XmlSchemas$XmlSchema' => 'mappings/xml_schemas',
        'Rest$PublishedRestService' => 'endpoints',
        'WebServices$PublishedService' => 'endpoints',
        'WebServices$PublishedWebService' => 'endpoints',
        'ODataPublish$PublishedODataService' => 'endpoints',
        'ODataPublish$PublishedODataService2' => 'endpoints',
        'Rest$ConsumedRestService' => 'integrations',
        'Rest$ConsumedODataService' => 'integrations',
        'AppServices$ConsumedAppService' => 'integrations',
        'ODataImport$ConsumedODataService' => 'integrations',
        'DatabaseConnector$DatabaseConnection' => 'persistence/external'
      }.freeze
      MAPPING_DOCUMENT_TYPES = INFRASTRUCTURE_DOCUMENT_ROUTES.keys.grep(
        /Mappings|JsonStructures|MessageDefinitions|XmlSchemas/
      ).freeze
      APPLICATION_DOCUMENT_ROUTES = {
        'DataSets$DataSet' => 'queries/datasets',
        'ScheduledEvents$ScheduledEvent' => 'jobs/scheduled_events',
        'JavaActions$JavaAction' => 'actions/java',
        'JavaScriptActions$JavaScriptAction' => 'actions/javascript'
      }.freeze
      PRESENTATION_DOCUMENT_ROUTES = {
        'Forms$Layout' => 'layouts',
        'Forms$PageTemplate' => 'page_templates',
        'Forms$BuildingBlock' => 'building_blocks',
        'Forms$Snippet' => 'snippets'
      }.freeze
      DOMAIN_DOCUMENT_ROUTES = {
        'DomainModels$ViewEntitySourceDocument' => 'oql_views',
        'Enumerations$Enumeration' => 'enumerations',
        'Constants$Constant' => 'constants'
      }.freeze
      EDITABLE_DOCUMENT_TYPES = (
        INFRASTRUCTURE_DOCUMENT_ROUTES.keys + APPLICATION_DOCUMENT_ROUTES.keys +
        PRESENTATION_DOCUMENT_ROUTES.keys +
        DOMAIN_DOCUMENT_ROUTES.keys
      ).freeze

      attr_reader :name, :sort_index, :from_app_store,
                  :app_store_guid, :app_store_version, :export_level

      def decode(doc)
        @name              = doc["Name"]
        @sort_index        = doc["SortIndex"] || doc["NewSortIndex"]
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

      def mapping_documents
        infrastructure_documents.select { MAPPING_DOCUMENT_TYPES.include?(_1[:type]) }
      end

      def infrastructure_documents
        @infrastructure_documents ||= routed_documents(INFRASTRUCTURE_DOCUMENT_ROUTES)
      end

      def application_documents
        @application_documents ||= routed_documents(APPLICATION_DOCUMENT_ROUTES)
      end

      def presentation_documents
        @presentation_documents ||= routed_documents(PRESENTATION_DOCUMENT_ROUTES)
      end

      def domain_documents
        @domain_documents ||= routed_documents(DOMAIN_DOCUMENT_ROUTES)
      end

      def oql_view_documents
        @oql_view_documents ||= domain_documents.select do |document|
          document[:type] == 'DomainModels$ViewEntitySourceDocument'
        end
      end

      def module_roles
        @module_roles ||= begin
          raw = @mpr.children_of(@id).find { _1["ContainmentName"] == "ModuleSecurity" }
          if raw
            doc = @mpr.parse_contents(raw)
            parse_array(doc["ModuleRoles"]).map do |role|
              {
                id: IO::BsonCodec.extract_id(role["$ID"]),
                name: role["Name"], description: role["Description"].to_s
              }
            end
          else
            []
          end
        end
      end

      def module_security_id
        raw = @mpr.children_of(@id).find { _1["ContainmentName"] == "ModuleSecurity" }
        return '' unless raw

        doc = @mpr.parse_contents(raw)
        IO::BsonCodec.extract_id(doc["$ID"]) || raw.fetch("UnitID")
      end

      def inspect
        "#<Mxrb::Module name=#{@name.inspect} entities=#{entities.size} " \
          "pages=#{pages.size} microflows=#{microflows.size}>"
      end

      private

      def unit_to_doc(unit_hash)
        @mpr.parse_contents(unit_hash[:raw])
      end

      def routed_documents(routes)
        document_units.filter_map do |unit|
          route = routes[unit[:type]]
          next unless route

          raw = unit.fetch(:raw)
          doc = @mpr.parse_contents(raw)
          {
            id: raw.fetch("UnitID"), container_id: raw.fetch("ContainerID"),
            containment: raw.fetch("ContainmentName"), type: unit.fetch(:type),
            name: doc["Name"] || doc["name"] || raw.fetch("UnitID"), doc:, route:
          }
        end
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
