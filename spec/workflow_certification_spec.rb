# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Workflow certification' do
  it 'keeps a workflow, user-task outcomes, and task page stable for two Ruby cycles' do
    Dir.mktmpdir('mxrb-workflow-') do |dir|
      current = File.join(dir, 'source.mpr')
      build_source(current)
      baseline_ids = workflow_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = Dir[File.join(exported, 'modules/App/application/workflows/*.rb')]
                 .map { File.read(_1) }.join("\n")
        expect(source).to include(
          'workflow :Approval', 'context_entity: "App.Request"',
          'workflow_name: "Approval request"', 'persistent_id:',
          'user_tasks:', ':task_page => "App.Review"', ':value => "Approve"',
          ':value => "Reject"'
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')
        page_source = Dir[File.join(exported, 'modules/App/presentation/pages/*.rb')]
                      .map { File.read(_1) }.join("\n")
        expect(page_source).to include(
          'parameters(:page_parameter)', 'name "WorkflowUserTask"',
          'Mxrb::Forms::DataType.object("System.WorkflowUserTask")'
        )

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(workflow_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
  end

  it 'keeps timers, targeting, creation events, and boundary timers editable' do
    Dir.mktmpdir('mxrb-advanced-workflow-') do |dir|
      current = File.join(dir, 'source.mpr')
      build_advanced_source(current)
      baseline_ids = workflow_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = Dir[File.join(exported, 'modules/App/application/workflows/*.rb')]
                 .map { File.read(_1) }.join("\n")
        expect(source).to include(
          'activities:', ':type => :wait_timer', ':delay => "addMinutes(',
          ':type => :microflow', ':microflow => "App.TargetUsers"',
          ':on_created =>', ':type => :interrupting_timer',
          ':type => :non_interrupting_timer', ':interval_type => "Minute"'
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(workflow_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
  end

  it 'keeps multi-user tasks, calls, workflow events, and event subprocesses editable' do
    Dir.mktmpdir('mxrb-full-workflow-') do |dir|
      current = File.join(dir, 'source.mpr')
      build_full_workflow_source(current)
      baseline_ids = workflow_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = Dir[File.join(exported, 'modules/App/application/workflows/*.rb')]
                 .map { File.read(_1) }.join("\n")
        expect(source).to include(
          ':type => :multi_user_task', ':type => :xpath_group',
          ':type => :percentage', ':type => :threshold',
          ':type => :call_microflow', ':parameter_mappings =>',
          ':type => :call_workflow', ':execute_async => true',
          'on_workflow_events:', 'WorkflowCompleted',
          'event_sub_processes:', ':interrupting => false'
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(workflow_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
  end

  it 'keeps workflows with unsupported activities in the native fallback' do
    builder = Mxrb::Dsl::ModuleBuilder.new(:App)
    builder.workflow(:Approval, context_entity: 'App.Request')
    valid = builder.native_documents.fetch(0).fetch(:doc)
    exporter = Mxrb::Exporter.allocate
    expect(exporter.send(:semantic_workflow?, valid)).to be(true)

    future = deep_copy(valid)
    future.fetch('Flow').fetch('Activities') << {
      '$ID' => SecureRandom.uuid, '$Type' => 'Workflows$FutureActivity'
    }
    expect(exporter.send(:semantic_workflow?, future)).to be(false)
    declaration = exporter.send(:integration_document_declaration, {
      type: 'Workflows$Workflow', name: 'Approval', id: SecureRandom.uuid,
      container_id: SecureRandom.uuid, containment: 'Documents', doc: future
    })
    expect(declaration).to include('native_document :Approval', 'deep_structure:')
  end

  it 'rejects unsupported workflow shapes at every typed boundary' do
    exporter = Mxrb::Exporter.allocate
    document = workflow_document

    invalid_documents = [
      ->(doc) { doc['Future'] = true },
      ->(doc) { doc['PersistentId'] = 'not-binary' },
      ->(doc) { doc['Title'] = nil },
      ->(doc) { doc['AdminPage'] = {} },
      ->(doc) { doc['Parameter'] = nil },
      ->(doc) { doc['WorkflowName'] = nil },
      ->(doc) { doc['WorkflowDescription'] = nil },
      ->(doc) { doc['Flow'] = nil },
      ->(doc) { doc['WorkflowMetaData'] = nil }
    ]
    invalid_documents.each do |mutate|
      candidate = deep_copy(document)
      mutate.call(candidate)
      expect(exporter.send(:semantic_workflow?, candidate)).to be(false)
    end

    flow = document.fetch('Flow')
    expect(exporter.send(:semantic_workflow_flow?, nil)).to be(false)
    expect(exporter.send(:semantic_workflow_flow?, flow.merge('Future' => true))).to be(false)

    task = Mxrb::IO::BsonCodec.parse_array(flow.fetch('Activities')).fetch(:items)[1]
    invalid_tasks = [
      ->(value) { value['$Type'] = 'Workflows$FutureActivity' },
      ->(value) { value['Future'] = true },
      ->(value) { value['DueDate'] = nil },
      ->(value) { value['TaskPage'] = nil },
      ->(value) { value['TaskName'] = nil },
      ->(value) { value['TaskDescription'] = nil },
      ->(value) { value['UserTargeting'] = nil },
      ->(value) { value['BoundaryEvents'] << { '$Type' => 'Workflows$FutureBoundaryEvent' } },
      ->(value) { value['OnCreatedEvent']['$Type'] = 'Workflows$FutureEvent' },
      ->(value) { value['AutoAssignSingleTargetUser'] = nil }
    ]
    invalid_tasks.each do |mutate|
      candidate = deep_copy(task)
      mutate.call(candidate)
      expect(exporter.send(:semantic_workflow_user_task?, candidate)).to be(false)
    end

    empty_outcomes = deep_copy(task)
    empty_outcomes['Outcomes'] = Mxrb::IO::BsonCodec.build_array([], marker: 2)
    expect(exporter.send(:semantic_workflow_user_task?, empty_outcomes)).to be(false)

    duplicate_outcomes = deep_copy(task)
    duplicate = deep_copy(outcome = Mxrb::IO::BsonCodec.parse_array(
      task.fetch('Outcomes')
    ).fetch(:items).first)
    duplicate_outcomes['Outcomes'] = Mxrb::IO::BsonCodec.build_array(
      [outcome, duplicate], marker: 2
    )
    expect(exporter.send(:semantic_workflow_user_task?, duplicate_outcomes)).to be(false)

    [
      ->(value) { value['$Type'] = 'Workflows$FutureOutcome' },
      ->(value) { value['Future'] = true },
      ->(value) { value['Value'] = nil },
      ->(value) { value['Value'] = '' }
    ].each do |mutate|
      candidate = deep_copy(outcome)
      mutate.call(candidate)
      expect(exporter.send(:semantic_workflow_outcome?, candidate)).to be(false)
    end
  end

  it 'rejects unsupported advanced activity, targeting, event, and timer shapes' do
    exporter = Mxrb::Exporter.allocate
    document = advanced_workflow_document
    activities = Mxrb::IO::BsonCodec.parse_array(
      document.fetch('Flow').fetch('Activities')
    ).fetch(:items)
    wait_timer = activities.fetch(1)
    task = activities.fetch(2)
    boundaries = Mxrb::IO::BsonCodec.parse_array(task.fetch('BoundaryEvents')).fetch(:items)
    interrupting, non_interrupting = boundaries

    expect(exporter.send(:semantic_workflow_activity?, nil)).to be(false)
    expect(exporter.send(:semantic_workflow_activity?, { '$Type' => 'Workflows$FutureActivity' }))
      .to be(false)
    expect(exporter.send(:semantic_workflow_activity?, wait_timer)).to be(true)
    expect(exporter.send(:semantic_workflow_user_task?, nil)).to be(false)
    expect(exporter.send(:semantic_workflow_user_task?, task.merge('PersistentId' => 'invalid')))
      .to be(false)

    no_targeting = task.fetch('UserTargeting')
    expect(exporter.send(:semantic_workflow_targeting?, no_targeting)).to be(true)
    expect(exporter.send(:workflow_targeting_spec, no_targeting)).to include(type: :none, id: a_kind_of(String))
    expect(exporter.send(:semantic_workflow_targeting?, { '$Type' => 'Workflows$FutureTargeting' }))
      .to be(false)
    expect(exporter.send(:semantic_workflow_user_task_event?, nil)).to be(false)

    expect(exporter.send(:semantic_workflow_boundary_event?, interrupting)).to be(true)
    expect(exporter.send(:semantic_workflow_boundary_event?, non_interrupting)).to be(true)
    expect(exporter.send(:semantic_workflow_boundary_event?, nil)).to be(false)
    invalid_boundary_mutations.each do |mutate|
      candidate = deep_copy(interrupting)
      mutate.call(candidate)
      expect(exporter.send(:semantic_workflow_boundary_event?, candidate)).to be(false)
    end

    interrupting_flow = interrupting.fetch('Flow')
    expect(exporter.send(:semantic_workflow_boundary_flow?, nil, interrupting.fetch('$Type')))
      .to be(false)
    expect(exporter.send(
             :semantic_workflow_boundary_flow?, interrupting_flow.merge('Future' => true),
             interrupting.fetch('$Type')
           )).to be(false)
    empty_flow = deep_copy(interrupting_flow)
    empty_flow['Activities'] = Mxrb::IO::BsonCodec.build_array([], marker: 2)
    expect(exporter.send(
             :semantic_workflow_boundary_flow?, empty_flow, interrupting.fetch('$Type')
           )).to be(false)

    expect(exporter.send(:semantic_workflow_recurrence?, nil)).to be(true)
    expect(exporter.send(:semantic_workflow_recurrence?, 'invalid')).to be(false)
    recurrence = non_interrupting.fetch('Recurrence')
    invalid_recurrence_mutations.each do |mutate|
      candidate = deep_copy(recurrence)
      mutate.call(candidate)
      expect(exporter.send(:semantic_workflow_recurrence?, candidate)).to be(false)
    end
  end

  it 'certifies every extended workflow variant and rejects malformed shapes' do
    builder = Mxrb::Dsl::ModuleBuilder.new(:App)
    exporter = Mxrb::Exporter.allocate
    target_inputs = [
      builder.send(:workflow_target_user_input, nil),
      builder.send(:workflow_target_user_input, type: :absolute, amount: 3),
      builder.send(:workflow_target_user_input, type: :percentage, percentage: 60)
    ]
    expect(target_inputs.map { exporter.send(:semantic_workflow_target_user_input?, _1) })
      .to all(be(true))
    expect(target_inputs.map { exporter.send(:workflow_target_user_input_spec, _1) })
      .to include(include(type: :all), include(type: :absolute), include(type: :percentage))
    expect(exporter.send(:semantic_workflow_target_user_input?, nil)).to be(false)
    expect(exporter.send(:semantic_workflow_target_user_input?, target_inputs[0].merge('Amount' => 1)))
      .to be(false)
    expect(exporter.send(:semantic_workflow_target_user_input?, target_inputs[1].merge('Amount' => nil)))
      .to be(false)
    expect(exporter.send(:semantic_workflow_target_user_input?, target_inputs[2].merge('Percentage' => 0)))
      .to be(false)
    expect(exporter.send(:semantic_workflow_target_user_input?, { '$Type' => 'Workflows$Future' }))
      .to be(false)
    expect { builder.send(:workflow_target_user_input, type: :percentage, percentage: 0) }
      .to raise_error(ArgumentError, /between 1 and 100/)
    expect { builder.send(:workflow_target_user_input, type: :future) }
      .to raise_error(ArgumentError, /unsupported workflow target user input/)

    criteria = %i[consensus majority microflow threshold veto].to_h do |type|
      options = {
        type:, fallback_outcome: SecureRandom.uuid, veto_outcome: SecureRandom.uuid
      }
      options[:microflow] = 'App.Criteria' if type == :microflow
      [type, builder.send(:workflow_completion_criteria, options)]
    end
    expect(criteria.values.map { exporter.send(:semantic_workflow_completion_criteria?, _1) })
      .to all(be(true))
    expect(criteria.values.map { exporter.send(:workflow_completion_criteria_spec, _1).fetch(:type) })
      .to contain_exactly(:consensus, :majority, :microflow, :threshold, :veto)
    binary_reference = criteria[:consensus].fetch('FallbackOutcomePointer')
    expect(builder.send(:workflow_outcome_reference, binary_reference)).to equal(binary_reference)
    expect(builder.send(:workflow_outcome_reference, nil)).to be_nil
    expect(exporter.send(:workflow_outcome_reference_spec, nil)).to be_nil
    expect(exporter.send(:semantic_workflow_completion_criteria?, nil)).to be(false)
    expect(exporter.send(:semantic_workflow_completion_criteria?, criteria[:consensus].merge('Future' => true)))
      .to be(false)
    missing_fallback = criteria[:consensus].reject { _1 == 'FallbackOutcomePointer' }
    expect(exporter.send(:semantic_workflow_completion_criteria?, missing_fallback))
      .to be(false)
    expect(exporter.send(:semantic_workflow_completion_criteria?, criteria[:majority].merge('CompletionType' => nil)))
      .to be(false)
    expect(exporter.send(:semantic_workflow_completion_criteria?, criteria[:microflow].merge('Microflow' => '')))
      .to be(false)
    expect(exporter.send(:semantic_workflow_completion_criteria?, criteria[:threshold].merge('Threshold' => nil)))
      .to be(false)
    expect(exporter.send(
             :semantic_workflow_completion_criteria?, criteria[:veto].merge('VetoOutcomePointer' => nil)
           ))
      .to be(true)
    expect(exporter.send(:semantic_workflow_completion_criteria?, { '$Type' => 'Workflows$Future' }))
      .to be(false)
    expect { builder.send(:workflow_completion_criteria, type: :future) }
      .to raise_error(ArgumentError, /unsupported workflow completion criteria/)

    multi_base = { task_page: 'App.Review', outcomes: [{ value: 'Approve' }] }
    multi_microflow = builder.send(
      :workflow_multi_user_task,
      multi_base.merge(completion_criteria: { type: :microflow, microflow: 'App.Complete' }), 0
    )
    multi_veto = builder.send(
      :workflow_multi_user_task, multi_base.merge(completion_criteria: { type: :veto }), 1
    )
    expect(exporter.send(:semantic_workflow_multi_user_task?, multi_microflow)).to be(true)
    expect(exporter.send(:semantic_workflow_multi_user_task?, multi_veto)).to be(true)
    expect(exporter.send(:semantic_workflow_multi_user_task?, nil)).to be(false)
    expect(exporter.send(:semantic_workflow_multi_user_task?, multi_veto.merge('Future' => true)))
      .to be(false)

    outcomes = [
      builder.send(:workflow_condition_outcome, type: :void),
      builder.send(:workflow_condition_outcome, type: :boolean, value: true),
      builder.send(:workflow_condition_outcome, type: :enumeration, value: 'App.Decision.Approve')
    ]
    expect(outcomes.map { exporter.send(:semantic_workflow_condition_outcome?, _1) }).to all(be(true))
    expect(outcomes.map { exporter.send(:workflow_condition_outcome_spec, _1).fetch(:type) })
      .to eq(%i[void boolean enumeration])
    invalid_outcomes = [
      nil, outcomes[0].merge('Future' => true), outcomes[0].merge('PersistentId' => 'invalid'),
      outcomes[0].merge('$Type' => 'Workflows$Future'), outcomes[1].merge('Value' => 'true'),
      outcomes[2].merge('Value' => true), outcomes[0].merge('Flow' => nil),
      outcomes[0].merge('Flow' => outcomes[0].fetch('Flow').merge('$Type' => 'Workflows$Future')),
      outcomes[0].merge('Flow' => outcomes[0].fetch('Flow').merge('Future' => true)),
      outcomes[0].merge('Flow' => outcomes[0].fetch('Flow').merge(
        'Activities' => Mxrb::IO::BsonCodec.build_array([{}], marker: 2)
      ))
    ]
    invalid_outcomes.each do |outcome|
      expect(exporter.send(:semantic_workflow_condition_outcome?, outcome)).to be(false)
    end
    expect { builder.send(:workflow_condition_outcome, type: :future) }
      .to raise_error(ArgumentError, /unsupported workflow condition outcome/)

    boundary = { type: :interrupting_timer, first_execution_time: '[%CurrentDateTime%]' }
    call_microflow = builder.send(
      :workflow_call_microflow,
      { microflow: 'App.Decide', outcomes: [{ type: :boolean, value: false }],
        parameter_mappings: [{ parameter: 'App.Decide.Input', expression: '$WorkflowContext' }],
        boundary_events: [boundary] }, 0
    )
    call_workflow = builder.send(
      :workflow_call_workflow,
      { workflow: 'App.Child', execute_async: true,
        parameter_mappings: [{ parameter: 'App.Child.WorkflowContext', expression: '$WorkflowContext' }],
        boundary_events: [boundary] }, 1
    )
    expect(exporter.send(:semantic_workflow_call_microflow?, call_microflow)).to be(true)
    expect(exporter.send(:semantic_workflow_call_workflow?, call_workflow)).to be(true)
    expect(exporter.send(:workflow_call_activity_spec, call_microflow, :microflow))
      .to include(type: :call_microflow, microflow: 'App.Decide')
    expect(exporter.send(:workflow_call_activity_spec, call_workflow, :workflow))
      .to include(type: :call_workflow, workflow: 'App.Child', execute_async: true)
    invalid_call_mutations(call_microflow, :microflow).each do |candidate|
      expect(exporter.send(:semantic_workflow_call_microflow?, candidate)).to be(false)
    end
    invalid_call_mutations(call_workflow, :workflow).each do |candidate|
      expect(exporter.send(:semantic_workflow_call_workflow?, candidate)).to be(false)
    end

    targetings = %i[xpath_group microflow_group].map do |type|
      source = if type == :xpath_group
                 { type:, constraint: '[id != empty]' }
               else
                 { type:, microflow: 'App.TargetGroups' }
               end
      builder.send(:workflow_user_targeting, { targeting: source })
    end
    expect(targetings.map { exporter.send(:semantic_workflow_targeting?, _1) }).to all(be(true))
    expect(targetings.map { exporter.send(:workflow_targeting_spec, _1).fetch(:type) })
      .to eq(%i[xpath_group microflow_group])

    handlers = [
      builder.send(:workflow_event_handler, description: 'Observed', event_types: []),
      builder.send(:workflow_event_handler, description: 'Audited', microflow: 'App.Audit',
                                            event_types: ['WorkflowCompleted'])
    ]
    expect(handlers.map { exporter.send(:semantic_workflow_event_handler?, _1) }).to all(be(true))
    expect(handlers.map { exporter.send(:workflow_event_handler_spec, _1) })
      .to include(include(description: 'Observed'), include(microflow: 'App.Audit'))
    invalid_event_handlers(handlers.last).each do |candidate|
      expect(exporter.send(:semantic_workflow_event_handler?, candidate)).to be(false)
    end

    processes = [true, false].map do |interrupting|
      builder.send(:workflow_event_sub_process, {
        name: 'Notice', interrupting:, activities: [{ type: :wait_timer, delay: '[%CurrentDateTime%]' }]
      }, 0)
    end
    expect(processes.map { exporter.send(:semantic_workflow_event_sub_process?, _1) }).to all(be(true))
    expect(processes.map { exporter.send(:workflow_event_sub_process_spec, _1).fetch(:interrupting) })
      .to eq([true, false])
    invalid_event_processes(processes.first).each do |candidate|
      expect(exporter.send(:semantic_workflow_event_sub_process?, candidate)).to be(false)
    end
  end

  it 'validates the concise authoring boundaries and explicit page parameter identities' do
    builder = Mxrb::Dsl::ModuleBuilder.new(:App)
    expect(builder.send(:workflow_recurrence, nil)).to be_nil
    expect do
      builder.workflow(
        :Invalid, context_entity: 'App.Request',
                  user_tasks: [{ task_page: 'App.Review', outcomes: [] }]
      )
    end.to raise_error(ArgumentError, /at least one outcome/)
    expect do
      builder.workflow(
        :Invalid, context_entity: 'App.Request',
                  user_tasks: [{ task_page: 'App.Review', outcomes: [{ value: '' }] }]
      )
    end.to raise_error(ArgumentError, /cannot be empty/)
    expect do
      builder.workflow(
        :Invalid, context_entity: 'App.Request', user_tasks: [{
          task_page: 'App.Review', outcomes: [{ value: 'Complete' }, { value: 'Complete' }]
        }]
      )
    end.to raise_error(ArgumentError, /must be unique/)
    expect do
      builder.workflow(
        :Invalid, context_entity: 'App.Request', user_tasks: [{ task_page: 'App.Review' }],
                  activities: [{ type: :wait_timer, delay: '1' }]
      )
    end.to raise_error(ArgumentError, /either activities or user_tasks/)
    expect do
      builder.workflow(
        :Invalid, context_entity: 'App.Request', activities: [{ type: :future }]
      )
    end.to raise_error(ArgumentError, /unsupported certified workflow activity/)
    expect do
      builder.workflow(
        :Invalid, context_entity: 'App.Request', user_tasks: [{
          task_page: 'App.Review', targeting: { type: :future }
        }]
      )
    end.to raise_error(ArgumentError, /unsupported workflow user targeting/)
    expect do
      builder.workflow(
        :Invalid, context_entity: 'App.Request', user_tasks: [{
          task_page: 'App.Review', boundary_events: [{ type: :future }]
        }]
      )
    end.to raise_error(ArgumentError, /unsupported workflow boundary event/)

    page = Mxrb::Dsl::PageBuilder.new(:Review)
    page.parameter(
      :WorkflowUserTask, entity: 'System.WorkflowUserTask',
                         id: 'parameter-id', type_id: 'type-id'
    )
    expect(page.to_h.fetch(:parameters).first).to include(
      id: 'parameter-id', type_id: 'type-id'
    )

    parameter = Mxrb::Writer.allocate.send(:page_parameter_doc, {
      name: 'WorkflowUserTask', entity: 'System.WorkflowUserTask', required: true,
      default_value: '', id: 'parameter-id', type_id: 'type-id'
    })
    expect(parameter).to include('$ID' => 'parameter-id')
    expect(parameter.fetch('ParameterType')).to include('$ID' => 'type-id')
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        entity(:Request) { string :Subject }
        page(:Landing) { title 'Landing' }
        page :Review do
          title 'Review task'
          parameter :WorkflowUserTask, entity: 'System.WorkflowUserTask'
        end
        workflow :Approval, context_entity: 'App.Request', title: 'Approval',
                            workflow_name: 'Approval request',
                            workflow_description: 'Review the request', due_date: '[%CurrentDateTime%]',
                            user_tasks: [{
                              name: 'Review', caption: 'Review', task_page: 'App.Review',
                              task_name: 'Review request', task_description: 'Review the request',
                              xpath: "[id = '[%CurrentUser%]']",
                              outcomes: [{ value: 'Approve' }, { value: 'Reject' }]
                            }]
      end
    end
  end

  def build_advanced_source(path) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        entity(:Request) { string :Subject }
        page(:Review) do
          title 'Review task'
          parameter :WorkflowUserTask, entity: 'System.WorkflowUserTask'
        end
        microflow :TargetUsers do
          parameter :Workflow, type: object_of('System.Workflow')
          parameter :WorkflowContext, type: object_of('App.Request')
          return_type list_of('System.User')
          retrieve_objects 'System.User', as: :Users
          return_value '$Users'
        end
        microflow :NotifyCreated do
          parameter :WorkflowUserTask, type: object_of('System.WorkflowUserTask')
          parameter :WorkflowContext, type: object_of('App.Request')
        end
        workflow :Approval, context_entity: 'App.Request', activities: [
          {
            type: :wait_timer, name: 'Pause', delay: 'addMinutes([%CurrentDateTime%], 5)'
          },
          {
            type: :user_task, name: 'Review', task_page: 'App.Review',
            targeting: { type: :microflow, microflow: 'App.TargetUsers' },
            on_created: { microflow: 'App.NotifyCreated' },
            outcomes: [{ value: 'Complete' }],
            boundary_events: [
              {
                type: :interrupting_timer,
                first_execution_time: 'addMinutes([%CurrentDateTime%], 10)'
              },
              {
                type: :non_interrupting_timer,
                first_execution_time: 'addMinutes([%CurrentDateTime%], 2)',
                recurrence: { interval_type: 'Minute', interval: 2, max_executions: 3 }
              }
            ]
          }
        ]
      end
    end
  end

  def build_full_workflow_source(path) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        entity(:Request) { string :Subject }
        page(:Review) do
          title 'Review task'
          parameter :WorkflowUserTask, entity: 'System.WorkflowUserTask'
        end
        microflow(:Prepare) do
          parameter :WorkflowContext, type: object_of('App.Request')
        end
        microflow(:AuditWorkflow) do
          parameter :WorkflowEvent, type: object_of('System.WorkflowEvent')
          parameter :WorkflowRecord, type: object_of('System.WorkflowRecord')
          parameter :WorkflowActivityRecord, type: object_of('System.WorkflowActivityRecord')
        end
        workflow :Child, context_entity: 'App.Request', user_tasks: [{
          name: 'ChildReview', task_page: 'App.Review', outcomes: [{ value: 'Done' }]
        }]
        workflow :Approval, context_entity: 'App.Request',
                            on_workflow_events: [{
                              description: 'Audit completion', microflow: 'App.AuditWorkflow',
                              event_types: ['WorkflowCompleted'], documentation: 'Audited'
                            }],
                            event_sub_processes: [{
                              name: 'Reminder', interrupting: false,
                              activities: [{
                                type: :wait_timer, name: 'WaitReminder',
                                delay: 'addMinutes([%CurrentDateTime%], 10)'
                              }]
                            }],
                            activities: [
                              {
                                type: :multi_user_task, name: 'CommitteeReview',
                                task_page: 'App.Review',
                                targeting: {
                                  type: :xpath_group, constraint: '[id != empty]'
                                },
                                target_user_input: { type: :percentage, percentage: 75 },
                                completion_criteria: {
                                  type: :threshold, completion_type: 'Relative', threshold: 60
                                },
                                await_all_users: false,
                                outcomes: [{ value: 'Approve' }, { value: 'Reject' }]
                              },
                              {
                                type: :call_microflow, name: 'Prepare', microflow: 'App.Prepare',
                                parameter_mappings: [{
                                  parameter: 'App.Prepare.WorkflowContext',
                                  expression: '$WorkflowContext'
                                }]
                              },
                              {
                                type: :call_workflow, name: 'CallChild', workflow: 'App.Child',
                                execute_async: true, parameter_mappings: [{
                                  parameter: 'App.Child.WorkflowContext',
                                  expression: '$WorkflowContext'
                                }]
                              }
                            ]
      end
    end
  end

  def workflow_ids(path)
    Mxrb.open(path) do |project|
      document = project.all_units.filter_map do |unit|
        value = project.parse_bson(unit)
        value if value['$Type'] == 'Workflows$Workflow'
      end.fetch(0)
      nested_documents(document).filter_map do |value|
        next unless value.is_a?(Hash) && value.key?('$ID')

        Mxrb::IO::BsonCodec.extract_id(value.fetch('$ID'))
      end
    end
  end

  def workflow_document
    builder = Mxrb::Dsl::ModuleBuilder.new(:App)
    builder.workflow(
      :Approval, context_entity: 'App.Request',
                 user_tasks: [{ task_page: 'App.Review', outcomes: [{ value: 'Complete' }] }]
    )
    builder.native_documents.fetch(0).fetch(:doc)
  end

  def advanced_workflow_document
    builder = Mxrb::Dsl::ModuleBuilder.new(:App)
    builder.workflow(
      :Advanced, context_entity: 'App.Request', activities: [
        { type: :wait_timer, delay: 'addMinutes([%CurrentDateTime%], 1)' },
        {
          type: :user_task, task_page: 'App.Review', targeting: { type: :none },
          boundary_events: [
            { type: :interrupting_timer, first_execution_time: '[%CurrentDateTime%]' },
            {
              type: :non_interrupting_timer, first_execution_time: '[%CurrentDateTime%]',
              recurrence: { interval_type: 'Minute', interval: 1, max_executions: 2 }
            }
          ]
        }
      ]
    )
    builder.native_documents.fetch(0).fetch(:doc)
  end

  def invalid_boundary_mutations # rubocop:disable Metrics/AbcSize
    [
      ->(value) { value['$Type'] = 'Workflows$FutureBoundaryEvent' },
      ->(value) { value['Future'] = true },
      ->(value) { value['PersistentId'] = 'invalid' },
      ->(value) { value['Annotation'] = 'invalid' },
      ->(value) { value['Caption'] = nil },
      ->(value) { value['FirstExecutionTime'] = nil },
      ->(value) { value['Flow'] = nil },
      ->(value) { value['Recurrence'] = nil }
    ]
  end

  def invalid_recurrence_mutations
    [
      ->(value) { value['$Type'] = 'Workflows$FutureRecurrence' },
      ->(value) { value['Future'] = true },
      ->(value) { value['IntervalType'] = nil },
      ->(value) { value['Interval'] = nil },
      ->(value) { value['MaxExecutions'] = nil }
    ]
  end

  def invalid_call_mutations(activity, kind) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    name = kind == :microflow ? 'Microflow' : 'Workflow'
    invalid_mapping = {
      '$Type' => 'Workflows$FutureMapping', 'Parameter' => '', 'Expression' => ''
    }
    candidates = [
      nil,
      activity.merge('$Type' => 'Workflows$FutureActivity'),
      activity.merge('Future' => true),
      activity.merge('PersistentId' => 'invalid'),
      activity.merge(name => nil),
      activity.merge(name => ''),
      activity.merge(
        'ParameterMappings' => Mxrb::IO::BsonCodec.build_array([invalid_mapping], marker: 2)
      ),
      activity.merge('BoundaryEvents' => Mxrb::IO::BsonCodec.build_array([{}], marker: 2))
    ]
    if kind == :microflow
      candidates.concat([
                          activity.merge('Outcomes' => Mxrb::IO::BsonCodec.build_array([], marker: 2)),
                          activity.merge('Outcomes' => Mxrb::IO::BsonCodec.build_array([{}], marker: 2))
                        ])
    else
      candidates << activity.merge('ExecuteAsync' => nil)
    end
    candidates
  end

  def invalid_event_handlers(handler) # rubocop:disable Metrics/AbcSize
    event_types = Mxrb::IO::BsonCodec.build_array([1], marker: 2)
    microflow = handler.fetch('MicroflowEventHandler')
    [
      nil, handler.merge('$Type' => 'Workflows$FutureHandler'), handler.merge('Future' => true),
      handler.merge('Description' => nil), handler.merge('Description' => ''),
      handler.merge('Documentation' => nil), handler.merge('EventTypes' => event_types),
      handler.merge('MicroflowEventHandler' => 'invalid'),
      handler.merge('MicroflowEventHandler' => microflow.merge('$Type' => 'Workflows$Future')),
      handler.merge('MicroflowEventHandler' => microflow.merge('Future' => true)),
      handler.merge('MicroflowEventHandler' => microflow.merge('Microflow' => nil)),
      handler.merge('MicroflowEventHandler' => microflow.merge('Microflow' => ''))
    ]
  end

  def invalid_event_processes(process) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    flow = process.fetch('Flow')
    activities = Mxrb::IO::BsonCodec.parse_array(flow.fetch('Activities')).fetch(:items)
    replace = lambda do |items|
      process.merge('Flow' => flow.merge(
        'Activities' => Mxrb::IO::BsonCodec.build_array(items, marker: 2)
      ))
    end
    invalid_start = activities.map { deep_copy(_1) }
    invalid_start.first['$Type'] = 'Workflows$FutureStartActivity'
    malformed_start = activities.map { deep_copy(_1) }
    malformed_start.first['PersistentId'] = 'invalid'
    invalid_end = activities.map { deep_copy(_1) }
    invalid_end.last['$Type'] = 'Workflows$FutureEndActivity'
    invalid_body = activities.map { deep_copy(_1) }
    invalid_body[1] = { '$Type' => 'Workflows$FutureActivity' }
    [
      nil, process.merge('$Type' => 'Workflows$FutureProcess'), process.merge('Future' => true),
      process.merge('PersistentId' => 'invalid'), process.merge('Annotation' => 'invalid'),
      process.merge('Name' => nil), process.merge('Caption' => nil), process.merge('Flow' => nil),
      process.merge('Flow' => flow.merge('$Type' => 'Workflows$FutureFlow')),
      process.merge('Flow' => flow.merge('Future' => true)), replace.call([]), replace.call([activities.first]),
      replace.call(invalid_start), replace.call(malformed_start), replace.call(invalid_end),
      replace.call(invalid_body)
    ]
  end

  def nested_documents(value)
    case value
    when Hash then [value, *value.values.flat_map { nested_documents(_1) }]
    when Array then value.drop(1).flat_map { nested_documents(_1) }
    else []
    end
  end

  def deep_copy(value)
    Mxrb::IO::BsonCodec.parse(Mxrb::IO::BsonCodec.serialize(value))
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
