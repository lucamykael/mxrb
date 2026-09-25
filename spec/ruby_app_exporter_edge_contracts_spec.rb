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

    attribute = double(id: 'attribute-id', name: 'Code')
    entity = double(attributes: [attribute], qualified_name: 'Sales.Order')
    expect(exporter.send(:index_member_name, entity, { 'Attribute' => 'Sales.Order.Name' }, 'Normal'))
      .to eq('Name')
    expect(exporter.send(:index_member_name, entity, { 'AttributePointer' => 'attribute-id' }, 'Normal'))
      .to eq('Code')
    expect(exporter.send(:index_member_name, entity, {}, 'Owner')).to eq('Owner')
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
       include('count' => 100)],
      [{ '$Type' => 'Microflows$ValidationFeedbackAction', 'Attribute' => '',
         'Association' => 'Sales.Item_Owner', 'ValidationVariableName' => 'Item',
         'FeedbackTemplate' => {} }, include('member' => 'Item_Owner')]
    ]
    cases.each do |action, matcher|
      expect(exporter.send(:nanoflow_action, action)).to matcher
    end
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

    one = double(name: 'Run', id: '')
    two = double(name: 'Run', id: 'two')
    expect { exporter.send(:duplicate_flow_ids, [one, two]) }
      .to raise_error(Mxrb::SerializationError, /distinct explicit unit ids/)
  end
end
# rubocop:enable Metrics/BlockLength
