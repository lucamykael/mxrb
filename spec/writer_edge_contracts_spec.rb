# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Writer, 'remaining edge contracts' do
  subject(:writer) { described_class.new('model.mpr', version: '11.12.1', modules: []) }

  it 'validates system indexes and scheduled-event edge cases' do
    expect(writer.send(:ruby_system_index_member?, name: :Owner, type: :Owner)).to be(true)
    expect(writer.send(:ruby_system_index_member?, name: :Owner, type: :ChangedBy)).to be(false)
    expect(writer.send(:ruby_index_member_pointer, { name: :Name }, 'Name' => 'attribute-id'))
      .to eq('attribute-id')
    expect(writer.send(:ruby_index_member_pointer, { name: :Owner, type: :Owner }, {}))
      .to eq(Mxrb::Writer::ZERO_UUID)
    expect { writer.send(:ruby_index_member_pointer, { name: :Future, type: :Future }, {}) }
      .to raise_error(Mxrb::ValidationError, /unknown indexed system member/)
    expect do
      writer.send(:validate_ruby_indexes!, [{ members: [{ name: :Future, type: :Future }] }],
                  {}, 'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /unknown indexed system member/)
    expect do
      writer.send(:validate_ruby_indexes!, [{ members: [{ name: :Owner, type: :Owner }] }],
                  {}, 'App', 'Item')
    end.not_to raise_error

    expect do
      writer.send(:validate_ruby_scheduled_events!, 'App', [
                    { name: 'Detached', unbound: true, enabled: true, microflow: '', schedule: nil }
                  ])
    end.to raise_error(Mxrb::ValidationError, /must be disabled/)
    unbound = writer.send(
      :ruby_unbound_scheduled_event_doc,
      { name: 'Detached', start_at: '', interval: 1 }, { 'StartDateTime' => '2026-01-01T00:00:00Z' }, 'id'
    )
    expect(unbound).to include('Enabled' => false, 'Schedule' => nil)
    expect do
      writer.send(:ruby_unbound_scheduled_event_doc,
                  { name: 'Bad', start_at: 'not-a-date', interval: 1 }, {}, 'id')
    end.to raise_error(Mxrb::ValidationError, /invalid start time/)
  end

  it 'rejects inconsistent regular-expression collections before writing' do
    raw_module = { 'UnitID' => 'module-id' }
    expression_id = '11111111-1111-4111-8111-111111111111'
    other_id = '22222222-2222-4222-8222-222222222222'
    raw_expression = { 'UnitID' => expression_id }
    raw_other = { 'UnitID' => other_id }
    native = {
      '$ID' => expression_id, '$Type' => Mxrb::RubyApp::RegularExpression::TYPE,
      'Name' => 'Email', 'Expression' => '.+'
    }
    mpr = double(root_unit: { 'UnitID' => 'root' }, unit: nil, all_units: [])
    allow(writer).to receive(:find_named).and_return(raw_module)
    allow(writer).to receive(:collect_documents).and_return([raw_expression, raw_other])
    allow(mpr).to receive(:parse_contents).with(raw_expression).and_return(native)
    allow(mpr).to receive(:parse_contents).with(raw_other).and_return(
      '$ID' => other_id, '$Type' => Mxrb::RubyApp::RegularExpression::TYPE,
      'Name' => 'Other', 'Expression' => '.+'
    )

    expect do
      writer.plan_ruby_regular_expressions(
        mpr, module_name: 'App',
             expressions: [{ name: '', properties: { 'Expression' => '.+' } }]
      )
    end.to raise_error(Mxrb::ValidationError, /duplicate or empty/)
    expect do
      writer.plan_ruby_regular_expressions(
        mpr, module_name: 'App',
             expressions: [{ name: 'Other', id: expression_id, properties: { 'Expression' => '.+' } }]
      )
    end.to raise_error(Mxrb::ValidationError, /conflicts with its native name/)
    expect do
      writer.plan_ruby_regular_expressions(
        mpr, module_name: 'App',
             expressions: [{ name: 'Email', properties: {}, absent_properties: %w[Expression Future] }]
      )
    end.to raise_error(Mxrb::ValidationError, /presence metadata/)
    expect do
      writer.plan_ruby_regular_expressions(
        mpr, module_name: 'App', expressions: [{ name: 'New', properties: {} }]
      )
    end.to raise_error(Mxrb::ValidationError, /requires its expression String/)
    expect do
      writer.plan_ruby_regular_expressions(
        mpr, module_name: 'App',
             expressions: [{ name: 'Email', properties: { 'Expression' => '.+' } }],
             remove_ids: [expression_id]
      )
    end.to raise_error(Mxrb::ValidationError, /both retained and removed/)
  end

  it 'encodes table and layout-grid structures including visibility and nested widgets' do
    table = writer.send(
      :table_widget_doc,
      { name: 'Matrix', options: {
        class: 'matrix', visible: '$currentObject/Visible', tab_index: 2,
        columns: [{ width: 30 }, { width: 70 }],
        rows: [{ options: { visible: 'true' }, cells: [
          { header: true, colspan: 2, rowspan: 2, widgets: [{ type: :text, name: 'Cell', options: {} }] }
        ] }]
      } }
    )
    expect(table).to include('$Type' => 'Forms$Table', 'Name' => 'Matrix')
    expect(Mxrb::IO::BsonCodec.parse_array(table['Cells'])[:items].first)
      .to include('Width' => 2, 'Height' => 2, 'IsHeader' => true)

    grid = writer.send(
      :layout_grid_widget_doc,
      { name: 'Grid', options: {
        width: :fixed, visible: 'true',
        rows: [{ options: { gutters: false, horizontal_alignment: :center }, columns: [{
          options: { phone: :auto, tablet: 6, desktop: 12, vertical_alignment: :center },
          widgets: [{ type: :text, name: 'Nested', options: {} }]
        }] }]
      } }
    )
    expect(grid).to include('$Type' => 'Forms$LayoutGrid', 'Width' => 'FixedWidth')
    expect(writer.send(:layout_grid_weight_value, :grow)).to eq(-1)
    expect(writer.send(:layout_grid_weight_value, :auto)).to eq(-2)
    expect(writer.send(:layout_grid_weight_value, 7)).to eq(7)
    expect { writer.send(:layout_grid_weight_value, 13) }.to raise_error(ArgumentError, /1\.\.12/)
    expect(writer.send(:layout_grid_enum_value, :center)).to eq('Center')
    expect(writer.send(:conditional_visibility_doc, '')).to be_nil
    expect(writer.send(:conditional_visibility_doc, 'true')).to include('Expression' => 'true')
  end

  it 'encodes data-view sources, references, mappings, variables, and conditions' do
    source_shapes = [
      { kind: :context, entity: 'App.Order', variable: { kind: :page_parameter, name: 'Order' } },
      { kind: :association, steps: [{ association: 'App.Order_Customer', entity: 'App.Customer' }] },
      { kind: :nanoflow, name: 'App.Load', mappings: [{ parameter: 'Input', expression: '$Order' }] },
      { kind: :microflow, name: 'App.Load', mappings: [{ parameter: 'Input', expression: '$Order' }] },
      { kind: :listen, target: 'Grid' },
      { kind: :native, native_type: 'Forms$FutureSource' }
    ]
    docs = source_shapes.map { writer.send(:data_view_source_doc, _1) }
    expect(docs.map { _1.fetch('$Type') }).to eq(
      %w[Forms$DataViewSource Forms$DataViewSource Forms$NanoflowSource Forms$MicroflowSource
         Forms$ListenTargetSource Forms$FutureSource]
    )
    expect { writer.send(:data_view_source_doc, kind: :future) }
      .to raise_error(ArgumentError, /unsupported data view source/)

    mappings = writer.send(
      :data_view_mappings_doc,
      [{ parameter: 'App.Load.Input', expression: '$Order',
         variable: { kind: :local_variable, name: 'Local' } }], :nanoflow
    )
    expect(Mxrb::IO::BsonCodec.parse_array(mappings)[:items].first)
      .to include('$Type' => 'Forms$NanoflowParameterMapping')
    %i[local_variable page_parameter snippet_parameter widget].each do |kind|
      expect(writer.send(:data_view_page_variable_doc, kind:, name: 'Value').values).to include('Value')
    end
    expect(writer.send(:data_view_page_variable_doc, nil)).to be_nil
    unknown = writer.send(:data_view_page_variable_doc, kind: :future, name: 'Ignored')
    expect(unknown.values).not_to include('Ignored')
    condition = writer.send(
      :data_view_condition_doc,
      { attribute: 'Active', expression: 'true', roles: ['App.User'], ignore_security: true,
        source_variable: { kind: :widget, name: 'Grid' } },
      type: 'Forms$ConditionalVisibilitySettings'
    )
    expect(condition).to include('Attribute' => 'Active', 'IgnoreSecurity' => true)
  end

  it 'encodes a complete data view and design-property alternatives' do
    option = writer.send(:data_view_design_property_doc, key: 'Color', option: 'Red')
    compound = writer.send(
      :data_view_design_property_doc,
      key: 'Outer', properties: [{ key: 'Inner', option: 'Compact' }]
    )
    expect(option.dig('Value', '$Type')).to eq('Forms$OptionDesignPropertyValue')
    expect(compound.dig('Value', '$Type')).to eq('Forms$CompoundDesignPropertyValue')
    expect(writer.send(:data_view_design_property_doc, 'opaque')).to eq('opaque')
    expect(writer.send(:data_view_design_property_doc, key: 'Unsupported')).to eq(key: 'Unsupported')

    document = writer.send(
      :data_view_widget_doc,
      {
        name: 'Order',
        options: {
          source: { kind: :microflow, name: 'Load', mappings: [] },
          design_properties: [{ key: 'Color', option: 'Red' }],
          editability: { expression: 'true' }, visibility: { expression: 'true' }
        },
        body: [{ type: :text, name: 'Body', options: {} }],
        footer: [{ type: :text, name: 'Footer', options: {} }]
      },
      context_entity: 'App.Context', module_name: 'App'
    )
    expect(document).to include('$Type' => 'Forms$DataView', 'Name' => 'Order')
    expect(document.dig('DataSource', 'MicroflowSettings', 'Microflow')).to eq('App.Load')
  end

  it 'validates client actions, export mappings, and REST result modes' do
    expect { writer.send(:client_action_doc, kind: :future) }
      .to raise_error(Mxrb::ValidationError, /unknown client action kind/)
    expect do
      writer.send(:export_xml_action_doc, variable: '', mapping: '', output: '')
    end.to raise_error(Mxrb::ValidationError, /requires variable, mapping, and as/)
    expect do
      writer.send(:export_xml_action_doc,
                  variable: 'Input', mapping: 'App.Export', output: 'Json', content_type: :yaml)
    end.to raise_error(Mxrb::ValidationError, /unsupported export mapping content type/)
    expect(writer.send(:export_xml_action_doc,
                       variable: 'Input', mapping: 'App.Export', output: 'Json', content_type: :json))
      .to include('$Type' => 'Microflows$ExportXmlAction')

    base = { commit: :yes, parameter_variable: '', force_single: false, single: false }
    expect { writer.send(:rest_result_handling_doc, base.merge(result_handling: :string, variable: '')) }
      .to raise_error(Mxrb::ValidationError, /string REST result handling requires as/)
    expect do
      writer.send(:rest_result_handling_doc,
                  base.merge(result_handling: :string, variable: 'Text', result_entity: 'App.Item'))
    end.to raise_error(Mxrb::ValidationError, /does not accept/)
    expect(writer.send(:rest_result_handling_doc,
                       base.merge(result_handling: :string, variable: 'Text')))
      .to include('ResultVariableName' => 'Text')
    expect { writer.send(:rest_result_handling_doc, base.merge(result_handling: :future)) }
      .to raise_error(Mxrb::ValidationError, /unsupported REST result handling/)
    expect { writer.send(:rest_call_action_doc, base.merge(result_handling: :future)) }
      .to raise_error(Mxrb::ValidationError, /unsupported REST result handling/)
  end

  it 'converts current-object template parameters into attribute references' do
    current = writer.send(:client_template_parameter_doc, '$currentObject/Name', entity: 'App.Order')
    expression = writer.send(:client_template_parameter_doc, '$value + 1', entity: 'App.Order')
    expect(current).to include('Expression' => '')
    expect(expression).to include('Expression' => '$value + 1')
    template = writer.send(
      :client_template_doc, 'Hello {1}', parameters: ['$currentObject/Name'], entity: 'App.Order'
    )
    expect(Mxrb::IO::BsonCodec.parse_array(template['Parameters'])[:items]).not_to be_empty
  end

  it 'validates typed project-document versions and inserts missing system texts' do
    legacy = described_class.new('legacy.mpr', version: '10.24.0', modules: [])
    legacy.instance_variable_get(:@definition)[:project_settings_model] = Object.new
    expect { legacy.send(:write_typed_project_settings, double, 'root') }
      .to raise_error(Mxrb::ValidationError, /supports Mendix 11 only/)
    expect { legacy.send(:write_system_texts, double, 'root', Object.new) }
      .to raise_error(Mxrb::ValidationError, /supports Mendix 11 only/)

    mpr = double(children_of: [])
    codec = instance_double(Mxrb::SystemTexts::MprCodec)
    allow(Mxrb::SystemTexts::MprCodec).to receive(:new).and_return(codec)
    allow(codec).to receive(:encode).and_return('$Type' => Mxrb::SystemTexts::MprCodec::COLLECTION_TYPE)
    expect(mpr).to receive(:insert_unit).with(
      container_uuid: 'root', containment_name: 'ProjectDocuments', contents_doc: anything
    )
    writer.send(:write_system_texts, mpr, 'root', Object.new)
  end

  it 'resolves, rejects, and relocates native document identities' do
    raw = { 'UnitID' => 'unit-id', 'ContainerID' => 'module-id' }
    mpr = double
    allow(mpr).to receive(:unit).and_return(raw)
    allow(mpr).to receive(:parse_contents).with(raw)
                                          .and_return('$Type' => 'Forms$Page', 'Name' => 'Existing')
    expect do
      writer.send(
        :upsert_native_unit, mpr, 'module-id',
        'unit_id' => 'unit-id', 'containment' => 'Documents',
        'doc' => { '$Type' => 'Forms$Page', 'Name' => 'Changed' }
      )
    end.to raise_error(Mxrb::ValidationError, /native unit unit-id/)

    candidates = [{ 'UnitID' => 'one' }, { 'UnitID' => 'two' }]
    allow(mpr).to receive(:unit).and_return(nil)
    allow(mpr).to receive(:children_of).and_return(candidates)
    allow(mpr).to receive(:parse_contents).and_return(
      '$Type' => 'Microflows$Microflow', 'Name' => 'Run'
    )
    expect do
      writer.send(
        :upsert_native_unit, mpr, 'module-id',
        'containment' => 'Documents',
        'doc' => { '$Type' => 'Microflows$Microflow', 'Name' => 'Run' }
      )
    end.to raise_error(Mxrb::ValidationError, /ambiguous native/)

    expect(mpr).to receive(:relocate_unit).with(
      'unit-id', container_uuid: 'folder-id', containment_name: 'Documents'
    )
    writer.send(:relocate_root_document, mpr, raw, 'module-id', 'folder-id')
  end

  it 'validates duplicate flow identities and document target stability' do
    expect do
      writer.send(:validate_flow_identities!, [{ name: 'Run' }, { name: 'Run' }], 'microflow')
    end.to raise_error(Mxrb::ValidationError, /distinct unit ids/)

    candidates = [{ 'UnitID' => 'one' }, { 'UnitID' => 'two' }]
    mpr = double(unit: nil)
    allow(mpr).to receive(:parse_contents).and_return(
      'Name' => 'Run', '$Type' => 'Microflows$Microflow'
    )
    expect do
      writer.send(
        :resolve_document_target, mpr, 'module-id', candidates,
        { 'Name' => 'Run', '$Type' => 'Microflows$Microflow' }, '', allow_name_fallback: true
      )
    end.to raise_error(Mxrb::ValidationError, /ambiguous Microflows\$Microflow/)

    stable = { 'UnitID' => 'stable' }
    allow(mpr).to receive(:unit).with('stable').and_return(stable)
    allow(mpr).to receive(:parse_contents).with(stable)
                                          .and_return('Name' => 'Other', '$Type' => 'Forms$Page')
    expect do
      writer.send(
        :resolve_document_target, mpr, 'module-id', [],
        { 'Name' => 'Home', '$Type' => 'Forms$Page' }, 'stable', allow_name_fallback: true
      )
    end.to raise_error(Mxrb::ValidationError, /document unit stable/)

    allow(mpr).to receive(:parse_contents).with(stable)
                                          .and_return('Name' => 'Home', '$Type' => 'Forms$Page')
    allow(writer).to receive(:collect_documents).and_return([])
    expect do
      writer.send(
        :resolve_document_target, mpr, 'module-id', [],
        { 'Name' => 'Home', '$Type' => 'Forms$Page' }, 'stable', allow_name_fallback: true
      )
    end.to raise_error(Mxrb::ValidationError, /outside module/)
  end

  it 'encodes overlay pages, deep menus, nested page attributes, and rescue breaks' do
    page = writer.send(
      :page_doc,
      {
        name: 'Home', unit_id: nil, write_mode: :overlay,
        deep_structure: { '$Type' => 'Forms$Page', 'Future' => true },
        widgets: [], allowed_roles: nil, public: false
      }, 'App'
    )
    expect(page.fetch('__mxrb_page_overlay')).to include(widgets: [], encoded_widgets: [])
    menu = writer.send(:menu_doc, name: 'Main', deep_structure: { '$Type' => 'Menus$MenuDocument' })
    expect(menu).to include('$Type' => 'Menus$MenuDocument', 'Name' => 'Main')

    widgets = [{
      type: :container,
      slots: [{ widgets: [{ type: :text_box, options: { attribute: 'SlotName' } }] }],
      children: [], body: [], footer: [],
      regions: {},
      options: { rows: [{
        cells: [{ widgets: [{ type: :text_box, options: { attribute: 'CellName' } }] }],
        columns: [{ widgets: [{ type: :text_box, options: { attribute: 'ColumnName' } }] }]
      }] }
    }]
    expect(writer.send(:simple_page_attributes, widgets))
      .to contain_exactly('SlotName', 'CellName', 'ColumnName')

    graph = writer.send(
      :build_microflow_graph,
      [{ type: :rescue_all, activities: [{ type: :break_event }] }], ''
    )
    expect(graph.fetch(:objects)).to include(include('$Type' => 'Microflows$BreakEvent'))
    action = writer.send(
      :activity_action_doc,
      type: :export_xml, variable: 'Input', mapping: 'App.Export', output: 'Text',
      content_type: :xml, error: :rollback
    )
    expect(action).to include('$Type' => 'Microflows$ExportXmlAction')
  end
end
# rubocop:enable Metrics/BlockLength
