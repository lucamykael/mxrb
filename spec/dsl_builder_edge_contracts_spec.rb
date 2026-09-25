# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'DSL builder edge contracts' do
  it 'constructs every extended semantic widget directly in a shared slot' do
    tree = Mxrb::Dsl::WidgetSlotBuilder.new
    tree.file_manager(:Files)
    tree.reference_set_selector(:Members)
    tree.navigation_list(:Links)
    tree.scroll_container(:Shell)
    tree.image_viewer(:Preview, entity: 'Ui.Picture')
    tree.image_uploader(:Upload)
    tree.menu_bar(:Menu, menu: 'Ui.MainMenu')
    tree.navigation_tree(:Tree, menu: 'Ui.MainMenu')
    tree.widget(:future_widget, :Future) { on_click microflow: :Run }

    expect(tree.widgets.map { _1[:type] }).to eq(
      %i[file_manager reference_set_selector navigation_list scroll_container image_viewer
         image_uploader menu_bar navigation_tree future_widget]
    )
    expect(tree.sort_by(:Name, direction: :descending)).to eq(attribute: 'Name', direction: 'descending')
  end

  it 'validates tables, spans, overlaps, and explicit column placement' do
    tree = Mxrb::Dsl::WidgetSlotBuilder.new
    expect { tree.table(:Empty) }.to raise_error(ArgumentError, /at least one column/)
    expect do
      tree.table(:Invalid, width_unit: :future) { column(width: 1) }
    end.to raise_error(ArgumentError, /width_unit/)
    expect do
      tree.table(:Invalid) { column }
    end.to raise_error(ArgumentError, /width must be positive/)
    expect do
      tree.table(:Invalid) do
        column(width: 1)
        row { cell(column: -1) }
      end
    end.to raise_error(ArgumentError, /column cannot be negative/)
    expect do
      tree.table(:Invalid) do
        column(width: 1)
        row { cell(colspan: 0) }
      end
    end.to raise_error(ArgumentError, /colspan must be positive/)
    expect do
      tree.table(:Invalid) do
        column(width: 1)
        row { cell(rowspan: 0) }
      end
    end.to raise_error(ArgumentError, /rowspan must be positive/)
    expect do
      tree.table(:Invalid) do
        column(width: 1)
        row { cell(colspan: 2) }
      end
    end.to raise_error(ArgumentError, /exceeds column count/)
    expect do
      tree.table(:Invalid) do
        column(width: 1)
        row { cell(rowspan: 2) }
      end
    end.to raise_error(ArgumentError, /rowspan exceeds row count/)
    expect do
      tree.table(:Invalid) do
        2.times { column(width: 1) }
        row do
          cell(column: 0, colspan: 2)
          cell(column: 1)
        end
      end
    end.to raise_error(ArgumentError, /cannot overlap/)
  end

  it 'normalizes grid aliases and rejects invalid widths and alignments' do
    tree = Mxrb::Dsl::WidgetSlotBuilder.new
    tree.layout_grid(:Grid, width: :fixed_width) do
      row(horizontal_alignment: :start, vertical_alignment: :center) do
        column(desktop: -1, tablet: -2, phone: 6, vertical_alignment: :end) { text :Caption }
      end
    end
    options = tree.widgets.last.fetch(:options)
    expect(options[:width]).to eq(:fixed)
    expect(options.dig(:rows, 0, :columns, 0, :options)).to include(
      desktop: :grow, tablet: :auto, phone: 6
    )
    expect { tree.layout_grid(:Bad, width: :fluid) }.to raise_error(ArgumentError, /width/)
    expect do
      tree.layout_grid(:Bad) { row(horizontal_alignment: :diagonal) }
    end.to raise_error(ArgumentError, /alignment/)
    expect do
      tree.layout_grid(:Bad) { row { column(desktop: 0) } }
    end.to raise_error(ArgumentError, /weight/)
    expect do
      tree.layout_grid(:Bad) { row { column(desktop: Object.new) } }
    end.to raise_error(ArgumentError, /weight/)
  end

  it 'validates data-view sources, enums, label widths, and native extension maps' do
    tree = Mxrb::Dsl::WidgetSlotBuilder.new
    expect { tree.data_view(:Bad, from: nil) }.to raise_error(ArgumentError, /semantic source/)
    expect { tree.data_view(:Bad, from: {}) }.to raise_error(ArgumentError, /requires kind/)
    expect { tree.data_view(:Bad, from: tree.context(entity: 'App.Item'), editable: :future) }
      .to raise_error(ArgumentError, /unsupported data view editability/)
    expect { tree.data_view(:Bad, from: tree.context(entity: 'App.Item'), read_only_style: :future) }
      .to raise_error(ArgumentError, /unsupported data view read-only style/)
    expect { tree.data_view(:Bad, from: tree.context(entity: 'App.Item'), label_width: -1) }
      .to raise_error(ArgumentError, /label_width cannot be negative/)

    tree.data_view(:Details, from: tree.context(entity: 'App.Item'), editable: :conditionally) do
      visible_when '$currentObject/Visible'
      editable_when '$currentObject/Editable'
      body { text :Body }
      footer { text :Footer }
      unknown_native 'Future' => false
    end
    details = tree.widgets.last
    expect(details.dig(:options, :editable)).to eq(:conditional)
    expect(details.fetch(:body).first[:name]).to eq('Body')
    expect(details.fetch(:footer).first[:name]).to eq('Footer')
    expect(details.dig(:options, :unknown_native)).to eq('Future' => false)
    builder = Mxrb::Dsl::DataViewBuilder.new(
      :Bad, from: tree.context(entity: 'App.Item'), editable: Mxrb::Dsl::UNSET,
            read_only_style: Mxrb::Dsl::UNSET, label_width: Mxrb::Dsl::UNSET,
            show_footer: Mxrb::Dsl::UNSET, no_entity_message: Mxrb::Dsl::UNSET,
            tab_index: Mxrb::Dsl::UNSET, class_name: Mxrb::Dsl::UNSET,
            style: Mxrb::Dsl::UNSET, dynamic_class: Mxrb::Dsl::UNSET
    )
    expect { builder.unknown_native([]) }.to raise_error(ArgumentError, /requires a Hash/)
  end

  it 'validates page variables, native widgets, pluggable slots, and binary values' do
    tree = Mxrb::Dsl::WidgetSlotBuilder.new
    expect { tree.page_variable(:Item, kind: :future) }.to raise_error(ArgumentError, /unsupported page variable/)
    expect { tree.native_widget(:Native, type: 'Vendor$Widget', deep_structure: []) }
      .to raise_error(ArgumentError, /requires a Hash/)
    binary = tree.bson_binary(Base64.strict_encode64('bytes'), subtype: :user)
    expect(binary).to be_a(BSON::Binary)

    builder = Mxrb::Dsl::PluggableWidgetBuilder.new(
      :Widget, options: { widget_id: 'vendor.Widget' }, properties_declared: false
    )
    expect { builder.properties }.to raise_error(ArgumentError, /requires a block/)
    expect { builder.slot(:content, within: :items) {} }.to raise_error(ArgumentError, /requires item/)
    expect(builder.send(:pluggable_slot_path, nil, within: nil, item: nil, path: %w[custom path]))
      .to eq(%w[custom path])
  end

  it 'normalizes association variants, raw view sources, and composite widget slots' do
    tree = Mxrb::Dsl::WidgetSlotBuilder.new
    hashes = tree.association([{ association: 'App.Order_Customer', entity: 'App.Customer' }],
                              entity: 'App.Customer')
    scalar = tree.association('App.Order_Customer', entity: 'App.Customer')
    expect(hashes.fetch(:steps).first).to eq(
      association: 'App.Order_Customer', entity: 'App.Customer'
    )
    expect(scalar.fetch(:steps).first).to eq(
      association: 'App.Order_Customer', entity: 'App.Customer'
    )
    expect(tree.view_source(:listen, target: 'grid')).to eq(kind: :listen, target: 'grid')

    generic = Mxrb::Dsl::GenericWidgetBuilder.new(:future, :Future, options: {}, events: [])
    generic.slot(path: %i[items content], role: :main) { text :Caption }
    generic_slot = generic.to_h.fetch(:slots).first
    expect(generic_slot).to include(path: %i[items content], role: 'main')
    expect(generic_slot.fetch(:widgets).first).to include(type: :text, name: 'Caption')

    pluggable = Mxrb::Dsl::PluggableWidgetBuilder.new(
      :Widget, options: { widget_id: 'vendor.Widget' }, properties_declared: false
    )
    pluggable.slot(:content, within: :items, item: 2, role: nil) { text :Nested }
    pluggable_slot = pluggable.to_h.fetch(:slots).first
    expect(pluggable_slot).to include(path: [:items, :objects, 2, :content], role: nil)
    expect(pluggable_slot.fetch(:widgets).first).to include(type: :text, name: 'Nested')
  end

  it 'builds valid tables, remote enumerations, metadata sequences, and binary values' do
    tree = Mxrb::Dsl::WidgetSlotBuilder.new
    tree.table(:Matrix) do
      column(width: 100)
      row { cell { text :Value } }
    end
    expect(tree.widgets.last).to include(type: :table, name: 'Matrix')
    expect(tree.widgets.last.dig(:options, :rows, 0, :cells, 0, :widgets, 0)).to include(name: 'Value')

    enumeration = Mxrb::Dsl::EnumerationBuilder.new(
      :Status, remote_service: 'Remote.Service', remote_name: 'Status'
    )
    enumeration.value(:Open, remote_name: 'OPEN')
    expect(enumeration.to_h.fetch(:remote_source)).to include(
      '$Type' => 'Rest$ODataRemoteEnumerationSource', 'ConsumedODataService' => 'Remote.Service'
    )
    expect(enumeration.to_h.dig(:values, 0, :remote_value)).to include('RemoteName' => 'OPEN')

    metadata = {
      'Run' => [
        { 'native_type' => 'Microflows$Microflow', 'unit_id' => 'first' },
        { 'native_type' => '', 'unit_id' => 'second' }
      ]
    }
    mod = Mxrb::Dsl::ModuleBuilder.new(:App, flow_metadata: metadata)
    expect(mod.send(:flow_metadata_for, :Run).fetch('unit_id')).to eq('first')
    expect(mod.send(:flow_metadata_for, :Run).fetch('unit_id')).to eq('second')

    encoded = Base64.strict_encode64('bytes')
    project = Mxrb::Dsl::Builder.new('/tmp/app.mpr')
    project.preserve_native_pages
    expect(project.instance_variable_get(:@preserve_native_pages)).to be(true)
    expect(project.bson_binary(encoded)).to be_a(BSON::Binary)
    expect(enumeration.bson_binary(encoded, subtype: :user).type).to eq(:user)
    expect(mod.bson_binary(encoded, subtype: :user).type).to eq(:user)
  end

  it 'materializes typed DataSet parameters and nested access constraints' do
    mod = Mxrb::Dsl::ModuleBuilder.new(:Reports)
    mod.dataset(:Orders) do
      parameter :Search, string
      parameter :Owner, object_of('Reports.Owner'), range: true
      parameter :Status, enum_of('Reports.Status')
      allow 'Reports.Reader' do
        parameter :Search do
          constraint '[%CurrentUser%]', enabled: false
        end
      end
      oql 'SELECT O/Number FROM Reports.Order O', ieiq: true
    end
    document = mod.native_documents.first.fetch(:doc)
    parameters = Mxrb::IO::BsonCodec.parse_array(document.fetch('Parameters')).fetch(:items)
    access = Mxrb::IO::BsonCodec.parse_array(
      document.dig('DataSetAccess', 'ModuleRoleAccessList')
    ).fetch(:items).first

    expect(parameters.map { _1.dig('ParameterType', '$Type') }).to eq(
      %w[DataTypes$StringType DataTypes$ObjectType DataTypes$EnumerationType]
    )
    expect(parameters[1].dig('ParameterType', 'Entity')).to eq('Reports.Owner')
    expect(parameters[2].dig('ParameterType', 'Enumeration')).to eq('Reports.Status')
    constraint = Mxrb::IO::BsonCodec.parse_array(
      Mxrb::IO::BsonCodec.parse_array(access.fetch('ParameterAccessList')).fetch(:items).first
          .fetch('ConstraintAccessList')
    ).fetch(:items).first
    expect(constraint).to include('ConstraintText' => '[%CurrentUser%]', 'Enabled' => false)

    expect do
      mod.dataset(:Invalid) { parameter :Value, { kind: :future } }
    end.to raise_error(ArgumentError, /unsupported dataset parameter type/)
  end

  it 'validates REST string handling, XML exports, code-action kinds, and enum flow types' do
    flow = Mxrb::Dsl::FlowBuilder.new(:Run, runtime: :server, kind: :microflow, public: false)
    expect do
      flow.call_rest(method: :get, location: '/', result_handling: :string, as: :body,
                     result_entity: 'App.Item')
    end.to raise_error(ArgumentError, /does not accept a result mapping or entity/)
    expect { flow.export_xml(:item, mapping: :Export, as: :xml, content_type: :future) }
      .to raise_error(ArgumentError, /unsupported export mapping content type/)
    expect { flow.export_xml('', mapping: :Export, as: :xml) }
      .to raise_error(ArgumentError, /requires variable, mapping, and as/)
    flow.export_xml(:item, mapping: :Export, as: :xml, content_type: :json)
    expect(flow.to_h.fetch(:body).last).to include(
      type: :export_xml, variable: 'item', mapping: 'Export', output: 'xml', content_type: 'json'
    )
    expect { flow.call_java(:Code, pass: { Input: { kind: :future, value: 'x' } }) }
      .to raise_error(ArgumentError, /unsupported code action parameter kind/)
    expect(flow.enum_of('App.Status')).to include(
      '$Type' => 'DataTypes$EnumerationType', 'Enumeration' => 'App.Status'
    )
  end

  it 'covers optional widget blocks, parameters, events, and composite regions' do
    tree = Mxrb::Dsl::WidgetSlotBuilder.new
    tree.text(:Greeting, parameters: %i[name count])
    tree.button(:Save, parameters: [:item])
    tree.gallery(:Cards, sort: [tree.sort_by(:Name)])
    expect { tree.table(:Table) }.to raise_error(ArgumentError, /at least one column/)
    tree.layout_grid(:Grid)
    tree.container(:Container)
    tree.pluggable_widget(:Widget, widget_id: 'vendor.Widget')
    tree.widget(:future, :Future)
    tree.data_view(:Details, from: tree.context(entity: 'App.Item'), visible: '$currentObject/Visible')
    expect(tree.widgets.map { _1[:type] }).to include(
      :text, :button, :gallery, :layout_grid, :container, :pluggable_widget, :future,
      :data_view
    )

    event_widget = Mxrb::Dsl::GenericWidgetBuilder.new(:future, :Events, options: {}, events: [])
    expect { event_widget.on_click(action: :save, pass: []) }
      .to raise_error(ArgumentError, /pass: must be a Hash/)
    event_widget.on_click(action: :save, pass: { item: 'value' })
    expect(event_widget.to_h.fetch(:events).first.fetch(:arguments)).to eq(item: 'value')

    composite = Mxrb::Dsl::GenericWidgetBuilder.new(:future, :Composite, options: {}, events: [])
    composite.body { text :Body }
    expect { composite.body { text :Duplicate } }.to raise_error(ArgumentError, /duplicate widget region/)
    composite.slot(path: [:content]) { text :Slot }
    expect(composite.to_h.fetch(:slots).first).not_to have_key(:role)
  end

  it 'covers builder validation and explicit appearance alternatives' do
    expect { Mxrb::Dsl::GenericWidgetBuilder.new(:x, :X, options: [], events: []) }
      .to raise_error(ArgumentError, /options must be a Hash/)
    expect { Mxrb::Dsl::GenericWidgetBuilder.new(:x, :X, options: {}, events: {}) }
      .to raise_error(ArgumentError, /events must be an Array/)
    expect { Mxrb::Dsl::GenericWidgetBuilder.new(:x, :X, options: {}, events: [:bad]) }
      .to raise_error(ArgumentError, /only Hash values/)

    pluggable = Mxrb::Dsl::PluggableWidgetBuilder.new(
      :Widget, options: { widget_id: 'vendor.Widget' }, properties_declared: false
    )
    pluggable.slot(:content) { text :Caption }
    expect(pluggable.to_h.dig(:slots, 0, :path)).to eq([:content])

    table = Mxrb::Dsl::TableBuilder.new(
      :Table, width_unit: :pixels, tab_index: 2, class_name: 'table', style: 'color:red',
              dynamic_class: '$class', visible: '$visible'
    )
    2.times { table.column(width: 1) }
    table.row(class_name: 'first', style: 'x', dynamic_class: '$row', visible: '$visible') do
      cell(column: 0, rowspan: 2, class_name: 'cell', style: 'x', dynamic_class: '$cell')
    end
    table.row { cell }
    expect(table.to_h.dig(:options, :rows, 1, :cells, 0, :column)).to eq(1)

    grid = Mxrb::Dsl::LayoutGridBuilder.new(
      :Grid, width: :fixed, tab_index: 2, class_name: 'grid', style: 'x',
             dynamic_class: '$grid', visible: '$visible'
    )
    grid.row(class_name: 'row', style: 'x', dynamic_class: '$row', visible: '$visible') do
      column(class_name: 'column', style: 'x', dynamic_class: '$column')
    end
    expect(grid.to_h.dig(:options, :class)).to eq('grid')
  end

  it 'covers repeated data-view conditions and identified design properties' do
    source = { kind: :context, entity: 'App.Item' }
    view = Mxrb::Dsl::DataViewBuilder.new(
      :Details, from: source, editable: :always, read_only_style: :text, label_width: 3,
                show_footer: false, no_entity_message: 'Missing', tab_index: 2,
                class_name: 'view', style: 'x', dynamic_class: '$view'
    )
    2.times do
      view.visible_when('$currentObject/Visible', attribute: 'App.Item.Visible')
      view.editable_when('$currentObject/Editable', attribute: 'App.Item.Editable')
    end
    view.design_property(:Color, option: :Red, id: 'property-id', value_id: 'value-id')
    expect(view.to_h.dig(:options, :design_properties, 0)).to include(
      id: 'property-id', value_id: 'value-id'
    )
  end

  it 'covers metadata, remote ids, native units, and complete schedules' do
    project = Mxrb::Dsl::Builder.new('/tmp/app.mpr')
    project.semantic_metadata('/tmp/mxrb-missing-semantic-metadata.json')
    project.native_unit('unit', container_id: 'container', containment: 'Modules',
                                module_name: 'App', deep_structure: {})
    expect(project.instance_variable_get(:@native_unit_overrides).first.fetch(:module)).to eq('App')

    enumeration = Mxrb::Dsl::EnumerationBuilder.new(
      :Status, remote_service: 'Remote.Service', remote_name: 'Status', remote_source_id: 'source-id'
    )
    enumeration.value(:Open, remote_name: 'OPEN', remote_id: 'value-id')
    expect(enumeration.to_h.dig(:remote_source, '$ID')).to eq('source-id')
    expect(enumeration.to_h.dig(:values, 0, :remote_value, '$ID')).to eq('value-id')

    schedule = Mxrb::Dsl::ScheduledEventBuilder.new(
      :Tick, microflow: 'App.Tick', schedule: 'ScheduledEvents$CustomSchedule',
             schedule_id: 'schedule-id', multiplier: 2, minute_offset: 3,
             hour_of_day: 4, minute_of_hour: 5, weekdays: [:monday]
    ).to_h.fetch(:schedule)
    expect(schedule).to include(type: 'ScheduledEvents$CustomSchedule', id: 'schedule-id')
    expect(schedule.fetch(:properties)).to include(
      multiplier: 2, minute_offset: 3, hour_of_day: 4, minute_of_hour: 5, monday: true
    )
  end
end
# rubocop:enable Metrics/BlockLength
