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
    snippet = {
      type: 'Forms$Snippet', name: 'Summary', id: 'snippet-id', container_id: 'module-id',
      doc: { 'Parameters' => [2], 'Variables' => [2], 'Widgets' => [2] }
    }
    expect(exporter.send(:integration_document_declaration, template)).to include('page_template_document')
    expect(exporter.send(:integration_document_declaration, block)).to include('building_block_document')
    expect(exporter.send(:integration_document_declaration, snippet)).to include('snippet_document')
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
        '$Type' => 'Microflows$MappingRequestHandling', 'MappingId' => 'App.Request',
        'MappingVariableName' => 'Input'
      },
      'ResultHandlingType' => 'String',
      'ResultHandling' => {
        'Bind' => true, 'ImportMappingCall' => nil, 'ResultVariableName' => 'Body',
        'VariableType' => { '$Type' => 'DataTypes$StringType' }
      }
    }
    expect(exporter.send(:editable_action?, string_rest)).to be(true)
    empty_request = Marshal.load(Marshal.dump(string_rest))
    empty_request['RequestHandling'] = {
      '$Type' => 'Microflows$MappingRequestHandling',
      'MappingId' => '', 'MappingVariableName' => ''
    }
    expect(exporter.send(:editable_action?, empty_request)).to be(false)
    expect(exporter.send(:rest_call_line, '', empty_request))
      .not_to include('request_mapping:', 'request_variable:')
    empty_request['RequestHandling']['MappingVariableName'] = 'Input'
    expect(exporter.send(:editable_action?, empty_request)).to be(false)

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

  it 'recognizes binary preview formats and skips empty external assets' do
    expect(exporter.send(:forms_binary_extension, "\x89PNG\r\n\x1A\nrest".b)).to eq('.png')
    expect(exporter.send(:forms_binary_extension, "\xFF\xD8\xFFrest".b)).to eq('.jpg')
    expect(exporter.send(:forms_binary_extension, 'GIF87arest')).to eq('.gif')
    expect(exporter.send(:forms_binary_extension, 'RIFFxxxxWEBPrest'.b)).to eq('.webp')
    expect(exporter.send(:forms_binary_extension, 'opaque')).to eq('.bin')

    empty_asset = double(bytes: ''.b)
    allow(exporter).to receive(:visit_settings_values).and_yield(empty_asset)
    exporter.instance_variable_set(:@output_dir, '/tmp/unused')
    expect(exporter.send(:externalize_settings_binary_assets, double)).to equal(empty_asset)

    emitter = double(emit_as: "page_template_document :Empty\n")
    allow(Mxrb::Forms::SourceEmitter).to receive(:new).and_return(emitter)
    model = double
    expect(exporter.send(
             :typed_forms_document_declaration,
             { type: 'Forms$PageTemplate', name: 'Empty' }, model, output_path: nil
           )).to eq('page_template_document :Empty')
  end

  it 'rejects non-semantic integration-document shapes and exports opaque documents' do
    expect(exporter.send(:semantic_scheduled_event?, 'Future' => true)).to be(false)
    expect(exporter.send(:semantic_scheduled_event?, 'Schedule' => nil)).to be(true)
    expect(exporter.send(:scheduled_event_schedule_options, nil)).to eq(schedule: nil)
    expect(exporter.send(:semantic_consumed_odata_service?, 'Future' => true)).to be(false)
    expect(exporter.send(:semantic_consumed_odata_service?, {
      'HttpConfiguration' => { '$Type' => 'Future' }
    })).to be(false)
    expect(exporter.send(:semantic_consumed_odata_service?, {
      'HttpConfiguration' => { '$Type' => 'Microflows$HttpConfiguration', 'Future' => true }
    })).to be(false)
    expect(exporter.send(:semantic_consumed_odata_service?, {
      'HttpConfiguration' => {
        '$Type' => 'Microflows$HttpConfiguration', 'CustomLocationTemplate' => {}
      }
    })).to be(false)
    expect(exporter.send(:semantic_message_definition_collection?, 'Future' => true)).to be(false)
    expect(exporter.send(:semantic_entity_message_definition?, 'scalar')).to be(false)
    expect(exporter.send(:semantic_entity_message_definition?, '$Type' => 'Future')).to be(false)
    expect(exporter.send(:semantic_entity_message_definition?, {
      '$Type' => 'MessageDefinitions$EntityMessageDefinition', 'Future' => true
    })).to be(false)
    expect(exporter.send(:semantic_database_connection?, {})).to be(false)
    expect(exporter.send(:semantic_database_connection?, 'ConnectionInput' => {})).to be(false)
    expect(exporter.send(:database_query_semantic?, '$Type' => 'Future')).to be(false)
    expect(exporter.send(:semantic_enumeration?, {})).to be(false)

    opaque = {
      type: 'Future$Document', name: 'Opaque', id: 'unit-id', container_id: 'module-id',
      containment: 'Documents', doc: {}
    }
    expect(exporter.send(:integration_document_declaration, opaque)).to include('native_document')
  end

  it 'covers code-action binary and information alternatives' do
    expect(exporter.send(:code_action_info_spec, 'scalar')).to be_nil
    expect(exporter.send(:code_action_info_spec, {
      '$ID' => 'info-id', 'IconData' => nil
    })).to include(icon: { data: '', subtype: :generic })
    expect { exporter.send(:code_action_binary_spec, 'invalid') }
      .to raise_error(KeyError, /unsupported code action binary/)
  end

  it 'exports semantic metadata for scalar parameters and id-less flows' do
    flow = double(name: 'Run', parameters: ['scalar'], objects: [], flows: [])
    mod = double(name: 'App', rules: [flow], microflows: [], nanoflows: [])
    exporter.instance_variable_set(:@output_dir, '/tmp/unused')
    allow(exporter).to receive(:write)
    exporter.send(:export_semantic_metadata, [mod])
    expect(exporter).to have_received(:write).with(
      '/tmp/unused/.mxrb/semantic_metadata.json', include('"Run"')
    )
  end

  it 'covers REST metadata absence, scalar statuses, and malformed parameters' do
    expect(exporter.send(:native_rest_response, 'SuccessStatusCode' => 201))
      .to eq([{ status: 201, description: '' }])
    expect(exporter.send(:native_rest_response,
                         'SuccessStatusCode' => { 'Name' => 'HttpStatusCode_202' }))
      .to eq([{ status: 202, description: '' }])
    expect(exporter.send(:rest_responses_for, {}, {}, mod: nil)).to eq([])
    allow(exporter).to receive(:architecture_module).and_return(nil)
    expect(exporter.send(:architecture_rest_response, 'App', { name: 'Api' }, {}, {})).to be_nil
    expect(exporter.send(:rest_operation_parameter_signature, 'scalar')).to be_nil
    expect(exporter.send(:rest_operation_parameter_signature, '$Type' => 'Future')).to be_nil
    expect(exporter.send(:rest_operation_parameter_signature, {
      '$Type' => 'Rest$RestOperationParameter', 'Type' => 'scalar'
    })).to be_nil
    signature = exporter.send(:rest_parameter_type_signature, {
      '$ID' => 'discarded', '$Type' => 'DataTypes$ObjectType',
      'Entity' => { 'Name' => 'App.Item' }
    })
    expect(signature).not_to have_key('$ID')
    expect(signature.fetch('Entity')).to eq('Name' => 'App.Item')
  end

  it 'covers typed Forms error names, scalar widget types, and empty module-role ids' do
    project = double(mendix_version: '11.12.1')
    unit = { 'UnitID' => 'unit-id' }
    calls = 0
    allow(project).to receive(:parse_bson).with(unit) do
      calls += 1
      calls == 1 ? { '$Type' => 'Other' } : raise(KeyError, 'missing')
    end
    expect { exporter.send(:prepare_typed_forms, project, [unit], []) }
      .to raise_error(Mxrb::SerializationError, /typed Forms export failed/)

    codec = double
    allow(codec).to receive(:register_pluggable_type)
    exporter.instance_variable_set(:@forms_codec, codec)
    exporter.send(:register_embedded_widget_types,
                  '$Type' => 'CustomWidgets$CustomWidget', 'Type' => 'scalar')
    expect(codec).not_to have_received(:register_pluggable_type)

    allow(exporter).to receive(:write)
    exporter.send(:export_module_security, '/tmp/App', double(module_roles: [{ name: 'User', id: '' }]))
    expect(exporter).to have_received(:write).with(anything, include('module_role :User'))
    expect(exporter.send(:oql_document_for,
                         double(oql_source_document: ''), [], 'App')).to be_nil
  end

  it 'falls back to native declarations for non-semantic known document types' do
    cases = {
      'Rest$PublishedRestService' => {},
      'MessageDefinitions$MessageDefinitionCollection' => { 'Future' => true },
      'DomainModels$ViewEntitySourceDocument' => {},
      'DatabaseConnector$DatabaseConnection' => {},
      'DataSets$DataSet' => {},
      'Queues$Queue' => {},
      'ScheduledEvents$ScheduledEvent' => { 'Future' => true },
      'JavaScriptActions$JavaScriptAction' => {}
    }
    cases.each do |type, doc|
      document = {
        type:, name: 'Opaque', id: 'unit-id', container_id: 'module-id',
        containment: 'Documents', doc:
      }
      declaration = exporter.send(:integration_document_declaration, document)
      expect(declaration).to include('native_document')
    end
  end

  it 'disambiguates generated REST operation names' do
    operation = {
      method: :get, microflow: 'App.Find', path: '', documentation: '', parameters: []
    }
    resource = { 'Operations' => [2, {}, {}] }
    document = {
      id: 'service-id', container_id: 'module-id', name: 'Api',
      doc: { 'Resources' => [2, resource] }
    }
    allow(exporter).to receive(:rest_resource_spec).and_return(
      id: '', name: 'Orders', documentation: '', operations: [operation, operation]
    )
    allow(exporter).to receive(:rest_responses_for).and_return([])
    source = exporter.send(:published_rest_declaration, document)
    expect(source).to include('get :find,', 'get :find_2,')
  end

  it 'exports all project-role and entity metadata alternatives' do
    role = {
      'Name' => 'Manager', 'Description' => 'Manages users', 'CheckSecurity' => false,
      'ManageAllRoles' => false, 'ManageUsersWithoutRoles' => true,
      'ModuleRoles' => [2], 'ManageableRoles' => [2, 'User']
    }
    source = exporter.send(:security_source, {
      'SecurityLevel' => 'Production', 'UserRoles' => [2, role],
      'EnableDemoUsers' => false, 'EnableGuestAccess' => false
    })
    expect(source).to include('description:', 'check_security: false',
                              'manageable_roles:', 'manage_users_without_roles: true')

    entity = Object.new
    {
      name: 'View', attributes: [], persistable: true, documentation: '', access_rules: [],
      oql_source_document: nil, oql_query: 'SELECT 1', system_members: {},
      indexes: [{ 'IncludeInOffline' => true, 'Attributes' => [2, {
        'Attribute' => 'App.View.Code', 'Ascending' => true
      }] }]
    }.each { |name, value| entity.define_singleton_method(name) { value } }
    allow(exporter).to receive(:oql_view_entity?).with(entity).and_return(true)
    entity_source = exporter.send(:entity_source, entity, double(name: 'App'), [], {
      lifecycle: [{ event: :before_commit, handler: 'App.Validate' }]
    })
    expect(entity_source).to include('query: "SELECT 1"', 'include_offline: true', 'before_commit')

    index_attribute = double(id: 'attribute-id', name: 'Code')
    indexed_entity = double(attributes: [index_attribute], qualified_name: 'App.View')
    expect(exporter.send(
             :exported_index_member_name, indexed_entity,
             { 'AttributePointer' => 'attribute-id' }, 'Normal'
           )).to eq('Code')
    expect(exporter.send(:exported_index_member_name, indexed_entity, {}, 'CreatedDate'))
      .to eq('CreatedDate')
    expect do
      exporter.send(:exported_index_member_name, indexed_entity, {}, 'Owner')
    end.to raise_error(Mxrb::SerializationError, /unsupported index member type/)
    expect do
      exporter.send(
        :exported_index_member_name, indexed_entity,
        { 'AttributePointer' => 'missing' }, 'Normal'
      )
    end.to raise_error(Mxrb::SerializationError, /unresolved index attribute pointer/)
  end

  it 'exports complete access-rule and public-page options' do
    access = exporter.send(:access_rule_source, {
      roles: ['App.User'], id: 'rule-id', documentation: 'Restricted',
      default_rights: 'None', members: [], xpath: '', xpath_caption: 'Visible records'
    })
    expect(access).to include('id:', 'documentation:', 'xpath_caption:')
    expect(exporter.send(:access_rule_source, {
      roles: ['App.User'], id: '', default_rights: 'None', members: [], xpath: ''
    })).not_to include('id:')

    page = double(
      name: 'Home', id: 'page-id', layout_id: nil, title: 'Home', popup_width: 0,
      popup_height: 0, allowed_module_roles: [], widgets: [], data_source: nil,
      raw_document: nil
    )
    expect(exporter.send(:page_source, page, { widgets: [], public: true }))
      .to include('public: true')
    emitter = double(emit_as: 'text :Body')
    allow(Mxrb::Forms::SourceEmitter).to receive(:new).and_return(emitter)
    expect(exporter.send(:typed_page_source, page, Object.new, public: true))
      .to include('public: true')
    expect(exporter.send(:typed_page_source, page, Object.new, nil))
      .not_to include('public: true')
  end

  it 'discovers every root widget-slot representation' do
    expect(exporter.send(:page_root_widget_slots, 'opaque')).to eq([])
    expect(exporter.send(:page_root_widget_slots, 'Widgets' => [2, { 'Name' => 'Root' }]))
      .to eq([[{ 'Name' => 'Root' }]])
    expect(exporter.send(:page_root_widget_slots, 'FormCall' => 'opaque')).to eq([])
    slots = exporter.send(:page_root_widget_slots, {
      'FormCall' => { 'Arguments' => [2, 'opaque',
                                      { 'Widgets' => [2, { 'Name' => 'Modern' }] },
                                      { 'Widget' => { 'Name' => 'Legacy' } }] }
    })
    expect(slots).to eq([[{ 'Name' => 'Modern' }], [{ 'Name' => 'Legacy' }]])
    page = double(raw_document: {})
    expect(exporter.send(:page_overlay_exportable?, page, [])).to be(false)
  end

  it 'validates and externalizes native fragments with metadata' do
    exporter.instance_variable_set(:@native_fragment_store, nil)
    expect { exporter.send(:native_fragment_ruby, 'value') }
      .to raise_error(Mxrb::ValidationError, /not initialized/)

    store = double(put: 'digest')
    exporter.instance_variable_set(:@native_fragment_store, store)
    document = {
      '$Type' => 'Future$Document', 'Name' => 'Opaque',
      'Endpoint' => 'https://example.test', 'Enabled' => true,
      'Payload' => BSON::Binary.new('bytes')
    }
    fragment = exporter.send(:native_fragment_ruby, document)
    expect(fragment).to include('types:', 'hints:', 'overrides:')
    sparse = exporter.send(:native_fragment_ruby, 'Payload' => BSON::Binary.new('bytes'))
    expect(sparse).not_to include('types:', 'overrides:')
    oversized = 'x' * (Mxrb::Exporter::INLINE_NATIVE_MAX_BYTES + 1)
    expect(exporter.send(:inline_native_fragment?, {}, oversized)).to be(false)
    long_line = 'x' * (Mxrb::Exporter::INLINE_NATIVE_MAX_LINE_BYTES + 1)
    expect(exporter.send(:inline_native_fragment?, {}, long_line)).to be(false)
  end

  it 'falls back for opaque code actions and exports scalar flow type metadata' do
    opaque = {
      type: 'JavaActions$JavaAction', name: 'Opaque', id: 'action-id',
      container_id: 'module-id', doc: {}
    }
    allow(exporter).to receive(:semantic_code_action?).with({}).and_return(false)
    allow(exporter).to receive(:native_document_declaration).with(opaque).and_return('native action')
    expect(exporter.send(:integration_document_declaration, opaque)).to eq('native action')

    Dir.mktmpdir('mxrb-semantic-metadata-') do |directory|
      exporter.instance_variable_set(:@output_dir, directory)
      allow(exporter).to receive(:editable_flow_body?).and_return(false)
      flow = double(
        id: 'flow-id', name: 'Run', parameters: [{ 'Name' => 'Value', 'Type' => 'String' }],
        objects: [], flows: [], return_type_document: nil
      )
      mod = double(name: 'App', rules: [flow], microflows: [], nanoflows: [])
      exporter.send(:export_semantic_metadata, [mod])
      metadata = JSON.parse(File.read(File.join(directory, '.mxrb', 'semantic_metadata.json')))
      expect(metadata.dig('modules', 'App', 'flows', 'Run', 'parameters', 0))
        .to include('name' => 'Value')
      expect(metadata.dig('modules', 'App', 'flows', 'Run', 'parameters', 0))
        .not_to have_key('type_id')
    end

    flow = double(
      name: 'Typed', parameters: [], return_type: 'App.Item', documentation: '',
      allow_concurrent_execution: true, mark_as_used: false, excluded: false,
      allowed_module_roles: [], objects: [], flows: []
    )
    expect(exporter.send(:microflow_source, flow)).to include('return_type :"App.Item"')
  end

  it 'renders sparse and decorated widget alternatives' do
    pluggable = exporter.send(:render_widget, {
      type: :pluggable_widget, name: 'Widget', options: {
        widget_id: 'vendor.Widget', platform: :Native
      }, events: []
    }, 0)
    expect(pluggable.join).to include('platform: :Native')
    expect(exporter.send(:render_widget, {
      type: :file_manager, name: 'Files', options: {}, events: []
    }, 0).join).to include('file_manager')
    expect(exporter.send(:render_widget, {
      type: :file_manager, name: 'Files', options: { editable: :always }, events: []
    }, 0).join).to include('editable: :always')
    table = exporter.send(:render_table_widget, {
      name: 'Table', options: { rows: [
        { options: { class: 'highlight' }, cells: [] }, { options: {}, cells: [] }
      ] }
    }, 0)
    expect(table.join).to include('class_name: "highlight"')
  end

  it 'rejects top-level break flows and renders default action alternatives' do
    objects = [
      { '$ID' => 'start', '$Type' => 'Microflows$StartEvent' },
      { '$ID' => 'break', '$Type' => 'Microflows$BreakEvent' },
      { '$ID' => 'end', '$Type' => 'Microflows$EndEvent' }
    ]
    flows = [
      { '$Type' => 'Microflows$SequenceFlow', 'OriginPointer' => 'start',
        'DestinationPointer' => 'break' },
      { '$Type' => 'Microflows$SequenceFlow', 'OriginPointer' => 'break',
        'DestinationPointer' => 'end' }
    ]
    expect(exporter.send(:editable_flow_body?, objects, flows, nested: false)).to be(false)
    download = exporter.send(:action_dsl_line, {
      'Action' => {
        '$Type' => 'Microflows$DownloadFileAction', 'FileDocumentVariableName' => 'File',
        'ShowFileInBrowser' => false, 'ErrorHandlingType' => 'Rollback'
      }
    }, 0)
    expect(download).to eq('download_file :File')
    expect(exporter.send(:database_query_line, '', 'Query' => nil)).to include('nil')
    xml = exporter.send(:export_xml_line, '', {
      'OutputMethod' => {}, 'ResultHandling' => { 'ContentType' => 'Xml' },
      'ErrorHandlingType' => 'Rollback'
    })
    expect(xml).not_to include('content_type:', 'error:')
  end

  it 'renders non-default REST result handling and region children' do
    action = {
      'HttpConfiguration' => {
        'HttpMethod' => 'Get', 'CustomLocationTemplate' => { 'Text' => '/items' }
      },
      'ResultHandling' => {
        'ImportMappingCall' => {
          'ContentType' => 'Yaml', 'ForceSingleOccurrence' => true,
          'Range' => { 'SingleObject' => true }, 'ParameterVariableName' => 'Input'
        }
      },
      'ErrorResultHandlingType' => 'None', 'ErrorHandlingType' => 'Rollback'
    }
    source = exporter.send(:rest_call_line, '', action)
    expect(source).to include('result_content_type: :yaml', 'force_single: true',
                              'single: true', 'parameter_variable: :Input')
    child = { type: :text, name: 'Child', options: {} }
    expect(exporter.send(:direct_widget_children, regions: { main: [child] })).to eq([child])
  end

  it 'covers empty Forms assets, nil schedule dates, scalar arrays, and empty semantic calls' do
    property = double(name: :image_data)
    schema = double(property: property)
    asset = Mxrb::Forms::BinaryAsset.from_bytes('')
    model = double(schema_type: schema, fetch: asset)
    expect(exporter.send(:externalize_forms_binary_assets, model, output_path: '/tmp/page.rb')).to be_nil

    document = {
      name: 'Tick', id: 'event-id', container_id: 'module-id',
      doc: { 'Microflow' => 'App.Tick', 'StartDateTime' => nil, 'Schedule' => nil }
    }
    expect(exporter.send(:scheduled_event_declaration, document)).to include('start_at: nil')
    expect(exporter.send(:semantic_call_lines, :constant, 'Value', {}, indent: 2))
      .to eq(['  constant :Value'])
    expect(exporter.send(:presentation_array_spec, %w[a b])).to eq(%w[a b])
  end

  it 'covers REST service and inferred-parameter alternatives' do
    expect(exporter.send(:semantic_rest_service?, {})).to be(false)
    rest_doc = { 'Resources' => [2], 'Path' => '/', 'Parameters' => [2, {}] }
    expect(exporter.send(:semantic_rest_service?, rest_doc)).to be(false)
    expect(exporter.send(:semantic_rest_operation_parameters?, { 'Parameters' => [2] }, nil)).to be(true)
    expect(exporter.send(:semantic_rest_operation_parameters?, {
      'Parameters' => [2, { '$Type' => 'Rest$RestOperationParameter' }]
    }, nil)).to be(false)

    invalid_flow = double(name: 'Run', parameters: ['scalar'])
    mod = double(name: 'App', microflows: [invalid_flow])
    expect(exporter.send(:inferred_rest_operation_parameters,
                         { 'Microflow' => 'Run', 'Path' => '/' }, mod)).to be_nil
    valid_flow = double(name: 'Run', parameters: [{
      'Name' => 'id', 'Type' => { '$Type' => 'DataTypes$StringType' }
    }])
    mod = double(name: 'App', microflows: [valid_flow])
    expect(exporter.send(:inferred_rest_operation_parameters,
                         { 'Microflow' => 'App.Run', 'Path' => '/{id}' }, mod).first)
      .to include(microflow_parameter: 'App.Run.id')
  end

  it 'renders REST resource identity, duplicate names, generated names, and enabled constraints' do
    document = {
      id: 'service-id', container_id: 'module-id', name: 'Api', doc: {
        'Resources' => [2, {
          'Name' => 'Orders', 'Operations' => [2, {}, {}]
        }]
      }
    }
    operations = [
      { method: :get, microflow: '', path: '', documentation: '', parameters: [] },
      { method: :get, microflow: '', path: '', documentation: '', parameters: [] }
    ]
    allow(exporter).to receive(:rest_resource_spec).and_return(
      id: '', name: 'Orders', documentation: '', operations:
    )
    source = exporter.send(:published_rest_declaration, document)
    expect(source).to include('resource :Orders do', 'get :get_1', 'get :get_2')

    dataset = {
      name: 'Data', doc: {
        'DataSetAccess' => { 'ModuleRoleAccessList' => [2, {
          'ModuleRole' => 'App.User', 'ParameterAccessList' => [2, {
            'ParameterName' => 'Value', 'ConstraintAccessList' => [2, {
              'ConstraintText' => 'true', 'Enabled' => true
            }]
          }]
        }] }, 'Source' => { 'Query' => 'SELECT 1' }
      }
    }
    dataset_source = exporter.send(:dataset_declaration, dataset)
    expect(dataset_source).to include('constraint "true"')
    expect(dataset_source).not_to include('enabled: false')
  end

  it 'renders sparse and specialized widgets through the main dispatch' do
    table = { type: :table, name: 'Table', options: { columns: [], rows: [] } }
    grid = { type: :layout_grid, name: 'Grid', options: { rows: [] } }
    expect(exporter.send(:render_widget, table, 0).first).to start_with('table')
    expect(exporter.send(:render_widget, grid, 0).first).to start_with('layout_grid')

    image = {
      type: :static_image, name: 'Logo',
      options: { image: 'App.Logo', responsive: false }, events: []
    }
    rendered = exporter.send(:render_widget, image, 0).join("\n")
    expect(rendered).to include('responsive: false')
    expect(rendered).not_to include('alternative_text:', 'width:', 'height:')

    data_grid = {
      type: :data_grid, name: 'Items', options: { selection: :single, columns: [] }, events: []
    }
    text = { type: :text, name: 'Title', options: { parameters: ['$name'] }, events: [] }
    expect(exporter.send(:render_widget, data_grid, 0).first).to include('selection: :single')
    expect(exporter.send(:render_widget, text, 0).first).to include('parameters:')
    expect do
      exporter.send(:render_legacy_semantic_widget,
                    { type: :static_image, name: 'Opaque', options: {} }, 0)
    end.to raise_error(NoMethodError)
  end

  it 'renders minimal and complex data-view declarations and appearances' do
    source = exporter.send(:data_view_source_ruby, kind: :context, entity: 'App.Item')
    expect(source).to eq('context(entity: "App.Item")')
    complex = exporter.send(
      :data_view_source_ruby,
      kind: :microflow, name: 'App.Load', settings_native: { 'Future' => true }
    )
    expect(complex).to start_with('view_source(')
    expect(exporter.send(:data_view_source_ruby,
                         kind: :listen, target: 'Grid')).to eq('listen_to(:Grid)')
    variable = exporter.send(:page_variable_ruby,
                             name: 'Item', sub_key: 'id', use_all_pages: true)
    expect(variable).to include('sub_key:', 'use_all_pages: true')
    expect(exporter.send(:data_view_condition_ruby, :visible_when, {}, 0))
      .to eq(['visible_when '])

    view = {
      type: :data_view, name: 'Details', options: {
        source: { kind: :context, entity: 'App.Item' }, show_footer: true,
        design_properties: [{ key: 'Color', option: 'Red' }]
      }
    }
    rendered = exporter.send(:render_data_view_widget, view, 0).join("\n")
    expect(rendered).to include('design_property "Color"')
    expect(rendered).not_to include('show_footer: false', 'id:', 'value_id:')

    args = []
    exporter.send(:append_appearance_ruby_args, args,
                  style: 'x', dynamic_class: '$class', visible: '$visible')
    expect(args).to include('style: "x"', 'dynamic_class: "$class"', 'visible: "$visible"')
  end
end
# rubocop:enable Metrics/BlockLength
