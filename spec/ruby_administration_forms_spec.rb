# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Administration forms in the Ruby application' do # rubocop:disable Metrics/BlockLength
  let(:application) { Mxrb::RubyApp::Application.allocate }

  def object(entity) = Mxrb::Runtime::Native::ObjectValue.new(entity:, id: 'object', members: {})

  def services(*parameters)
    [{ 'services' => [{ 'name' => 'Admin.Save', 'parameters' => parameters }] }]
  end

  def stub_runtime(modules)
    schema = Mxrb::Runtime::RuntimeSchema.new(entities: [], associations: [],
                                              inheritance: { 'Admin.Account' => ['System.User'] })
    store = double('store', schema:)
    allow(application).to receive_messages(manifest: double('manifest', modules:),
                                           bridge: double('bridge', interpreter: double('interpreter', store:)))
  end

  it 'publishes the System entities and associations in the client schema' do
    allow(application).to receive(:manifest).and_return(double('manifest', modules: [], data: {}))
    system = application.send(:runtime_schema_modules).find { _1['name'] == 'System' }
    expect(system.fetch('associations')).to include(
      'name' => 'UserRoles', 'type' => 'ReferenceSet', 'from_entity' => 'System.User', 'to_entity' => 'System.UserRole'
    )
    user = system.fetch('models').find { _1['name'] == 'System.User' }
    names = user.fetch('attributes').map { _1['name'] }
    expect(names).to include('Name', 'Active')
    expect(names).not_to include('Password')

    catalog = double('catalog', modules: [{ 'name' => 'System' }])
    allow(Mxrb::RubyApp::RuntimeCatalog).to receive(:new).and_return(catalog)
    expect(application.send(:runtime_schema_modules).map { _1['name'] }).to eq(['System'])
  end

  it 'passes the data view object to the one unmapped parameter of its entity' do
    reference = { 'type' => 'Admin.Account', 'id' => 'object' }
    stub_runtime(services({ 'name' => 'Data', 'entity' => 'Admin.Data' },
                          { 'name' => 'User', 'entity' => 'System.User' },
                          { 'name' => 'Count', 'type' => 'DataTypes$IntegerType' }))
    implicit = lambda do |arguments, context, name: 'Admin.Save'|
      arguments.tap { application.send(:implicit_context_argument, name, _1, context, reference) }
    end

    expect(implicit.call({}, object('Admin.Account'))).to eq('User' => reference)
    expect(implicit.call({ 'User' => 'mapped' }, object('Admin.Account'))).to eq('User' => 'mapped')
    expect(implicit.call({}, object('Admin.Other'))).to eq({})
    expect(implicit.call({}, nil)).to eq({})
    expect(implicit.call({}, object('Admin.Account'), name: 'Admin.Missing')).to eq({})

    stub_runtime(services({ 'name' => 'First', 'entity' => 'System.User' },
                          { 'name' => 'Second', 'entity' => 'System.User' }))
    expect(implicit.call({}, object('Admin.Account'))).to eq({})
  end
end
