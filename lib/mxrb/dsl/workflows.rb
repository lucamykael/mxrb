# frozen_string_literal: true

require 'securerandom'

module Mxrb
  module Dsl
    # Typed, fail-closed declarations for the certified Workflow subset.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ModuleLength
    module Workflows
      def workflow( # rubocop:disable Metrics/ParameterLists
        name, context_entity:, title: nil, workflow_name: nil, workflow_description: '',
        due_date: '', parameter_name: 'WorkflowContext', start: {}, finish: {}, user_tasks: [],
        activities: nil, on_workflow_events: [], event_sub_processes: [],
        persistent_id: nil, parameter_id: nil, flow_id: nil, workflow_name_id: nil,
        workflow_description_id: nil, metadata_id: nil, activities_marker: 2,
        on_workflow_event_marker: 2, event_sub_processes_marker: 2,
        detached_activities_marker: 2, flow_lines_marker: 2, annotations_marker: 2,
        unit_id: nil, container_id: nil
      )
        document = workflow_identity(unit_id).merge(
          'PersistentId' => workflow_guid(persistent_id),
          'Title' => (title || name).to_s,
          'Parameter' => workflow_parameter(context_entity, parameter_name, parameter_id),
          'AdminPage' => nil,
          'Flow' => workflow_flow(
            start, finish,
            { user_tasks:, activities:, id: flow_id, marker: activities_marker }
          ),
          'WorkflowName' => workflow_string_template(
            workflow_name || title || name, workflow_name_id
          ),
          'WorkflowDescription' => workflow_string_template(
            workflow_description, workflow_description_id
          ),
          'DueDate' => due_date.to_s,
          'OnWorkflowEvent' => workflow_array(
            Array(on_workflow_events).map { workflow_event_handler(_1) },
            on_workflow_event_marker
          ),
          'EventSubProcesses' => workflow_array(
            Array(event_sub_processes).each_with_index.map { workflow_event_sub_process(_1, _2) },
            event_sub_processes_marker
          ),
          'Annotation' => nil,
          'WorkflowMetaData' => workflow_metadata(
            metadata_id, detached_activities_marker, flow_lines_marker, annotations_marker
          ),
          'WorkflowV2' => false
        )
        native_document(
          name, type: 'Workflows$Workflow', deep_structure: document,
                unit_id:, container_id:, containment: 'Documents'
        )
      end

      private

      def workflow_parameter(entity, name, id)
        workflow_identity(id).merge(
          '$Type' => 'Workflows$Parameter', 'Entity' => entity.to_s, 'Name' => name.to_s
        )
      end

      def workflow_flow(start, finish, options)
        user_tasks = options.fetch(:user_tasks)
        activities = options.fetch(:activities)
        raise ArgumentError, 'workflow accepts either activities or user_tasks' if
          activities && Array(user_tasks).any?

        sources = activities || Array(user_tasks).map { _1.to_h.merge(type: :user_task) }
        body = Array(sources).each_with_index.map { workflow_activity(_1, _2) }
        finish_position = "0;#{160 * (body.size + 1)}"
        {
          '$ID' => workflow_id(options[:id]), '$Type' => 'Workflows$Flow',
          'Activities' => workflow_array([
                                           workflow_terminal_activity(start, :start),
                                           *body,
                                           workflow_terminal_activity(
                                             finish, :finish, default_position: finish_position
                                           )
                                         ], options.fetch(:marker))
        }
      end

      def workflow_activity(source, index)
        spec = source.to_h.transform_keys(&:to_sym)
        case spec.fetch(:type, :user_task).to_sym
        when :user_task then workflow_user_task(spec, index)
        when :multi_user_task then workflow_multi_user_task(spec, index)
        when :wait_timer then workflow_wait_timer(spec, index)
        when :call_microflow then workflow_call_microflow(spec, index)
        when :call_workflow then workflow_call_workflow(spec, index)
        else raise ArgumentError, "unsupported certified workflow activity #{spec[:type].inspect}"
        end
      end

      def workflow_user_task(source, index)
        spec = source.to_h.transform_keys(&:to_sym)
        outcomes = Array(spec.fetch(:outcomes, [{ value: 'Complete' }]))
        validate_workflow_outcomes!(outcomes)

        workflow_identity(spec[:id]).merge(
          '$Type' => 'Workflows$SingleUserTaskActivity',
          'PersistentId' => workflow_guid(spec[:persistent_id]),
          'Name' => spec.fetch(:name, "UserTask#{index + 1}").to_s,
          'Caption' => spec.fetch(:caption, spec.fetch(:name, "User task #{index + 1}")).to_s,
          'Annotation' => nil,
          'RelativeMiddlePoint' => spec.fetch(:position, "0;#{160 * (index + 1)}").to_s,
          'Size' => spec.fetch(:size, '120;60').to_s,
          'TaskPage' => workflow_page_reference(spec.fetch(:task_page), spec[:task_page_id]),
          'TaskName' => workflow_string_template(
            spec.fetch(:task_name, spec.fetch(:caption, spec.fetch(:name, 'User task'))),
            spec[:task_name_id]
          ),
          'TaskDescription' => workflow_string_template(
            spec.fetch(:task_description, ''), spec[:task_description_id]
          ),
          'DueDate' => spec.fetch(:due_date, '').to_s,
          'UserTargeting' => workflow_user_targeting(spec),
          'Outcomes' => workflow_array(
            outcomes.map { workflow_user_task_outcome(_1) }, spec.fetch(:outcomes_marker, 2)
          ),
          'BoundaryEvents' => workflow_array(
            Array(spec[:boundary_events]).each_with_index.map { workflow_boundary_event(_1, _2) },
            spec.fetch(:boundary_events_marker, 2)
          ),
          'OnCreatedEvent' => workflow_user_task_event(spec),
          'AutoAssignSingleTargetUser' => spec.fetch(:auto_assign, false) == true
        )
      end

      def workflow_wait_timer(spec, index)
        workflow_activity_identity(spec, index, default_name: 'WaitForTimer').merge(
          '$Type' => 'Workflows$WaitForTimerActivity',
          'Delay' => spec.fetch(:delay).to_s
        )
      end

      def workflow_multi_user_task(spec, index) # rubocop:disable Metrics/CyclomaticComplexity
        task = workflow_user_task(spec, index)
        fallback = workflow_array_items(task.fetch('Outcomes')).first.fetch('$ID')
        criteria = (spec[:completion_criteria] || {}).to_h.transform_keys(&:to_sym)
        criteria_type = (criteria[:type] || :consensus).to_sym
        criteria[:fallback_outcome] ||= fallback unless criteria_type == :microflow
        criteria[:veto_outcome] ||= fallback if criteria_type == :veto
        task.merge(
          '$Type' => 'Workflows$MultiUserTaskActivity',
          'TargetUserInput' => workflow_target_user_input(spec[:target_user_input]),
          'CompletionCriteria' => workflow_completion_criteria(criteria),
          'AwaitAllUsers' => spec.fetch(:await_all_users, false) == true
        )
      end

      def workflow_target_user_input(source)
        spec = (source || {}).to_h.transform_keys(&:to_sym)
        id = spec[:id]
        case spec.fetch(:type, :all).to_sym
        when :all
          workflow_identity(id).merge('$Type' => 'Workflows$AllUserInput')
        when :absolute
          workflow_identity(id).merge(
            '$Type' => 'Workflows$AbsoluteAmountUserInput',
            'Amount' => Integer(spec.fetch(:amount, 2))
          )
        when :percentage
          percentage = Integer(spec.fetch(:percentage, 100))
          raise ArgumentError, 'workflow target percentage must be between 1 and 100' unless
            (1..100).cover?(percentage)

          workflow_identity(id).merge(
            '$Type' => 'Workflows$PercentageAmountUserInput', 'Percentage' => percentage
          )
        else
          raise ArgumentError, "unsupported workflow target user input #{spec[:type].inspect}"
        end
      end

      def workflow_completion_criteria(source) # rubocop:disable Metrics/CyclomaticComplexity
        spec = (source || {}).to_h.transform_keys(&:to_sym)
        id = spec[:id]
        case spec.fetch(:type, :consensus).to_sym
        when :consensus
          workflow_identity(id).merge(
            '$Type' => 'Workflows$ConsensusCompletionCriteria',
            'FallbackOutcomePointer' => workflow_outcome_reference(spec[:fallback_outcome])
          )
        when :majority
          workflow_identity(id).merge(
            '$Type' => 'Workflows$MajorityCompletionCriteria',
            'CompletionType' => spec.fetch(:completion_type, 'Absolute').to_s,
            'FallbackOutcomePointer' => workflow_outcome_reference(spec[:fallback_outcome])
          )
        when :microflow
          workflow_identity(id).merge(
            '$Type' => 'Workflows$MicroflowCompletionCriteria',
            'Microflow' => spec.fetch(:microflow).to_s
          )
        when :threshold
          workflow_identity(id).merge(
            '$Type' => 'Workflows$ThresholdCompletionCriteria',
            'CompletionType' => spec.fetch(:completion_type, 'Relative').to_s,
            'Threshold' => Integer(spec.fetch(:threshold, 50)),
            'FallbackOutcomePointer' => workflow_outcome_reference(spec[:fallback_outcome])
          )
        when :veto
          workflow_identity(id).merge(
            '$Type' => 'Workflows$VetoCompletionCriteria',
            'VetoOutcomePointer' => workflow_outcome_reference(spec[:veto_outcome])
          )
        else
          raise ArgumentError, "unsupported workflow completion criteria #{spec[:type].inspect}"
        end
      end

      def workflow_call_microflow(spec, index)
        outcomes = Array(spec.fetch(:outcomes, [{ type: :void }]))
        workflow_activity_identity(spec, index, default_name: 'CallMicroflow').merge(
          '$Type' => 'Workflows$CallMicroflowActivity',
          'Outcomes' => workflow_array(
            outcomes.map { workflow_condition_outcome(_1) }, spec.fetch(:outcomes_marker, 2)
          ),
          'Microflow' => spec.fetch(:microflow).to_s,
          'ParameterMappings' => workflow_array(
            workflow_parameter_mappings(spec[:parameter_mappings], :microflow),
            spec.fetch(:parameter_mappings_marker, 2)
          ),
          'BoundaryEvents' => workflow_array(
            Array(spec[:boundary_events]).each_with_index.map { workflow_boundary_event(_1, _2) },
            spec.fetch(:boundary_events_marker, 2)
          )
        )
      end

      def workflow_condition_outcome(source)
        spec = source.to_h.transform_keys(&:to_sym)
        type = spec.fetch(:type, :void).to_sym
        storage_type = {
          void: 'Workflows$VoidConditionOutcome',
          boolean: 'Workflows$BooleanConditionOutcome',
          enumeration: 'Workflows$EnumerationValueConditionOutcome'
        }.fetch(type) { raise ArgumentError, "unsupported workflow condition outcome #{type.inspect}" }
        outcome = workflow_identity(spec[:id]).merge(
          '$Type' => storage_type, 'PersistentId' => workflow_guid(spec[:persistent_id]),
          'Flow' => {
            '$ID' => workflow_id(spec[:flow_id]), '$Type' => 'Workflows$Flow',
            'Activities' => workflow_array([], spec.fetch(:activities_marker, 2))
          }
        )
        outcome['Value'] = spec.fetch(:value) unless type == :void
        outcome
      end

      def workflow_call_workflow(spec, index)
        workflow_activity_identity(spec, index, default_name: 'CallWorkflow').merge(
          '$Type' => 'Workflows$CallWorkflowActivity',
          'Workflow' => spec.fetch(:workflow).to_s,
          'ParameterMappings' => workflow_array(
            workflow_parameter_mappings(spec[:parameter_mappings], :workflow),
            spec.fetch(:parameter_mappings_marker, 2)
          ),
          'BoundaryEvents' => workflow_array(
            Array(spec[:boundary_events]).each_with_index.map { workflow_boundary_event(_1, _2) },
            spec.fetch(:boundary_events_marker, 2)
          ),
          'ExecuteAsync' => spec.fetch(:execute_async, false) == true
        )
      end

      def workflow_parameter_mappings(sources, kind)
        Array(sources).map do |source|
          spec = source.to_h.transform_keys(&:to_sym)
          type = if kind == :microflow
                   'Workflows$MicroflowCallParameterMapping'
                 else
                   'Workflows$WorkflowCallParameterMapping'
                 end
          workflow_identity(spec[:id]).merge(
            '$Type' => type, 'Parameter' => spec.fetch(:parameter).to_s,
            'Expression' => spec.fetch(:expression, '').to_s
          )
        end
      end

      def workflow_page_reference(page, id)
        workflow_identity(id).merge('$Type' => 'Workflows$PageReference', 'Page' => page.to_s)
      end

      def workflow_user_targeting(spec)
        source = spec[:targeting] ? spec[:targeting].to_h.transform_keys(&:to_sym) : {}
        type = source.fetch(:type, :xpath).to_sym
        id = source[:id] || spec[:targeting_id]
        handler = {
          xpath: :workflow_xpath_targeting,
          xpath_group: :workflow_xpath_group_targeting,
          microflow: :workflow_microflow_targeting,
          microflow_group: :workflow_microflow_group_targeting,
          none: :workflow_no_targeting
        }.fetch(type) { raise ArgumentError, "unsupported workflow user targeting #{type.inspect}" }
        send(handler, spec, source, id)
      end

      def workflow_xpath_targeting(spec, source, id)
        constraint = source[:constraint].to_s
        constraint = spec.fetch(:xpath, "[id = '[%CurrentUser%]']").to_s if constraint.empty?
        workflow_identity(id).merge(
          '$Type' => 'Workflows$XPathUserTargeting', 'XPathConstraint' => constraint
        )
      end

      def workflow_microflow_targeting(_spec, source, id)
        workflow_identity(id).merge(
          '$Type' => 'Workflows$MicroflowUserTargeting',
          'Microflow' => source.fetch(:microflow).to_s
        )
      end

      def workflow_xpath_group_targeting(spec, source, id)
        workflow_xpath_targeting(spec, source, id).merge('$Type' => 'Workflows$XPathGroupTargeting')
      end

      def workflow_microflow_group_targeting(spec, source, id)
        workflow_microflow_targeting(spec, source, id).merge(
          '$Type' => 'Workflows$MicroflowGroupTargeting'
        )
      end

      def workflow_no_targeting(_spec, _source, id) =
        workflow_identity(id).merge('$Type' => 'Workflows$NoUserTargeting')

      def workflow_user_task_event(spec)
        source = spec[:on_created]&.to_h&.transform_keys(&:to_sym)
        return workflow_identity(spec[:on_created_event_id]).merge('$Type' => 'Workflows$NoEvent') unless source

        workflow_identity(source[:id] || spec[:on_created_event_id]).merge(
          '$Type' => 'Workflows$MicroflowBasedEvent',
          'Microflow' => source.fetch(:microflow).to_s
        )
      end

      def workflow_boundary_event(source, index)
        spec = source.to_h.transform_keys(&:to_sym)
        type = spec.fetch(:type).to_sym
        storage_type = {
          interrupting_timer: 'Workflows$InterruptingTimerBoundaryEvent',
          non_interrupting_timer: 'Workflows$NonInterruptingTimerBoundaryEvent'
        }.fetch(type) { raise ArgumentError, "unsupported workflow boundary event #{type.inspect}" }
        document = workflow_identity(spec[:id]).merge(
          '$Type' => storage_type,
          'PersistentId' => workflow_guid(spec[:persistent_id]),
          'Flow' => workflow_boundary_flow(spec, type, index),
          'Caption' => spec.fetch(:caption, '').to_s,
          'Annotation' => nil,
          'FirstExecutionTime' => spec.fetch(:first_execution_time).to_s
        )
        document['Recurrence'] = workflow_recurrence(spec[:recurrence]) if type == :non_interrupting_timer
        document
      end

      def workflow_boundary_flow(spec, type, index)
        ending_type = if type == :interrupting_timer
                        'Workflows$EndWorkflowActivity'
                      else
                        'Workflows$EndOfBoundaryEventPathActivity'
                      end
        ending = workflow_activity_identity(
          spec.fetch(:end, {}).to_h.transform_keys(&:to_sym), 0,
          default_name: "EndBoundaryPath#{index + 1}", default_position: '0;80'
        ).merge('$Type' => ending_type)
        {
          '$ID' => workflow_id(spec[:flow_id]), '$Type' => 'Workflows$Flow',
          'Activities' => workflow_array([ending], spec.fetch(:activities_marker, 2))
        }
      end

      def workflow_recurrence(source)
        return nil unless source

        spec = source.to_h.transform_keys(&:to_sym)
        workflow_identity(spec[:id]).merge(
          '$Type' => 'Workflows$LinearRecurrence',
          'IntervalType' => spec.fetch(:interval_type, 'Minute').to_s,
          'Interval' => Integer(spec.fetch(:interval, 1)),
          'MaxExecutions' => Integer(spec.fetch(:max_executions, 1))
        )
      end

      def workflow_user_task_outcome(source)
        spec = source.to_h.transform_keys(&:to_sym)
        workflow_identity(spec[:id]).merge(
          '$Type' => 'Workflows$UserTaskOutcome',
          'PersistentId' => workflow_guid(spec[:persistent_id]),
          'Flow' => {
            '$ID' => workflow_id(spec[:flow_id]), '$Type' => 'Workflows$Flow',
            'Activities' => workflow_array([], spec.fetch(:activities_marker, 2))
          },
          'Value' => spec.fetch(:value, 'Complete').to_s
        )
      end

      def workflow_event_handler(source)
        spec = source.to_h.transform_keys(&:to_sym)
        microflow = spec[:microflow]
        handler = if microflow
                    workflow_identity(spec[:handler_id]).merge(
                      '$Type' => 'Workflows$MicroflowEventHandler', 'Microflow' => microflow.to_s
                    )
                  end
        workflow_identity(spec[:id]).merge(
          '$Type' => 'Workflows$WorkflowEventHandler',
          'Description' => spec.fetch(:description).to_s,
          'MicroflowEventHandler' => handler,
          'EventTypes' => workflow_array(Array(spec[:event_types]).map(&:to_s),
                                         spec.fetch(:event_types_marker, 2)),
          'Documentation' => spec.fetch(:documentation, '').to_s
        )
      end

      def workflow_event_sub_process(source, index)
        spec = source.to_h.transform_keys(&:to_sym)
        interrupting = spec.fetch(:interrupting, true) == true
        sources = Array(spec[:activities])
        start_type = if interrupting
                       'Workflows$InterruptingNotificationEventSubProcessStartActivity'
                     else
                       'Workflows$NonInterruptingNotificationEventSubProcessStartActivity'
                     end
        start = workflow_activity_identity(
          spec.fetch(:start, {}).to_h.transform_keys(&:to_sym), 0,
          default_name: "EventStart#{index + 1}", default_position: '0;0'
        ).merge('$Type' => start_type)
        body = sources.each_with_index.map { workflow_activity(_1, _2) }
        finish = workflow_activity_identity(
          spec.fetch(:finish, {}).to_h.transform_keys(&:to_sym), body.size,
          default_name: "EventEnd#{index + 1}", default_position: "0;#{160 * (body.size + 1)}"
        ).merge('$Type' => 'Workflows$EndWorkflowActivity')
        workflow_identity(spec[:id]).merge(
          '$Type' => 'Workflows$EventSubProcess',
          'PersistentId' => workflow_guid(spec[:persistent_id]),
          'Name' => spec.fetch(:name, "EventSubProcess#{index + 1}").to_s,
          'Flow' => {
            '$ID' => workflow_id(spec[:flow_id]), '$Type' => 'Workflows$Flow',
            'Activities' => workflow_array(
              [start, *body, finish], spec.fetch(:activities_marker, 2)
            )
          },
          'Caption' => spec.fetch(:caption, '').to_s,
          'Annotation' => nil
        )
      end

      def validate_workflow_outcomes!(outcomes)
        raise ArgumentError, 'certified workflow user tasks require at least one outcome' if outcomes.empty?

        values = outcomes.map { _1.to_h.transform_keys(&:to_sym).fetch(:value, 'Complete').to_s }
        raise ArgumentError, 'certified workflow outcome values cannot be empty' if values.any?(&:empty?)
        raise ArgumentError, 'certified workflow outcome values must be unique' unless values.uniq == values
      end

      def workflow_terminal_activity(source, kind, default_position: '0;0')
        spec = source.to_h.transform_keys(&:to_sym)
        defaults = kind == :start ? %w[Start Start] : %w[End End]
        type = kind == :start ? 'StartWorkflowActivity' : 'EndWorkflowActivity'
        workflow_activity_identity(
          spec, 0, default_name: defaults[0], default_caption: defaults[1],
                   default_position:
        ).merge(
          '$Type' => "Workflows$#{type}"
        )
      end

      def workflow_activity_identity(spec, index, default_name:, default_caption: nil,
                                     default_position: nil)
        name = spec.fetch(:name, default_name).to_s
        workflow_identity(spec[:id]).merge(
          'PersistentId' => workflow_guid(spec[:persistent_id]),
          'Name' => name,
          'Caption' => spec.fetch(:caption, default_caption || name).to_s,
          'Annotation' => nil,
          'RelativeMiddlePoint' => spec.fetch(
            :position, default_position || "0;#{160 * (index + 1)}"
          ).to_s,
          'Size' => spec.fetch(:size, '120;60').to_s
        )
      end

      def workflow_string_template(text, id)
        workflow_identity(id).merge(
          '$Type' => 'Microflows$StringTemplate', 'Arguments' => workflow_array([], 2),
          'Text' => text.to_s
        )
      end

      def workflow_metadata(id, activities_marker, lines_marker, annotations_marker)
        workflow_identity(id).merge(
          '$Type' => 'Workflows$WorkflowMetaData',
          'DetachedActivities' => workflow_array([], activities_marker),
          'FlowLines' => workflow_array([], lines_marker),
          'Annotation' => workflow_array([], annotations_marker)
        )
      end

      def workflow_guid(value)
        BSON::Binary.new(IO::BsonCodec.uuid_to_blob(workflow_id(value)), :generic)
      end

      def workflow_outcome_reference(value)
        return value if value.is_a?(BSON::Binary)
        return nil if value.to_s.empty?

        workflow_guid(value)
      end

      def workflow_identity(id) = { '$ID' => workflow_id(id) }
      def workflow_id(value) = value.to_s.empty? ? SecureRandom.uuid : value.to_s
      def workflow_array(items, marker) = IO::BsonCodec.build_array(items, marker: marker.to_i)
      def workflow_array_items(value) = IO::BsonCodec.parse_array(value).fetch(:items)
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ModuleLength
  end
end
