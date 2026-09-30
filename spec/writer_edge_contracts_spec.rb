# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Writer, 'remaining edge contracts' do
  subject(:writer) { described_class.new('model.mpr', version: '11.12.1', modules: []) }

  it 'validates system indexes and scheduled-event edge cases' do
    expect(writer.send(:ruby_system_index_member?, name: :CreatedDate, type: :CreatedDate)).to be(true)
    expect(writer.send(:ruby_system_index_member?, name: :Owner, type: :Owner)).to be(false)
    expect(writer.send(:ruby_index_member_pointer, { name: :Name }, 'Name' => 'attribute-id'))
      .to eq('attribute-id')
    expect(writer.send(:ruby_index_member_pointer, { name: :CreatedDate, type: :CreatedDate }, {}))
      .to eq(Mxrb::Writer::ZERO_UUID)
    expect { writer.send(:ruby_index_member_pointer, { name: :Future, type: :Future }, {}) }
      .to raise_error(Mxrb::ValidationError, /unknown indexed system member/)
    expect do
      writer.send(:validate_ruby_indexes!, [{ members: [{ name: :Future, type: :Future }] }],
                  {}, 'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /unknown indexed system member/)
    expect do
      writer.send(:validate_ruby_indexes!, [{ members: [{ name: :CreatedDate, type: :CreatedDate }] }],
                  {}, 'App', 'Item')
    end.not_to raise_error
    expect do
      writer.send(:validate_ruby_indexes!, [{ members: [{ name: :Owner, type: :Owner }] }],
                  {}, 'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /unknown indexed system member/)

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
    settings = Mxrb::Settings::ProjectBuilder.new.to_model
    legacy.instance_variable_get(:@definition)[:project_settings_model] = settings
    legacy_mpr = double(children_of: [])
    expect(legacy_mpr).to receive(:insert_unit).with(
      container_uuid: 'root', containment_name: 'ProjectDocuments',
      contents_doc: anything, unit_uuid: anything
    )
    legacy.send(:write_typed_project_settings, legacy_mpr, 'root')
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

  it 'validates missing modules, domain models, and regular-expression members' do
    mpr = double(root_unit: { 'UnitID' => 'root' }, all_units: [], unit: nil)
    allow(writer).to receive(:find_named).and_return(nil)
    expect do
      writer.plan_ruby_regular_expressions(mpr, module_name: 'Missing', expressions: [])
    end.to raise_error(Mxrb::ValidationError, /module Missing does not exist/)
    %i[
      synchronize_ruby_entity_access! synchronize_ruby_entity_structures!
      synchronize_ruby_entity_behaviors!
    ].each do |method|
      expect { writer.public_send(method, mpr, module_name: 'Missing', entities: []) }
        .to raise_error(Mxrb::ValidationError, /module Missing does not exist/)
    end

    allow(writer).to receive(:find_named).and_return('UnitID' => 'module-id')
    allow(mpr).to receive(:units_by_containment).and_return([])
    %i[
      synchronize_ruby_entity_access! synchronize_ruby_entity_structures!
      synchronize_ruby_entity_behaviors!
    ].each do |method|
      expect { writer.public_send(method, mpr, module_name: 'App', entities: []) }
        .to raise_error(Mxrb::ValidationError, /has no domain model/)
    end

    allow(writer).to receive(:collect_documents).and_return([])
    expect do
      writer.plan_ruby_regular_expressions(
        mpr, module_name: 'App', expressions: [{ name: 'Bad', properties: { 'Expression' => 1 } }]
      )
    end.to raise_error(Mxrb::ValidationError, /invalid regular-expression property type/)
    expect do
      writer.plan_ruby_regular_expressions(
        mpr, module_name: 'App', expressions: [], remove_ids: ['missing']
      )
    end.to raise_error(Mxrb::ValidationError, /outside its collection/)
  end

  it 'skips undeclared access and behavior collections' do
    raw_domain = { 'UnitID' => 'domain-id', 'ContainerID' => 'module-id' }
    domain = { 'Entities' => [2] }
    mpr = double(root_unit: { 'UnitID' => 'root' }, units_by_containment: [raw_domain])
    allow(mpr).to receive(:parse_contents).with(raw_domain).and_return(domain)
    allow(mpr).to receive(:transaction).and_yield
    allow(mpr).to receive(:update_unit)
    allow(writer).to receive(:find_named).and_return('UnitID' => 'module-id')
    expect(writer.synchronize_ruby_entity_access!(mpr, module_name: 'App',
                                                       entities: [{ access_rules: nil }])).to equal(writer)
    expect(writer.synchronize_ruby_entity_behaviors!(mpr, module_name: 'App',
                                                          entities: [])).to equal(writer)
  end

  it 'covers time objects, missing target fallbacks, and successful page overlays' do
    event = writer.send(
      :ruby_scheduled_event_doc,
      {
        name: 'Tick', microflow: 'App.Tick', interval: 1, enabled: true,
        start_at: Time.utc(2026, 1, 1), schedule: {
          id: nil, type: 'ScheduledEvents$DaySchedule', properties: {}
        }
      }, {}, 'App'
    )
    expect(event.fetch('StartDateTime')).to eq(Time.utc(2026, 1, 1))
    mpr = double(unit: nil)
    expect(writer.send(
             :resolve_document_target, mpr, 'module-id', [],
             { 'Name' => 'Home', '$Type' => 'Forms$Page' }, 'missing', allow_name_fallback: false
           )).to be_nil

    overlay = instance_double(Mxrb::Writer::PageOverlay, apply: { 'Result' => true })
    allow(Mxrb::Writer::PageOverlay).to receive(:new).and_return(overlay)
    generated = {
      'Name' => 'Home', '__mxrb_allowed_roles_declared' => true,
      '__mxrb_page_overlay' => { baseline: {}, metadata: {}, widgets: [], encoded_widgets: [] }
    }
    expect(writer.send(:apply_page_overlay, {}, generated))
      .to include('Result' => true, '__mxrb_allowed_roles_declared' => true)
  end

  it 'validates absent pluggable pointers and normalizes XPath sorts' do
    expect do
      writer.send(:validate_pluggable_widget_object!, nil, nil, [:content])
    end.to raise_error(Mxrb::ValidationError, /invalid ObjectType/)
    expect do
      writer.send(:validate_pluggable_widget_value!, { 'ValueType' => nil, 'Value' => nil }, [:content])
    end.to raise_error(Mxrb::ValidationError, /invalid WidgetValue/)

    source = writer.send(
      :custom_xpath_source_doc, 'App.Item', sort: [
        { attribute: 'App.Item.Name', direction: :Ascending },
        ['App.Item.Code', :Descending]
      ]
    )
    items = Mxrb::IO::BsonCodec.parse_array(source.dig('SortBar', 'SortItems')).fetch(:items)
    expect(items.map { _1.fetch('SortDirection') }).to eq(%w[Ascending Descending])
  end

  it 'covers OQL, generalization, page context, and legacy widget alternatives' do
    expect(writer.send(:apply_oql_view!, {}, nil, nil, module_name: 'App', entity_name: 'Item')).to be_nil
    expect(writer.send(:generalization_doc, 'System.User')).to include(
      'Generalization' => 'System.User'
    )
    expect(writer.send(:generalization_doc, target: 'System.User', id: 'generalization-id'))
      .to include('$ID' => 'generalization-id')
    expect(writer.send(:legacy_semantic_widget_doc,
                       type: :static_image, name: 'Image', options: {})).to be_nil

    allow(writer).to receive(:flow_return_entity).and_return(nil)
    allow(writer).to receive(:first_data_view_source).and_return(kind: :context, entity: 'App.Nested')
    expect(writer.send(:page_context_entity, { data_source: nil, widgets: [] }, 'App')).to eq('App.Nested')
    expect(writer.send(:page_context_entity,
                       { data_source: { entity: 'App.Direct' }, widgets: [] }, 'App'))
      .to eq('App.Direct')
  end

  it 'covers image event and thumbnail defaults' do
    no_click = writer.send(:image_viewer_widget_fields,
                           { events: [] }, entity: 'App.Image')
    with_click = writer.send(:image_viewer_widget_fields,
                             { events: [{ event: :on_click, kind: :action, handler: :save_changes }] },
                             entity: 'App.Image')
    expect(no_click.dig('ClickAction', '$Type')).to eq('Forms$NoAction')
    expect(with_click.fetch('ClickAction')).to be_a(Hash)
    expect(writer.send(:image_uploader_widget_fields,
                       thumbnail_width: 20, thumbnail_height: 30).fetch('ThumbnailSize')).to eq('20;30')
    expect(writer.send(:image_uploader_widget_fields,
                       thumbnail_width: 0, thumbnail_height: 0).fetch('ThumbnailSize')).to eq('100;75')
  end

  it 'covers regex filtering, duplicate native names, and missing entity targets' do
    raw_module = { 'UnitID' => 'module-id' }
    raw = { 'UnitID' => 'unit-id' }
    mpr = double(root_unit: { 'UnitID' => 'root' }, unit: nil, all_units: [])
    allow(writer).to receive(:find_named).and_return(raw_module)
    allow(writer).to receive(:collect_documents).and_return([raw])
    allow(mpr).to receive(:parse_contents).with(raw).and_return('$Type' => 'Future$Document')
    expect(writer.plan_ruby_regular_expressions(mpr, module_name: 'App', expressions: []))
      .to include(changes: [], removed: [])

    second = { 'UnitID' => 'second' }
    allow(writer).to receive(:collect_documents).and_return([raw, second])
    allow(mpr).to receive(:parse_contents).and_return(
      '$Type' => Mxrb::RubyApp::RegularExpression::TYPE, 'Name' => 'Email'
    )
    expect do
      writer.plan_ruby_regular_expressions(
        mpr, module_name: 'App', expressions: [{ name: 'Email', properties: {} }]
      )
    end.to raise_error(Mxrb::ValidationError, /ambiguous native regular-expression name/)

    raw_domain = { 'UnitID' => 'domain-id', 'ContainerID' => 'module-id' }
    domain = { 'Entities' => [2] }
    allow(mpr).to receive(:units_by_containment).and_return([raw_domain])
    allow(mpr).to receive(:parse_contents).with(raw_domain).and_return(domain)
    allow(writer).to receive(:find_named).and_return(raw_module)
    expect do
      writer.synchronize_ruby_entity_access!(
        mpr, module_name: 'App', entities: [{ name: 'Missing', access_rules: [] }]
      )
    end.to raise_error(Mxrb::ValidationError, /entity App.Missing does not exist/)
    expect do
      writer.synchronize_ruby_entity_structures!(
        mpr, module_name: 'App', entities: [{ name: 'Missing' }]
      )
    end.to raise_error(Mxrb::ValidationError, /entity App.Missing does not exist/)
    expect do
      writer.synchronize_ruby_entity_behaviors!(
        mpr, module_name: 'App', entities: [{ name: 'Missing' }]
      )
    end.to raise_error(Mxrb::ValidationError, /entity App.Missing does not exist/)
  end

  it 'validates module security and scheduled-event modules and prunes removed events' do
    mpr = double(root_unit: { 'UnitID' => 'root' })
    allow(writer).to receive(:find_named).and_return(nil)
    expect do
      writer.synchronize_ruby_module_security!(mpr, module_name: 'Missing', security: {})
    end.to raise_error(Mxrb::ValidationError, /module Missing does not exist/)
    expect do
      writer.synchronize_ruby_scheduled_events!(mpr, module_name: 'Missing', events: [])
    end.to raise_error(Mxrb::ValidationError, /module Missing does not exist/)

    raw = { 'UnitID' => 'event-id' }
    allow(writer).to receive(:find_named).and_return('UnitID' => 'module-id')
    allow(writer).to receive(:collect_documents).and_return([raw])
    allow(mpr).to receive(:parse_contents).with(raw).and_return(
      '$ID' => 'event-id', '$Type' => 'ScheduledEvents$ScheduledEvent', 'Name' => 'Old'
    )
    allow(mpr).to receive(:transaction).and_yield
    allow(mpr).to receive(:delete_unit)
    writer.synchronize_ruby_scheduled_events!(mpr, module_name: 'App', events: [])
    expect(mpr).to have_received(:delete_unit).with('event-id')
  end

  it 'covers native index, generalization, OQL value, and security-role alternatives' do
    expect(writer.send(:ruby_index_member_signature,
                       { 'Type' => 'Owner' }, {})).to eq(%w[Owner Owner])
    entity = {}
    writer.send(:synchronize_ruby_generalization!, entity, target: 'System.User')
    expect(entity.fetch('MaybeGeneralization')).to include('Generalization' => 'System.User')

    entity = { 'Attributes' => [2, { 'Name' => 'Code', 'Value' => 'scalar' }] }
    writer.send(:synchronize_ruby_oql_member_values!, entity)
    value = Mxrb::IO::BsonCodec.parse_array(entity.fetch('Attributes')).fetch(:items).first.fetch('Value')
    expect(value).to include('Reference' => 'Code')
    security = writer.send(:ruby_project_security_doc, {
      id: '', admin_user_role: '', user_roles: [], demo_users: [], password_policy: nil
    }, {})
    expect(Mxrb::IO::BsonCodec.parse_array(security.fetch('UserRoles')).fetch(:items)).to be_empty
    expect(security).not_to have_key('PasswordPolicySettings')
  end

  it 'covers unbound schedules and explicit modern security identities' do
    unbound = writer.send(
      :ruby_scheduled_event_doc,
      { name: 'Detached', unbound: true, start_at: Time.utc(2026), interval: 1 }, {}, 'App'
    )
    expect(unbound).to include('Schedule' => nil, 'Enabled' => false)
    expect(writer.send(:scheduled_event_schedule,
                       schedule_specified: true, schedule: nil)).to be_nil
    schedule = writer.send(:scheduled_event_schedule,
                           schedule_specified: true,
                           schedule: { id: 'schedule-id', type: 'ScheduledEvents$DaySchedule', properties: {} })
    expect(schedule.fetch('$ID')).to eq('schedule-id')

    role = writer.send(:user_role_doc, {
      name: 'User', id: 'role-id', guid: '11111111-1111-4111-8111-111111111111',
      admin: false, module_roles: []
    })
    expect(role).to include('$ID' => 'role-id')
    expect(Mxrb::IO::BsonCodec.parse_array(role.fetch('ModuleRoles')).fetch(:items))
      .to include('System.User')
    user = writer.send(:demo_user_doc, {
      name: 'demo', id: 'user-id', password: 'x', entity: 'System.User', roles: []
    })
    expect(user.fetch('$ID')).to eq('user-id')
    security = writer.send(:project_security_doc,
                           password_policy_id: 'policy-id', user_roles: [], demo_users: [])
    expect(security.dig('PasswordPolicySettings', '$ID')).to eq('policy-id')
  end

  it 'covers typed page ids, public pages, widget dispatch, and full layout widths' do
    codec = double
    allow(Mxrb::Forms::MprCodec).to receive(:new).and_return(codec)
    allow(codec).to receive(:encode).and_return('$ID' => 'generated', '$Type' => 'Forms$Page')
    typed = writer.send(:page_doc, { name: 'Typed', unit_id: 'stable', forms_model: Object.new })
    expect(typed.fetch('$ID')).to eq('stable')

    deep = writer.send(:page_doc, {
      name: 'Deep', unit_id: nil, deep_structure: {}, public: true, widgets: []
    })
    expect(deep.fetch('ExportLevel')).to eq('Public')
    plain = writer.send(:page_doc, {
      name: 'Plain', unit_id: nil, layout: 'App.Layout', title: 'Plain', public: true,
      widgets: [], events: [], allowed_roles: nil, popup: false
    })
    expect(plain.fetch('ExportLevel')).to eq('Public')

    expect(writer.send(:widget_doc,
                       { type: :table, name: 'Table', options: { columns: [], rows: [] } }))
      .to include('$Type' => 'Forms$Table')
    expect(writer.send(:widget_doc,
                       { type: :layout_grid, name: 'Grid', options: { rows: [] } }))
      .to include('$Type' => 'Forms$LayoutGrid', 'Width' => 'FullWidth')
  end

  it 'covers page context flow results and nested data-view source entities' do
    allow(writer).to receive(:flow_return_entity).and_return('App.FlowResult')
    expect(writer.send(:page_context_entity,
                       { data_source: { name: 'App.Load' }, widgets: [] }, 'App'))
      .to eq('App.FlowResult')
    allow(writer).to receive(:first_data_view_source).and_return(kind: :microflow, name: 'App.Load')
    expect(writer.send(:page_context_entity, { data_source: nil, widgets: [] }, 'App'))
      .to eq('App.FlowResult')
    expect(writer.send(:data_view_source_entity,
                       kind: :association, steps: [{ entity: 'App.Customer' }]))
      .to eq('App.Customer')
    expect(writer.send(:data_view_source_entity, kind: :association, steps: [])).to be_nil

    odd_key = Object.new
    expect(writer.send(:symbolize_data_view_value, odd_key => 'value')).to include(odd_key => 'value')
  end

  it 'covers pluggable platforms, typed mappings, native merge filtering, and unit identities' do
    allow(Mxrb::WidgetPackage).to receive(:find).and_return(nil)
    descriptor = { id: 'vendor.Widget', name: 'Widget', studio_category: 'Custom', studio_pro_category: 'Custom' }
    widget = {
      type: :pluggable_widget, name: 'Widget', options: {
        widget_id: 'vendor.Widget', widget_name: 'Widget', platform: :Native
      }, events: []
    }
    doc = writer.send(:pluggable_widget_doc, widget, descriptor)
    expect(doc.dig('Type', 'SupportedPlatform')).to eq('Native')

    mappings = writer.send(:client_parameter_mapping_docs, {
      'App.Run.Input' => { kind: :widget, name: 'Grid' }, 'Other' => 'value'
    }, handler: 'App.Run', kind: :page)
    items = Mxrb::IO::BsonCodec.parse_array(mappings).fetch(:items)
    expect(items.first).to include('Argument' => '', 'Parameter' => 'App.Run.Input')
    expect(items.last.fetch('Argument')).to eq('value')

    native_source = writer.send(:data_view_source_doc, {
      kind: :native, native_type: 'Forms$FutureSource', unknown_native: {
        '$ID' => 'discarded', '$Type' => 'Discarded', 'Future' => true
      }
    })
    expect(native_source).to include('$Type' => 'Forms$FutureSource', Future: true)
    expect(native_source.fetch('$ID')).not_to eq('discarded')

    flow = {
      name: 'Run', unit_id: 'flow-id', parameters: [], body: [], return_type: nil,
      runtime: :server, kind: :use_case, public: false
    }
    expect(writer.send(:microflow_doc, flow, 'App', identity_by_unit_id: true))
      .to include('__mxrb_unit_id' => 'flow-id')
    expect do
      writer.send(:code_action_parameter_doc,
                  { kind: :entity_type, value: '' }, basic_type: 'Microflows$Basic', code: {})
    end.to raise_error(Mxrb::ValidationError, /requires an entity/)
    expect(writer.send(:code_action_parameter_doc,
                       { kind: :microflow, value: 'App.Helper' },
                       basic_type: 'Microflows$Basic', code: false))
      .to include('$Type' => 'Microflows$MicroflowJavaActionParameterValue',
                  'Microflow' => 'App.Helper')
  end

  it 'covers undeclared behavior collections and invalid typed settings models' do
    raw_module = { 'UnitID' => 'module-id' }
    raw_domain = { 'UnitID' => 'domain-id', 'ContainerID' => 'module-id' }
    domain = { 'Entities' => [2, { 'Name' => 'Item' }] }
    mpr = double(root_unit: { 'UnitID' => 'root' })
    allow(writer).to receive(:find_named).and_return(raw_module)
    allow(mpr).to receive(:units_by_containment).and_return([raw_domain])
    allow(mpr).to receive(:parse_contents).with(raw_domain).and_return(domain)
    allow(mpr).to receive(:transaction).and_yield
    allow(mpr).to receive(:update_unit)
    expect(writer.synchronize_ruby_entity_behaviors!(
             mpr, module_name: 'App', entities: [{ name: 'Item', validation_rules: nil }]
           )).to equal(writer)

    writer.instance_variable_get(:@definition)[:project_settings_model] = Object.new
    allow(mpr).to receive(:children_of).and_return([])
    expect { writer.send(:write_typed_project_settings, mpr, 'root') }
      .to raise_error(Mxrb::Settings::Error, /Settings::Node root/)
  end

  it 'covers opaque security entries and valid duplicate flow identities' do
    previous = writer.send(:project_security_doc, admin_user_role: '', user_roles: [], demo_users: [])
    previous['UserRoles'] = Mxrb::IO::BsonCodec.build_array(['opaque'])
    security = writer.send(:ruby_project_security_doc, {
      id: nil, admin_user_role: '', user_roles: [], demo_users: []
    }, previous)
    expect(Mxrb::IO::BsonCodec.parse_array(security.fetch('UserRoles')).fetch(:items))
      .to eq(['opaque'])
    expect do
      writer.send(:validate_flow_identities!, [
                    { name: 'Run', unit_id: 'one' }, { name: 'Run', unit_id: 'two' }
                  ], 'Microflows$Microflow')
    end.not_to raise_error
  end

  it 'covers overlay metadata alternatives and direct nested page contexts' do
    overlay = instance_double(Mxrb::Writer::PageOverlay, apply: true)
    allow(Mxrb::Writer::PageOverlay).to receive(:new).and_return(overlay)
    writer.send(:verify_page_overlay_target!, {}, {
      name: 'Home', deep_structure: { Mxrb::Writer::PageOverlay::METADATA_KEY => {} }, widgets: []
    }, 'App')
    writer.send(:verify_page_overlay_target!, {}, { name: 'Home', widgets: [] }, 'App')

    allow(writer).to receive(:flow_return_entity).and_return(nil)
    expect(writer.send(:page_context_entity, {
      data_source: nil, widgets: [{ type: :data_view, options: {
        source: { kind: :context, entity: 'App.Direct' }
      } }]
    }, 'App')).to eq('App.Direct')
    nested = [{ type: :container, options: {}, children: [{
      type: :data_view, options: { source: { kind: :context, entity: 'App.Nested' } }
    }] }]
    expect(writer.send(:first_data_view_source, nested)).to include(entity: 'App.Nested')

    raw_module = { 'UnitID' => 'module-id' }
    raw_page = { 'UnitID' => 'page-id' }
    mpr = double(all_units: [raw_module, raw_page])
    definition = writer.instance_variable_get(:@definition)
    definition[:modules] = [{
      name: 'App', pages: [{
        name: 'Home', write_mode: :overlay,
        deep_structure: { Mxrb::Writer::PageOverlay::METADATA_KEY => {} }, widgets: []
      }]
    }]
    allow(writer).to receive(:overlay_module_target).and_return(raw_module)
    allow(writer).to receive(:overlay_page_target).and_return(raw_page)
    allow(writer).to receive(:verify_page_overlay_target!)
    allow(mpr).to receive(:parse_contents).and_return({})
    writer.send(:preflight_page_overlays!, mpr, 'root')
  end

  it 'covers native document retention and storage identity alternatives' do
    mpr = double
    allow(writer).to receive(:collect_documents).and_return(
      [{ 'UnitID' => 'retained' }, { 'UnitID' => 'declared' }]
    )
    allow(mpr).to receive(:parse_contents).and_return(
      { '$Type' => 'Future$Document', 'Name' => 'Kept' },
      { '$Type' => 'Future$Document', 'Name' => 'Declared' }
    )
    allow(mpr).to receive(:delete_unit)
    allow(writer).to receive(:native_document_target).and_return({ 'UnitID' => 'retained' })
    allow(writer).to receive(:conventional_document_container).and_return('module-id')
    allow(writer).to receive(:relocate_root_document)
    allow(mpr).to receive(:update_unit)
    writer.send(:write_native_documents, mpr, 'module-id', {
      native_documents: [{
        type: 'Future$Document', name: 'Declared', containment: 'Documents',
        doc: { '$Type' => 'Future$Document', 'Name' => 'Declared' }
      }], managed_native_document_types: ['Future$Document']
    })
    expect(mpr).not_to have_received(:delete_unit)

    stable = { 'UnitID' => 'stable-id' }
    semantic = { 'UnitID' => 'semantic-id' }
    allow(mpr).to receive(:unit).with('missing-id').and_return(nil)
    allow(mpr).to receive(:children_of).and_return([semantic])
    allow(mpr).to receive(:parse_contents).with(semantic).and_return(
      '$ID' => 'semantic-doc', '$Type' => 'Future$Document', 'Name' => 'Kept'
    )
    expect(writer.send(:upsert_native_unit, mpr, 'module-id', {
      'unit_id' => '', 'containment' => 'Documents',
      'doc' => { '$Type' => 'Future$Document', 'Name' => 'Kept' }
    })).to eq('semantic-id')
    allow(mpr).to receive(:unit).with('stable-id').and_return(stable)
    allow(mpr).to receive(:parse_contents).with(stable).and_return(
      '$Type' => 'Future$Document', 'Name' => 'Stable'
    )
    allow(mpr).to receive(:insert_unit).and_return('inserted')
    expect(writer.send(:upsert_native_unit, mpr, 'module-id', {
      'unit_id' => 'stable-id', 'containment' => 'Documents',
      'doc' => { '$Type' => 'Future$Document', 'Name' => 'Stable' }
    })).to eq('stable-id')
  end

  it 'covers document lookup, native merges, OQL, access, association, and schedule alternatives' do
    candidates = [{ 'UnitID' => 'one' }, { 'UnitID' => 'two' }]
    mpr = double(unit: nil)
    allow(mpr).to receive(:parse_contents).and_return(
      { '$Type' => 'Microflows$Microflow' }, { '$Type' => 'Microflows$Microflow' }
    )
    expect do
      writer.send(:resolve_document_target, mpr, 'module', candidates,
                  { 'Name' => 'Run', '$Type' => 'Microflows$Microflow' }, 'missing-id',
                  allow_name_fallback: true)
    end.to raise_error(Mxrb::ValidationError, /with missing unit id/)

    merged = writer.send(:merge_existing_document,
                         { '$Type' => 'Constants$Constant', 'Type' => 'opaque' },
                         { '$Type' => 'Constants$Constant', 'Type' => 'new' })
    expect(merged.fetch('Type')).to eq('new')
    generated_type = { '$ID' => 'generated' }
    writer.send(:preserve_flow_parameter_metadata,
                { 'VariableType' => generated_type }, { 'VariableType' => {} })
    expect(generated_type.fetch('$ID')).to eq('generated')

    oql = {}
    writer.send(:apply_oql_view!, oql, { query: '', source: '' }, nil,
                module_name: 'App', entity_name: 'View')
    expect(oql).to include('Source')
    expect(writer.send(:apply_oql_view!, {}, { query: nil, source: '' }, nil,
                       module_name: 'App', entity_name: 'View')).to be_nil
    access = writer.send(:access_rule_doc, { roles: [], xpath_caption: nil }, 'App', 'Item')
    expect(access).not_to have_key('XPathConstraintCaption')
    expect(writer.send(:access_rule_doc, {
      roles: [], xpath_caption: 'Visible records'
    }, 'App', 'Item')).to include('XPathConstraintCaption' => 'Visible records')
    association = writer.send(:association_doc, { name: 'App.Link', type: :Reference },
                              from_id: 'from', to_id: 'to', previous: nil, oql_view: true)
    expect(association.dig('Source', '$Type')).to eq('DomainModels$OqlViewAssociationSource')
    previous = { 'Source' => { '$ID' => 'source-id' } }
    association = writer.send(:association_doc, { name: 'App.Link', type: :Reference },
                              from_id: 'from', to_id: 'to', previous:, oql_view: true)
    expect(association.dig('Source', '$ID')).to eq('source-id')
    schedule = writer.send(
      :scheduled_event_schedule, schedule_specified: true,
                                 schedule: { id: 'explicit', type: 'ScheduledEvents$DaySchedule', properties: {} }
    )
    expect(schedule.fetch('$ID')).to eq('explicit')
    generated_schedule = writer.send(
      :scheduled_event_schedule, schedule_specified: true,
                                 schedule: { id: '', type: 'ScheduledEvents$DaySchedule', properties: {} }
    )
    expect(generated_schedule.fetch('$ID')).not_to be_empty

    allow(writer).to receive(:flow_return_entity).and_return(nil, 'App.FlowResult')
    expect(writer.send(:page_context_entity, {
      data_source: nil, widgets: [{
        type: :data_view, options: { source: { kind: :microflow, name: 'App.Load' } }
      }]
    }, 'App')).to eq('App.FlowResult')
  end
end
# rubocop:enable Metrics/BlockLength
