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
          'Flow' => workflow_flow(start, user_tasks, finish, flow_id, activities_marker),
          'WorkflowName' => workflow_string_template(
            workflow_name || title || name, workflow_name_id
          ),
          'WorkflowDescription' => workflow_string_template(
            workflow_description, workflow_description_id
          ),
          'DueDate' => due_date.to_s,
          'OnWorkflowEvent' => workflow_array([], on_workflow_event_marker),
          'EventSubProcesses' => workflow_array([], event_sub_processes_marker),
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

      def workflow_flow(start, user_tasks, finish, id, marker)
        tasks = Array(user_tasks).each_with_index.map { workflow_user_task(_1, _2) }
        finish_position = "0;#{160 * (tasks.size + 1)}"
        {
          '$ID' => workflow_id(id), '$Type' => 'Workflows$Flow',
          'Activities' => workflow_array([
                                           workflow_terminal_activity(start, :start),
                                           *tasks,
                                           workflow_terminal_activity(
                                             finish, :finish, default_position: finish_position
                                           )
                                         ], marker)
        }
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
          'BoundaryEvents' => workflow_array([], spec.fetch(:boundary_events_marker, 2)),
          'OnCreatedEvent' => workflow_identity(spec[:on_created_event_id]).merge(
            '$Type' => 'Workflows$NoEvent'
          ),
          'AutoAssignSingleTargetUser' => spec.fetch(:auto_assign, false) == true
        )
      end

      def workflow_page_reference(page, id)
        workflow_identity(id).merge('$Type' => 'Workflows$PageReference', 'Page' => page.to_s)
      end

      def workflow_user_targeting(spec)
        workflow_identity(spec[:targeting_id]).merge(
          '$Type' => 'Workflows$XPathUserTargeting',
          'XPathConstraint' => spec.fetch(:xpath, "[id = '[%CurrentUser%]']").to_s
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
        workflow_identity(spec[:id]).merge(
          '$Type' => "Workflows$#{type}",
          'PersistentId' => workflow_guid(spec[:persistent_id]),
          'Name' => spec.fetch(:name, defaults[0]).to_s,
          'Caption' => spec.fetch(:caption, defaults[1]).to_s,
          'Annotation' => nil,
          'RelativeMiddlePoint' => spec.fetch(:position, default_position).to_s,
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

      def workflow_identity(id) = { '$ID' => workflow_id(id) }
      def workflow_id(value) = value.to_s.empty? ? SecureRandom.uuid : value.to_s
      def workflow_array(items, marker) = IO::BsonCodec.build_array(items, marker: marker.to_i)
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/ModuleLength
  end
end
