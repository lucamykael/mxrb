# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Workflow certification' do
  it 'keeps a workflow, single user task, outcome, and task page stable for two Ruby cycles' do
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
          'user_tasks:', ':task_page => "App.Review"', ':value => "Complete"'
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
      ->(value) { value['BoundaryEvents'] << { '$Type' => 'Workflows$TimerBoundaryEvent' } },
      ->(value) { value['OnCreatedEvent']['$Type'] = 'Workflows$MicroflowEvent' },
      ->(value) { value['AutoAssignSingleTargetUser'] = nil }
    ]
    invalid_tasks.each do |mutate|
      candidate = deep_copy(task)
      mutate.call(candidate)
      expect(exporter.send(:semantic_workflow_user_task?, candidate)).to be(false)
    end

    outcome = Mxrb::IO::BsonCodec.parse_array(task.fetch('Outcomes')).fetch(:items).first
    [
      ->(value) { value['$Type'] = 'Workflows$FutureOutcome' },
      ->(value) { value['Future'] = true },
      ->(value) { value['Value'] = nil }
    ].each do |mutate|
      candidate = deep_copy(outcome)
      mutate.call(candidate)
      expect(exporter.send(:semantic_workflow_outcome?, candidate)).to be(false)
    end
  end

  it 'validates the concise authoring boundaries and explicit page parameter identities' do
    builder = Mxrb::Dsl::ModuleBuilder.new(:App)
    expect do
      builder.workflow(
        :Invalid, context_entity: 'App.Request',
                  user_tasks: [{ task_page: 'App.Review', outcomes: [{}, {}] }]
      )
    end.to raise_error(ArgumentError, /exactly one outcome/)

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
                              outcomes: [{ value: 'Complete' }]
                            }]
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
