# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::Exporter, 'edge contracts' do
  subject(:exporter) { described_class.allocate }

  it 'reports malformed REST metadata and reads documented success responses' do
    Dir.mktmpdir('mxrb-rest-metadata-') do |dir|
      exporter.instance_variable_set(:@mendix_sidecar, dir)
      path = File.join(dir, '.mxrb', 'rest_metadata.json')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, '{broken')
      expect { exporter.send(:read_rest_response_metadata) }
        .to raise_error(Mxrb::SerializationError, /invalid REST metadata sidecar/)
    end

    marker = Mxrb::Dsl::IntegrationDocuments::REST_RESPONSES_MARKER
    expect(exporter.send(:rest_documented_success_status, "#{marker.lstrip}- 204: empty"))
      .to eq('204')
    expect(exporter.send(:rest_documented_success_status, "intro#{marker}- 202: accepted"))
      .to eq('202')
    expect(exporter.send(:rest_documented_success_status, 'plain documentation')).to be_nil
  end

  it 'projects scheduled events and resolves every index member form' do
    mod = double(name: 'Sales')
    exporter.instance_variable_set(:@embedded_identities, {})
    exporter.instance_variable_set(:@embedded_source_paths, {})
    exporter.instance_variable_set(:@embedded_sources, [])
    exporter.instance_variable_set(:@coverage, [])
    allow(exporter).to receive(:write)
    event = {
      'Name' => 'Cleanup', '$ID' => 'event-id', 'Enabled' => true,
      'Microflow' => 'Sales.Cleanup', 'Schedule' => {
        '$ID' => 'schedule-id', '$Type' => 'ScheduledEvents$Daily', 'Hour' => 3
      }
    }
    manifest = exporter.send(:export_scheduled_event, mod, event, 'Sales', 'sales')
    expect(manifest.fetch('schedule')).to include('type' => 'ScheduledEvents$Daily')
    event['Name'] = 'Detached'
    event['Schedule'] = nil
    event['Enabled'] = false
    event['Microflow'] = ''
    expect(exporter.send(:export_scheduled_event, mod, event, 'Sales', 'sales'))
      .to include('schedule' => nil, 'unbound' => true)

    attribute = double(id: 'attribute-id', name: 'Code')
    entity = double(attributes: [attribute], qualified_name: 'Sales.Order')
    expect(exporter.send(:index_member_name, entity, { 'Attribute' => 'Sales.Order.Name' }, 'Normal'))
      .to eq('Name')
    expect(exporter.send(:index_member_name, entity, { 'AttributePointer' => 'attribute-id' }, 'Normal'))
      .to eq('Code')
    expect(exporter.send(:index_member_name, entity, {}, 'CreatedDate')).to eq('CreatedDate')
    expect do
      exporter.send(:index_member_name, entity, { 'AttributePointer' => 'missing-id' }, 'Normal')
    end.to raise_error(Mxrb::SerializationError, /unresolved index attribute pointer/)
    expect { exporter.send(:index_member_name, entity, {}, 'Unsupported') }
      .to raise_error(Mxrb::SerializationError, /unsupported index member/)
  end

  it 'projects all remaining nanoflow action shapes' do
    mapping = [{ 'Parameter' => 'Sales.Child.Input', 'Argument' => '$Input' }]
    javascript_mapping = [{
      'Parameter' => 'Sales.Action.Input', 'ParameterValue' => { 'Argument' => '$Input' }
    }]
    cases = [
      [{ '$Type' => 'Microflows$CreateChangeAction', 'VariableName' => 'Item',
         'Entity' => 'Sales.Item', 'Items' => [] }, include('variable' => 'Item')],
      [{ '$Type' => 'Microflows$NanoflowCallAction', 'UseReturnVariable' => true,
         'OutputVariableName' => 'Result', 'NanoflowCall' => {
           'Nanoflow' => 'Sales.Child', 'ParameterMappings' => mapping
         } }, include('arguments' => { 'Input' => '$Input' }, 'result_variable' => 'Result')],
      [{ '$Type' => 'Microflows$JavaScriptActionCallAction', 'UseReturnVariable' => true,
         'OutputVariableName' => 'Result', 'JavaScriptAction' => 'Sales.Action',
         'ParameterMappings' => javascript_mapping },
       include('arguments' => { 'Input' => '$Input' }, 'result_variable' => 'Result')],
      [{ '$Type' => 'Microflows$ShowFormAction', 'FormSettings' => {
        'Form' => 'Sales.Edit', 'ParameterMappings' => mapping
      } }, include('page' => 'Sales.Edit')],
      [{ '$Type' => 'Microflows$CloseFormAction', 'NumberOfPagesToClose' => 200 },
       include('count' => '200')],
      [{ '$Type' => 'Microflows$ValidationFeedbackAction', 'Attribute' => '',
         'Association' => 'Sales.Item_Owner', 'ValidationVariableName' => 'Item',
         'FeedbackTemplate' => {} }, include('member' => 'Item_Owner')]
    ]
    cases.each do |action, matcher|
      expect(exporter.send(:nanoflow_action, action)).to matcher
    end
  end

  it 'passes entity type arguments to JavaScript actions as literal qualified entity names' do
    mapping = [{ 'Parameter' => 'FeedbackModule.Read.Entity', 'ParameterValue' => {
      '$Type' => 'Microflows$EntityTypeCodeActionParameterValue', 'Entity' => 'FeedbackModule.Feedback'
    } }]
    expect(exporter.send(:javascript_action_arguments, mapping))
      .to eq('Entity' => "'FeedbackModule.Feedback'")
  end

  it 'recovers embedded artifact paths by identity and qualified name' do
    exporter.instance_variable_set(:@embedded_sources, [
                                     { path: 'README.md', contents: 'ignored' },
                                     { path: 'app/constants/sales/by_id.rb',
                                       contents: "mendix_name 'Sales.Other', id: 'constant-id'" },
                                     { path: 'app/constants/sales/by_name.rb', contents: "mendix_name 'Sales.Named'" },
                                     { path: 'app/enumerations/sales/by_id.rb',
                                       contents: "mendix_name 'Sales.Other', id: 'enum-id'" },
                                     { path: 'app/enumerations/sales/by_name.rb',
                                       contents: "mendix_name 'Sales.State'" },
                                     { path: 'app/scheduled_events/sales/by_id.rb',
                                       contents: "mendix_name 'Sales.Other', id: 'event-id'" },
                                     { path: 'app/scheduled_events/sales/by_name.rb',
                                       contents: "mendix_name 'Sales.Cleanup'" }
                                   ])
    expect(exporter.send(:embedded_constant_path, 'constant-id', 'Sales.Missing')).to end_with('by_id.rb')
    expect(exporter.send(:embedded_constant_path, 'missing', 'Sales.Named')).to end_with('by_name.rb')
    expect(exporter.send(:embedded_enumeration_path, 'enum-id', 'Sales.Missing')).to end_with('by_id.rb')
    expect(exporter.send(:embedded_enumeration_path, 'missing', 'Sales.State')).to end_with('by_name.rb')
    expect(exporter.send(:embedded_scheduled_event_path, 'event-id', 'Sales.Missing')).to end_with('by_id.rb')
    expect(exporter.send(:embedded_scheduled_event_path, '', 'Sales.Cleanup')).to end_with('by_name.rb')
  end

  it 'serializes regions, slots, native fragments, binary values, and nested widget names' do
    Dir.mktmpdir('mxrb-native-fragments-') do |dir|
      exporter.instance_variable_set(:@native_fragment_store, Mxrb::NativeFragmentStore.new(dir))
      widget = {
        type: :container, name: :Root,
        regions: { main: [{ type: :text, name: :Region }] },
        slots: [{ path: [:content], role: :main, widgets: [{ type: :text, name: :Slot }] }]
      }
      expect(exporter.send(:widget_manifest, widget)).to include(
        'regions' => { 'main' => [include('name' => 'Region')] },
        'slots' => [include('role' => 'main')]
      )
      native = {
        type: :native_widget, name: :Native,
        options: { deep_structure: { 'Future' => true } }
      }
      expect(exporter.send(:widget_manifest, native).dig('options', 'native_fragment', 'digest'))
        .to match(/\A[0-9a-f]{64}\z/)
      nested_native = { type: :container, options: { child: native } }
      expect(exporter.send(:runtime_widget_options, nested_native)
                     .dig('options', 'child', 'options', 'native_fragment', 'digest')).to be_a(String)
      expect(exporter.send(:runtime_value, BSON::Binary.new('bytes'))).to include('$binary' => 'Ynl0ZXM=')
      expect { exporter.send(:native_widget_fragment_manifest, deep_structure: []) }
        .to raise_error(Mxrb::SerializationError, /must be a Hash/)
      exporter.instance_variable_set(:@native_fragment_store, nil)
      expect { exporter.send(:native_widget_fragment_manifest, deep_structure: {}) }
        .to raise_error(Mxrb::SerializationError, /not initialized/)
    end

    tree = {
      'name' => 'Root', 'children' => [{ 'name' => 'Child' }],
      'slots' => [{ 'widgets' => [{ 'name' => 'Slot' }] }],
      'regions' => { 'main' => [{ 'name' => 'Region' }] },
      'options' => { 'rows' => [{
        'widgets' => [{ 'name' => 'Row' }],
        'columns' => [{ 'widgets' => [{ 'name' => 'Column' }] }],
        'cells' => [{ 'widgets' => [{ 'name' => 'Cell' }] }]
      }] }
    }
    expect(exporter.send(:frontend_widget_names, tree))
      .to include('Root', 'Child', 'Slot', 'Region', 'Row', 'Column', 'Cell')
  end

  it 'emits fallback security, unbound schedules, gallery sorts, and design-property rejection' do
    fallback = exporter.send(:password_policy_source, 'properties' => { 'Future' => nil })
    expect(fallback).to include('password_policy properties:')
    event = {
      'name' => 'Sales.Cleanup', 'documentation' => '', 'export_level' => 'Hidden',
      'unbound' => true, 'microflow' => '', 'start_at' => '', 'time_zone' => '',
      'on_overlap' => '', 'enabled' => false, 'interval_type' => '', 'interval' => 0,
      'schedule' => nil
    }
    expect(exporter.send(:scheduled_event_source, 'Sales', 'Cleanup', event)).to include('unbound')
    gallery = { 'type' => 'gallery', 'name' => 'Items', 'options' => {
      'sort' => [{ 'attribute' => 'Name', 'direction' => 'ascending' }]
    } }
    expect(exporter.send(:runtime_widget_call_source, gallery, 0, generic_sink: true)).to include('sort_by')
    expect(exporter.send(:runtime_design_property_supported?, 'future')).to be(false)
    expect(exporter.send(
             :runtime_design_property_supported?,
             'id' => 'id', 'key' => 'key', 'value_id' => 'value'
           )).to be(false)

    one = double(name: 'Run', id: '')
    two = double(name: 'Run', id: 'two')
    expect { exporter.send(:duplicate_flow_ids, [one, two]) }
      .to raise_error(Mxrb::SerializationError, /distinct explicit unit ids/)
  end

  it 'covers absent sidecars, identities, and source files' do
    Dir.mktmpdir('mxrb-ruby-exporter-missing-') do |dir|
      exporter.instance_variable_set(:@mendix_sidecar, dir)
      expect(exporter.send(:read_rest_response_metadata)).to eq([])
      exporter.instance_variable_set(:@embedded_identities, {
        %w[record id] => { 'path' => 'app/models/item.rb' }
      })
      exporter.instance_variable_set(:@embedded_source_paths, nil)
      expect(exporter.send(:embedded_identity, :record, :id)).to be_nil
      exporter.instance_variable_set(:@output_dir, dir)
      expect(exporter.send(:copy_round_trip_metadata)).to be_nil
    end
  end

  it 'projects project security without native ids or a password policy' do
    unit = { 'UnitID' => 'security-unit' }
    document = {
      '$Type' => 'Security$ProjectSecurity', '$ID' => nil,
      'SecurityLevel' => 'Production', 'UserRoles' => [2], 'DemoUsers' => [2]
    }
    project = double(all_units: [unit])
    allow(project).to receive(:parse_bson).with(unit).and_return(document)
    allow(exporter).to receive(:embedded_identity_path).and_return(nil)
    allow(exporter).to receive(:embedded_security_path).and_return(nil)
    allow(exporter).to receive(:write)
    allow(exporter).to receive(:add_coverage)
    manifest = exporter.send(:export_project_security, project)
    expect(manifest).to include('id' => 'security-unit', 'password_policy' => nil)
  end

  it 'covers OQL, generalization, and validation-rule fallbacks' do
    entity = double
    allow(entity).to receive_messages(
      oql_view?: true, oql_source_document: 'Missing', source: nil, oql_query: 'SELECT 1',
      generalization_target: 'System.User', generalization: nil
    )
    mod = double(name: 'App', oql_view_documents: [])
    expect(exporter.send(:oql_view_manifest, entity, mod)).to include('query' => 'SELECT 1')
    expect(exporter.send(:generalization_manifest, entity)).to eq('target' => 'System.User')
    empty_entity = Object.new
    empty_entity.define_singleton_method(:oql_view?) { true }
    empty_entity.define_singleton_method(:oql_source_document) { 'Missing' }
    empty_entity.define_singleton_method(:oql_query) { '' }
    empty_entity.define_singleton_method(:generalization_target) { 'System.User' }
    expect(exporter.send(:oql_view_manifest, empty_entity, mod)).to include('source' => 'Missing')
    expect(exporter.send(:generalization_manifest, empty_entity)).to eq('target' => 'System.User')
    manifest = exporter.send(:validation_rule_manifest, {
      '$ID' => nil, 'Attribute' => 'App.Item.Name', 'RuleInfo' => 'scalar', 'Message' => 'scalar'
    })
    expect(manifest).to include('rule_info' => {}, 'translations' => [])
    source = exporter.send(:validation_rule_source, {
      'attribute' => 'Name', 'kind' => 'Future', 'rule_info' => {}, 'translations' => []
    })
    expect(source).to include('kind: "Future"')
    expect(source).not_to include('rule_info:')
    expect(exporter.send(:validation_rule_source, {
      'attribute' => 'Name', 'kind' => 'Future', 'rule_info' => { 'Future' => true },
      'translations' => []
    })).to include('rule_info:')
  end

  it 'rejects multiple nanoflow errors and covers unused result alternatives' do
    expect do
      exporter.send(:nanoflow_action_case_source, { 'type' => 'Unknown' }, [
                      { 'error' => true, 'destination' => 'one' },
                      { 'error' => true, 'destination' => 'two' }
                    ])
    end.to raise_error(Mxrb::SerializationError, /multiple error-handler paths/)
    nanoflow = exporter.send(:nanoflow_action, {
      '$Type' => 'Microflows$NanoflowCallAction', 'UseReturnVariable' => false,
      'NanoflowCall' => { 'Nanoflow' => 'App.Run', 'ParameterMappings' => [2] }
    })
    javascript = exporter.send(:nanoflow_action, {
      '$Type' => 'Microflows$JavaScriptActionCallAction', 'UseReturnVariable' => false,
      'JavaScriptAction' => 'App.Run', 'ParameterMappings' => [2]
    })
    feedback = exporter.send(:nanoflow_action, {
      '$Type' => 'Microflows$ValidationFeedbackAction', 'Attribute' => 'App.Item.Name',
      'ValidationVariableName' => 'Item', 'FeedbackTemplate' => {}
    })
    expect(nanoflow.fetch('result_variable')).to eq('')
    expect(javascript.fetch('result_variable')).to eq('')
    expect(feedback.fetch('member')).to eq('Name')
  end

  it 'omits empty widget regions and slot roles and clears empty security collections' do
    manifest = exporter.send(:widget_manifest, {
      type: :container, name: :Empty,
      body: [{ type: :text, name: :Body, options: {} }], regions: 'scalar',
      slots: [{ path: [:content], widgets: [] }]
    })
    expect(manifest.fetch('body').first.fetch('name')).to eq('Body')
    expect(manifest.fetch('slots').first).not_to have_key('role')
    security = {
      'security_level' => '', 'admin_user_role' => '', 'demo_users_enabled' => false,
      'guest_access_enabled' => false, 'guest_user_role' => '', 'sign_in_microflow' => nil,
      'user_roles' => [], 'demo_users' => []
    }
    expect(exporter.send(:project_security_source, security))
      .to include('clear_user_roles!', 'clear_demo_users!')
  end

  it 'covers empty runtime widget, condition, data-view, and grid rendering branches' do
    widget = { 'type' => 'container', 'name' => 'Empty' }
    expect(exporter.send(:runtime_widget_call_source, widget, 0, generic_sink: true))
      .to eq('container "Empty"')
    expect(exporter.send(:runtime_widget_call_source,
                         { 'type' => 'future', 'name' => 'Opaque' }, 0, generic_sink: true))
      .to eq('widget :future, "Opaque"')
    expect(exporter.send(:runtime_pluggable_properties_source,
                         { 'options' => {} }, 0)).to be_nil
    expect(exporter.send(:runtime_dsl_sink_regions_supported?, :container,
                         'body' => [])).to be(false)
    expect(exporter.send(:runtime_dsl_sink_typed?, :container, {}, 'body' => [])).to be(false)
    expect(exporter.send(:runtime_data_view_options_supported?, {})).to be(false)
    expect(exporter.send(:runtime_data_view_supported?, {}, {
      'type' => 'data_view', 'name' => 'Details', 'options' => {}, 'events' => [], 'body' => []
    })).to be(false)
    expect(exporter.send(:runtime_data_view_condition_source, 'visible_when', {}, 0))
      .to eq('visible_when')
    data_view = {
      'name' => 'Details', 'options' => {
        'source' => { 'kind' => 'context', 'entity' => 'App.Item' },
        'editable' => 'always', 'read_only_style' => 'control', 'label_width' => 0,
        'show_footer' => true, 'no_entity_message' => '', 'tab_index' => 0
      }
    }
    expect(exporter.send(:runtime_data_view_source, data_view, 0)).to start_with('data_view')
    grid = {
      'name' => 'Grid', 'options' => { 'columns' => [] }, 'events' => []
    }
    expect(exporter.send(:runtime_data_grid_source, grid, 0)).to include('data_grid', "\nend")
    expect(exporter.send(:runtime_table_geometry_supported?, 2, [
                           { 'cells' => [{ 'column' => 0, 'rowspan' => 2 }] },
                           { 'cells' => [{}] }
                         ])).to be(true)
    expect(exporter.send(:runtime_table_source, {
      'name' => 'Table', 'options' => { 'columns' => [], 'rows' => [] }
    }, 0)).to start_with('table "Table" do')
    expect(exporter.send(:runtime_table_cell_source,
                         { 'rowspan' => 2, 'widgets' => [] }, 2, 0).first)
      .to include('rowspan: 2')
    expect(exporter.send(:runtime_layout_grid_source, {
      'name' => 'Grid', 'options' => { 'rows' => [] }
    }, 0)).to start_with('layout_grid "Grid" do')
  end

  it 'returns when a frontend logo already exists and rejects id-less flow suffixes' do
    Dir.mktmpdir('mxrb-ruby-exporter-logo-') do |dir|
      exporter.instance_variable_set(:@output_dir, dir)
      exporter.instance_variable_set(:@mendix_sidecar, dir)
      logo = File.join(dir, 'frontend', 'src', 'generated', 'platform', 'theme', 'web', 'logo.png')
      FileUtils.mkdir_p(File.dirname(logo))
      File.binwrite(logo, 'logo')
      public_assets = File.join(dir, 'theme', 'web')
      FileUtils.mkdir_p(public_assets)
      File.write(File.join(public_assets, 'index.html'), '<html>Legacy entry point</html>')
      File.write(File.join(public_assets, 'help.htm'), '<html>Legacy help</html>')
      File.write(File.join(public_assets, 'theme.css'), '.mx-page { color: blue; }')
      File.binwrite(File.join(public_assets, 'logo.png'), 'logo')
      allow(exporter).to receive(:write)
      expect(exporter.send(:copy_frontend_theme)).to be_nil
      target = File.join(dir, 'frontend', 'public')
      expect(File).not_to exist(File.join(target, 'index.html'))
      expect(File).not_to exist(File.join(target, 'help.htm'))
      expect(File.read(File.join(target, 'theme.css'))).to include('color: blue')
    end
    expect { exporter.send(:flow_identity_suffix, double(id: '', name: 'Run')) }
      .to raise_error(Mxrb::SerializationError, /has no unit id/)
    expect(exporter.send(:frontend_widget_names,
                         'name' => 'Root', 'regions' => 'scalar')).to eq(['Root'])
  end
end
# rubocop:enable Metrics/BlockLength
