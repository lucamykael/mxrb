# frozen_string_literal: true

module Mxrb
  class Exporter
    # Recognizes the certified workflow subset and declares it as Ruby.
    module WorkflowDeclarations
      WORKFLOW_FIELDS = %w[
        $ID $Type AdminPage Annotation DueDate EventSubProcesses Flow Name OnWorkflowEvent
        Parameter PersistentId Title WorkflowDescription WorkflowMetaData WorkflowName WorkflowV2
      ].freeze

      WORKFLOW_PARAMETER_FIELDS = %w[$ID $Type Entity Name].freeze

      WORKFLOW_FLOW_FIELDS = %w[$ID $Type Activities].freeze

      WORKFLOW_PARAMETER_MAPPING_FIELDS = %w[$ID $Type Expression Parameter].freeze

      WORKFLOW_PAGE_REFERENCE_FIELDS = %w[$ID $Type Page].freeze

      WORKFLOW_XPATH_TARGETING_FIELDS = %w[$ID $Type XPathConstraint].freeze

      WORKFLOW_MICROFLOW_TARGETING_FIELDS = %w[$ID $Type Microflow].freeze

      WORKFLOW_NO_TARGETING_FIELDS = %w[$ID $Type].freeze

      WORKFLOW_OUTCOME_FIELDS = %w[$ID $Type Flow PersistentId Value].freeze

      WORKFLOW_CONDITION_OUTCOME_FIELDS = %w[$ID $Type Flow PersistentId Value].freeze

      WORKFLOW_NO_EVENT_FIELDS = %w[$ID $Type].freeze

      WORKFLOW_MICROFLOW_EVENT_FIELDS = %w[$ID $Type Microflow].freeze

      WORKFLOW_BOUNDARY_FIELDS = %w[
        $ID $Type Annotation Caption FirstExecutionTime Flow PersistentId Recurrence
      ].freeze

      WORKFLOW_RECURRENCE_FIELDS = %w[$ID $Type Interval IntervalType MaxExecutions].freeze

      WORKFLOW_TEMPLATE_FIELDS = %w[$ID $Type Arguments Text].freeze

      WORKFLOW_METADATA_FIELDS = %w[$ID $Type Annotation DetachedActivities FlowLines].freeze

      WORKFLOW_TARGET_INPUT_FIELDS = %w[$ID $Type Amount Percentage].freeze

      WORKFLOW_COMPLETION_FIELDS = %w[
        $ID $Type CompletionType FallbackOutcomePointer Microflow Threshold VetoOutcomePointer
      ].freeze

      WORKFLOW_EVENT_HANDLER_FIELDS = %w[
        $ID $Type Description Documentation EventTypes MicroflowEventHandler
      ].freeze

      WORKFLOW_EVENT_SUB_PROCESS_FIELDS = %w[
        $ID $Type Annotation Caption Flow Name PersistentId
      ].freeze

      private

      def semantic_workflow?(doc)
        return false unless (doc.keys - WORKFLOW_FIELDS).empty?
        return false unless doc['PersistentId'].is_a?(BSON::Binary)
        return false unless doc['Title'].is_a?(String) && doc['DueDate'].is_a?(String)
        return false unless doc['AdminPage'].nil? && doc['Annotation'].nil? && doc['WorkflowV2'] == false
        return false unless semantic_workflow_parameter?(doc['Parameter'])
        return false unless semantic_workflow_template?(doc['WorkflowName'])
        return false unless semantic_workflow_template?(doc['WorkflowDescription'])
        return false unless semantic_workflow_flow?(doc['Flow'])
        return false unless semantic_workflow_metadata?(doc['WorkflowMetaData'])

        bson_items(doc['OnWorkflowEvent']).all? { semantic_workflow_event_handler?(_1) } &&
          bson_items(doc['EventSubProcesses']).all? { semantic_workflow_event_sub_process?(_1) }
      end

      def semantic_workflow_parameter?(parameter)
        parameter.is_a?(Hash) && parameter['$Type'] == 'Workflows$Parameter' &&
          (parameter.keys - WORKFLOW_PARAMETER_FIELDS).empty? &&
          parameter['Entity'].is_a?(String) && parameter['Name'].is_a?(String)
      end

      def semantic_workflow_template?(template)
        template.is_a?(Hash) && template['$Type'] == 'Microflows$StringTemplate' &&
          (template.keys - WORKFLOW_TEMPLATE_FIELDS).empty? &&
          template['Text'].is_a?(String) && bson_marker(template['Arguments'], 2) == 2 &&
          bson_items(template['Arguments']).empty?
      end

      def semantic_workflow_flow?(flow)
        return false unless flow.is_a?(Hash) && flow['$Type'] == 'Workflows$Flow'
        return false unless (flow.keys - WORKFLOW_FLOW_FIELDS).empty?

        activities = bson_items(flow['Activities'])
        activities.size >= 2 &&
          semantic_workflow_terminal?(activities.first, 'Workflows$StartWorkflowActivity') &&
          semantic_workflow_terminal?(activities.last, 'Workflows$EndWorkflowActivity') &&
          activities[1...-1].all? { semantic_workflow_activity?(_1) }
      end

      def semantic_workflow_activity?(activity)
        case activity&.fetch('$Type', nil)
        when 'Workflows$SingleUserTaskActivity' then semantic_workflow_user_task?(activity)
        when 'Workflows$MultiUserTaskActivity' then semantic_workflow_multi_user_task?(activity)
        when 'Workflows$WaitForTimerActivity' then semantic_workflow_wait_timer?(activity)
        when 'Workflows$CallMicroflowActivity' then semantic_workflow_call_microflow?(activity)
        when 'Workflows$CallWorkflowActivity' then semantic_workflow_call_workflow?(activity)
        else false
        end
      end

      def semantic_workflow_wait_timer?(activity)
        (activity.keys - WORKFLOW_WAIT_TIMER_FIELDS).empty? &&
          semantic_workflow_activity_base?(activity) && activity['Delay'].is_a?(String)
      end

      def semantic_workflow_terminal?(activity, type)
        activity.is_a?(Hash) && activity['$Type'] == type &&
          (activity.keys - WORKFLOW_ACTIVITY_FIELDS).empty? &&
          activity['PersistentId'].is_a?(BSON::Binary) && activity['Annotation'].nil? &&
          activity['RelativeMiddlePoint'].is_a?(String) && activity['Size'].is_a?(String) &&
          activity['Name'].is_a?(String) && activity['Caption'].is_a?(String)
      end

      def semantic_workflow_user_task?(activity)
        return false unless activity.is_a?(Hash) &&
                            activity['$Type'] == 'Workflows$SingleUserTaskActivity'
        return false unless (activity.keys - WORKFLOW_USER_TASK_FIELDS).empty?
        return false unless semantic_workflow_activity_base?(activity)
        return false unless activity['DueDate'].is_a?(String)
        return false unless semantic_workflow_page_reference?(activity['TaskPage'])
        return false unless semantic_workflow_template?(activity['TaskName'])
        return false unless semantic_workflow_template?(activity['TaskDescription'])
        return false unless semantic_workflow_targeting?(activity['UserTargeting'])
        return false unless bson_items(activity['BoundaryEvents']).all? do
          semantic_workflow_boundary_event?(_1)
        end
        return false unless semantic_workflow_user_task_event?(activity['OnCreatedEvent'])
        return false unless [true, false].include?(activity['AutoAssignSingleTargetUser'])

        outcomes = bson_items(activity['Outcomes'])
        !outcomes.empty? && outcomes.all? { semantic_workflow_outcome?(_1) } &&
          outcomes.map { _1['Value'] }.uniq.size == outcomes.size
      end

      def semantic_workflow_multi_user_task?(activity)
        return false unless activity.is_a?(Hash) &&
                            activity['$Type'] == 'Workflows$MultiUserTaskActivity'
        return false unless (activity.keys - WORKFLOW_MULTI_USER_TASK_FIELDS).empty?

        single = activity.merge('$Type' => 'Workflows$SingleUserTaskActivity')
                         .reject { |key| %w[AwaitAllUsers CompletionCriteria TargetUserInput].include?(key) }
        semantic_workflow_user_task?(single) &&
          semantic_workflow_target_user_input?(activity['TargetUserInput']) &&
          semantic_workflow_completion_criteria?(activity['CompletionCriteria']) &&
          [true, false].include?(activity['AwaitAllUsers'])
      end

      def semantic_workflow_target_user_input?(input)
        return false unless input.is_a?(Hash) && (input.keys - WORKFLOW_TARGET_INPUT_FIELDS).empty?

        case input['$Type']
        when 'Workflows$AllUserInput' then (input.keys - %w[$ID $Type]).empty?
        when 'Workflows$AbsoluteAmountUserInput' then input['Amount'].is_a?(Integer)
        when 'Workflows$PercentageAmountUserInput'
          input['Percentage'].is_a?(Integer) && (1..100).cover?(input['Percentage'])
        else false
        end
      end

      def semantic_workflow_completion_criteria?(criteria)
        return false unless criteria.is_a?(Hash) &&
                            (criteria.keys - WORKFLOW_COMPLETION_FIELDS).empty?

        case criteria['$Type']
        when 'Workflows$ConsensusCompletionCriteria'
          criteria['FallbackOutcomePointer'].is_a?(BSON::Binary)
        when 'Workflows$MajorityCompletionCriteria'
          criteria['CompletionType'].is_a?(String) &&
            (criteria['FallbackOutcomePointer'].nil? ||
              criteria['FallbackOutcomePointer'].is_a?(BSON::Binary))
        when 'Workflows$MicroflowCompletionCriteria'
          criteria['Microflow'].is_a?(String) && !criteria['Microflow'].empty?
        when 'Workflows$ThresholdCompletionCriteria'
          criteria['CompletionType'].is_a?(String) && criteria['Threshold'].is_a?(Integer) &&
            criteria['FallbackOutcomePointer'].is_a?(BSON::Binary)
        when 'Workflows$VetoCompletionCriteria'
          criteria['VetoOutcomePointer'].nil? || criteria['VetoOutcomePointer'].is_a?(BSON::Binary)
        else false
        end
      end

      def semantic_workflow_call_microflow?(activity)
        activity.is_a?(Hash) && activity['$Type'] == 'Workflows$CallMicroflowActivity' &&
          (activity.keys - WORKFLOW_CALL_MICROFLOW_FIELDS).empty? &&
          semantic_workflow_activity_base?(activity) && activity['Microflow'].is_a?(String) &&
          !activity['Microflow'].empty? &&
          !bson_items(activity['Outcomes']).empty? &&
          bson_items(activity['Outcomes']).all? { semantic_workflow_condition_outcome?(_1) } &&
          semantic_workflow_parameter_mappings?(activity['ParameterMappings'], :microflow) &&
          bson_items(activity['BoundaryEvents']).all? { semantic_workflow_boundary_event?(_1) }
      end

      def semantic_workflow_condition_outcome?(outcome)
        return false unless outcome.is_a?(Hash) &&
                            (outcome.keys - WORKFLOW_CONDITION_OUTCOME_FIELDS).empty?
        return false unless outcome['PersistentId'].is_a?(BSON::Binary)
        return false unless %w[
          Workflows$VoidConditionOutcome Workflows$BooleanConditionOutcome
          Workflows$EnumerationValueConditionOutcome
        ].include?(outcome['$Type'])
        return false if outcome['$Type'] == 'Workflows$BooleanConditionOutcome' &&
                        ![true, false].include?(outcome['Value'])
        return false if outcome['$Type'] == 'Workflows$EnumerationValueConditionOutcome' &&
                        !outcome['Value'].is_a?(String)

        flow = outcome['Flow']
        flow.is_a?(Hash) && flow['$Type'] == 'Workflows$Flow' &&
          (flow.keys - WORKFLOW_FLOW_FIELDS).empty? && bson_items(flow['Activities']).empty?
      end

      def semantic_workflow_call_workflow?(activity)
        activity.is_a?(Hash) && activity['$Type'] == 'Workflows$CallWorkflowActivity' &&
          (activity.keys - WORKFLOW_CALL_WORKFLOW_FIELDS).empty? &&
          semantic_workflow_activity_base?(activity) && activity['Workflow'].is_a?(String) &&
          !activity['Workflow'].empty? && [true, false].include?(activity['ExecuteAsync']) &&
          semantic_workflow_parameter_mappings?(activity['ParameterMappings'], :workflow) &&
          bson_items(activity['BoundaryEvents']).all? { semantic_workflow_boundary_event?(_1) }
      end

      def semantic_workflow_parameter_mappings?(value, kind)
        type = if kind == :microflow
                 'Workflows$MicroflowCallParameterMapping'
               else
                 'Workflows$WorkflowCallParameterMapping'
               end
        bson_items(value).all? do |mapping|
          mapping.is_a?(Hash) && mapping['$Type'] == type &&
            (mapping.keys - WORKFLOW_PARAMETER_MAPPING_FIELDS).empty? &&
            mapping['Parameter'].is_a?(String) && mapping['Expression'].is_a?(String)
        end
      end

      def semantic_workflow_activity_base?(activity)
        activity['PersistentId'].is_a?(BSON::Binary) && activity['Annotation'].nil? &&
          activity['RelativeMiddlePoint'].is_a?(String) && activity['Size'].is_a?(String) &&
          activity['Name'].is_a?(String) && activity['Caption'].is_a?(String)
      end

      def semantic_workflow_page_reference?(reference)
        reference.is_a?(Hash) && reference['$Type'] == 'Workflows$PageReference' &&
          (reference.keys - WORKFLOW_PAGE_REFERENCE_FIELDS).empty? && reference['Page'].is_a?(String)
      end

      def semantic_workflow_targeting?(targeting)
        return false unless targeting.is_a?(Hash)

        case targeting['$Type']
        when 'Workflows$XPathUserTargeting', 'Workflows$XPathGroupTargeting'
          (targeting.keys - WORKFLOW_XPATH_TARGETING_FIELDS).empty? &&
            targeting['XPathConstraint'].is_a?(String)
        when 'Workflows$MicroflowUserTargeting', 'Workflows$MicroflowGroupTargeting'
          (targeting.keys - WORKFLOW_MICROFLOW_TARGETING_FIELDS).empty? &&
            targeting['Microflow'].is_a?(String) && !targeting['Microflow'].empty?
        when 'Workflows$NoUserTargeting'
          (targeting.keys - WORKFLOW_NO_TARGETING_FIELDS).empty?
        else false
        end
      end

      def semantic_workflow_user_task_event?(event)
        return false unless event.is_a?(Hash)

        case event['$Type']
        when 'Workflows$NoEvent'
          (event.keys - WORKFLOW_NO_EVENT_FIELDS).empty?
        when 'Workflows$MicroflowBasedEvent'
          (event.keys - WORKFLOW_MICROFLOW_EVENT_FIELDS).empty? &&
            event['Microflow'].is_a?(String) && !event['Microflow'].empty?
        else false
        end
      end

      def semantic_workflow_boundary_event?(event)
        return false unless event.is_a?(Hash)
        return false unless %w[
          Workflows$InterruptingTimerBoundaryEvent Workflows$NonInterruptingTimerBoundaryEvent
        ].include?(event['$Type'])
        return false unless (event.keys - WORKFLOW_BOUNDARY_FIELDS).empty?
        return false unless event['PersistentId'].is_a?(BSON::Binary) && event['Annotation'].nil?
        return false unless event['Caption'].is_a?(String) && event['FirstExecutionTime'].is_a?(String)
        return false unless semantic_workflow_boundary_flow?(event['Flow'], event['$Type'])

        recurrence = event['Recurrence']
        if event['$Type'] == 'Workflows$InterruptingTimerBoundaryEvent'
          !event.key?('Recurrence')
        else
          semantic_workflow_recurrence?(recurrence)
        end
      end

      def semantic_workflow_boundary_flow?(flow, event_type)
        return false unless flow.is_a?(Hash) && flow['$Type'] == 'Workflows$Flow'
        return false unless (flow.keys - WORKFLOW_FLOW_FIELDS).empty?

        activities = bson_items(flow['Activities'])
        ending_type = if event_type == 'Workflows$InterruptingTimerBoundaryEvent'
                        'Workflows$EndWorkflowActivity'
                      else
                        'Workflows$EndOfBoundaryEventPathActivity'
                      end
        activities.one? && semantic_workflow_terminal?(activities.first, ending_type)
      end

      def semantic_workflow_recurrence?(recurrence)
        return true if recurrence.nil?

        recurrence.is_a?(Hash) && recurrence['$Type'] == 'Workflows$LinearRecurrence' &&
          (recurrence.keys - WORKFLOW_RECURRENCE_FIELDS).empty? &&
          recurrence['IntervalType'].is_a?(String) && recurrence['Interval'].is_a?(Integer) &&
          recurrence['MaxExecutions'].is_a?(Integer)
      end

      def semantic_workflow_outcome?(outcome)
        return false unless outcome.is_a?(Hash) && outcome['$Type'] == 'Workflows$UserTaskOutcome'
        return false unless (outcome.keys - WORKFLOW_OUTCOME_FIELDS).empty?
        return false unless outcome['PersistentId'].is_a?(BSON::Binary) &&
                            outcome['Value'].is_a?(String) && !outcome['Value'].empty?

        flow = outcome['Flow']
        flow.is_a?(Hash) && flow['$Type'] == 'Workflows$Flow' &&
          (flow.keys - WORKFLOW_FLOW_FIELDS).empty? && bson_items(flow['Activities']).empty?
      end

      def semantic_workflow_metadata?(metadata)
        metadata.is_a?(Hash) && metadata['$Type'] == 'Workflows$WorkflowMetaData' &&
          (metadata.keys - WORKFLOW_METADATA_FIELDS).empty? &&
          bson_items(metadata['DetachedActivities']).empty? &&
          bson_items(metadata['FlowLines']).empty? && bson_items(metadata['Annotation']).empty?
      end

      def semantic_workflow_event_handler?(event)
        return false unless event.is_a?(Hash) && event['$Type'] == 'Workflows$WorkflowEventHandler'
        return false unless (event.keys - WORKFLOW_EVENT_HANDLER_FIELDS).empty?
        return false unless event['Description'].is_a?(String) && !event['Description'].empty?
        return false unless event['Documentation'].is_a?(String)
        return false unless bson_items(event['EventTypes']).all? { _1.is_a?(String) }

        handler = event['MicroflowEventHandler']
        handler.nil? || semantic_workflow_microflow_handler?(handler)
      end

      def semantic_workflow_microflow_handler?(handler)
        handler.is_a?(Hash) && handler['$Type'] == 'Workflows$MicroflowEventHandler' &&
          (handler.keys - WORKFLOW_MICROFLOW_EVENT_FIELDS).empty? &&
          handler['Microflow'].is_a?(String) && !handler['Microflow'].empty?
      end

      def semantic_workflow_event_sub_process?(process)
        return false unless process.is_a?(Hash) && process['$Type'] == 'Workflows$EventSubProcess'
        return false unless (process.keys - WORKFLOW_EVENT_SUB_PROCESS_FIELDS).empty?
        return false unless process['PersistentId'].is_a?(BSON::Binary) && process['Annotation'].nil?
        return false unless process['Name'].is_a?(String) && process['Caption'].is_a?(String)

        semantic_workflow_event_sub_process_flow?(process['Flow'])
      end

      def semantic_workflow_event_sub_process_flow?(flow)
        return false unless flow.is_a?(Hash) && flow['$Type'] == 'Workflows$Flow'
        return false unless (flow.keys - WORKFLOW_FLOW_FIELDS).empty?

        activities = bson_items(flow['Activities'])
        return false if activities.size < 2

        interrupting = activities.first['$Type'] ==
                       'Workflows$InterruptingNotificationEventSubProcessStartActivity'
        non_interrupting = activities.first['$Type'] ==
                           'Workflows$NonInterruptingNotificationEventSubProcessStartActivity'
        return false unless interrupting || non_interrupting
        return false unless semantic_workflow_terminal?(activities.first, activities.first['$Type'])

        semantic_workflow_terminal?(activities.last, 'Workflows$EndWorkflowActivity') &&
          activities[1...-1].all? { semantic_workflow_activity?(_1) }
      end

      def workflow_declaration(document)
        doc = document.fetch(:doc)
        flow = doc.fetch('Flow')
        activities = bson_items(flow.fetch('Activities'))
        start = activities.first
        finish = activities.last
        metadata = doc.fetch('WorkflowMetaData')
        body = activities[1...-1]
        activity_options = if body.all? { _1['$Type'] == 'Workflows$SingleUserTaskActivity' }
                             { user_tasks: body.map { workflow_user_task_spec(_1) } }
                           else
                             { activities: body.map { workflow_activity_spec(_1) } }
                           end
        semantic_call_source(:workflow, document, {
          context_entity: doc.fetch('Parameter').fetch('Entity', ''),
          title: doc.fetch('Title', ''), workflow_name: doc.fetch('WorkflowName').fetch('Text', ''),
          workflow_description: doc.fetch('WorkflowDescription').fetch('Text', ''),
          due_date: doc.fetch('DueDate', ''), parameter_name: doc.fetch('Parameter').fetch('Name', ''),
          start: workflow_terminal_spec(start), finish: workflow_terminal_spec(finish),
          persistent_id: document_id_value(doc.fetch('PersistentId')),
          parameter_id: document_id(doc.fetch('Parameter')), flow_id: document_id(flow),
          workflow_name_id: document_id(doc.fetch('WorkflowName')),
          workflow_description_id: document_id(doc.fetch('WorkflowDescription')),
          metadata_id: document_id(metadata), activities_marker: bson_marker(flow['Activities'], 2),
          on_workflow_events: bson_items(doc['OnWorkflowEvent']).map { workflow_event_handler_spec(_1) },
          event_sub_processes: bson_items(doc['EventSubProcesses']).map do |process|
            workflow_event_sub_process_spec(process)
          end,
          on_workflow_event_marker: bson_marker(doc['OnWorkflowEvent'], 2),
          event_sub_processes_marker: bson_marker(doc['EventSubProcesses'], 2),
          detached_activities_marker: bson_marker(metadata['DetachedActivities'], 2),
          flow_lines_marker: bson_marker(metadata['FlowLines'], 2),
          annotations_marker: bson_marker(metadata['Annotation'], 2)
        }.merge(activity_options))
      end

      def workflow_terminal_spec(activity)
        {
          id: document_id(activity), persistent_id: document_id_value(activity.fetch('PersistentId')),
          name: activity.fetch('Name', ''), caption: activity.fetch('Caption', ''),
          position: activity.fetch('RelativeMiddlePoint', ''), size: activity.fetch('Size', '')
        }
      end

      def workflow_user_task_spec(activity)
        spec = {
          type: if activity['$Type'] == 'Workflows$MultiUserTaskActivity'
                  :multi_user_task
                else
                  :user_task
                end,
          id: document_id(activity),
          persistent_id: document_id_value(activity.fetch('PersistentId')),
          name: activity.fetch('Name', ''), caption: activity.fetch('Caption', ''),
          position: activity.fetch('RelativeMiddlePoint', ''), size: activity.fetch('Size', ''),
          task_page: activity.fetch('TaskPage').fetch('Page', ''),
          task_page_id: document_id(activity.fetch('TaskPage')),
          task_name: activity.fetch('TaskName').fetch('Text', ''),
          task_name_id: document_id(activity.fetch('TaskName')),
          task_description: activity.fetch('TaskDescription').fetch('Text', ''),
          task_description_id: document_id(activity.fetch('TaskDescription')),
          due_date: activity.fetch('DueDate', ''),
          targeting: workflow_targeting_spec(activity.fetch('UserTargeting')),
          outcomes: bson_items(activity['Outcomes']).map { workflow_outcome_spec(_1) },
          outcomes_marker: bson_marker(activity['Outcomes'], 2),
          boundary_events_marker: bson_marker(activity['BoundaryEvents'], 2),
          boundary_events: bson_items(activity['BoundaryEvents']).map { workflow_boundary_spec(_1) },
          on_created_event_id: document_id(activity.fetch('OnCreatedEvent')),
          auto_assign: activity['AutoAssignSingleTargetUser'] == true
        }
        event = activity.fetch('OnCreatedEvent')
        if event['$Type'] == 'Workflows$MicroflowBasedEvent'
          spec[:on_created] = {
            id: document_id(event), microflow: event.fetch('Microflow', '')
          }
        end
        if activity['$Type'] == 'Workflows$MultiUserTaskActivity'
          spec[:target_user_input] = workflow_target_user_input_spec(activity.fetch('TargetUserInput'))
          spec[:completion_criteria] = workflow_completion_criteria_spec(
            activity.fetch('CompletionCriteria')
          )
          spec[:await_all_users] = activity['AwaitAllUsers'] == true
        end
        spec
      end

      def workflow_activity_spec(activity)
        case activity['$Type']
        when 'Workflows$SingleUserTaskActivity', 'Workflows$MultiUserTaskActivity'
          workflow_user_task_spec(activity)
        when 'Workflows$CallMicroflowActivity'
          workflow_call_activity_spec(activity, :microflow)
        when 'Workflows$CallWorkflowActivity'
          workflow_call_activity_spec(activity, :workflow)
        else
          workflow_terminal_spec(activity).merge(type: :wait_timer, delay: activity.fetch('Delay', ''))
        end
      end

      def workflow_target_user_input_spec(input)
        base = { id: document_id(input) }
        case input['$Type']
        when 'Workflows$AbsoluteAmountUserInput'
          base.merge(type: :absolute, amount: input.fetch('Amount', 2))
        when 'Workflows$PercentageAmountUserInput'
          base.merge(type: :percentage, percentage: input.fetch('Percentage', 100))
        else base.merge(type: :all)
        end
      end

      def workflow_completion_criteria_spec(criteria)
        base = { id: document_id(criteria) }
        case criteria['$Type']
        when 'Workflows$MajorityCompletionCriteria'
          base.merge(
            type: :majority, completion_type: criteria.fetch('CompletionType', ''),
            fallback_outcome: workflow_outcome_reference_spec(criteria['FallbackOutcomePointer'])
          )
        when 'Workflows$MicroflowCompletionCriteria'
          base.merge(type: :microflow, microflow: criteria.fetch('Microflow', ''))
        when 'Workflows$ThresholdCompletionCriteria'
          base.merge(
            type: :threshold, completion_type: criteria.fetch('CompletionType', ''),
            threshold: criteria.fetch('Threshold', 50),
            fallback_outcome: workflow_outcome_reference_spec(criteria['FallbackOutcomePointer'])
          )
        when 'Workflows$VetoCompletionCriteria'
          base.merge(
            type: :veto,
            veto_outcome: workflow_outcome_reference_spec(criteria['VetoOutcomePointer'])
          )
        else
          base.merge(
            type: :consensus,
            fallback_outcome: workflow_outcome_reference_spec(criteria['FallbackOutcomePointer'])
          )
        end
      end

      def workflow_outcome_reference_spec(value)
        value.nil? ? nil : document_id_value(value)
      end

      def workflow_call_activity_spec(activity, kind)
        spec = workflow_terminal_spec(activity).merge(
          type: kind == :microflow ? :call_microflow : :call_workflow,
          parameter_mappings: bson_items(activity['ParameterMappings']).map do |mapping|
            {
              id: document_id(mapping), parameter: mapping.fetch('Parameter', ''),
              expression: mapping.fetch('Expression', '')
            }
          end,
          parameter_mappings_marker: bson_marker(activity['ParameterMappings'], 2),
          boundary_events: bson_items(activity['BoundaryEvents']).map { workflow_boundary_spec(_1) },
          boundary_events_marker: bson_marker(activity['BoundaryEvents'], 2)
        )
        if kind == :microflow
          spec.merge!(microflow: activity.fetch('Microflow', ''),
                      outcomes: bson_items(activity['Outcomes']).map do |outcome|
                        workflow_condition_outcome_spec(outcome)
                      end,
                      outcomes_marker: bson_marker(activity['Outcomes'], 2))
        else
          spec.merge!(workflow: activity.fetch('Workflow', ''),
                      execute_async: activity['ExecuteAsync'] == true)
        end
        spec
      end

      def workflow_condition_outcome_spec(outcome)
        flow = outcome.fetch('Flow')
        type = case outcome['$Type']
               when 'Workflows$BooleanConditionOutcome' then :boolean
               when 'Workflows$EnumerationValueConditionOutcome' then :enumeration
               else :void
               end
        {
          id: document_id(outcome),
          persistent_id: document_id_value(outcome.fetch('PersistentId')),
          type:, value: outcome['Value'], flow_id: document_id(flow),
          activities_marker: bson_marker(flow['Activities'], 2)
        }.compact
      end

      def workflow_targeting_spec(targeting)
        base = { id: document_id(targeting) }
        case targeting['$Type']
        when 'Workflows$XPathUserTargeting'
          base.merge(type: :xpath, constraint: targeting.fetch('XPathConstraint', ''))
        when 'Workflows$XPathGroupTargeting'
          base.merge(type: :xpath_group, constraint: targeting.fetch('XPathConstraint', ''))
        when 'Workflows$MicroflowUserTargeting'
          base.merge(type: :microflow, microflow: targeting.fetch('Microflow', ''))
        when 'Workflows$MicroflowGroupTargeting'
          base.merge(type: :microflow_group, microflow: targeting.fetch('Microflow', ''))
        else base.merge(type: :none)
        end
      end

      def workflow_event_handler_spec(event)
        spec = {
          id: document_id(event), description: event.fetch('Description', ''),
          event_types: bson_items(event['EventTypes']),
          event_types_marker: bson_marker(event['EventTypes'], 2),
          documentation: event.fetch('Documentation', '')
        }
        handler = event['MicroflowEventHandler']
        if handler
          spec[:handler_id] = document_id(handler)
          spec[:microflow] = handler.fetch('Microflow', '')
        end
        spec
      end

      def workflow_event_sub_process_spec(process)
        flow = process.fetch('Flow')
        activities = bson_items(flow['Activities'])
        {
          id: document_id(process),
          persistent_id: document_id_value(process.fetch('PersistentId')),
          name: process.fetch('Name', ''), caption: process.fetch('Caption', ''),
          flow_id: document_id(flow), activities_marker: bson_marker(flow['Activities'], 2),
          interrupting: activities.first['$Type'] ==
            'Workflows$InterruptingNotificationEventSubProcessStartActivity',
          start: workflow_terminal_spec(activities.first),
          activities: activities[1...-1].map { workflow_activity_spec(_1) },
          finish: workflow_terminal_spec(activities.last)
        }
      end

      def workflow_boundary_spec(event)
        flow = event.fetch('Flow')
        ending = bson_items(flow.fetch('Activities')).first
        spec = {
          id: document_id(event), persistent_id: document_id_value(event.fetch('PersistentId')),
          type: if event['$Type'] == 'Workflows$InterruptingTimerBoundaryEvent'
                  :interrupting_timer
                else
                  :non_interrupting_timer
                end,
          caption: event.fetch('Caption', ''),
          first_execution_time: event.fetch('FirstExecutionTime', ''),
          flow_id: document_id(flow), activities_marker: bson_marker(flow['Activities'], 2),
          end: workflow_terminal_spec(ending)
        }
        recurrence = event['Recurrence']
        spec[:recurrence] = workflow_recurrence_spec(recurrence) if recurrence
        spec
      end

      def workflow_recurrence_spec(recurrence)
        {
          id: document_id(recurrence), interval_type: recurrence.fetch('IntervalType', ''),
          interval: recurrence.fetch('Interval', 1), max_executions: recurrence.fetch('MaxExecutions', 1)
        }
      end

      def workflow_outcome_spec(outcome)
        flow = outcome.fetch('Flow')
        {
          id: document_id(outcome),
          persistent_id: document_id_value(outcome.fetch('PersistentId')),
          value: outcome.fetch('Value', ''), flow_id: document_id(flow),
          activities_marker: bson_marker(flow['Activities'], 2)
        }
      end
    end
  end
end
