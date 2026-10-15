# frozen_string_literal: true

module Mxrb
  class Exporter
    # Decides which flow bodies are editable and linearizes them into structured Ruby.
    module FlowLinearization
      EDITABLE_FLOW_OBJECT_TYPES = %w[
        Microflows$StartEvent
        Microflows$EndEvent
        Microflows$ActionActivity
        Microflows$ExclusiveSplit
        Microflows$InheritanceSplit
        Microflows$ExclusiveMerge
        Microflows$LoopedActivity
        Microflows$ErrorEvent
        Microflows$ContinueEvent
        Microflows$BreakEvent
        Microflows$Annotation
        Microflows$MicroflowParameter
      ].freeze

      EDITABLE_ACTION_TYPES = %w[
        Microflows$CreateObjectAction
        Microflows$CreateChangeAction
        Microflows$ChangeObjectAction
        Microflows$ChangeAction
        Microflows$RetrieveAction
        Microflows$CommitObjectsAction
        Microflows$CommitAction
        Microflows$DeleteAction
        Microflows$MicroflowCallAction
        Microflows$CreateVariableAction
        Microflows$ChangeVariableAction
        Microflows$ShowMessageAction
        Microflows$LogMessageAction
        Microflows$ShowFormAction
        Microflows$ShowHomePageAction
        Microflows$CloseFormAction
        Microflows$JavaActionCallAction
        Microflows$JavaScriptActionCallAction
        Microflows$NanoflowCallAction
        Microflows$AppServiceCallAction
        Microflows$AggregateAction
        Microflows$RollbackAction
        Microflows$CastAction
        Microflows$CreateListAction
        Microflows$ListOperationsAction
        Microflows$ChangeListAction
        Microflows$ValidationFeedbackAction
        Microflows$RestCallAction
        DatabaseConnector$ExecuteDatabaseQueryAction
        Microflows$ImportXmlAction
        Microflows$ExportXmlAction
        Microflows$DownloadFileAction
      ].freeze

      private

      def editable_flow_body?(objects, flows, nested: false)
        return nested if objects.empty?
        return false unless nested || editable_annotation_endpoints?(objects, flows)

        local_flows = flows_for_objects(flows, objects)
        unless nested
          return false unless objects.count { _1['$Type'] == 'Microflows$StartEvent' } == 1
          return false unless objects.any? { _1['$Type'] == 'Microflows$EndEvent' }
        end
        connected_objects = objects.reject do |object|
          %w[Microflows$Annotation Microflows$MicroflowParameter].include?(object['$Type'])
        end
        return false if connected_objects.size > 1 && local_flows.empty?
        return false unless objects.all? { EDITABLE_FLOW_OBJECT_TYPES.include?(_1['$Type']) }
        return false if !nested && objects.any? { _1['$Type'] == 'Microflows$BreakEvent' }
        return false unless local_flows.all? do
          %w[Microflows$SequenceFlow Microflows$AnnotationFlow].include?(_1['$Type'])
        end

        sequence_flows = local_flows.select { _1['$Type'] == 'Microflows$SequenceFlow' }
        return false if sequence_flows.select { _1['IsErrorHandler'] == true }
                                      .group_by { _1['OriginPointer'] }.any? { |_origin, items| items.size > 1 }

        by_id = objects.to_h { [_1['$ID'], _1] }

        objects.all? do |object|
          case object['$Type']
          when 'Microflows$ActionActivity'
            editable_action?(object['Action'] || {})
          when 'Microflows$ExclusiveSplit'
            decision_shape_editable?(object, sequence_flows, by_id)
          when 'Microflows$InheritanceSplit'
            branches = sequence_flows.select { _1['OriginPointer'] == object['$ID'] }
            !object['SplitVariableName'].to_s.empty? &&
              branches.size >= 2 &&
              branches.all? { by_id.key?(_1['DestinationPointer']) }
          when 'Microflows$LoopedActivity'
            collection = object['ObjectCollection'] || {}
            inner_objects = bson_items(collection['Objects'])
            source = loop_source(object)
            return false unless %w[
              Microflows$WhileLoopCondition Microflows$IterableList
              Microflows$IteratorList
            ].include?(source['$Type'])

            editable_flow_body?(
              inner_objects, flows, nested: true
            )
          else
            true
          end
        end
      end

      def editable_annotation_endpoints?(objects, flows)
        references = annotation_flow_endpoint_refs(objects, flows)
        body_dsl_lines(objects, flows) unless references.empty?
        true
      rescue SerializationError
        false
      end

      def editable_action?(action)
        return false unless EDITABLE_ACTION_TYPES.include?(action['$Type'])

        case action['$Type']
        when 'Microflows$ChangeObjectAction'
          action.fetch('Commit', 'No') == 'No' && action.fetch('RefreshInClient', false) == false
        when 'Microflows$CreateChangeAction', 'Microflows$ChangeAction'
          %w[No Yes YesWithoutEvents].include?(action.fetch('Commit', 'No')) &&
            [true, false].include?(action.fetch('RefreshInClient', false))
        when 'Microflows$RetrieveAction'
          source = action['RetrieveSource'] || {}
          case source['$Type']
          when 'Microflows$DatabaseRetrieveSource'
            range_type = source.dig('Range', '$Type')
            %w[Microflows$ConstantRange Microflows$CustomRange].include?(range_type) &&
              bson_items(source.dig('NewSortings', 'Sortings') || source['SortItems']).all? do |sorting|
                !(sorting['AttributePath'] || sorting.dig('AttributeRef', 'Attribute')).to_s.empty?
              end
          when 'Microflows$AssociationRetrieveSource'
            !source['AssociationId'].to_s.empty? && !source['StartVariableName'].to_s.empty?
          else
            false
          end
        when 'Microflows$ShowMessageAction'
          bson_items(action.dig('Template', 'Parameters')).all? { _1['Expression'] }
        when 'Microflows$LogMessageAction'
          bson_items(action.dig('MessageTemplate', 'Parameters')).all? { _1['Expression'] }
        when 'Microflows$ShowFormAction'
          settings = action['FormSettings'] || {}
          title = settings['FormTitle'] || settings['TitleOverride']
          title_supported = title.nil? ||
                            (title.is_a?(Hash) && bson_items(title['Parameters']).empty?)
          title_supported && bson_items(settings['ParameterMappings']).all? do |mapping|
            mapping['Parameter'] && mapping['Argument']
          end
        when 'Microflows$JavaActionCallAction'
          !action['JavaAction'].to_s.empty? && bson_items(action['ParameterMappings']).all? do |mapping|
            value = mapping['Value'] || {}
            mapping['Parameter'] && %w[
              Microflows$BasicJavaActionParameterValue
              Microflows$BasicCodeActionParameterValue
              Microflows$EntityTypeCodeActionParameterValue
              Microflows$EntityTypeJavaActionParameterValue
              Microflows$MicroflowJavaActionParameterValue
              Microflows$MicroflowParameterValue
              Microflows$ImportMappingJavaActionParameterValue
              Microflows$ExportMappingJavaActionParameterValue
            ].include?(value['$Type'])
          end
        when 'Microflows$JavaScriptActionCallAction'
          !action['JavaScriptAction'].to_s.empty? && bson_items(action['ParameterMappings']).all? do |mapping|
            value = mapping['ParameterValue'] || {}
            mapping['Parameter'] && %w[
              Microflows$BasicCodeActionParameterValue
              Microflows$EntityTypeCodeActionParameterValue
            ].include?(value['$Type'])
          end
        when 'Microflows$NanoflowCallAction'
          !action.dig('NanoflowCall', 'Nanoflow').to_s.empty? &&
            bson_items(action.dig('NanoflowCall', 'ParameterMappings')).all? do |mapping|
              mapping['Parameter'] && mapping['Argument']
            end
        when 'Microflows$AppServiceCallAction'
          !action['AppServiceAction'].to_s.empty? && bson_items(action['ParameterMappings']).all? do |mapping|
            mapping['Parameter'] && mapping['Argument']
          end
        when 'Microflows$ValidationFeedbackAction'
          bson_items(action.dig('FeedbackTemplate', 'Parameters')).all? do |parameter|
            parameter['Expression']
          end
        when 'Microflows$RestCallAction'
          http = action['HttpConfiguration'] || {}
          request = action['RequestHandling'] || {}
          request_supported = case request['$Type']
                              when 'Microflows$MappingRequestHandling'
                                mapping_id = request['MappingId'].to_s
                                mapping_variable = request['MappingVariableName'].to_s
                                !mapping_id.empty? && !mapping_variable.empty?
                              when 'Microflows$CustomRequestHandling'
                                template = request['Template'] || {}
                                bson_items(template['Parameters']).all? { _1['Expression'] }
                              else
                                false
                              end
          result = action['ResultHandling'] || {}
          result_mapping = result['ImportMappingCall'] || {}
          result_supported = case action['ResultHandlingType']
                             when 'Mapping'
                               !result_mapping['ReturnValueMapping'].to_s.empty? &&
                               result_mapping.dig('Range', '$Type') ==
                               'Microflows$ConstantRange'
                             when 'HttpResponse'
                               result['Bind'] == true &&
                               result['ImportMappingCall'].nil? &&
                               !result['ResultVariableName'].to_s.empty? &&
                               !result.dig('VariableType', 'Entity').to_s.empty?
                             when 'String'
                               result['Bind'] == true &&
                               result['ImportMappingCall'].nil? &&
                               !result['ResultVariableName'].to_s.empty? &&
                               result.dig('VariableType', '$Type') == 'DataTypes$StringType'
                             else
                               false
                             end
          !http['HttpMethod'].to_s.empty? &&
            bson_items(http['HttpHeaderEntries']).all? { _1['Key'] && _1['Value'] } &&
            bson_items(http.dig('CustomLocationTemplate', 'Parameters')).all? do
              _1['Expression']
            end &&
            request_supported && result_supported
        when 'DatabaseConnector$ExecuteDatabaseQueryAction'
          (!action['Query'].to_s.empty? || !action['DynamicQuery'].to_s.empty?) &&
            bson_items(action['ParameterMappings']).all? do |mapping|
              mapping['ParameterName'] && mapping['Value']
            end &&
            bson_items(action['ConnectionParameterMappings']).all? do |mapping|
              mapping['ParameterName'] && mapping['Value']
            end
        when 'Microflows$ImportXmlAction'
          result = action['ResultHandling'] || {}
          mapping = result['ImportMappingCall'] || {}
          !action['XmlDocumentVariableName'].to_s.empty? &&
            result['Bind'] == true && !result['ResultVariableName'].to_s.empty? &&
            !result.dig('VariableType', 'Entity').to_s.empty? &&
            !mapping['ReturnValueMapping'].to_s.empty? &&
            mapping.dig('Range', '$Type') == 'Microflows$ConstantRange'
        when 'Microflows$ExportXmlAction'
          output = action['OutputMethod'] || {}
          handling = action['ResultHandling'] || {}
          output['$Type'] == 'ExportXmlAction$StringExport' &&
            !output['OutputVariableName'].to_s.empty? &&
            handling['$Type'] == 'Microflows$MappingRequestHandling' &&
            %w[Xml Json].include?(handling['ContentType']) &&
            !handling['MappingId'].to_s.empty? &&
            !handling['MappingVariableName'].to_s.empty? &&
            [true, false].include?(action['IsValidationRequired'])
        when 'Microflows$DownloadFileAction'
          !action['FileDocumentVariableName'].to_s.empty?
        else
          true
        end
      end

      def decision_shape_editable?(object, flows, by_id)
        condition = object['SplitCondition'] || {}
        condition_supported = !condition['Expression'].to_s.empty? ||
                              (condition['$Type'] == 'Microflows$RuleSplitCondition' &&
                               !condition.dig('RuleCall', 'Microflow').to_s.empty? &&
                               bson_items(condition.dig('RuleCall', 'ParameterMappings')).all? do
                                 _1['Parameter'] && _1['Argument']
                               end)
        return false unless condition_supported

        branches = flows.reject { _1['IsErrorHandler'] == true }
                        .select { _1['OriginPointer'] == object['$ID'] }
        branches.size >= 2 && branches.all? { by_id.key?(_1['DestinationPointer']) }
      end

      def body_dsl_lines(objects, flows, indent = 2, nested: false, endpoint_refs: nil,
                         emitted_refs: nil)
        return [] if objects.empty?

        by_id   = objects.to_h { |o| [o['$ID'], o] }
        fwd_map = {}
        err_map = {}
        flows.each do |f|
          next unless f['$Type'] == 'Microflows$SequenceFlow'

          from     = f['OriginPointer']
          to       = f['DestinationPointer']
          case_val = flow_case_value(f)
          if f['IsErrorHandler'] == true
            err_map[from] = to
          else
            fwd_map[from] ||= []
            fwd_map[from] << { to: to, case_val: case_val }
          end
        end
        start = objects.find { |o| o['$Type'] == 'Microflows$StartEvent' }
        if nested && !start
          destinations = flows.to_h { [_1['DestinationPointer'], true] }
          start = objects.find { !destinations.key?(_1['$ID']) }
        end
        return [] unless start

        endpoint_refs ||= annotation_flow_endpoint_refs(objects, flows)
        emitted_refs ||= {}
        lines = annotation_dsl_lines(objects, indent, endpoint_refs, emitted_refs)
        linearize_flow(
          start['$ID'], fwd_map, err_map, by_id, flows, {}, lines, indent, nil,
          endpoint_refs, emitted_refs
        )
        if !nested && (endpoint_refs.values - emitted_refs.keys).any?
          raise SerializationError, 'annotation flow references a node outside the exported graph'
        end

        lines.concat(annotation_flow_dsl_lines(flows, endpoint_refs, indent)) unless nested
        lines
      end

      def annotation_dsl_lines(objects, indent, endpoint_refs = {}, emitted_refs = {})
        pad = ' ' * indent
        objects.flat_map do |object|
          next [] unless object['$Type'] == 'Microflows$Annotation'

          declaration = "#{pad}annotation #{ruby(object['Caption'].to_s)}, " \
            "position: #{ruby(object['RelativeMiddlePoint'].to_s)}, " \
            "size: #{ruby(object['Size'].to_s)}"
          reference = endpoint_refs[object['$ID']]
          emitted_refs[reference] = true if reference
          [declaration, ("#{pad}as_node #{ruby(reference)}" if reference)].compact
        end
      end

      def annotation_flow_endpoint_refs(objects, flows)
        annotation_flows = Array(flows).select { _1['$Type'] == 'Microflows$AnnotationFlow' }
        return {} if annotation_flows.empty?

        all_objects = nested_flow_objects(objects)
        by_id = all_objects.to_h { [_1['$ID'], _1] }
        counters = Hash.new(0)
        references = all_objects.to_h do |object|
          prefix = {
            'Microflows$Annotation' => 'annotation',
            'Microflows$ActionActivity' => 'activity',
            'Microflows$ExclusiveSplit' => 'decision',
            'Microflows$InheritanceSplit' => 'type_decision',
            'Microflows$LoopedActivity' => 'loop',
            'Microflows$EndEvent' => 'return',
            'Microflows$ErrorEvent' => 'error',
            'Microflows$ContinueEvent' => 'continue',
            'Microflows$BreakEvent' => 'break'
          }[object['$Type']]
          next [object['$ID'], nil] unless prefix

          counters[prefix] += 1
          [object['$ID'], "#{prefix}_#{counters[prefix]}"]
        end
        endpoint_ids = annotation_flows.flat_map do |flow|
          [flow['OriginPointer'], flow['DestinationPointer']]
        end.uniq
        endpoint_ids.to_h do |id|
          object = by_id[id]
          raise SerializationError, 'annotation flow references a missing object' unless object

          reference = references[id]
          unless reference
            raise SerializationError,
                  "unsupported annotation flow endpoint #{object['$Type']}"
          end
          [id, reference]
        end
      end

      def nested_flow_objects(objects)
        Array(objects).flat_map do |object|
          nested = bson_items(object.dig('ObjectCollection', 'Objects'))
          [object, *nested_flow_objects(nested)]
        end
      end

      def annotation_flow_dsl_lines(flows, endpoint_refs, indent)
        pad = ' ' * indent
        Array(flows).filter_map do |flow|
          next unless flow['$Type'] == 'Microflows$AnnotationFlow'

          from = endpoint_refs.fetch(flow['OriginPointer'])
          to = endpoint_refs.fetch(flow['DestinationPointer'])
          line = flow['Line'] || {}
          origin_vector = line['OriginControlVector'] || flow['OriginBezierVector'] || '0;0'
          destination_vector = line['DestinationControlVector'] ||
                               flow['DestinationBezierVector'] || '0;-30'
          "#{pad}annotation_flow from: #{ruby(from)}, to: #{ruby(to)}, " \
            "origin_index: #{flow.fetch('OriginConnectionIndex', 1)}, " \
            "destination_index: #{flow.fetch('DestinationConnectionIndex', 0)}, " \
            "origin_vector: #{ruby(origin_vector)}, " \
            "destination_vector: #{ruby(destination_vector)}"
        end
      end

      def flow_objects_contain_annotation?(objects)
        Array(objects).any? do |object|
          object['$Type'] == 'Microflows$Annotation' ||
            flow_objects_contain_annotation?(
              bson_items(object.dig('ObjectCollection', 'Objects'))
            )
        end
      end

      def decision_declaration_lines(condition, indent)
        pad = ' ' * indent
        return ["#{pad}decision #{ruby(condition['Expression'].to_s)} do"] \
          unless condition['$Type'] == 'Microflows$RuleSplitCondition'

        rule = condition['RuleCall'] || {}
        lines = ["#{pad}rule_decision #{ruby(rule['Microflow'])} do"]
        bson_items(rule['ParameterMappings']).each do |mapping|
          lines << "#{pad}  argument #{ruby(mapping['Parameter'])}, #{ruby(mapping['Argument'])}"
        end
        lines
      end

      def flow_case_value(flow)
        case_doc = bson_items(flow['CaseValues']).first || flow['NewCaseValue']
        value = case_doc&.dig('Value')
        return true if value == 'true'
        return false if value == 'false'

        value
      end

      # "Custom with rollback" keeps its rollback through the round trip.
      def rescue_header(activity)
        activity.dig('Action', 'ErrorHandlingType') == 'Custom' ? 'rescue_all(rollback: true) do' : 'rescue_all do'
      end

      def linearize_flow(cursor, fwd, err, by_id, graph_flows, seen, lines, indent, stop_at,
                         endpoint_refs = {}, emitted_refs = {})
        while cursor && cursor != stop_at
          break if seen[cursor]

          seen[cursor] = true
          obj = by_id[cursor]
          break unless obj

          case obj['$Type']
          when 'Microflows$StartEvent'
            cursor = (fwd[cursor] || []).first&.dig(:to)

          when 'Microflows$ActionActivity'
            line = action_dsl_line(obj, indent)
            lines << line if line
            append_flow_node_reference(lines, obj, indent, endpoint_refs, emitted_refs) if line
            next_id  = (fwd[cursor] || []).first&.dig(:to)
            error_to = err[cursor]
            if error_to
              rescue_lines = []
              linearize_flow(
                error_to, fwd, err, by_id, graph_flows,
                seen.dup, rescue_lines, indent + 2, nil, endpoint_refs, emitted_refs
              )
              lines << "#{' ' * indent}#{rescue_header(obj)}"
              lines.concat(rescue_lines)
              lines << "#{' ' * indent}end"
            end
            cursor = next_id

          when 'Microflows$ExclusiveSplit'
            condition_doc = obj['SplitCondition'] || {}
            nexts = fwd[cursor] || []
            merge_id = find_common_merge_node(nexts.map { _1[:to] }, fwd, by_id)
            lines.concat(decision_declaration_lines(condition_doc, indent))
            nexts.each do |edge|
              branch_lines = []
              linearize_flow(
                edge[:to], fwd, err, by_id, graph_flows, seen.dup,
                branch_lines, indent + 4, merge_id, endpoint_refs, emitted_refs
              )
              lines << "#{' ' * (indent + 2)}on(#{ruby(edge[:case_val])}) do"
              lines.concat(branch_lines)
              lines << "#{' ' * (indent + 2)}end"
            end
            lines << "#{' ' * indent}end"
            append_flow_node_reference(lines, obj, indent, endpoint_refs, emitted_refs)
            cursor = merge_id

          when 'Microflows$ExclusiveMerge'
            cursor = (fwd[cursor] || []).first&.dig(:to)

          when 'Microflows$InheritanceSplit'
            nexts = fwd[cursor] || []
            merge_id = find_common_merge_node(nexts.map { _1[:to] }, fwd, by_id)
            lines << "#{' ' * indent}type_decision :#{obj['SplitVariableName']} do"
            nexts.each do |edge|
              branch_lines = []
              linearize_flow(
                edge[:to], fwd, err, by_id, graph_flows, seen.dup,
                branch_lines, indent + 4, merge_id, endpoint_refs, emitted_refs
              )
              if edge[:case_val].to_s.empty?
                lines << "#{' ' * (indent + 2)}otherwise do"
              else
                lines << "#{' ' * (indent + 2)}on_type #{ruby(edge[:case_val])} do"
              end
              lines.concat(branch_lines)
              lines << "#{' ' * (indent + 2)}end"
            end
            lines << "#{' ' * indent}end"
            append_flow_node_reference(lines, obj, indent, endpoint_refs, emitted_refs)
            cursor = merge_id

          when 'Microflows$LoopedActivity'
            loop_src = loop_source(obj)
            variable  = (loop_src['ListVariableName'] || loop_src['Variable']).to_s
            iterator  = (loop_src['VariableName'] || loop_src['IteratorVariable']).to_s
            inner_col = obj['ObjectCollection'] || {}
            inner_objects = bson_items(inner_col['Objects'])
            inner_lines = body_dsl_lines(
              inner_objects,
              graph_flows,
              indent + 2,
              nested: true,
              endpoint_refs: endpoint_refs,
              emitted_refs: emitted_refs
            )
            if loop_src['$Type'] == 'Microflows$WhileLoopCondition'
              lines << "#{' ' * indent}while_loop #{ruby(loop_src['WhileExpression'])} do"
            else
              as_clause = iterator != variable && !iterator.empty? ? ", as: :#{iterator}" : ''
              lines << "#{' ' * indent}loop_over :#{variable}#{as_clause} do"
            end
            lines.concat(inner_lines)
            lines << "#{' ' * indent}end"
            append_flow_node_reference(lines, obj, indent, endpoint_refs, emitted_refs)
            cursor = (fwd[cursor] || []).first&.dig(:to)

          when 'Microflows$EndEvent'
            ret = obj['ReturnValue'].to_s.strip
            if ret.empty?
              lines << "#{' ' * indent}end_flow" if indent > 2
            elsif (match = ret.match(/\A\$([A-Za-z_][A-Za-z0-9_]*)\z/))
              lines << "#{' ' * indent}return_value :#{match[1]}"
            else
              lines << "#{' ' * indent}return_value #{ruby(ret)}"
            end
            if indent == 2 && (reference = endpoint_refs[obj['$ID']])
              emitted_refs[reference] = true
              lines << "#{' ' * indent}return_node #{ruby(reference)}"
            else
              append_flow_node_reference(lines, obj, indent, endpoint_refs, emitted_refs)
            end
            break

          when 'Microflows$ErrorEvent'
            lines << "#{' ' * indent}error_event"
            append_flow_node_reference(lines, obj, indent, endpoint_refs, emitted_refs)
            break

          when 'Microflows$ContinueEvent'
            lines << "#{' ' * indent}continue_loop"
            append_flow_node_reference(lines, obj, indent, endpoint_refs, emitted_refs)
            break

          when 'Microflows$BreakEvent'
            lines << "#{' ' * indent}break_loop"
            append_flow_node_reference(lines, obj, indent, endpoint_refs, emitted_refs)
            break

          else
            cursor = (fwd[cursor] || []).first&.dig(:to)
          end
        end
      end

      def append_flow_node_reference(lines, object, indent, endpoint_refs, emitted_refs)
        reference = endpoint_refs[object['$ID']]
        return unless reference && !emitted_refs[reference]

        emitted_refs[reference] = true
        lines << "#{' ' * indent}as_node #{ruby(reference)}"
      end

      def flows_for_objects(flows, objects)
        ids = objects.to_h { [_1['$ID'], true] }
        flows.select do |flow|
          ids.key?(flow['OriginPointer']) && ids.key?(flow['DestinationPointer'])
        end
      end

      def loop_source(object)
        object['LoopSource'] || object['LoopObject'] || begin
          if object['ListVariableName'] || object['IteratorVariableName']
            {
              '$Type' => 'Microflows$IterableList',
              'ListVariableName' => object['ListVariableName'],
              'VariableName' => object['IteratorVariableName']
            }
          else
            {}
          end
        end
      end

      def find_merge_node(true_start, false_start, fwd, by_id)
        t = reachable_merge_ids(true_start,  fwd, by_id)
        f = reachable_merge_ids(false_start, fwd, by_id)
        (t & f).first
      end

      def find_common_merge_node(starts, fwd, by_id)
        sets = starts.compact.map { reachable_merge_ids(_1, fwd, by_id) }
        return nil if sets.empty?

        sets.reduce { |common, ids| common & ids }.first
      end

      def reachable_merge_ids(start_id, fwd, by_id)
        result  = []
        visited = {}
        queue   = [start_id].compact
        while (id = queue.shift)
          next if visited[id]

          visited[id] = true
          obj = by_id[id]
          next unless obj

          result << id if obj['$Type'] == 'Microflows$ExclusiveMerge'
          (fwd[id] || []).each { |e| queue << e[:to] }
        end
        result
      end
    end
  end
end
