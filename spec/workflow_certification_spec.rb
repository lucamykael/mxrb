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
