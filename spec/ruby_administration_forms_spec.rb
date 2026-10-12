# frozen_string_literal: true

require 'spec_helper'
require 'json'

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

  let(:local_condition) do
    { 'Attribute' => 'Admin.Account.IsLocalUser', 'Expression' => '',
      'Conditions' => [2, { '$Type' => 'Enumerations$Condition', 'AttributeValue' => 'true',
                            'EditableVisible' => false }] }
  end

  def label_options
    label = { '$Type' => 'Forms$Label', 'Name' => 'warning', 'ConditionalVisibilitySettings' => local_condition,
              'Caption' => { 'Items' => [3, { 'LanguageCode' => 'en_US', 'Text' => 'Managed elsewhere' }] } }
    Mxrb::Model::Page.allocate.send(:widget_options, label, :text)
  end

  it 'imports label captions, attribute visibility and button icons' do
    expect(label_options).to include(caption: 'Managed elsewhere',
                                     visibility: include(attribute: 'Admin.Account.IsLocalUser'))
    page = Mxrb::Model::Page.allocate
    button = { '$Type' => 'Forms$ActionButton', 'Name' => 'edit', 'ButtonStyle' => 'Default',
               'Icon' => { '$Type' => 'Forms$IconCollectionIcon', 'Image' => 'Atlas_Core.Atlas_Filled.pencil' },
               'ConditionalVisibilitySettings' => { 'Expression' => '$currentObject/Active' } }
    options = page.send(:widget_options, button, :button)
    expect(options).to include(icon: 'Atlas_Core.Atlas_Filled.pencil', visible: '$currentObject/Active')
    expect(options).not_to have_key(:visibility)
    glyph = button.merge('Icon' => { '$Type' => 'Forms$GlyphIcon', 'Code' => 1 })
    expect(page.send(:widget_options, glyph, :button)).not_to have_key(:icon)
  end

  it 'declares and exports them with typed text and button calls' do
    builder = Mxrb::Dsl::WidgetSlotBuilder.new
    builder.instance_eval do
      text 'warning', caption: '', visibility: input_condition(attribute: 'A.B.C', conditions: [['true', false]])
      button 'edit', caption: '', icon: 'Atlas_Core.Atlas_Filled.pencil'
    end
    text, edit = builder.widgets
    expect(text.dig(:options, :visibility))
      .to eq(attribute: 'A.B.C', conditions: [{ 'AttributeValue' => 'true', 'EditableVisible' => false }])
    expect(edit.dig(:options, :icon)).to eq('Atlas_Core.Atlas_Filled.pencil')

    widget = JSON.parse(JSON.generate(type: :text, name: 'warning', events: [], options: label_options))
    source = Mxrb::RubyApp::Exporter.allocate.send(:runtime_widget_call_source, widget, 0, generic_sink: true)
    expect(source).to include('visibility: input_condition(attribute: "Admin.Account.IsLocalUser", ' \
                              'conditions: [["true", false]])')
  end
end
