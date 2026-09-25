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
    expect do
      writer.send(:validate_ruby_scheduled_events!, 'App', [
                    { name: 'Detached', unbound: true, enabled: false, microflow: '', schedule: nil }
                  ])
    end.not_to raise_error
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
        widgets: [{ type: :text, name: 'Title', options: {} }],
        allowed_roles: nil, public: false
      }, 'App'
    )
    expect(page.fetch('__mxrb_page_overlay')).to include(
      widgets: [{ type: :text, name: 'Title', options: {} }]
    )
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

  it 'resolves page overlay module/page identities and wraps preflight failures' do
    raw_module = { 'UnitID' => 'module-id', 'ContainmentName' => 'Modules' }
    raw_page = { 'UnitID' => 'page-id' }
    mpr = double(all_units: [raw_module, raw_page], children_of: [raw_module])
    allow(mpr).to receive(:parse_contents).with(raw_module).and_return('Name' => 'App')
    allow(mpr).to receive(:parse_contents).with(raw_page)
                                          .and_return('$Type' => 'Forms$Page', 'Name' => 'Home')
    allow(mpr).to receive(:unit).with('module-id').and_return(raw_module)
    allow(mpr).to receive(:unit).with('page-id').and_return(raw_page)
    metadata = { 'module_unit_id' => 'module-id', 'page_unit_id' => 'page-id' }
    expect(writer.send(:overlay_module_target, mpr, 'root', { name: 'App' }, metadata))
      .to equal(raw_module)
    allow(writer).to receive(:documents_by_name).and_return('Home' => [raw_page])
    expect(writer.send(:overlay_page_target, mpr, raw_module, { name: 'Home' }, metadata))
      .to equal(raw_page)

    expect do
      writer.send(:overlay_module_target, mpr, 'root', { name: 'Missing' }, nil)
    end.to raise_error(Mxrb::ValidationError, /module identity changed/)
    allow(writer).to receive(:documents_by_name).and_return('Home' => [])
    expect do
      writer.send(:overlay_page_target, mpr, raw_module, { name: 'Home' }, nil)
    end.to raise_error(Mxrb::ValidationError, /page overlay identity changed/)

    overlay = instance_double(Mxrb::Writer::PageOverlay, apply: true)
    allow(Mxrb::Writer::PageOverlay).to receive(:new).and_return(overlay)
    allow(writer).to receive(:widget_doc).and_return('$Type' => 'Forms$TextBox')
    expect(writer.send(
             :verify_page_overlay_target!, { '$Type' => 'Forms$Page' },
             { deep_structure: { '$Type' => 'Forms$Page' }, widgets: [{ type: :text_box }] }, 'App'
           )).to be(true)

    definition = writer.instance_variable_get(:@definition)
    definition[:modules] = [{
      name: 'App', pages: [{ name: 'Home', write_mode: :overlay, widgets: [] }]
    }]
    allow(writer).to receive(:overlay_module_target).and_return(raw_module)
    allow(writer).to receive(:overlay_page_target).and_return(raw_page)
    allow(writer).to receive(:verify_page_overlay_target!).and_return(true)
    expect { writer.send(:preflight_page_overlays!, mpr, 'root') }.not_to raise_error

    definition[:modules] = [{ name: 'Missing', pages: [{ name: 'Home', write_mode: :overlay }] }]
    allow(writer).to receive(:overlay_module_target).and_call_original
    expect { writer.send(:preflight_page_overlays!, mpr, 'root') }
      .to raise_error(Mxrb::ValidationError, /page overlay Missing.Home/)
  end

  it 'validates simple, duplicate, and nested pluggable widget slots' do
    widgets_type = { '$ID' => 'widgets-value', 'Type' => 'Widgets' }
    content_type = {
      '$ID' => 'content-property', 'PropertyKey' => 'content', 'ValueType' => widgets_type
    }
    object_type = { '$ID' => 'object-type', 'PropertyTypes' => [2, content_type] }
    content = {
      '$Type' => 'CustomWidgets$WidgetProperty', 'TypePointer' => 'content-property',
      'Value' => { '$Type' => 'CustomWidgets$WidgetValue', 'TypePointer' => 'widgets-value' }
    }
    object = {
      '$Type' => 'CustomWidgets$WidgetObject', 'TypePointer' => 'object-type',
      'Properties' => [2, content]
    }
    widget = { 'Name' => 'Grid', 'Type' => { 'ObjectType' => object_type }, 'Object' => object }
    resolved = writer.send(:pluggable_slot_property!, object_type, object, ['content'], ['content'])
    expect(resolved.fetch('ValueType')).to include('Type' => 'Widgets')
    writer.send(
      :configure_pluggable_widget_slots!, widget,
      [{ path: ['content'], widgets: [{ type: :text, name: 'Inside', options: {} }] }]
    )
    expect(Mxrb::IO::BsonCodec.parse_array(content.dig('Value', 'Widgets'))[:items]).not_to be_empty
    expect do
      writer.send(:configure_pluggable_widget_slots!, widget,
                  [{ path: ['content'] }, { path: ['content'] }])
    end.to raise_error(Mxrb::ValidationError, /duplicate pluggable widget slot/)
    expect { writer.send(:pluggable_slot_property!, object_type, object, [], []) }
      .to raise_error(Mxrb::ValidationError, /path cannot be empty/)
    expect { writer.send(:pluggable_slot_property!, object_type, object, ['missing'], ['missing']) }
      .to raise_error(Mxrb::ValidationError, /has no property/)
    expect do
      writer.send(:pluggable_slot_property!, object_type, object,
                  %w[content invalid], %w[content invalid])
    end.to raise_error(Mxrb::ValidationError, /must descend through/)
    expect do
      writer.send(:configure_pluggable_widget_slots!, widget, [{ path: ['content'], widgets: [] }])
    end.not_to raise_error
    content_type['ValueType']['Type'] = 'String'
    expect do
      writer.send(:configure_pluggable_widget_slots!, widget, [{ path: ['content'], widgets: [] }])
    end.to raise_error(Mxrb::ValidationError, /is not a widgets property/)
    expect do
      writer.send(:reusable_widget_object!, object_type, object, { missing: true }, 0)
    end.to raise_error(Mxrb::ValidationError, /invalid WidgetProperty/)
  end

  it 'descends through nested pluggable objects and rejects invalid object indexes' do
    leaf_value = { '$ID' => 'leaf-value', 'Type' => 'Widgets' }
    leaf_property_type = {
      '$ID' => 'leaf-property', 'PropertyKey' => 'content', 'ValueType' => leaf_value
    }
    nested_type = { '$ID' => 'nested-type', 'PropertyTypes' => [2, leaf_property_type] }
    leaf_property = {
      '$Type' => 'CustomWidgets$WidgetProperty', 'TypePointer' => 'leaf-property',
      'Value' => { '$Type' => 'CustomWidgets$WidgetValue', 'TypePointer' => 'leaf-value' }
    }
    nested_object = {
      '$Type' => 'CustomWidgets$WidgetObject', 'TypePointer' => 'nested-type',
      'Properties' => [2, leaf_property]
    }
    object_value = { '$ID' => 'object-value', 'Type' => 'Object', 'ObjectType' => nested_type }
    root_property_type = {
      '$ID' => 'items-property', 'PropertyKey' => 'items', 'ValueType' => object_value
    }
    root_type = { '$ID' => 'root-type', 'PropertyTypes' => [2, root_property_type] }
    root_property = {
      '$Type' => 'CustomWidgets$WidgetProperty', 'TypePointer' => 'items-property',
      'Value' => {
        '$Type' => 'CustomWidgets$WidgetValue', 'TypePointer' => 'object-value',
        'Objects' => [2, nested_object]
      }
    }
    root = {
      '$Type' => 'CustomWidgets$WidgetObject', 'TypePointer' => 'root-type',
      'Properties' => [2, root_property]
    }
    path = ['items', 'objects', 0, 'content']
    expect(writer.send(:pluggable_slot_property!, root_type, root, path, path))
      .to include('TypePointer' => 'leaf-property')
    expect do
      writer.send(:pluggable_slot_property!, root_type, root,
                  ['items', 'objects', -1, 'content'], path)
    end.to raise_error(Mxrb::ValidationError, /has no object at index/)
    root_property_type['ValueType'] = object_value.merge('ObjectType' => nil)
    expect do
      writer.send(:pluggable_slot_property!, root_type, root, path, path)
    end.to raise_error(Mxrb::ValidationError, /has no ObjectType/)
    root_property_type['ValueType'] = object_value
    nested_object['$Type'] = 'Future$Object'
    expect do
      writer.send(:pluggable_slot_property!, root_type, root, path, path)
    end.to raise_error(Mxrb::ValidationError, /does not resolve to a WidgetObject/)

    expect do
      writer.send(:validate_available_pluggable_slots!, { 'Name' => 'Grid' },
                  __kind: :native, __slots: [{ path: ['content'] }])
    end.to raise_error(Mxrb::ValidationError, /has declared slots/)
  end

  it 'updates existing OQL documents and typed Forms documents' do
    raw = { 'UnitID' => 'view-id' }
    mpr = double
    allow(writer).to receive(:collect_documents).and_return([raw])
    allow(mpr).to receive(:parse_contents).with(raw).and_return(
      '$ID' => 'view-id', '$Type' => 'DomainModels$ViewEntitySourceDocument',
      'Name' => 'View', 'Oql' => 'old'
    )
    expect(mpr).to receive(:update_unit).with('view-id', hash_including('Oql' => 'SELECT 1'))
    writer.send(
      :synchronize_ruby_oql_documents!, mpr, 'module-id', 'App',
      [{ name: 'View', oql_view: { source: 'App.View', query: 'SELECT 1' } }]
    )

    forms_model = Object.new
    declaration = {
      name: 'Home', type: 'Forms$Page', containment: 'Documents', forms_model:
    }
    existing = { 'UnitID' => 'page-id', 'ContainerID' => 'module-id' }
    current = { '$ID' => 'page-id', '$Type' => 'Forms$Page', 'Name' => 'Home' }
    codec = instance_double(Mxrb::Forms::MprCodec)
    allow(Mxrb::Forms::MprCodec).to receive(:new).and_return(codec)
    allow(codec).to receive(:encode).with(forms_model).and_return(current)
    allow(codec).to receive(:encode).with(forms_model, baseline: current).and_return(current)
    allow(writer).to receive(:native_document_target).and_return(existing)
    allow(writer).to receive(:conventional_document_container).and_return('module-id')
    forms_mpr = double
    allow(forms_mpr).to receive(:parse_contents).with(existing).and_return(current)
    expect(forms_mpr).to receive(:update_unit).with('page-id', hash_including('Name' => 'Home'))
    writer.send(:write_native_documents, forms_mpr, 'module-id', native_documents: [declaration])
  end

  it 'prunes undeclared managed native documents and resolves anonymous shapes' do
    raw = { 'UnitID' => 'old-id' }
    mpr = double
    allow(writer).to receive(:collect_documents).and_return([raw])
    allow(mpr).to receive(:parse_contents).with(raw).and_return(
      '$Type' => 'Forms$Snippet', 'Name' => 'Old'
    )
    expect(mpr).to receive(:delete_unit).with('old-id')
    writer.send(
      :write_native_documents, mpr, 'module-id',
      native_documents: [], managed_native_document_types: ['Forms$Snippet']
    )

    expect(writer.send(
             :resolve_document_target, mpr, 'module-id', [raw],
             { 'Name' => '', '$Type' => 'Forms$Snippet' }, '', allow_name_fallback: true
           )).to equal(raw)
  end

  it 'wraps page overlay application errors with the generated page name' do
    generated = {
      'Name' => 'Home', '__mxrb_page_overlay' => {
        baseline: {}, metadata: {}, widgets: [], encoded_widgets: []
      }
    }
    overlay = instance_double(Mxrb::Writer::PageOverlay)
    allow(Mxrb::Writer::PageOverlay).to receive(:new).and_return(overlay)
    allow(overlay).to receive(:apply).and_raise(Mxrb::ValidationError, 'changed')
    expect { writer.send(:apply_page_overlay, {}, generated) }
      .to raise_error(Mxrb::ValidationError, /page overlay Home: changed/)
  end
end
# rubocop:enable Metrics/BlockLength
