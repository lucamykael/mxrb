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
        microflow :DeleteAll do
          retrieve_objects 'Clinic.Animal', as: :animals, limit: 1
          delete :animals
        end
        microflow :ExternalFailure do
          create_object 'Clinic.Animal', as: :animal
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
    expect(@interpreter.call('Clinic.DeleteAll')).to be_nil
    expect(@interpreter.store.count('Clinic.Animal')).to eq(0)
  end

  it 'rolls back a failed call and rejects unsupported or malformed execution' do
    expect { @interpreter.call('Clinic.ExternalFailure') }
      .to raise_error(Mxrb::NativeRuntimeError, /unsupported activity.*JavaAction/)
    expect(@interpreter.store.count('Clinic.Animal')).to eq(0)
    expect { @interpreter.call('Clinic.Missing') }
      .to raise_error(Mxrb::NativeRuntimeError, /not found/)
    expect { @interpreter.call('Clinic.Choose') }
      .to raise_error(Mxrb::NativeRuntimeError, /missing argument Flag/)
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
    variables = { 'animal' => animal, 'number' => 2, 'text' => 'Ada' }

    expect(expression.evaluate(nil, variables)).to be_nil
    expect(expression.evaluate({ 'Value' => 'false' }, variables)).to be(false)
    expect(expression.evaluate({ 'Expression' => '1.5' }, variables)).to eq(1.5)
    expect(expression.evaluate("'it''s'", variables)).to eq("it's")
    expect(expression.evaluate('$animal', variables)).to eq(animal)
    expect(expression.evaluate('$animal/Clinic.Animal.Name', variables)).to eq('Ada')
    expect(expression.evaluate('($number >= 2) and ($text != \'Bob\')', variables)).to be(true)
    expect(expression.evaluate('$number < 2 or $text = \'Ada\'', variables)).to be(true)
    expect { expression.evaluate('$missing', variables) }.to raise_error(Mxrb::NativeRuntimeError, /unknown variable/)
    expect { expression.evaluate('$text/Name', variables) }.to raise_error(Mxrb::NativeRuntimeError, /not an object/)
    expect { expression.evaluate('now()', variables) }.to raise_error(Mxrb::NativeRuntimeError, /unsupported/)
  end

  it 'covers transactional store helpers and native aggregate semantics' do
    store = described_class::Store.new
    first = store.create('Clinic.Animal')
    second = store.create('Clinic.Animal')
    first.members['Age'] = 2
    second.members['Age'] = 4
    expect(store.count('Clinic.Animal', ->(item) { item.members['Age'] > 2 })).to eq(1)

    snapshot = store.snapshot
    first.members['Age'] = 9
    store.delete(first)
    store.restore(snapshot)
    expect(store.retrieve('Clinic.Animal').map { _1.members['Age'] }).to eq([2, 4])

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
end
# rubocop:enable Metrics/BlockLength
