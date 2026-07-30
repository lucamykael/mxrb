# frozen_string_literal: true

require "securerandom"
require "set"

module Mxrb
  module Semantic
    class InlinePlan
      attr_reader :source, :called_name, :call_id

      def initialize(project:, source:, called_name:, call_id:,
                     inner_objects:, inner_flows:,
                     entry_flow:, exit_flow:,
                     source_doc:, source_raw:)
        @project = project
        @source = source
        @called_name = called_name
        @call_id = call_id
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
        count = @inner_objects.size
        suffix = count == 1 ? "y" : "ies"
        [
          "inline #{@called_name} into #{@source.qualified_name}",
          "replace call_microflow activity with #{count} inlined activit#{suffix}"
        ]
      end

      def apply!
        raise ArgumentError, "inline plan was already applied" if applied?

        @project.mpr.transaction { patch_source_microflow! }
        @project.refresh!
        @applied = true
        self
      end

      private

      def patch_source_microflow!
        # Remap every inlined object's UUID to avoid collisions with existing caller objects
        id_map = @inner_objects.to_h { [_1["$ID"], SecureRandom.uuid] }

        remapped_objects = @inner_objects.map { |obj| obj.merge("$ID" => id_map.fetch(obj["$ID"])) }
        remapped_flows   = @inner_flows.map do |flow|
          flow.merge(
            "$ID"                  => SecureRandom.uuid,
            "OriginPointer"        => id_map.fetch(flow["OriginPointer"],      flow["OriginPointer"]),
            "DestinationPointer"   => id_map.fetch(flow["DestinationPointer"], flow["DestinationPointer"])
          )
        end

        first_id  = id_map.fetch(@entry_flow["DestinationPointer"])
        last_id   = id_map.fetch(@exit_flow["OriginPointer"])
        origin_id = @entry_flow["OriginPointer"]
        dest_id   = @exit_flow["DestinationPointer"]

        all_objects = normalize_all(parse_array(@source_doc["ObjectCollection"]["Objects"]))
        kept_objects = all_objects.reject { _1["$ID"] == @call_id }
        kept_objects.concat(remapped_objects)

        removed_flow_ids = Set.new([@entry_flow["$ID"], @exit_flow["$ID"]].compact)
        all_flows = normalize_all(parse_array(@source_doc["Flows"]))
        kept_flows = all_flows.reject { removed_flow_ids.include?(_1["$ID"]) }
        kept_flows << simple_flow_doc(origin_id, first_id)
        kept_flows << simple_flow_doc(last_id,   dest_id)
        kept_flows.concat(remapped_flows)

        patched = @source_doc.merge(
          "ObjectCollection" => @source_doc["ObjectCollection"].merge(
            "Objects" => IO::BsonCodec.build_array(kept_objects)
          ),
          "Flows" => IO::BsonCodec.build_array(kept_flows)
        )
        @project.mpr.update_unit(@source_raw.fetch("UnitID"), patched)
      end

      def simple_flow_doc(from_id, to_id)
        {
          "$ID"                    => SecureRandom.uuid,
          "$Type"                  => "Microflows$SequenceFlow",
          "OriginPointer"          => from_id,
          "DestinationPointer"     => to_id,
          "IsErrorHandler"         => false,
          "OriginConnectionIndex"  => 1,
          "DestinationConnectionIndex" => 3
        }
      end

      POINTER_KEYS = %w[$ID OriginPointer DestinationPointer].freeze

      def normalize_ids(hash)
        hash.each_with_object({}) do |(k, v), out|
          out[k] = POINTER_KEYS.include?(k) ? (IO::BsonCodec.extract_id(v) || v) : v
        end
      end

      def normalize_all(arr) = arr.map { normalize_ids(_1) }
      def parse_array(value) = IO::BsonCodec.parse_array(value)[:items]
    end

    # Inlines a called microflow back into its caller, replacing the
    # call_microflow activity with the callee's activities.
    class Inliner
      FLOW_KINDS = %i[microflow nanoflow].freeze

      def initialize(project)
        @project = project
      end

      # @param source_name [String] qualified name of the caller microflow
      # @param calling     [String] qualified name of the microflow to inline
      def plan(source_name, calling:)
        source = resolve(source_name)
        raise ArgumentError, "#{source.qualified_name} is not a microflow or nanoflow" \
          unless FLOW_KINDS.include?(source.kind)

        called = resolve(calling)
        raise ArgumentError, "#{called.qualified_name} is not a microflow or nanoflow" \
          unless FLOW_KINDS.include?(called.kind)

        source_raw = @project.raw_unit(source.unit_id)
        source_doc = @project.parse_bson(source_raw)

        all_objects = normalize_all(parse_array(source_doc["ObjectCollection"]["Objects"]))
        all_flows   = normalize_all(parse_array(source_doc["Flows"]))

        call_activity = all_objects.find do |obj|
          obj["$Type"] == "Microflows$ActionActivity" &&
            obj.dig("Action", "MicroflowCall", "Microflow") == calling
        end
        raise ArgumentError, "no call to #{calling.inspect} found in #{source_name.inspect}" \
          unless call_activity

        call_id    = call_activity["$ID"]
        entry_flow = all_flows.find { _1["DestinationPointer"] == call_id }
        exit_flow  = all_flows.find { _1["OriginPointer"]      == call_id }
        raise ArgumentError, "cannot find entry flow for call activity" unless entry_flow # :nocov:
        raise ArgumentError, "cannot find exit flow for call activity"  unless exit_flow  # :nocov:

        called_raw = @project.raw_unit(called.unit_id)
        called_doc = @project.parse_bson(called_raw)

        called_objects = normalize_all(parse_array(called_doc["ObjectCollection"]["Objects"]))
        called_flows   = normalize_all(parse_array(called_doc["Flows"]))

        start_event = called_objects.find { _1["$Type"] == "Microflows$StartEvent" }
        end_event   = called_objects.find { _1["$Type"] == "Microflows$EndEvent"   }
        raise ArgumentError, "#{calling.inspect} has no start event" unless start_event
        raise ArgumentError, "#{calling.inspect} has no end event"   unless end_event  # :nocov:

        start_id = start_event["$ID"]
        end_id   = end_event["$ID"]

        inner_objects = called_objects.reject { [start_id, end_id].include?(_1["$ID"]) }
        raise ArgumentError, "#{calling.inspect} has no activities to inline" if inner_objects.empty? # :nocov:

        inner_flows = called_flows.reject do |f|
          [start_id, end_id].include?(f["OriginPointer"]) ||
            [start_id, end_id].include?(f["DestinationPointer"])
        end

        start_to_first = called_flows.find { _1["OriginPointer"]      == start_id }
        last_to_end    = called_flows.find { _1["DestinationPointer"] == end_id   }
        raise ArgumentError, "cannot resolve first activity in #{calling.inspect}"  unless start_to_first # :nocov:
        raise ArgumentError, "cannot resolve last activity in #{calling.inspect}"   unless last_to_end    # :nocov:

        # Synthesise entry/exit flows that point at the actual first/last inlined objects
        synthetic_entry = entry_flow.merge("DestinationPointer" => start_to_first["DestinationPointer"])
        synthetic_exit  = exit_flow.merge("OriginPointer"       => last_to_end["OriginPointer"])

        InlinePlan.new(
          project:       @project,
          source:        source,
          called_name:   calling,
          call_id:       call_id,
          inner_objects: inner_objects,
          inner_flows:   inner_flows,
          entry_flow:    synthetic_entry,
          exit_flow:     synthetic_exit,
          source_doc:    source_doc,
          source_raw:    source_raw
        )
      end

      private

      def resolve(name)
        artifact = @project.find_artifact(name)
        raise KeyError, "unknown Mendix artifact #{name.inspect}" unless artifact
        artifact
      end

      POINTER_KEYS = %w[$ID OriginPointer DestinationPointer].freeze

      def normalize_ids(hash)
        hash.each_with_object({}) do |(k, v), out|
          out[k] = POINTER_KEYS.include?(k) ? (IO::BsonCodec.extract_id(v) || v) : v
        end
      end

      def normalize_all(arr) = arr.map { normalize_ids(_1) }
      def parse_array(value) = IO::BsonCodec.parse_array(value)[:items]
    end
  end
end
