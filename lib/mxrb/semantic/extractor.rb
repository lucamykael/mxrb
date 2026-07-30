# frozen_string_literal: true

require "securerandom"
require "set"

module Mxrb
  module Semantic
    # Plan produced by Extractor#plan. Describes what will be extracted and
    # applies the change atomically when apply! is called.
    class ExtractionPlan
      attr_reader :source, :new_name, :selected_ids

      def initialize(project:, source:, new_name:, selected_ids:,
                     inner_objects:, inner_flows:,
                     entry_flow:, exit_flow:,
                     source_doc:, source_raw:)
        @project = project
        @source = source
        @new_name = new_name
        @selected_ids = selected_ids
        @inner_objects = inner_objects
        @inner_flows = inner_flows
        @entry_flow = entry_flow
        @exit_flow = exit_flow
        @source_doc = source_doc
        @source_raw = source_raw
        @applied = false
      end

      def applied? = @applied

      def changes
        [
          "extract #{@inner_objects.size} activit#{@inner_objects.size == 1 ? 'y' : 'ies'} " \
            "from #{@source.qualified_name} into #{@new_name}",
          "replace selection in #{@source.qualified_name} with call to #{@new_name}"
        ]
      end

      def apply!
        raise ArgumentError, "extraction plan was already applied" if applied?

        module_unit_id = find_module_unit_id
        @project.mpr.transaction do
          insert_extracted_microflow!(module_unit_id)
          patch_source_microflow!
        end
        @project.refresh!
        @applied = true
        self
      end

      private

      def find_module_unit_id
        mod = @project.modules.find { _1.name == @source.module_name }
        raise ArgumentError, "cannot find module #{@source.module_name.inspect}" unless mod

        mod.id
      end

      def insert_extracted_microflow!(module_unit_id)
        local_name = @new_name.split(".", 2).last
        start_id = SecureRandom.uuid
        end_id   = SecureRandom.uuid
        first_id = @entry_flow["DestinationPointer"]
        last_id  = @exit_flow["OriginPointer"]

        objects = [
          event_doc(start_id, "Microflows$StartEvent"),
          *@inner_objects,
          event_doc(end_id, "Microflows$EndEvent")
        ]
        flows = [
          simple_flow_doc(start_id, first_id),
          *@inner_flows,
          simple_flow_doc(last_id, end_id)
        ]

        doc = {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$Microflow",
          "Name" => local_name,
          "Documentation" => "",
          "AllowConcurrentExecution" => true,
          "MarkAsUsed" => false,
          "Excluded" => false,
          "MicroflowReturnType" => { "$ID" => SecureRandom.uuid, "$Type" => "DataTypes$VoidType" },
          "AllowedModuleRoles" => IO::BsonCodec.build_array([]),
          "ObjectCollection" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$MicroflowObjectCollection",
            "Objects" => IO::BsonCodec.build_array(objects)
          },
          "Flows" => IO::BsonCodec.build_array(flows)
        }
        @project.mpr.insert_unit(
          container_uuid: module_unit_id,
          containment_name: "Documents",
          contents_doc: doc
        )
      end

      def patch_source_microflow!
        call_id = SecureRandom.uuid
        call_activity = call_activity_doc(call_id)

        removed_ids = @selected_ids
        origin_id   = @entry_flow["OriginPointer"]
        dest_id     = @exit_flow["DestinationPointer"]

        # Rebuild objects: keep non-selected, add call activity
        all_objects = normalize_all(parse_array(@source_doc["ObjectCollection"]["Objects"]))
        kept_objects = all_objects.reject { removed_ids.include?(_1["$ID"]) }
        kept_objects << call_activity

        # Rebuild flows: drop entry/exit flows and inner flows, add two new ones
        inner_flow_ids = @inner_flows.map { _1["$ID"] }.to_set
        removed_flow_ids = inner_flow_ids + [@entry_flow["$ID"], @exit_flow["$ID"]].compact.to_set
        all_flows = normalize_all(parse_array(@source_doc["Flows"]))
        kept_flows = all_flows.reject { removed_flow_ids.include?(_1["$ID"]) }
        kept_flows << simple_flow_doc(origin_id, call_id)
        kept_flows << simple_flow_doc(call_id, dest_id)

        patched = @source_doc.merge(
          "ObjectCollection" => @source_doc["ObjectCollection"].merge(
            "Objects" => IO::BsonCodec.build_array(kept_objects)
          ),
          "Flows" => IO::BsonCodec.build_array(kept_flows)
        )
        @project.mpr.update_unit(@source_raw.fetch("UnitID"), patched)
      end

      def event_doc(id, type)
        { "$ID" => id, "$Type" => type, "RelativeMiddlePoint" => "0;0", "Size" => "20;20" }
      end

      def simple_flow_doc(from_id, to_id)
        {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Microflows$SequenceFlow",
          "OriginPointer" => from_id,
          "DestinationPointer" => to_id,
          "IsErrorHandler" => false,
          "OriginConnectionIndex" => 1,
          "DestinationConnectionIndex" => 3
        }
      end

      def call_activity_doc(id)
        {
          "$ID" => id,
          "$Type" => "Microflows$ActionActivity",
          "RelativeMiddlePoint" => "0;0",
          "Size" => "120;60",
          "Action" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$MicroflowCallAction",
            "ErrorHandlingType" => "Rollback",
            "UseReturnVariable" => false,
            "ResultVariableName" => "ReturnValue",
            "MicroflowCall" => {
              "$ID" => SecureRandom.uuid,
              "$Type" => "Microflows$MicroflowCall",
              "Microflow" => @new_name,
              "ParameterMappings" => IO::BsonCodec.build_array([])
            }
          }
        }
      end

      def parse_array(value)
        IO::BsonCodec.parse_array(value)[:items]
      end

      POINTER_KEYS_EP = %w[$ID OriginPointer DestinationPointer].freeze

      def normalize_ids(hash)
        hash.each_with_object({}) do |(k, v), out|
          out[k] = POINTER_KEYS_EP.include?(k) ? (IO::BsonCodec.extract_id(v) || v) : v
        end
      end

      def normalize_all(arr)
        arr.map { normalize_ids(_1) }
      end
    end

    # Extracts a contiguous subgraph of a microflow's activities into a new
    # microflow and replaces the selection with a call to it.
    class Extractor
      FLOW_KINDS = %i[microflow nanoflow].freeze

      def initialize(project)
        @project = project
      end

      # Plan an extraction.
      #
      # @param source_name [String] qualified name of the source microflow
      # @param as [String]         qualified name for the new extracted microflow
      # @param object_ids [Array]  $ID values of the objects to extract
      def plan(source_name, as:, object_ids:)
        source = resolve(source_name)
        raise ArgumentError, "#{source.qualified_name} is not a microflow or nanoflow" \
          unless FLOW_KINDS.include?(source.kind)

        source_module = source.qualified_name.split(".").first
        new_module    = as.split(".").first
        raise ArgumentError, "extracted microflow must be in the same module (#{source_module})" \
          unless new_module == source_module

        raise ArgumentError, "#{as.inspect} already exists" if @project.find_artifact(as)
        raise ArgumentError, "object_ids cannot be empty" if object_ids.empty?

        raw = @project.raw_unit(source.unit_id)
        doc = @project.parse_bson(raw)

        all_objects = parse_array(doc["ObjectCollection"]["Objects"]).map { normalize_ids(_1) }
        all_flows   = parse_array(doc["Flows"]).map { normalize_ids(_1) }
        by_id = all_objects.to_h { [_1["$ID"], _1] }

        selected = Set.new(object_ids.map { IO::BsonCodec.extract_id(_1)&.to_s || _1.to_s })
        missing  = selected - by_id.keys.to_set
        raise ArgumentError, "unknown object IDs: #{missing.to_a.join(', ')}" unless missing.empty?

        # Reject selection of start/end events — those belong to the frame
        all_objects.each do |obj|
          if selected.include?(obj["$ID"]) && %w[
            Microflows$StartEvent Microflows$EndEvent
          ].include?(obj["$Type"])
            raise ArgumentError, "cannot include start/end event in extraction selection"
          end
        end

        inner_flows  = all_flows.select do
          selected.include?(_1["OriginPointer"]) && selected.include?(_1["DestinationPointer"])
        end
        entry_flows  = all_flows.select do
          !selected.include?(_1["OriginPointer"]) && selected.include?(_1["DestinationPointer"])
        end
        exit_flows   = all_flows.select do
          selected.include?(_1["OriginPointer"]) && !selected.include?(_1["DestinationPointer"])
        end

        if entry_flows.size != 1
          raise ArgumentError,
                "selection must have exactly one entry point (found #{entry_flows.size})"
        end
        if exit_flows.size != 1
          raise ArgumentError,
                "selection must have exactly one exit point (found #{exit_flows.size})"
        end

        inner_objects = all_objects.select { selected.include?(_1["$ID"]) }

        ExtractionPlan.new(
          project: @project,
          source: source,
          new_name: as,
          selected_ids: selected,
          inner_objects: inner_objects,
          inner_flows: inner_flows,
          entry_flow: entry_flows.first,
          exit_flow: exit_flows.first,
          source_doc: doc,
          source_raw: raw
        )
      end

      private

      def resolve(name)
        artifact = @project.find_artifact(name)
        return artifact if artifact

        raise KeyError, "unknown Mendix artifact #{name.inspect}"
      end

      def parse_array(value)
        IO::BsonCodec.parse_array(value)[:items]
      end

      POINTER_KEYS = %w[$ID OriginPointer DestinationPointer].freeze

      def normalize_ids(hash)
        hash.each_with_object({}) do |(k, v), out|
          out[k] = POINTER_KEYS.include?(k) ? (IO::BsonCodec.extract_id(v) || v) : v
        end
      end
    end
  end
end
