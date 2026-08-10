# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Native runtime entity security context' do
  it 'round-trips ApplyEntityAccess in microflow model documents' do
    mpr = double
    allow(mpr).to receive(:parse_contents) { _1 }
    enabled = Mxrb::Model::Microflow.new(
      {
        '$ID' => 'flow', '$Type' => 'Microflows$Microflow', 'Name' => 'Run',
        'ApplyEntityAccess' => true, 'ObjectCollection' => { 'Objects' => [] }, 'Flows' => []
      },
      mpr
    )
    disabled = Mxrb::Model::Microflow.new(
      { '$ID' => 'other', '$Type' => 'Microflows$Microflow', 'Name' => 'Other' }, mpr
    )

    expect(enabled.apply_entity_access).to be(true)
    expect(enabled.to_bson).to include('ApplyEntityAccess' => true)
    expect(disabled.apply_entity_access).to be(false)
    expect(disabled.to_bson).to include('ApplyEntityAccess' => false)
  end

  it 'authorizes native create/change/retrieve/commit/delete actions for an active user context' do
    interpreter = Mxrb::Runtime::Native::Interpreter.allocate
    context = Mxrb::Runtime::SecurityContext.new(user: 'ada', module_roles: ['M.User'])
    object = Mxrb::Runtime::Native::ObjectValue.new(entity: 'M.E', id: '1', members: {})
    store = double
    allow(store).to receive_messages(
      create: object, retrieve: [object], commit: object, delete: nil
    )
    policy = double
    allow(policy).to receive_messages(authorize!: true, filter_readable: [object], entity_allowed?: true)
    interpreter.instance_variable_set(:@store, store)
    interpreter.instance_variable_set(:@policy, policy)
    interpreter.instance_variable_set(:@security_context, context)
    interpreter.instance_variable_set(:@apply_entity_access, true)
    interpreter.instance_variable_set(:@expression, Mxrb::Runtime::Native::Expression.new)
    interpreter.instance_variable_set(:@associations, {})

    interpreter.send(
      :action_create_change,
      { 'Entity' => 'M.E', 'VariableName' => 'created', 'Items' => [], 'Commit' => 'No' }, {}
    )
    interpreter.send(:apply_changes, object, [{ 'Attribute' => 'M.E/Name', 'Value' => "'Ada'" }], {})
    variables = { 'record' => object }
    interpreter.send(
      :action_retrieve,
      { 'RetrieveSource' => { '$Type' => 'Microflows$DatabaseRetrieveSource', 'Entity' => 'M.E' },
        'ResultVariableName' => 'records' }, variables
    )
    interpreter.send(:action_commit, { 'CommitVariableName' => 'record' }, variables)
    interpreter.send(:action_delete, { 'DeleteVariableName' => 'record' }, variables)

    expect(object.members['Name']).to eq('Ada')
    expect(policy).to have_received(:filter_readable).with('M.E', [object], context:)
    expect(policy).to have_received(:authorize!).with(
      'M.E', kind: :entity, action: :create, context:, member: nil, record: nil
    )
    expect(policy).to have_received(:authorize!).with(
      'M.E', kind: :entity, action: :write, context:, member: 'Name', record: object
    )
    expect(policy).to have_received(:authorize!).with(
      'M.E', kind: :entity, action: :delete, context:, member: nil, record: object
    )
  end

  it 'inherits context into nested microflows and keeps system calls trusted' do
    Dir.mktmpdir('mxrb-native-security-') do |dir|
      path = File.join(dir, 'Security.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module :M do
          entity(:E) { string :Name }
          microflow :Secured do
            apply_entity_access
            create_object 'M.E', as: :record, set: { Name: "'created'" }
            commit :record
          end
          microflow(:Outer) { call_microflow 'M.Secured' }
        end
      end
      Mxrb.open(path) do |project|
        secured = project.modules.first.microflows.find { _1.name == 'Secured' }
        expect(secured.apply_entity_access).to be(true)
        policy = double
        allow(policy).to receive(:authorize!) do
          raise Mxrb::Runtime::AuthorizationError, 'denied'
        end
        interpreter = Mxrb::Runtime::Native::Interpreter.new(project, policy:)
        context = Mxrb::Runtime::SecurityContext.new(user: 'ada')

        expect { interpreter.call('M.Outer', context:) }
          .to raise_error(Mxrb::Runtime::AuthorizationError, /denied/)
        expect(interpreter.call('M.Outer')).to be_nil
        expect(interpreter.store.count('M.E')).to eq(1)
      end
    end
  end

  it 'filters association retrieval and bypasses policy for trusted system execution' do
    interpreter = Mxrb::Runtime::Native::Interpreter.allocate
    context = Mxrb::Runtime::SecurityContext.new(user: 'ada')
    start = Mxrb::Runtime::Native::ObjectValue.new(entity: 'M.Parent', id: 'p', members: {})
    child = Mxrb::Runtime::Native::ObjectValue.new(entity: 'M.Child', id: 'c', members: {})
    store = double(retrieve_association: [child])
    policy = double(entity_allowed?: false)
    interpreter.instance_variable_set(:@store, store)
    interpreter.instance_variable_set(:@policy, policy)
    interpreter.instance_variable_set(:@security_context, context)
    interpreter.instance_variable_set(:@apply_entity_access, true)
    interpreter.instance_variable_set(:@associations, {})
    variables = { 'parent' => start }
    interpreter.send(
      :action_association_retrieve,
      { 'ResultVariableName' => 'children' },
      { '$Type' => 'Microflows$AssociationRetrieveSource', 'StartVariableName' => 'parent',
        'AssociationId' => 'M.Parent_Child' }, variables
    )
    expect(variables['children']).to eq([])

    interpreter.instance_variable_set(:@security_context, nil)
    expect(interpreter.send(:authorize_entity!, 'M.Child', :delete)).to be(true)
  end

  it 'resolves references without mutation and authorizes explicit synchronized context changes' do
    application = Mxrb::RubyApp::Application.allocate
    object = Mxrb::Runtime::Native::ObjectValue.new(
      entity: 'M.E', id: '1', members: { 'Name' => 'Original' }
    )
    store = double(find: object)
    interpreter = double(store:)
    application.instance_variable_set(:@bridge, double(interpreter:))
    policy = double(authorize!: true)
    application.instance_variable_set(:@access_control, policy)
    payload = { 'id' => '1', 'type' => 'M.E', 'attributes' => { 'Name' => 'Changed' } }

    expect(application.send(:deserialize, payload).members['Name']).to eq('Original')
    expect(application.send(:deserialize, 'id' => '1', 'type' => 'M.E')).to equal(object)
    context = Object.new
    application.send(:deserialize, payload, context:, synchronize: true)
    expect(object.members['Name']).to eq('Changed')
    expect(policy).to have_received(:authorize!).once.with(
      'M.E', kind: :entity, action: :write, context:, member: 'Name', record: object
    )

    detached_store = Object.new
    detached_interpreter = Struct.new(:store).new(detached_store)
    application.instance_variable_set(:@bridge, Struct.new(:interpreter).new(detached_interpreter))
    expect(application.send(:synchronize_context, 1, context:)).to eq(1)

    transactional_store = Class.new do
      def transaction = yield
    end.new
    transactional_interpreter = Struct.new(:store).new(transactional_store)
    application.instance_variable_set(:@bridge, Struct.new(:interpreter).new(transactional_interpreter))
    expect(application.send(:synchronize_context, 2, context:)).to eq(2)
  end

  it 'materializes REST input as a detached authorized object and propagates service context' do
    application = Mxrb::RubyApp::Application.allocate
    store = double
    interpreter = double(store:)
    application.instance_variable_set(:@bridge, double(interpreter:))
    policy = double(authorize!: true)
    application.instance_variable_set(:@access_control, policy)
    context = Object.new
    parameter = { 'name' => 'Input', 'entity' => 'M.Input', 'required' => true }

    expect(store).not_to receive(:create)
    object = application.send(
      :deserialize_rest_value, { 'Name' => 'Ada' }, parameter, context:
    )
    expect(object).to have_attributes(entity: 'M.Input', members: { 'Name' => 'Ada' })
    expect(policy).to have_received(:authorize!).with(
      'M.Input', kind: :entity, action: :create, context:, member: nil, record: nil
    )

    service = Class.new(Mxrb::RubyApp::Service) do
      mendix_name 'M.Run', id: 'run'
    end
    expect(application).to receive(:native_call).with('M.Run', { value: 1 }, context:).and_return(:ok)
    expect(service.new(application, context:).call(value: 1)).to eq(:ok)
  end
end
# rubocop:enable Metrics/BlockLength
