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
end
# rubocop:enable Metrics/BlockLength
