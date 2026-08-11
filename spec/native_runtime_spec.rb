# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::Native do
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def build_project(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :Clinic do
        entity(:Animal) { string :Name }
        entity(:Scratch) do
          non_persistent!
          string :Value
        end
        microflow :CreateWithoutCommit do
          return_type 'Clinic.Animal'
          create_object 'Clinic.Animal', as: :animal, set: { Name: "'detached'" }
          return_value '$animal'
        end
        microflow :CreateTransientWithoutCommit do
          return_type 'Clinic.Scratch'
          create_object 'Clinic.Scratch', as: :scratch, set: { Value: "'session-local'" }
          return_value '$scratch'
        end
        microflow :ChangeWithoutCommit do
          return_type 'Clinic.Animal'
          retrieve_objects 'Clinic.Animal', as: :animal, single: true
          change_object(:animal) { set 'Clinic.Animal/Name', to: "'detached change'" }
          return_value '$animal'
        end
        microflow :CommitThenChangeWithoutCommit do
          return_type 'Clinic.Animal'
          create_object 'Clinic.Animal', as: :animal, commit: true, set: { Name: "'published'" }
          change_object(:animal) { set 'Clinic.Animal/Name', to: "'detached after commit'" }
          return_value '$animal'
        end
        microflow :SeedAndCount do
          return_type :Integer
          create_object 'Clinic.Animal', as: :animal, set: { Name: "'First'" }
          change_object(:animal) { set 'Clinic.Animal/Name', to: "'Updated'" }
          commit :animal
          retrieve_objects 'Clinic.Animal', as: :animals
          aggregate :animals, function: :count, as: :count
          log_message 'seeded'
          return_value '$count'
        end
        microflow :Child do
          return_type :String
          return_value "'child'"
        end
        microflow :CallChild do
          return_type :String
          call_microflow 'Clinic.Child', as: :result
          return_value '$result'
        end
        microflow :Choose do
          parameter :Flag, type: :Boolean
          return_type :String
          decision '$Flag' do
            on(true) { return_value "'yes'" }
            on(false) { return_value "'no'" }
          end
        end
        microflow :Loop do
          return_type :Integer
          create_variable :counter, type: :Integer, value: '0'
          while_loop '$counter < 3' do
            change_variable :counter, to: '$counter + 1'
          end
          return_value '$counter'
        end
        microflow :DeleteAll do
          retrieve_objects 'Clinic.Animal', as: :animals, limit: 1
          delete :animals
        end
        microflow :ExternalFailure do
          create_object 'Clinic.Animal', as: :animal
          call_java 'Clinic.External'
        end
        microflow :CommittedFailure do
          create_object 'Clinic.Animal', as: :animal, commit: true
          call_java 'Clinic.External'
        end
      end
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @mpr = File.join(root, 'Clinic.mpr')
      build_project(@mpr)
      @project = Mxrb::Model::Project.open(@mpr)
      @interpreter = described_class::Interpreter.new(@project)
      example.run
    ensure
      @project&.close
    end
  end

  it 'executes variables, CRUD, retrieve, aggregate, calls, decisions, and logs' do
    expect(@interpreter.call('Clinic.SeedAndCount')).to eq(1)
    expect(@interpreter.store.count('Clinic.Animal')).to eq(1)
    expect(@interpreter.store.retrieve('Clinic.Animal').first.members).to include('Name' => 'Updated')
    expect(@interpreter.log).to eq(['seeded'])
    expect(@interpreter.call('Clinic.CallChild')).to eq('child')
    expect(@interpreter.call('Clinic.Choose', 'Flag' => true)).to eq('yes')
    expect(@interpreter.call('Clinic.Choose', 'Flag' => false)).to eq('no')
    expect(@interpreter.call('Clinic.Loop')).to eq(3)
    expect(@interpreter.call('Clinic.DeleteAll')).to be_nil
    expect(@interpreter.store.count('Clinic.Animal')).to eq(0)
  end

  it 'rolls back a failed call and rejects unsupported or malformed execution' do
    expect { @interpreter.call('Clinic.ExternalFailure') }
      .to raise_error(Mxrb::NativeRuntimeError, /Java Custom Action Clinic\.External is not registered/)
    expect(@interpreter.store.count('Clinic.Animal')).to eq(0)
    expect { @interpreter.call('Clinic.CommittedFailure') }
      .to raise_error(Mxrb::NativeRuntimeError, /Java Custom Action Clinic\.External is not registered/)
    expect(@interpreter.store.count('Clinic.Animal')).to eq(0)
    expect { @interpreter.call('Clinic.Missing') }
      .to raise_error(Mxrb::NativeRuntimeError, /not found/)
    expect { @interpreter.call('Clinic.Choose') }
      .to raise_error(Mxrb::NativeRuntimeError, /missing argument Flag/)
  end

  it 'uses the real MPR root call as a unit of work and keeps returned values detached' do
    created = @interpreter.call('Clinic.CreateWithoutCommit')
    expect(created.members['Name']).to eq('detached')
    expect(@interpreter.store.retrieve('Clinic.Animal')).to be_empty

    expect(@interpreter.call('Clinic.SeedAndCount')).to eq(1)
    changed = @interpreter.call('Clinic.ChangeWithoutCommit')
    expect(changed.members['Name']).to eq('detached change')
    durable_values = @interpreter.store.retrieve('Clinic.Animal')
    expect(durable_values.size).to eq(1)
    durable = durable_values.fetch(0)
    expect(durable.members['Name']).to eq('Updated')
    expect(durable).not_to equal(changed)

    commit_then_change = @interpreter.call('Clinic.CommitThenChangeWithoutCommit')
    expect(commit_then_change.members['Name']).to eq('detached after commit')
    published = @interpreter.store.retrieve('Clinic.Animal').find do |object|
      object.id == commit_then_change.id
    end
    expect(published.members['Name']).to eq('published')

    transient = @interpreter.call('Clinic.CreateTransientWithoutCommit')
    expect(transient.members['Value']).to eq('session-local')
    expect(@interpreter.store.retrieve('Clinic.Scratch')).to include(transient)
  end

  it 'runs functional definitions and emits compatible results and reports' do
    definition = Mxrb::Functional::Definition.new([
      Mxrb::Functional::TestCase.new(
        'native CRUD', 'Clinic.SeedAndCount', {}, 1.0, '1',
        [Mxrb::Functional::CountExpectation.new('Clinic.Animal', nil, 1)]
      ),
      Mxrb::Functional::TestCase.new('native decision', 'Clinic.Choose', { 'Flag' => 'true' }, 1.0, "'yes'"),
      Mxrb::Functional::TestCase.new('expected failure', 'Clinic.Child', {}, 1.0, "'other'")
    ].freeze)
    output = StringIO.new
    execution = described_class::Executor.new(@mpr, definition, output:).run

    expect(execution.result.tests.map(&:passed?)).to eq([true, true, false])
    expect(execution.runtime_output).to include(
      '[MXRB_TEST] PASS native CRUD', '[MXRB_TEST] FAIL expected failure', '[MXRB_TEST] DONE'
    )
    expect(output.string).to eq(execution.runtime_output)
    expect(execution.build_output).to eq('Ruby microflow interpreter')
  end

  it 'is available through mxrb test --native without Java or mxbuild' do
    suite = File.join(@root, 'functional.rb')
    File.write(suite, <<~RUBY)
      microflow "native", call: "Clinic.SeedAndCount",
                expect: { return: 1, count: { entity: "Clinic.Animal", equals: 1 } }
    RUBY
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__),
      'test', @mpr, suite, '--native'
    )
    expect(status).to be_success, stderr
    expect(stdout).to include('[pass] native', '1/1 passed')
  end

  it 'evaluates scalar, object, comparison, and boolean Mendix expressions' do
    expression = described_class::Expression.new
    animal = described_class::ObjectValue.new(entity: 'Clinic.Animal', id: '1', members: { 'Name' => 'Ada' })
    owner = described_class::ObjectValue.new(entity: 'Clinic.Owner', id: '2', members: {})
    animal.members['Animal_Owner'] = owner
    variables = { 'animal' => animal, 'owner' => owner, 'number' => 2, 'text' => 'Ada' }

    expect(expression.evaluate(nil, variables)).to be_nil
    expect(expression.evaluate({ 'Value' => 'false' }, variables)).to be(false)
    expect(expression.evaluate({ 'Expression' => '1.5' }, variables)).to eq(1.5)
    expect(expression.evaluate("'it''s'", variables)).to eq("it's")
    expect(expression.evaluate('$animal', variables)).to eq(animal)
    expect(expression.evaluate('$animal/Clinic.Animal.Name', variables)).to eq('Ada')
    expect(expression.evaluate('($number >= 2) and ($text != \'Bob\')', variables)).to be(true)
    expect(expression.evaluate('$number < 2 or $text = \'Ada\'', variables)).to be(true)
    expect(expression.evaluate("substring('abcdef', 1, 3) + toString($number)", variables)).to eq('bcd2')
    expect(expression.evaluate("find('abcdef', 'cd')", variables)).to eq(2)
    expect(expression.evaluate('round(2.6) * 3 + parseInteger(\'4\')', variables)).to eq(13)
    expect(expression.evaluate("formatDateTime([%CurrentDateTime%], 'yyyy')", variables)).to match(/\A\d{4}\z/)
    expect(expression.evaluate(
             "(Clinic.Animal_Owner = $owner and Name = 'Ada')", variables, node: animal
           )).to be(true)
    expect(expression.evaluate('Clinic.Status.Active', variables, node: animal)).to eq('Clinic.Status.Active')
    expect { expression.evaluate('$missing', variables) }.to raise_error(Mxrb::NativeRuntimeError, /unknown variable/)
    expect { expression.evaluate('$text/Name', variables) }.to raise_error(Mxrb::NativeRuntimeError, /not an object/)
    expect { expression.evaluate('now()', variables) }.to raise_error(Mxrb::NativeRuntimeError, /unsupported/)
  end

  it 'covers transactional store helpers and native aggregate semantics' do
    store = described_class::Store.new(defaults: { 'Clinic.Animal' => { 'Active' => false } })
    first = store.create('Clinic.Animal')
    second = store.create('Clinic.Animal')
    expect(first.members).to include('Active' => false)
    first.members['Age'] = 2
    second.members['Age'] = 4
    expect(store.count('Clinic.Animal', ->(item) { item.members['Age'] > 2 })).to eq(1)

    snapshot = store.snapshot
    first.members['Age'] = 9
    store.delete(first)
    store.restore(snapshot)
    expect(store.retrieve('Clinic.Animal').map { _1.members['Age'] }).to eq([2, 4])
    expect(store.find('Clinic.Animal', first.id)&.members&.fetch('Age')).to eq(2)
    expect(store.find('Clinic.Animal', 'missing')).to be_nil

    owner = store.create('Clinic.Owner')
    restored_first = store.retrieve('Clinic.Animal').first
    restored_first.members['Animal_Owner'] = owner
    expect(store.retrieve_association('Animal_Owner', owner)).to eq([restored_first])
    expect(store.retrieve_association('Clinic.Animal_Owner', owner)).to eq([restored_first])

    transient_store = described_class::Store.new(transient_entities: ['Clinic.Scratch'])
    transient_events = []
    %i[before_delete after_delete].each do |event|
      transient_store.on('Clinic.Scratch', event) { transient_events << event }
    end
    transient = transient_store.create('Clinic.Scratch')
    transient.members['Value'] = 'committed in memory'
    transient_store.commit(transient)
    returned = transient_store.transaction do
      transient.members['Value'] = 'session-local change'
      transient
    end
    expect(returned.members['Value']).to eq('session-local change')
    expect(transient_store.retrieve('Clinic.Scratch')).to eq([transient])
    transient_store.delete(transient, events: false)
    expect(transient_events).to be_empty

    expect(@interpreter.send(:aggregate, :sum, [2, nil, 4])).to eq(6)
    expect(@interpreter.send(:aggregate, :minimum, [2, 4])).to eq(2)
    expect(@interpreter.send(:aggregate, :maximum, [2, 4])).to eq(4)
    expect(@interpreter.send(:aggregate, :average, [2, 4])).to eq(3.0)
    expect(@interpreter.send(:aggregate, :average, [])).to be_nil
    expect { @interpreter.send(:aggregate, :median, [2, 4]) }
      .to raise_error(Mxrb::NativeRuntimeError, /unsupported aggregate/)
  end

  it 'fails deterministically for malformed graphs and unsupported activity documents' do
    flow = Struct.new(:name, :objects, :flows)
    expect { @interpreter.send(:execute, flow.new('Empty', [], []), {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /no start event/)

    allow(@interpreter).to receive(:identifier) do |value|
      value.is_a?(Hash) ? (value['id'] || value.dig('$ID', 'id')) : value
    end
    start = { '$Type' => 'Microflows$StartEvent', 'id' => 'start' }
    expect { @interpreter.send(:execute, flow.new('Stopped', [start], []), {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /stops at/)
    edge = { 'OriginPointer' => 'start', 'DestinationPointer' => 'missing' }
    expect { @interpreter.send(:execute, flow.new('Broken', [start], [edge]), {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /missing object/)
    loop_edge = { 'OriginPointer' => 'start', 'DestinationPointer' => 'start' }
    expect { @interpreter.send(:execute, flow.new('Loop', [start], [loop_edge]), {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /exceeded 10000 steps/)
    expect { @interpreter.send(:execute_action, nil, {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /has no action/)
    expect do
      @interpreter.send(
        :action_retrieve,
        { 'RetrieveSource' => { '$Type' => 'Microflows$AssociationRetrieveSource' } }, {}
      )
    end.to raise_error(Mxrb::NativeRuntimeError, /unsupported retrieve source/)
    expect do
      @interpreter.send(:action_retrieve, {
        'RetrieveSource' => {
          '$Type' => 'Microflows$DatabaseRetrieveSource',
          'NewSortings' => { 'Sortings' => [{ 'SortOrder' => 'Ascending' }] }
        }
      }, {})
    end.to raise_error(Mxrb::NativeRuntimeError, /sorting/)
  end

  it 'executes pure-Ruby UI, client, validation, list, REST, and adapter actions' do
    animal = @interpreter.store.create('Clinic.Animal')
    variables = { 'animal' => animal, 'items' => [1, 2, 3], 'other' => [3, 4] }
    text = {
      'Text' => { 'Items' => [2, { 'LanguageCode' => 'en_US', 'Text' => 'Hello {1}' }] },
      'Parameters' => [2, { 'Expression' => "'Ruby'" }]
    }
    @interpreter.send(:action_show_message, {
      'Template' => text, 'Type' => 'Information', 'Blocking' => true
    }, variables)
    @interpreter.send(:action_validation_feedback, {
      'ValidationVariableName' => 'animal', 'Attribute' => 'Clinic.Animal.Name',
      'FeedbackTemplate' => text
    }, variables)
    @interpreter.send(:action_java_script_action_call, {
      'JavaScriptAction' => 'Client.Copy', 'OutputVariableName' => 'client'
    }, variables)
    @interpreter.send(:action_nanoflow_call, {
      'NanoflowCall' => { 'Nanoflow' => 'Clinic.ClientFlow' }, 'OutputVariableName' => 'nano'
    }, variables)

    expect(@interpreter.effects).to include(
      include(type: 'show_message', message: 'Hello Ruby', blocking: true),
      include(type: 'validation_feedback', member: 'Name', message: 'Hello Ruby'),
      include(type: 'javascript', name: 'Client.Copy'), include(type: 'nanoflow')
    )
    expect(variables).to include('client' => nil, 'nano' => nil)

    expect(@interpreter.send(:list_operation, 'Microflows$Head', variables['items'], nil, nil, variables)).to eq(1)
    expect(@interpreter.send(:list_operation, 'Microflows$Tail', variables['items'], nil, nil, variables)).to eq([2, 3])
    expect(@interpreter.send(:list_operation, 'Microflows$Union', variables['items'], variables['other'], nil,
                             variables)).to eq([1, 2, 3, 4])
    expect(@interpreter.send(:list_operation, 'Microflows$Intersect', variables['items'], variables['other'], nil,
                             variables)).to eq([3])
    expect(@interpreter.send(:list_operation, 'Microflows$Subtract', variables['items'], variables['other'], nil,
                             variables)).to eq([1, 2])
    expect(@interpreter.send(:list_operation, 'Microflows$Contains', variables['items'], 2, nil, variables)).to be(true)
    expect { @interpreter.send(:list_operation, 'Microflows$Unknown', [], nil, nil, {}) }
      .to raise_error(Mxrb::NativeRuntimeError, /unsupported list operation/)

    response = Struct.new(:code, :body).new('200', '{"Name":"Remote"}')
    interpreter = described_class::Interpreter.new(
      @project,
      adapters: {
        app_service: ->(_name, _document, _variables) { 'service-result' },
        web_service: ->(_name, _document, _variables) { 'soap-result' },
        import_xml: ->(_name, _document, _variables) { 'xml-result' },
        document: ->(_name, _document, _variables) { 'document-result' },
        import_mapping: ->(_name, _document, _variables) { 'import-result' },
        export_mapping: ->(_name, _document, _variables) { 'export-result' }
      },
      http: ->(*_arguments) { response }
    )
    rest_variables = {}
    interpreter.send(:action_rest_call, {
      'HttpConfiguration' => {
        'HttpMethod' => 'Get',
        'CustomLocationTemplate' => { 'Text' => 'https://example.test/animals' },
        'HttpHeaderEntries' => [2, { 'Key' => 'Accept', 'Value' => 'application/json' }]
      },
      'RequestHandling' => {},
      'ResultHandling' => {
        'Bind' => true, 'ResultVariableName' => 'remote',
        'VariableType' => { 'Entity' => 'Clinic.Animal' }
      }
    }, rest_variables)
    expect(rest_variables.fetch('remote').members).to include('Name' => 'Remote')
    interpreter.send(:action_app_service_call, {
      'AppServiceAction' => 'Remote.Service', 'ResultVariableName' => 'service'
    }, rest_variables)
    expect(rest_variables['service']).to eq('service-result')
    {
      action_call_web_service: ['WebServiceCall', 'Soap.Operation', 'soap', 'soap-result'],
      action_import_xml: ['ImportMapping', 'Xml.Import', 'xml', 'xml-result'],
      action_generate_document: ['DocumentTemplate', 'Docs.Invoice', 'document', 'document-result'],
      action_import_mapping_java: ['ImportMapping', 'Json.Import', 'import', 'import-result'],
      action_export_mapping_java: ['ExportMapping', 'Json.Export', 'export', 'export-result']
    }.each do |method, (key, name, result_name, expected)|
      interpreter.send(method, { key => name, 'ResultVariableName' => result_name }, rest_variables)
      expect(rest_variables[result_name]).to eq(expected)
    end
    interpreter.send(:action_download_file, {
      'FileDocumentVariableName' => 'remote', 'ShowFileInBrowser' => true
    }, rest_variables)
    interpreter.send(:action_show_home_page, {}, rest_variables)
    interpreter.send(:action_empty, {}, rest_variables)
    expect(interpreter.effects).to include(
      include(type: :download_file, show_in_browser: true), include(type: :show_home_page)
    )
    expect do
      interpreter.send(:action_java_action_call, { 'JavaAction' => 'Legacy.Custom' }, {})
    end.to raise_error(Mxrb::NativeRuntimeError, /Legacy\.Custom is not registered/)
  end

  it 'follows modeled error-handler sequence flows' do
    flow = Struct.new(:name, :objects, :flows)
    start = { '$ID' => 'start', '$Type' => 'Microflows$StartEvent' }
    action = {
      '$ID' => 'action', '$Type' => 'Microflows$ActionActivity',
      'Action' => { '$Type' => 'Microflows$UnsupportedAction', 'ErrorHandlingType' => 'Rollback' }
    }
    ending = { '$ID' => 'end', '$Type' => 'Microflows$EndEvent', 'ReturnValue' => "'handled'" }
    edges = [
      { 'OriginPointer' => 'start', 'DestinationPointer' => 'action' },
      { 'OriginPointer' => 'action', 'DestinationPointer' => 'end', 'IsErrorHandler' => true }
    ]

    allow(@interpreter.store).to receive(:snapshot).and_call_original
    expect(@interpreter.send(:execute, flow.new('Handled', [start, action, ending], edges), {}))
      .to eq('handled')
    expect(@interpreter.store).to have_received(:snapshot).once
  end

  it 'does not snapshot the store for ordinary action activities' do
    flow = Struct.new(:name, :objects, :flows)
    start = { '$ID' => 'start', '$Type' => 'Microflows$StartEvent' }
    action = {
      '$ID' => 'action', '$Type' => 'Microflows$ActionActivity',
      'Action' => { '$Type' => 'Microflows$EmptyAction', 'ErrorHandlingType' => 'None' }
    }
    ending = { '$ID' => 'end', '$Type' => 'Microflows$EndEvent', 'ReturnValue' => "'done'" }
    edges = [
      { 'OriginPointer' => 'start', 'DestinationPointer' => 'action' },
      { 'OriginPointer' => 'action', 'DestinationPointer' => 'end' }
    ]
    allow(@interpreter.store).to receive(:snapshot).and_call_original

    expect(@interpreter.send(:execute, flow.new('Ordinary', [start, action, ending], edges), {}))
      .to eq('done')
    expect(@interpreter.store).not_to have_received(:snapshot)
  end

  it 'filters and sorts database retrieves and XPath counts' do
    [['Ada', 4, true], ['Bob', 2, false], ['Cal', 4, true]].each do |name, age, active|
      animal = @interpreter.store.create('Clinic.Animal')
      animal.members.update('Name' => name, 'Age' => age, 'Active' => active)
    end
    variables = { 'minimum' => 3 }
    retrieve = {
      'RetrieveSource' => {
        '$Type' => 'Microflows$DatabaseRetrieveSource', 'Entity' => 'Clinic.Animal',
        'XpathConstraint' => '[Age >= $minimum][Active]',
        'NewSortings' => { 'Sortings' => [
          { 'AttributePath' => 'Clinic.Animal.Age', 'SortOrder' => 'Descending' },
          { 'AttributeRef' => { 'Attribute' => 'Clinic.Animal.Name' }, 'SortOrder' => 'Ascending' }
        ] }
      },
      'ResultVariableName' => 'animals'
    }

    @interpreter.send(:action_retrieve, retrieve, variables)
    expect(variables['animals'].map { _1.members['Name'] }).to eq(%w[Ada Cal])
    expect(@interpreter.count('Clinic.Animal', "[Name = 'Bob']")).to eq(1)
    expect(@interpreter.count('Clinic.Animal', '[Active = true or Age < 3]')).to eq(3)
    expect do
      @interpreter.count('Clinic.Animal', "//Clinic.Animal[Name = 'Ada']")
    end.to raise_error(Mxrb::NativeRuntimeError, /unsupported native XPath/)

    expression = described_class::Expression.new
    expect(expression.evaluate('4 > 3', {})).to be(true)
    expect(expression.evaluate('3 <= 3', {})).to be(true)
    expect(expression.send(:matching_parenthesis, '(missing', 0)).to be_nil
    expect(expression.send(:matching_parenthesis, 'x()', 1)).to eq(2)
    equal = described_class::ObjectValue.new(entity: 'Clinic.Animal', id: 'equal', members: { 'Age' => 4 })
    expect(@interpreter.send(:compare_by_keys, equal, equal, [['Age', false]])).to eq(0)
    expect(@interpreter.send(:compare_members, nil, nil)).to eq(0)
    expect(@interpreter.send(:compare_members, nil, 1)).to eq(1)
    expect(@interpreter.send(:compare_members, 1, nil)).to eq(-1)
  end

  it 'handles lower-level graph cases, mutations, templates, and collection encodings' do
    animal = described_class::ObjectValue.new(entity: 'Clinic.Animal', id: '1', members: {})
    split = { '$Type' => 'Microflows$InheritanceSplit', 'SplitVariableName' => 'value' }
    expect(@interpreter.send(:split_value, split, 'value' => animal)).to eq('Clinic.Animal')
    expect(@interpreter.send(:split_value, split, 'value' => 'text')).to eq('String')
    expect(@interpreter.send(:flow_case, 'CaseValues' => [{ '$Type' => 'Microflows$NoCase' }])).to eq('')

    variables = {}
    @interpreter.send(:action_create_variable, { 'VariableName' => 'x', 'InitialValue' => '1' }, variables)
    @interpreter.send(:action_change_variable, { 'ChangeVariableName' => 'x', 'Value' => '2' }, variables)
    expect(variables).to eq('x' => 2)
    expect(@interpreter.send(:render_template, nil, variables)).to eq('')
    template = { 'Text' => 'value={1}', 'Parameters' => [{ 'Expression' => '$x' }] }
    expect(@interpreter.send(:render_template, template, variables)).to eq('value=2')
    allow(Mxrb::IO::BsonCodec).to receive(:parse_array).and_raise(ArgumentError)
    expect(@interpreter.send(:items, [1, 'a'])).to eq(['a'])
    expect(@interpreter.send(:items, ['a'])).to eq(['a'])
  end

  it 'supports executor hooks, failure details, optional output, and portable clocks' do
    hook = Mxrb::Functional::Hook.new('Clinic.Child', {})
    seed_hook = Mxrb::Functional::Hook.new('Clinic.SeedAndCount', {})
    definition = Mxrb::Functional::Definition.new([
      Mxrb::Functional::TestCase.new('hooks', 'Clinic.Child', {}, 1.0, nil, [], hook, hook),
      Mxrb::Functional::TestCase.new(
        'bad count', 'Clinic.Child', {}, 1.0, nil,
        [Mxrb::Functional::CountExpectation.new('Clinic.Animal', nil, 2)]
      ),
      Mxrb::Functional::TestCase.new(
        'xpath count', 'Clinic.Child', {}, 1.0, nil,
        [Mxrb::Functional::CountExpectation.new('Clinic.Animal', "[Name = 'Updated']", 1)], seed_hook
      ),
      Mxrb::Functional::TestCase.new('runtime error', 'Clinic.Missing', {}, 1.0)
    ].freeze)
    calls = 0
    clock = lambda do |*arguments|
      raise ArgumentError unless arguments.empty?

      calls += 1
      calls.to_f
    end
    execution = described_class::Executor.new(@mpr, definition, clock:).run
    expect(execution.result.tests.map(&:passed?)).to eq([true, false, true, false])
    expect(execution.result.tests[1].message).to include('count 0, expected 2')
    expect(execution.result.tests[2].message).to eq('passed')
    expect(execution.result.tests[3].message).to include('not found')
    expect(execution.elapsed).to eq(1.0)
  end

  it 'covers optional native activity fields and opening failures' do
    variables = {}
    retrieve = {
      'RetrieveSource' => {
        '$Type' => 'Microflows$DatabaseRetrieveSource', 'Entity' => 'Clinic.Animal',
        'Range' => { 'LimitExpression' => '1' }
      },
      'ResultVariableName' => 'animals'
    }
    2.times { @interpreter.store.create('Clinic.Animal') }
    @interpreter.send(:action_retrieve, retrieve, variables)
    expect(variables['animals'].size).to eq(1)
    retrieve['RetrieveSource']['Range'] = { 'SingleObject' => true }
    retrieve['ResultVariableName'] = 'animal'
    @interpreter.send(:action_retrieve, retrieve, variables)
    expect(variables['animal']).to be_a(described_class::ObjectValue)

    variables['animals'].first.members['Age'] = 4
    aggregate = {
      'AggregateVariableName' => 'animals', 'Attribute' => 'Clinic.Animal.Age',
      'AggregateFunction' => 'sum', 'VariableName' => 'total'
    }
    @interpreter.send(:action_aggregate, aggregate, variables)
    expect(variables['total']).to eq(4)

    object = variables['animals'].first
    change = [{ 'Association' => 'Clinic.Animal_Owner', 'Value' => "'owner'" }]
    @interpreter.send(:apply_changes, object, change, variables)
    expect(object.members['Animal_Owner']).to eq('owner')

    allow(@interpreter).to receive(:call) do |name, arguments|
      expect([name, arguments]).to eq(['Clinic.Child', { 'Value' => 2 }])
      'ignored'
    end
    action = {
      'MicroflowCall' => {
        'Microflow' => 'Clinic.Child',
        'ParameterMappings' => [{ 'Parameter' => 'Clinic.Child.Value', 'Argument' => '2' }]
      },
      'UseReturnVariable' => false, 'ResultVariableName' => 'unused'
    }
    @interpreter.send(:action_microflow_call, action, variables)
    expect(variables).not_to have_key('unused')

    flow = Struct.new(:parameters).new([nil, { 'Name' => 'Value' }])
    expect(@interpreter.send(:normalize_arguments, flow, 'Value' => 2)).to eq('Value' => 2)
    missing = described_class::Executor.new(File.join(@root, 'missing.mpr'), Mxrb::Functional::Definition.new([]))
    expect { missing.run }.to raise_error(Mxrb::Error)
  end

  it 'covers lifecycle hooks, action aliases, adapters, rollback, and transport alternatives' do
    events = []
    store = described_class::Store.new
    expect { store.on('Clinic.Animal', :unknown) {} }.to raise_error(ArgumentError, /unknown lifecycle/)
    expect { store.on('Clinic.Animal', :before_commit) }.to raise_error(ArgumentError, /callback/)
    described_class::Store::LIFECYCLE_EVENTS.each do |event|
      store.on('Clinic.Animal', event) { |value| events << [event, value.id] }
    end
    animal = store.create('Clinic.Animal', events: false)
    store.commit(animal)
    animal.members['Name'] = 'changed'
    store.commit(animal)
    store.delete(animal)
    expect(events.map(&:first)).to eq(
      %i[before_create before_commit after_commit after_create
         before_update before_commit after_commit after_update before_delete after_delete]
    )
    restored = store.create('Clinic.Animal')
    restored.members['Name'] = 'saved'
    store.commit(restored)
    restored.members['Name'] = 'dirty'
    expect(store.rollback(restored).members['Name']).to eq('saved')
    fresh = store.create('Clinic.Animal')
    store.rollback(fresh)
    expect(store.retrieve('Clinic.Animal')).not_to include(fresh)
    expect { store.create('Clinic.Animal', events: :invalid) }.to raise_error(ArgumentError, /boolean/)

    object = @interpreter.store.create('Clinic.Animal')
    variables = { 'animal' => object, 'items' => [1, 2, 3] }
    @interpreter.send(:commit_for_action, { 'Commit' => { 'Value' => 'YesWithoutEvents' } }, object)
    object.members['Name'] = 'dirty'
    @interpreter.send(:action_rollback, { 'RollbackVariableName' => 'animal' }, variables)
    @interpreter.send(:action_list_operations, {
      'NewOperation' => { '$Type' => 'Microflows$Head', 'ListName' => 'items' },
      'ResultVariableName' => 'head'
    }, variables)
    expect(variables['head']).to eq(1)
    expect(@interpreter.send(:list_operation, 'Microflows$Find', [object], nil, 'true', variables)).to eq(object)
    expect(@interpreter.send(:list_operation, 'Microflows$Filter', [object], nil, 'true', variables)).to eq([object])
    expect(@interpreter.send(
             :list_operation, 'Microflows$Sort', [object],
             [{ 'AttributePath' => 'Clinic.Animal.Name' }], nil, variables
           )).to eq([object])

    rest = described_class::Interpreter.new(
      @project, http: ->(*_args) { Struct.new(:code, :body).new('500', '{}') }
    )
    expect do
      rest.send(:action_rest_call, {
        'HttpConfiguration' => {
          'HttpMethod' => 'Get', 'CustomLocationTemplate' => { 'Text' => 'https://example.test' }
        }
      }, {})
    end.to raise_error(Mxrb::NativeRuntimeError, /HTTP 500/)
    expect do
      @interpreter.send(:invoke_adapter, :missing, 'x', {}, {}, result_name: '')
    end.to raise_error(Mxrb::NativeRuntimeError, /adapter is not configured/)
    expect(@interpreter.send(:runtime_json, object)).to be_a(Hash)
    expect(@interpreter.send(:runtime_json, { one: [object] })).to include(one: [kind_of(Hash)])
    expect(@interpreter.send(:render_text_template, { 'Text' => 'plain' }, {})).to eq('plain')
    java_action_handlers = %i[
      action_java_action action_basic_java action_basic_code action_entity_type_java action_microflow_java
    ]
    java_action_handlers.each do |name|
      expect { @interpreter.send(name, {}, {}) }.to raise_error(Mxrb::NativeRuntimeError, /Java Custom Action/)
    end
  end

  it 'normalizes lifecycle arguments and wraps low-level REST failures' do
    object = @interpreter.store.create('Clinic.Animal')
    expect(@interpreter.send(:qualify_flow, 'Clinic', 'Child')).to eq('Clinic.Child')
    expect(@interpreter.send(:qualify_flow, 'Clinic', 'Clinic.Child')).to eq('Clinic.Child')
    expect(@interpreter.send(
             :lifecycle_arguments, 'Clinic.Choose', object, pass_event_object: true
           )).to eq('Flag' => object)
    expect(@interpreter.send(
             :lifecycle_arguments, 'Clinic.Choose', object, pass_event_object: false
           )).to eq({})

    error_event = { '$Type' => 'Microflows$ErrorEvent', 'ErrorExpression' => "'boom'" }
    expect do
      @interpreter.send(:execute_collection, [error_event], {}, {}, label: 'event')
    end.to raise_error(Mxrb::NativeRuntimeError, 'boom')

    invalid_json = described_class::Interpreter.new(
      @project, http: ->(*_args) { Struct.new(:code, :body).new('200', '{') }
    )
    expect do
      invalid_json.send(:action_rest_call, {
        'HttpConfiguration' => {
          'HttpMethod' => 'Get', 'CustomLocationTemplate' => { 'Text' => 'https://example.test' }
        },
        'ResultHandling' => { 'Bind' => true, 'ResultVariableName' => 'result' }
      }, {})
    end.to raise_error(Mxrb::NativeRuntimeError, /REST call failed/)
  end

  it 'builds HTTP requests with headers, bodies, SSL, and timeout defaults' do
    transport = double(:transport)
    allow(transport).to receive(:request) { |request| request }
    allow(Net::HTTP).to receive(:start).and_yield(transport)

    plain = @interpreter.send(:http_request, 'GET', 'http://example.test/path', { 'X-Test' => 'yes' }, nil, nil)
    expect(plain['X-Test']).to eq('yes')
    expect(Net::HTTP).to have_received(:start).with(
      'example.test', 80, use_ssl: false, open_timeout: 10, read_timeout: 30
    )

    secure = @interpreter.send(:http_request, 'POST', 'https://example.test/path', {}, '{}', 2)
    expect(secure.body).to eq('{}')
    expect(Net::HTTP).to have_received(:start).with(
      'example.test', 443, use_ssl: true, open_timeout: 2, read_timeout: 2
    )
  end

  it 'covers native store fallbacks, lifecycle defenses, and non-rollback handlers' do
    store = described_class::Store.new
    object = store.create('Clinic.Animal')
    expect { store.send(:run_hooks, :unknown, object) }
      .to raise_error(ArgumentError, /unknown lifecycle event/)

    attribute = Struct.new(:type, :default_value).new(:enumeration, '')
    expect(@interpreter.send(:attribute_default, attribute)).to be_nil

    no_hooks = described_class::Interpreter.allocate
    no_hooks.instance_variable_set(:@store, Object.new)
    expect(no_hooks.send(:register_model_lifecycle)).to be_nil

    lifecycle_entity = Struct.new(:name, :lifecycle)
    plain_entity = Struct.new(:name).new('Plain')
    callbacks = [
      { event: :unsupported, handler: 'Ignored' },
      { event: :before_commit, handler: 'Validate', raise_error_on_false: false }
    ]
    mod = Struct.new(:name, :entities).new(
      'Clinic', [plain_entity, lifecycle_entity.new('Animal', callbacks)]
    )
    lifecycle = described_class::Interpreter.allocate
    lifecycle_store = described_class::Store.new
    lifecycle.instance_variable_set(:@project, Struct.new(:modules).new([mod]))
    lifecycle.instance_variable_set(:@store, lifecycle_store)
    lifecycle.instance_variable_set(:@flows, {})
    allow(lifecycle).to receive(:call).with('Clinic.Validate', {}).and_return(true)
    lifecycle.send(:register_model_lifecycle)
    lifecycle_store.commit(lifecycle_store.create('Clinic.Animal'))
    expect(lifecycle).to have_received(:call).with('Clinic.Validate', {})

    action = {
      '$ID' => 'action', '$Type' => 'Microflows$ActionActivity',
      'Action' => { '$Type' => 'Microflows$UnsupportedAction', 'ErrorHandlingType' => 'Continue' }
    }
    flow = Struct.new(:name, :objects, :flows)
    objects = [
      { '$ID' => 'start', '$Type' => 'Microflows$StartEvent' }, action,
      { '$ID' => 'end', '$Type' => 'Microflows$EndEvent', 'ReturnValue' => "'continued'" }
    ]
    edges = [
      { 'OriginPointer' => 'start', 'DestinationPointer' => 'action' },
      { 'OriginPointer' => 'action', 'DestinationPointer' => 'end', 'IsErrorHandler' => true }
    ]
    expect(@interpreter.send(:execute, flow.new('Continue', objects, edges), {})).to eq('continued')

    wrapper = Class.new do
      attr_reader :restored

      def initialize
        @store = Mxrb::Runtime::Native::Store.new
        @restored = false
      end

      def snapshot = @store.snapshot

      def restore(snapshot)
        @restored = true
        @store.restore(snapshot)
      end

      def method_missing(name, *arguments, **keywords, &block)
        @store.public_send(name, *arguments, **keywords, &block)
      end

      def respond_to_missing?(name, include_private = false)
        name != :transaction && @store.respond_to?(name, include_private)
      end
    end.new
    fallback = described_class::Interpreter.new(@project, store: wrapper)
    expect(fallback.call('Clinic.Child')).to eq('child')
    expect { fallback.call('Clinic.ExternalFailure') }
      .to raise_error(Mxrb::NativeRuntimeError, /Java Custom Action/)
    expect(wrapper.restored).to be(true)
  end

  it 'covers optional commit, REST, adapter, validation, and template branches' do
    passive_store = Object.new
    passive = described_class::Interpreter.allocate
    passive.instance_variable_set(:@store, passive_store)
    passive.send(:action_commit, { 'CommitVariableName' => 'item' }, 'item' => Object.new)
    passive.send(:action_rollback, { 'RollbackVariableName' => 'item' }, 'item' => Object.new)
    expect(passive.send(:action_events, 'Commit' => { 'Value' => 'YesWithoutEvents' })).to be(false)

    animal = @interpreter.store.create('Clinic.Animal')
    @interpreter.send(:action_validation_feedback, {
      'ValidationVariableName' => 'animal', 'Association' => 'Clinic.Animal_Owner',
      'FeedbackTemplate' => { 'Text' => 'Owner is required' }
    }, 'animal' => animal)
    expect(@interpreter.effects.last).to include(member: 'Animal_Owner')

    response = Struct.new(:code, :body).new('200', '{"ok":true}')
    calls = []
    rest = described_class::Interpreter.new(
      @project, http: lambda { |*arguments|
        calls << arguments
        response
      }
    )
    variables = { 'payload' => { value: 1 } }
    rest.send(:action_rest_call, {
      'HttpConfiguration' => {
        'HttpMethod' => 'Post', 'CustomLocationTemplate' => { 'Text' => 'https://example.test' }
      },
      'RequestHandling' => { 'MappingVariableName' => 'payload' },
      'UseRequestTimeOut' => true, 'TimeOutExpression' => '2',
      'ResultHandling' => { 'Bind' => false }
    }, variables)
    expect(calls.last).to include('Post', 'https://example.test', {}, '{"value":1}', 2)
    rest.send(:bind_rest_result, {
      'Bind' => true, 'ResultVariableName' => 'raw'
    }, '{"ok":true}', variables)
    expect(variables['raw']).to eq('ok' => true)

    adapted = described_class::Interpreter.new(
      @project, adapters: { nanoflow: ->(*) { 'adapter-result' } }
    )
    adapted_variables = {}
    expect(adapted.send(
             :client_action, :nanoflow, 'Clinic.Client', {}, adapted_variables, result_name: ''
           )).to eq('adapter-result')
    expect(adapted_variables).to be_empty
    plain_variables = {}
    @interpreter.send(:client_action, :nanoflow, 'Clinic.Client', {}, plain_variables, result_name: '')
    expect(plain_variables).to be_empty

    expect(@interpreter.send(:render_text_template, nil, {})).to eq('')
    expect(@interpreter.send(:render_text_template, { 'Text' => { 'Items' => [2] } }, {})).to eq('')
  end
end
# rubocop:enable Metrics/BlockLength
