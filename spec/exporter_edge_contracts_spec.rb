# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Exporter, 'remaining edge contracts' do
  subject(:exporter) { described_class.allocate }

  it 'dispatches presentation documents and preserves binary values' do
    template = {
      type: 'Forms$PageTemplate', name: 'Starter', id: 'template-id', container_id: 'module-id',
      doc: { 'ImageData' => BSON::Binary.new('preview') }
    }
    block = {
      type: 'Forms$BuildingBlock', name: 'Card', id: 'block-id', container_id: 'module-id',
      doc: { 'ImageData' => BSON::Binary.new('preview') }
    }
    expect(exporter.send(:integration_document_declaration, template)).to include('page_template_document')
    expect(exporter.send(:integration_document_declaration, block)).to include('building_block_document')
    expect(exporter.send(:presentation_value_spec, BSON::Binary.new('bytes')))
      .to include(binary: 'Ynl0ZXM=', subtype: :generic)

    queue = {
      name: 'Jobs', id: 'queue-id', container_id: 'module-id',
      doc: { 'Config' => { '$Type' => 'Queues$BasicQueueConfig', 'Parallelism' => 4 } }
    }
    expect(exporter.send(:task_queue_declaration, queue)).to include('parallelism: 4')
  end

  it 'exports remote enumeration identities and values' do
    caption = { '$ID' => 'caption-id', 'Items' => [3, {
      '$ID' => 'translation-id', 'LanguageCode' => 'en_US', 'Text' => 'Open'
    }] }
    document = {
      name: 'State', id: 'unit-id',
      doc: {
        '$ID' => 'enum-id', 'RemoteSource' => {
                              '$ID' => 'remote-source-id', '$Type' => 'Rest$ODataRemoteEnumerationSource',
                              'ConsumedODataService' => 'App.Api', 'RemoteName' => 'RemoteState'
                            },
        'Values' => [3, {
          '$ID' => 'value-id', 'Name' => 'Open', 'Caption' => caption,
          'RemoteValue' => {
            '$ID' => 'remote-value-id', '$Type' => 'Rest$ODataRemoteEnumerationValue',
            'RemoteName' => 'remote-open'
          }
        }]
      }
    }
    source = exporter.send(:enumeration_declaration, document)
    expect(source).to include('remote_service:', 'remote_name:', 'remote_id:')
  end

  it 'splits REST response metadata and emits datasets with access constraints' do
    marker = Mxrb::Dsl::IntegrationDocuments::REST_RESPONSES_MARKER
    prose, responses = exporter.send(
      :split_rest_responses, "#{marker.lstrip}- 201: created\nignored\n- 204: empty"
    )
    expect(prose).to eq('')
    expect(responses).to eq([{ status: 201, description: 'created' },
                             { status: 204, description: 'empty' }])
    expect(exporter.send(:split_rest_responses, 'plain')).to eq(['plain', []])

    parameter_access = [
      2,
      { 'ParameterName' => 'Order', 'ConstraintAccessList' => [2] },
      {
        'ParameterName' => 'State',
        'ConstraintAccessList' => [2, {
          'ConstraintText' => '[%CurrentUser%]', 'Enabled' => false
        }]
      }
    ]
    document = {
      name: 'Orders',
      doc: {
        'Parameters' => [2,
                         { 'Name' => 'Order', 'ParameterType' => {
                           '$Type' => 'DataTypes$ObjectType', 'Entity' => 'App.Order'
                         } },
                         { 'Name' => 'State', 'ParameterType' => {
                           '$Type' => 'DataTypes$EnumerationType', 'Enumeration' => 'App.State'
                         } }],
        'DataSetAccess' => { 'ModuleRoleAccessList' => [2, {
          'ModuleRole' => 'App.User', 'ParameterAccessList' => parameter_access
        }] },
        'Source' => { 'Query' => "SELECT *\nFROM App.Order", 'IEIQ' => true }
      }
    }
    source = exporter.send(:dataset_declaration, document)
    expect(source).to include('object_of(', 'enum_of(', 'allow "App.User" do',
                              'enabled: false', 'OQL, ieiq: true')
    expect(exporter.send(:dataset_type_source, '$Type' => 'DataTypes$StringType')).to eq('string')
  end

  it 'infers and compares semantic REST operation parameters' do
    parameters = [{
      'Name' => 'id', 'VariableType' => { '$Type' => 'DataTypes$StringType' }
    }, {
      'Name' => 'filter', 'Type' => { '$Type' => 'DataTypes$IntegerType' }
    }]
    flow = double(name: 'Find', parameters:)
    mod = double(name: 'App', microflows: [flow])
    operation = { 'Microflow' => 'Find', 'Path' => '/{id}' }
    inferred = exporter.send(:inferred_rest_operation_parameters, operation, mod)
    expect(inferred).to include(include(name: 'id', parameter_type: 'Path'),
                                include(name: 'filter', parameter_type: 'Query'))
    actual = inferred.map do |item|
      {
        '$Type' => 'Rest$RestOperationParameter', 'Name' => item.fetch(:name),
        'Description' => '', 'MicroflowParameter' => item.fetch(:microflow_parameter),
        'ParameterType' => item.fetch(:parameter_type),
        'Type' => parameters.find { (_1['Name'] || _1['name']) == item.fetch(:name) }
                            .then { _1['VariableType'] || _1['Type'] }
      }
    end
    operation['Parameters'] = Mxrb::IO::BsonCodec.build_array(actual)
    expect(exporter.send(:semantic_rest_operation_parameters?, operation, mod)).to be(true)
    actual.first['Unexpected'] = true
    expect(exporter.send(:rest_operation_parameter_signature, actual.first)).to be_nil
    expect(exporter.send(:inferred_rest_operation_parameters, operation, nil)).to be_nil
    expect(exporter.send(:inferred_rest_operation_parameters,
                         operation.merge('Microflow' => 'Missing'), mod)).to be_nil
  end

  it 'renders pluggable slots and a fully configured data view' do
    expect(exporter.send(:pluggable_slot_declaration, [:content], 2)).to eq('  slot :content')
    expect(exporter.send(:pluggable_slot_declaration, [:items, :objects, 1, :content], 2))
      .to include('within: :items', 'item: 1')
    expect(exporter.send(:pluggable_slot_declaration, %i[future path], 2)).to include('slot path:')
    expect(exporter.send(:render_pluggable_slot, { path: [:content], widgets: [] }, 2))
      .to eq(['  slot :content'])
    expect(exporter.send(
      :render_pluggable_slot,
      { path: [:content], widgets: [{ type: :text, name: 'Child', options: {} }] }, 2
    ).join("\n")).to include('slot :content do', 'text :Child')

    source = exporter.send(
      :render_data_view_widget,
      {
        type: :data_view, name: 'Order',
        options: {
          source: {
            kind: :context, entity: 'App.Order', force_full_objects: true,
            variable: { name: 'Order', kind: :local_variable, sub_key: 'id', use_all_pages: true }
          },
          editable: :never, read_only_style: :text, label_width: 4, show_footer: false,
          no_entity_message: 'Missing', tab_index: 2,
          visibility: {
            expression: 'true', roles: ['App.User'], attribute: 'Active',
            conditions: [{ value: true }], ignore_security: true,
            source_variable: { name: 'Order', kind: :widget, unknown_native: { 'Future' => true } },
            unknown_native: { 'Flag' => true }
          },
          editability: { expression: 'false' },
          design_properties: [
            { key: 'Color', option: 'Red', id: 'property-id', value_id: 'value-id' },
            { future: true }
          ],
          unknown_native: { 'Future' => true }
        },
        body: [{ type: :text, name: 'Body', options: {} }],
        footer: [{ type: :text, name: 'Footer', options: {} }]
      }, 0
    ).join("\n")
    expect(source).to include('editable: :never', 'body do', 'footer do', 'visible_when',
                              'design_property', 'design_properties(', 'unknown_native(')
  end

  it 'renders every concise data-view source and mapping alternative' do
    context = exporter.send(
      :data_view_source_ruby,
      kind: :context, entity: 'App.Order', variable: {
        name: 'Order', kind: :local_variable, sub_key: 'id', use_all_pages: true
      }
    )
    association = exporter.send(
      :data_view_source_ruby,
      kind: :association, entity: 'App.Customer',
      steps: [{ association: 'App.Order_Customer' }],
      variable: { name: 'Order' }
    )
    multi = exporter.send(
      :data_view_source_ruby,
      kind: :association, entity: 'App.Region', steps: [
        { association: 'App.Order_Customer', entity: 'App.Customer' },
        { association: 'App.Customer_Region', entity: 'App.Region' }
      ]
    )
    flow = exporter.send(
      :data_view_source_ruby,
      kind: :microflow, name: 'App.Load', mappings: [
        { parameter: 'Input', expression: '$Order' },
        { parameter: 'Context', variable: { name: 'Order', kind: :widget } }
      ]
    )
    listen = exporter.send(
      :data_view_source_ruby,
      kind: :listen, target: 'Grid', force_full_objects: true,
      unknown_native: { 'Future' => true }
    )
    complex = exporter.send(:data_view_source_ruby, kind: :native, native_type: 'Future')
    expect([context, association, multi, flow, listen, complex].join("\n"))
      .to include('context(', 'association(', 'microflow_source(', 'listen_to(', 'view_source(')
  end

  it 'renders table and responsive layout-grid branches' do
    table = exporter.send(
      :render_table_widget,
      {
        type: :table, name: 'Matrix', options: {
          width_unit: :pixels, tab_index: 2, columns: [{ width: 40 }],
          rows: [{ options: { class: 'row' }, cells: [
            { column: 1, colspan: 2, rowspan: 3, header: true, options: { class: 'cell' },
              widgets: [{ type: :text, name: 'Value', options: {} }] },
            { widgets: [] }
          ] }]
        }
      }, 0
    ).join("\n")
    expect(table).to include('table :Matrix', 'column width: 40', 'colspan: 2', 'header: true')

    grid = exporter.send(
      :render_layout_grid_widget,
      {
        type: :layout_grid, name: 'Grid', options: {
          width: :fixed, tab_index: 2,
          rows: [
            { options: {}, columns: [] },
            { options: { horizontal_alignment: :center, vertical_alignment: :bottom, gutters: false },
              columns: [
                { options: { desktop: 6, tablet: :auto, phone: :grow,
                             vertical_alignment: :center }, widgets: [] },
                { options: {}, widgets: [{ type: :text, name: 'Nested', options: {} }] }
              ] }
          ]
        }
      }, 0
    ).join("\n")
    expect(grid).to include('layout_grid :Grid', 'horizontal_alignment: :center',
                            'tablet: :auto', 'desktop: 6', 'text :Nested')
  end

  it 'renders export XML, string REST results, and nonliteral Ruby values' do
    xml = exporter.send(
      :export_xml_line, '  ',
      'OutputMethod' => { 'OutputVariableName' => 'Json' },
      'ResultHandling' => {
        'MappingVariableName' => 'Input', 'MappingId' => 'App.Export', 'ContentType' => 'Json'
      },
      'IsValidationRequired' => true, 'ErrorHandlingType' => 'Continue'
    )
    expect(xml).to include('content_type: :json', 'validate: true', 'error: :continue')
    rest = exporter.send(
      :rest_call_line, '',
      'HttpConfiguration' => {
        'HttpMethod' => 'Get', 'CustomLocationTemplate' => { 'Text' => '/items' },
        'HttpHeaderEntries' => [2]
      },
      'RequestHandling' => {}, 'ResultHandling' => { 'ResultVariableName' => 'Body' },
      'ResultHandlingType' => 'String', 'ErrorResultHandlingType' => 'Rollback',
      'ErrorHandlingType' => 'Rollback'
    )
    expect(rest).to include('result_handling: :string', 'as: :Body')
    expect(exporter.send(:ruby_val, 'hello world')).to eq('"hello world"')
  end

  it 'renders enum flow types, event arguments, pluggable bodies, and container events' do
    expect(exporter.send(
             :flow_type_source,
             '$Type' => 'DataTypes$EnumerationType', 'Enumeration' => 'App.State'
           )).to eq('enum_of("App.State")')
    event = { event: :on_click, kind: :microflow, handler: 'App.Run', arguments: { Input: '$value' } }
    expect(exporter.send(:render_widget_event, event, 2)).to include('pass:')
    pluggable = {
      type: :pluggable_widget, name: 'Grid',
      options: { widget_id: 'Vendor.Grid' },
      slots: [{ path: [:content], widgets: [] }], events: [event]
    }
    expect(exporter.send(:render_widget, pluggable, 0).join("\n"))
      .to include('pluggable_widget :Grid', 'slot :content', 'on_click')
    container = { type: :container, name: 'Box', options: {}, children: [], events: [event] }
    expect(exporter.send(:render_widget, container, 0).join("\n"))
      .to include('container :Box do', 'on_click')
    expect(exporter.send(:direct_widget_children, type: :container,
                                                  slots: [{ widgets: [{ name: 'Nested' }] }]))
      .to eq([{ name: 'Nested' }])
  end

  it 'recognizes editable string REST and export-XML actions and emits break loops' do
    string_rest = {
      '$Type' => 'Microflows$RestCallAction',
      'HttpConfiguration' => {
        'HttpMethod' => 'Get', 'HttpHeaderEntries' => [2],
        'CustomLocationTemplate' => { 'Parameters' => [2] }
      },
      'RequestHandling' => {
        '$Type' => 'Microflows$MappingRequestHandling', 'MappingId' => 'App.Request'
      },
      'ResultHandlingType' => 'String',
      'ResultHandling' => {
        'Bind' => true, 'ImportMappingCall' => nil, 'ResultVariableName' => 'Body',
        'VariableType' => { '$Type' => 'DataTypes$StringType' }
      }
    }
    expect(exporter.send(:editable_action?, string_rest)).to be(true)

    export_xml = {
      '$Type' => 'Microflows$ExportXmlAction',
      'OutputMethod' => {
        '$Type' => 'ExportXmlAction$StringExport', 'OutputVariableName' => 'Body'
      },
      'ResultHandling' => {
        '$Type' => 'Microflows$MappingRequestHandling', 'ContentType' => 'Json',
        'MappingId' => 'App.Export', 'MappingVariableName' => 'Input'
      },
      'IsValidationRequired' => false
    }
    expect(exporter.send(:editable_action?, export_xml)).to be(true)
    expect(exporter.send(:action_dsl_line, { 'Action' => export_xml }, 0)).to include('export_xml')
    break_event = { '$ID' => 'break', '$Type' => 'Microflows$BreakEvent' }
    expect(exporter.send(:body_dsl_lines, [break_event], [], 4, nested: true))
      .to eq(['    break_loop'])
  end

  it 'wraps typed Forms, settings, and system-text decoding failures' do
    project = double(mendix_version: '11.12.1')
    unit = { 'UnitID' => 'page-id' }
    allow(project).to receive(:parse_bson).with(unit).and_return(
      '$Type' => 'Forms$PageTemplate', 'Name' => 'Broken'
    )
    codec = double
    allow(codec).to receive(:register_pluggable_type)
    allow(codec).to receive(:decode).and_raise(KeyError, 'missing field')
    allow(Mxrb::Forms::MprCodec).to receive(:new).and_return(codec)
    expect { exporter.send(:prepare_typed_forms, project, [unit], []) }
      .to raise_error(Mxrb::SerializationError, /typed Forms export failed for Broken/)

    page = double(id: 'runtime-page', raw_document: {}, widgets: [{ type: :future }], name: 'Runtime')
    mod = double(pages: [page])
    allow(exporter).to receive(:semantic_page_baseline?).and_return(false)
    expect { exporter.send(:prepare_typed_forms, project, [], [mod]) }
      .to raise_error(Mxrb::SerializationError, /typed Forms export failed for page Runtime/)

    settings_codec = double(decode: nil)
    allow(settings_codec).to receive(:decode).and_raise(KeyError, 'settings')
    allow(Mxrb::Settings::MprCodec).to receive(:new).and_return(settings_codec)
    expect { exporter.send(:typed_project_settings_declaration, {}) }
      .to raise_error(Mxrb::SerializationError, /typed project settings export failed/)

    texts_codec = double(decode: nil)
    allow(texts_codec).to receive(:decode).and_raise(KeyError, 'texts')
    allow(Mxrb::SystemTexts::MprCodec).to receive(:new).and_return(texts_codec)
    expect { exporter.send(:typed_system_text_declaration, {}) }
      .to raise_error(Mxrb::SerializationError, /typed system-text export failed/)
  end

  it 'emits resource documentation, page event arguments, and symbolic values' do
    document = {
      id: 'service-id', container_id: 'module-id', name: 'Api',
      doc: { 'Resources' => [2, { 'Operations' => [2] }] }
    }
    allow(exporter).to receive(:rest_resource_spec).and_return(
      id: 'resource-id', name: 'Orders', documentation: 'Order operations', operations: []
    )
    expect(exporter.send(:published_rest_declaration, document))
      .to include('documentation: "Order operations"')

    page = double(
      name: 'Home', id: 'page-id', layout_id: nil, title: 'Home', popup_width: 0,
      popup_height: 0, allowed_module_roles: [], widgets: [], data_source: nil,
      raw_document: nil
    )
    metadata = {
      widgets: [], public: false,
      events: [{ event: :on_load, kind: :microflow, handler: 'App.Load', arguments: { Input: '$value' } }]
    }
    expect(exporter.send(:page_source, page, metadata)).to include('pass:')
    expect(exporter.send(:ruby_val, :future)).to eq('"future"')
  end
end
# rubocop:enable Metrics/BlockLength
