# frozen_string_literal: true

require 'spec_helper'
require 'json'

# Shapes found in private real projects, which their public Ruby
# projection must express with typed calls.
RSpec.describe 'Ruby projection of private project shapes' do # rubocop:disable Metrics/BlockLength
  let(:exporter) { Mxrb::RubyApp::Exporter.allocate }

  def stringify(value) = JSON.parse(JSON.generate(value))

  it 'declares typed data grids in snippets and keeps the generic form otherwise' do
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.data_grid 'typed', entity: 'App.Item', presentation: 'datagrid2', class_name: 'grid' do
      header { text 'title', caption: 'Items' }
      column 'Name', attribute: 'App.Item.Name'
      on_click page: 'App.Edit'
    end
    tree.data_grid 'plain', entity: 'App.Item', columns: [tree.grid_column('Name')], events: []
    typed, plain = tree.widgets
    expect(typed).to include('type' => 'data_grid', 'name' => 'typed',
                             'options' => include('class' => 'grid', 'columns' => [include('name' => 'Name')]))
    expect(typed.fetch('header')).to eq([{ 'type' => 'text', 'name' => 'title',
                                           'options' => { 'caption' => 'Items' }, 'events' => [] }])
    expect(typed.fetch('events')).to eq([{ 'event' => 'on_click', 'kind' => 'page', 'handler' => 'App.Edit' }])
    expect(plain).to eq('type' => 'data_grid', 'name' => 'plain',
                        'options' => { 'entity' => 'App.Item', 'columns' => [{ 'name' => 'Name' }] })
  end

  it 'exports snippet data grids through the typed data grid source' do
    grid = stringify(type: :data_grid, name: 'claims', events: [],
                     options: { entity: 'App.Claim', presentation: 'datagrid2',
                                columns: [{ name: 'Name', attribute: 'App.Claim.Name',
                                            filter: { type: 'text', operator: 'contains' }, width: 'manual' }] })
    source = exporter.send(:presentation_widget_source, [grid])
    expect(source).to include('data_grid "claims"', 'grid_filter(:text, operator: :contains)')
    expect(source).not_to include('=>')
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.instance_eval(source)
    expect(tree.widgets).to eq([grid.except('events')])
  end

  it 'restricts attribute conditions to module roles' do
    builder = Mxrb::Dsl::WidgetSlotBuilder.new
    condition = builder.input_condition(attribute: 'App.Item.Status', conditions: [['_1', true]],
                                        roles: [:'App.Admin'], ignore_security: true)
    expect(condition).to include(roles: ['App.Admin'], ignore_security: true)
    expect(builder.input_condition(roles: ['App.Admin'])).to eq(roles: ['App.Admin'])

    native = { 'attribute' => 'App.Item.Status', 'roles' => ['App.Admin'], 'ignore_security' => true,
               'conditions' => [{ 'AttributeValue' => '_1', 'EditableVisible' => true }] }
    expect(exporter.send(:runtime_input_condition_source, native))
      .to eq('input_condition(attribute: "App.Item.Status", conditions: [["_1", true]], roles: ["App.Admin"], ' \
             'ignore_security: true)')
    expect(exporter.send(:runtime_input_condition_source, native.merge('roles' => [1]))).to be_nil
    expect(exporter.send(:runtime_input_condition_source, native.merge('ignore_security' => false))).to be_nil
  end

  it 'leaves the body of an excluded nanoflow that refers to removed model elements empty' do
    flow = Data.define(:id, :parameters, :excluded).new('flow', [], true)
    allow(exporter).to receive(:nanoflow_plan).and_raise(Mxrb::SerializationError, 'unknown nanoflow association')
    expect(exporter.send(:nanoflow_typescript, flow, 'App.Old')).to include('defineNanoflow', '"App.Old"')
    expect { exporter.send(:nanoflow_typescript, flow.with(excluded: false), 'App.Old') }
      .to raise_error(Mxrb::SerializationError, /unknown nanoflow association/)
  end

  it 'takes the entity of an image viewer over an association from its last step' do
    viewer = {
      'DataSource' => {
        '$Type' => 'Forms$ImageViewerSource', 'ForceFullObjects' => false,
        'EntityRef' => { '$Type' => 'DomainModels$IndirectEntityRef',
                         'Steps' => [2, { 'Association' => 'App.Item_Image', 'DestinationEntity' => 'App.Image' }] }
      }
    }
    expect(Mxrb::Model::Page.allocate.send(:image_viewer_options, viewer)).to include(entity: 'App.Image')
  end
end
