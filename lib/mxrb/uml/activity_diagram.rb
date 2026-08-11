# frozen_string_literal: true

require_relative 'support'

module Mxrb
  module Uml
    # Renders the native object/sequence-flow graph of one Mendix microflow.
    # rubocop:disable Metrics
    class ActivityDiagram
      def initialize(microflow)
        @microflow = microflow
        @objects = Array(microflow.objects)
        @flows = Array(microflow.flows)
        @objects_by_id = @objects.to_h { [raw_object_id(_1), _1] }
      end

      def to_mermaid
        lines = ['flowchart TD']
        @objects.each { lines << "  #{mermaid_node(_1)}" }
        @flows.each do |flow|
          line = flow_line(flow, :mermaid)
          lines << "  #{line}" if line
        end
        "#{lines.join("\n")}\n"
      end

      def to_plantuml
        lines = ['@startuml', "title #{Support.plantuml_text(@microflow.name)}"]
        @objects.each { lines << plantuml_node(_1) }
        @flows.each do |flow|
          line = flow_line(flow, :plantuml)
          lines << line if line
        end
        lines << '@enduml'
        "#{lines.join("\n")}\n"
      end

      private

      def mermaid_node(object)
        id = node_id(object)
        label = Support.mermaid_text(object_label(object))
        case object_type(object)
        when 'StartEvent' then %(#{id}(["Start"]))
        when 'EndEvent', 'ErrorEvent', 'ContinueEvent' then %(#{id}(["#{label}"]))
        when 'DecisionMergeActivity', 'ExclusiveMerge' then %(#{id}{"#{label}"})
        else %(#{id}["#{label}"])
        end
      end

      def plantuml_node(object)
        id = node_id(object)
        label = Support.plantuml_text(object_label(object))
        shape = %w[DecisionMergeActivity ExclusiveMerge].include?(object_type(object)) ? 'choice' : 'state'
        %(#{shape} "#{label}" as #{id})
      end

      def flow_line(flow, format)
        origin = pointer(flow, 'OriginPointer', 'Origin')
        destination = pointer(flow, 'DestinationPointer', 'Destination')
        return unless @objects_by_id.key?(origin) && @objects_by_id.key?(destination)

        label = flow_label(flow)
        if format == :mermaid
          middle = label.empty? ? '-->' : %(-->|"#{Support.mermaid_text(label)}"|)
          "#{node_id(@objects_by_id.fetch(origin))} #{middle} #{node_id(@objects_by_id.fetch(destination))}"
        else
          suffix = label.empty? ? '' : " : #{Support.plantuml_text(label)}"
          "#{node_id(@objects_by_id.fetch(origin))} --> #{node_id(@objects_by_id.fetch(destination))}#{suffix}"
        end
      end

      def object_label(object)
        type = object_type(object)
        return 'Start' if type == 'StartEvent'
        return Support.words(type) unless type == 'ActionActivity'

        caption = object['Caption'] || object['caption']
        action = object['Action'] || object['action'] || {}
        generated = object['AutoGenerateCaption'] == true || caption.to_s == 'Activity'
        return caption unless caption.to_s.empty? || generated

        call = action['MicroflowCall'] || action['microflowCall'] || {}
        target = call['Microflow'] || call['microflow']
        return "Call #{target}" unless target.to_s.empty?

        Support.words(action['$Type'] || action['Type'] || 'Action')
      end

      def flow_label(flow)
        direct = flow['Caption'] || flow['Label'] || flow['Condition']
        return direct.to_s unless direct.to_s.empty?

        value = flow['CaseValue'] || flow['caseValue']
        value = Mxrb::IO::BsonCodec.parse_array(flow['CaseValues'])[:items].first if value.nil? && flow['CaseValues']
        return '' if value.nil?

        if value.is_a?(Hash)
          return '' if (value['$Type'] || value['Type']).to_s.end_with?('$NoCase')

          (value['StringRepresentation'] || value['Value'] || Support.words(value['$Type'])).to_s
        else
          value.to_s
        end
      end

      def pointer(flow, *keys)
        value = keys.filter_map { flow[_1] }.first
        Mxrb::IO::BsonCodec.extract_id(value).to_s
      end

      def raw_object_id(object) = Mxrb::IO::BsonCodec.extract_id(object['$ID'] || object['ID']).to_s
      def object_type(object) = (object['$Type'] || object['Type']).to_s.delete_prefix('Microflows$')
      def node_id(object) = Support.identifier(raw_object_id(object), prefix: 'activity')
    end
    # rubocop:enable Metrics
  end
end
