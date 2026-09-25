# frozen_string_literal: true

require 'spec_helper'

# These examples exercise the lossless widget-to-Ruby projection guards. Each
# rejected shape must fall back to the generic/native representation instead
# of emitting a typed DSL call that could silently change semantics.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::Exporter do
  subject(:exporter) { described_class.allocate }

  def copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def without(value, key)
    copy(value).tap { _1.delete(key) }
  end

  def text_widget(name = 'Label')
    {
      'type' => 'text', 'name' => name, 'options' => { 'caption' => 'Hello' },
      'events' => [], 'children' => []
    }
  end

  it 'projects native widgets, tab controls, events, regions, and typed sinks losslessly' do
    digest = 'a' * 64
    native = {
      'type' => 'native_widget', 'name' => 'Native',
      'options' => { 'native_type' => 'Forms$Custom', 'native_fragment' => { 'digest' => digest } },
      'events' => []
    }
    expect(exporter.send(:runtime_native_widget_supported?, native['options'], native)).to be(true)
    expect(exporter.send(:runtime_widget_call_source, native, 2))
      .to include('native_widget(', '"Native"', 'type: "Forms$Custom"', %(native_fragment("#{digest}")))

    native_failures = [
      native.merge('unexpected' => true), native.merge('name' => :Native), without(native, 'options'),
      native.merge('options' => native['options'].merge('extra' => true)),
      native.merge('options' => native['options'].merge('native_type' => '')),
      native.merge('options' => native['options'].merge('native_type' => :type)),
      native.merge('events' => [{}]),
      native.merge('options' => native['options'].merge('native_fragment' => nil)),
      native.merge('options' => native['options'].merge('native_fragment' => { 'digest' => digest, 'x' => 1 })),
      native.merge('options' => native['options'].merge('native_fragment' => { 'digest' => 'bad' }))
    ].map { copy(_1) }
    native_failures.each do |candidate|
      expect(exporter.send(:runtime_native_widget_supported?, candidate['options'] || {}, candidate)).to be(false)
    end

    tabs = {
      'type' => 'tab_control', 'name' => 'Tabs', 'events' => [],
      'options' => {
        'tabs' => [
          { 'name' => 'General', 'caption' => 'General', 'widgets' => [] },
          { 'name' => 'Details', 'caption' => 'Details', 'widgets' => [text_widget] }
        ]
      }
    }
    expect(exporter.send(:runtime_tab_control_supported?, tabs['options'], tabs)).to be(true)
    expect(exporter.send(:runtime_widget_call_source, tabs, 0))
      .to include('tab_control "Tabs" do', 'tab_page "General", caption: "General"', 'text "Label"')
    [
      tabs.merge('x' => true), tabs.merge('name' => nil), without(tabs, 'options'),
      tabs.merge('options' => tabs['options'].merge('x' => true)), tabs.merge('events' => [{}]),
      tabs.merge('options' => { 'tabs' => nil }), tabs.merge('options' => { 'tabs' => [] }),
      tabs.merge('options' => { 'tabs' => [{ 'name' => 'X', 'caption' => 'X', 'widgets' => [], 'x' => 1 }] }),
      tabs.merge('options' => { 'tabs' => [{ 'name' => 1, 'caption' => 'X', 'widgets' => [] }] }),
      tabs.merge('options' => { 'tabs' => [{ 'name' => 'X', 'caption' => 1, 'widgets' => [] }] }),
      tabs.merge('options' => { 'tabs' => [{ 'name' => 'X', 'caption' => 'X', 'widgets' => nil }] }),
      tabs.merge('options' => { 'tabs' => [{ 'name' => 'X', 'caption' => 'X', 'widgets' => [{}] }] })
    ].map { copy(_1) }.each do |candidate|
      expect(exporter.send(:runtime_tab_control_supported?, candidate['options'] || {}, candidate)).to be(false)
    end

    event = {
      'event' => 'on_click', 'kind' => 'microflow', 'handler' => 'Sales.Save',
      'arguments' => {
        'Order' => { 'kind' => 'page_parameter', 'name' => 'Order' }, 'Count' => 2
      }
    }
    button = {
      'type' => 'button', 'name' => 'Save', 'options' => { 'caption' => 'Save' },
      'events' => [event], 'children' => [text_widget('Inside')]
    }
    expect(exporter.send(:runtime_dsl_sink_typed?, :button, button['options'], button)).to be(true)
    source = exporter.send(:runtime_widget_call_source, button, 0, generic_sink: true)
    expect(source).to include('button "Save", caption: "Save" do', 'on_click microflow: "Sales.Save" do')
    expect(source).to include('argument "Order", page_variable(', 'argument "Count", 2', 'text "Inside"')

    empty_event = event.merge('arguments' => {})
    compact = exporter.send(:runtime_widget_event_source, { 'events' => [empty_event] }, 0)
    preserved = exporter.send(
      :runtime_widget_event_source, { 'events' => [empty_event] }, 0, preserve_empty: true
    )
    expect(compact).to eq('on_click microflow: "Sales.Save"')
    expect(preserved).to eq("on_click microflow: \"Sales.Save\" do\nend")

    invalid_events = [
      'bad', [event.merge('extra' => true)], [event.merge('event' => 'after_load')],
      [event.merge('kind' => 'java')], [event.merge('event' => '')], [event.merge('kind' => '')],
      [event.merge('handler' => '')], [event.merge('arguments' => [])],
      [event.merge('arguments' => { '' => 1 })], [event.merge('arguments' => { key: 1 })]
    ]
    invalid_events.each do |events|
      expect(exporter.send(:runtime_widget_events_supported?, 'events' => events)).to be(false)
    end
    expect(exporter.send(:runtime_widget_events_supported?, {})).to be(true)

    expect(exporter.send(:runtime_dsl_sink_typed?, :unknown, {}, button)).to be(false)
    expect(exporter.send(:runtime_dsl_sink_typed?, :button, { 'caption' => 'x', 'bad' => 1 }, button)).to be(false)
    expect(exporter.send(:runtime_dsl_sink_typed?, :button, {}, button)).to be(false)
    expect(exporter.send(:runtime_dsl_sink_typed?, :snippet, { 'snippet' => 'M.S' }, button)).to be(false)
    expect(exporter.send(:runtime_dsl_sink_regions_supported?, :button, button.merge('body' => []))).to be(false)
    expect(exporter.send(:runtime_dsl_sink_regions_supported?, :button, button.merge('footer' => []))).to be(false)
    expect(exporter.send(:runtime_dsl_sink_regions_supported?, :button, button.merge('regions' => {}))).to be(false)
    expect(exporter.send(:runtime_dsl_sink_regions_supported?, :button, button.merge('slots' => []))).to be(false)
    expect(exporter.send(
             :runtime_dsl_sink_regions_supported?, :pluggable_widget,
             button.merge('slots' => [{ 'path' => ['content'], 'widgets' => [] }])
           )).to be(true)
    expect(exporter.send(
             :runtime_dsl_sink_regions_supported?, :pluggable_widget,
             button.merge('slots' => [{ 'path' => [], 'role' => 'content', 'widgets' => [] }])
           )).to be(false)

    regions = {
      'body' => [], 'footer' => [text_widget('Footer')],
      'regions' => { 'sidebar' => [text_widget('Side')] },
      'slots' => [
        { 'path' => ['content', 0], 'widgets' => [] },
        { 'path' => ['footer'], 'role' => 'content', 'widgets' => [text_widget('Slot')] }
      ]
    }
    region_source = exporter.send(:runtime_widget_regions_source, regions, 0, generic_sink: true)
    expect(region_source).to include('body', 'footer do', 'region "sidebar" do')
    expect(region_source).to include('slot path: ["content", 0]', 'role: "content"', 'text "Slot"')
    expect(exporter.send(:runtime_widget_keyword, :snippet, 'snippet', generic_sink: true)).to eq('from')
    expect(exporter.send(:runtime_widget_keyword, :text, 'class', generic_sink: false)).to eq('class_name')
    expect(exporter.send(:runtime_widget_keyword, :text, :caption, generic_sink: false)).to eq('caption')
  end

  it 'validates and emits tables and responsive layout grids without changing geometry' do
    table = {
      'type' => 'table', 'name' => 'Matrix', 'events' => [], 'children' => [],
      'options' => {
        'width_unit' => 'pixels', 'tab_index' => 3, 'class' => 'matrix', 'style' => 'color:red',
        'dynamic_class' => '$Class', 'visible' => 'true',
        'columns' => [{ 'width' => 1 }, { 'width' => 2 }],
        'rows' => [
          {
            'options' => { 'class' => 'top', 'visible' => 'true' },
            'cells' => [{
              'column' => 0, 'colspan' => 2, 'rowspan' => 1, 'header' => true,
              'options' => { 'class' => 'head' }, 'widgets' => [text_widget]
            }]
          },
          {
            'options' => {},
            'cells' => [
              { 'options' => {}, 'widgets' => [] },
              { 'column' => 1, 'options' => {}, 'widgets' => [text_widget('Cell')] }
            ]
          }
        ]
      }
    }
    expect(exporter.send(:runtime_structured_widget?, :table, table['options'], table)).to be(true)
    table_source = exporter.send(:runtime_widget_call_source, table, 0)
    expect(table_source).to include('table(', '"Matrix"', 'width_unit: :pixels', 'tab_index: 3')
    expect(table_source).to include('column width: 2', 'colspan: 2', 'header: true', 'cell do')
    shifted = exporter.send(
      :runtime_table_cell_source,
      { 'column' => 1, 'options' => {}, 'widgets' => [text_widget('Shifted')] }, 0, 0
    )
    expect(shifted.join("\n")).to include('cell column: 1 do', 'text "Shifted"')

    expect(exporter.send(:runtime_structured_widget?, :unknown, {}, table)).to be(false)
    expect(exporter.send(:runtime_structured_widget?, :table, table['options'].merge('bad' => 1), table)).to be(false)
    expect(exporter.send(:runtime_structured_widget?, :table, table['options'],
                         table.merge('events' => [{}]))).to be(false)
    expect(exporter.send(:runtime_structured_widget?, :table, table['options'],
                         table.merge('children' => [{}]))).to be(false)
    expect(exporter.send(:runtime_table_supported?, table['options'].merge('width_unit' => 'bad'))).to be(false)
    expect(exporter.send(:runtime_table_supported?, table['options'].merge('columns' => []))).to be(false)
    expect(exporter.send(:runtime_table_supported?, table['options'].merge('columns' => [{}]))).to be(false)
    expect(exporter.send(:runtime_table_supported?,
                         table['options'].merge('columns' => [{ 'width' => 0 }]))).to be(false)
    expect(exporter.send(:runtime_table_supported?, table['options'].merge('rows' => [{ 'bad' => 1 }]))).to be(false)

    row = table['options']['rows'].first
    expect(exporter.send(:runtime_table_row_supported?, row.merge('bad' => 1))).to be(false)
    expect(exporter.send(:runtime_table_row_supported?, row.merge('options' => { 'bad' => 1 }))).to be(false)
    cell = row['cells'].first
    [
      cell.merge('bad' => 1), cell.merge('options' => { 'bad' => 1 }),
      cell.merge('colspan' => 0), cell.merge('rowspan' => 0), cell.merge('column' => -1),
      cell.merge('widgets' => [{}])
    ].each do |bad_cell|
      expect(exporter.send(:runtime_table_row_supported?, row.merge('cells' => [bad_cell]))).to be(false)
    end

    overflow = [{ 'cells' => [{ 'column' => 1, 'colspan' => 2 }] }]
    too_tall = [{ 'cells' => [{ 'rowspan' => 2 }] }]
    overlap = [{ 'cells' => [{ 'column' => 0 }, { 'column' => 0 }] }]
    expect(exporter.send(:runtime_table_geometry_supported?, 2, overflow)).to be(false)
    expect(exporter.send(:runtime_table_geometry_supported?, 2, too_tall)).to be(false)
    expect(exporter.send(:runtime_table_geometry_supported?, 2, overlap)).to be(false)

    grid = {
      'type' => 'layout_grid', 'name' => 'Responsive', 'events' => [], 'children' => [],
      'options' => {
        'width' => 'fixed', 'tab_index' => 2, 'class' => 'grid',
        'rows' => [
          {
            'options' => {
              'horizontal_alignment' => 'center', 'vertical_alignment' => 'end',
              'gutters' => false, 'dynamic_class' => '$RowClass'
            },
            'columns' => [
              {
                'options' => {
                  'desktop' => 6, 'tablet' => 'auto', 'phone' => 'grow',
                  'vertical_alignment' => 'start', 'style' => 'min-height:1px'
                },
                'widgets' => [text_widget]
              },
              { 'options' => {}, 'widgets' => [] }
            ]
          },
          { 'options' => {}, 'columns' => [] }
        ]
      }
    }
    expect(exporter.send(:runtime_structured_widget?, :layout_grid, grid['options'], grid)).to be(true)
    grid_source = exporter.send(:runtime_widget_call_source, grid, 0)
    expect(grid_source).to include('layout_grid "Responsive"', 'width: :fixed', 'gutters: false')
    expect(grid_source).to include('desktop: 6', 'tablet: :auto', 'vertical_alignment: :start')

    expect(exporter.send(:runtime_layout_grid_supported?, grid['options'].merge('width' => 'fluid'))).to be(false)
    expect(exporter.send(
             :runtime_layout_grid_supported?, grid['options'].merge('rows' => [{ 'bad' => 1 }])
           )).to be(false)
    grid_row = grid['options']['rows'].first
    expect(exporter.send(:runtime_layout_grid_row_supported?, grid_row.merge('options' => { 'bad' => 1 }))).to be(false)
    expect(exporter.send(
             :runtime_layout_grid_row_supported?,
             grid_row.merge('options' => grid_row['options'].merge('horizontal_alignment' => 'justify'))
           )).to be(false)
    expect(exporter.send(
             :runtime_layout_grid_row_supported?,
             grid_row.merge('options' => grid_row['options'].merge('vertical_alignment' => 'baseline'))
           )).to be(false)
    expect(exporter.send(
             :runtime_layout_grid_row_supported?, grid_row.merge('columns' => [{ 'bad' => 1 }])
           )).to be(false)
    column = grid_row['columns'].first
    expect(exporter.send(:runtime_layout_grid_column_supported?,
                         column.merge('options' => { 'bad' => 1 }))).to be(false)
    expect(exporter.send(
             :runtime_layout_grid_column_supported?,
             column.merge('options' => column['options'].merge('vertical_alignment' => 'baseline'))
           )).to be(false)
    %w[desktop tablet phone].each do |viewport|
      invalid = column.merge('options' => column['options'].merge(viewport => 13))
      expect(exporter.send(:runtime_layout_grid_column_supported?, invalid)).to be(false)
    end
    expect(exporter.send(:runtime_layout_grid_column_supported?, column.merge('widgets' => [{}]))).to be(false)
  end

  it 'validates nested widget containers, slots, and data-view contracts defensively' do
    nested = text_widget
    expect(exporter.send(:runtime_nested_widget_supported?, nested)).to be(true)
    [
      nested.merge('x' => 1), without(nested, 'type'), without(nested, 'name'),
      nested.merge('caption' => 'legacy'), without(nested, 'options'),
      nested.merge('options' => []), nested.merge('events' => {}), nested.merge('children' => {}),
      nested.merge('body' => {}), nested.merge('footer' => {}), nested.merge('regions' => []),
      nested.merge('regions' => { 'x' => {} }),
      nested.merge('slots' => [{ 'path' => [], 'widgets' => [], 'bad' => 1 }]),
      nested.merge('slots' => [{ 'widgets' => [] }]), nested.merge('slots' => [{ 'path' => [] }]),
      nested.merge('slots' => [{ 'path' => 'bad', 'widgets' => [] }]),
      nested.merge('slots' => [{ 'path' => [nil], 'widgets' => [] }]),
      nested.merge('slots' => [{ 'path' => [], 'role' => 1, 'widgets' => [] }]),
      nested.merge('slots' => [{ 'path' => [], 'widgets' => {} }])
    ].map { copy(_1) }.each do |candidate|
      expect(exporter.send(:runtime_nested_widget_supported?, candidate)).to be(false)
    end
    expect(exporter.send(:runtime_widget_collection_supported?, [nested])).to be(true)
    expect(exporter.send(:runtime_widget_collection_supported?, {})).to be(false)

    options = {
      'source' => {
        'kind' => 'association', 'entity' => 'Sales.Line',
        'steps' => [{ 'association' => 'Sales.Order_Lines', 'entity' => 'Sales.Line' }],
        'variable' => { 'kind' => 'page_parameter', 'name' => 'Order' },
        'force_full_objects' => true, 'unknown_native' => {}, 'entity_ref_native' => {}
      },
      'editable' => 'conditional', 'read_only_style' => 'control', 'label_width' => 3,
      'show_footer' => true, 'no_entity_message' => 'Missing', 'tab_index' => 1,
      'class' => 'view', 'style' => 'display:block', 'dynamic_class' => '$Class',
      'visibility' => {
        'expression' => '$Order != empty', 'roles' => ['Sales.User'], 'attribute' => 'Name',
        'conditions' => [], 'ignore_security' => false,
        'source_variable' => { 'kind' => 'current' }, 'unknown_native' => {}
      },
      'editability' => { 'expression' => 'true' },
      'design_properties' => [
        { 'id' => '1', 'key' => 'density', 'option' => 'compact', 'value_id' => '2' }
      ],
      'unknown_native' => { 'Future' => true }
    }
    view = {
      'type' => 'data_view', 'name' => 'Order', 'options' => options, 'events' => [],
      'body' => [text_widget], 'footer' => []
    }
    expect(exporter.send(:runtime_data_view_supported?, options, view)).to be(true)
    source = exporter.send(:runtime_widget_call_source, view, 0)
    expect(source).to include('data_view(', '"Order"', '"kind" => "association"', 'body do', 'footer')
    expect(source).to include('visible_when', 'editable_when', 'design_property "density"')
    expect(source).to include('unknown_native({"Future" => true})')

    [
      view.merge('x' => 1), view.merge('options' => options.merge('x' => 1)),
      view.merge('events' => [{}]), without(view, 'body'), view.merge('body' => {}),
      view.merge('footer' => {})
    ].map { copy(_1) }.each do |candidate|
      expect(exporter.send(:runtime_data_view_supported?, candidate['options'], candidate)).to be(false)
    end
    expect(exporter.send(:runtime_data_view_region_supported?, [text_widget])).to be(true)
    expect(exporter.send(:runtime_data_view_region_supported?, {})).to be(false)
    expect(exporter.send(:runtime_data_view_region_supported?, [{}])).to be(false)

    invalid_options = [
      options.merge('source' => nil), options.merge('editable' => 'sometimes'),
      options.merge('read_only_style' => 'image'), options.merge('label_width' => -1),
      options.merge('tab_index' => 'bad'), options.merge('show_footer' => nil),
      options.merge('no_entity_message' => nil), options.merge('class' => 1),
      options.merge('style' => 1), options.merge('dynamic_class' => 1),
      options.merge('visibility' => []), options.merge('editability' => []),
      options.merge('design_properties' => {}), options.merge('unknown_native' => []),
      options.merge('editable' => 'always', 'read_only_style' => 'text')
    ]
    invalid_options[0...-1].each do |candidate|
      expect(exporter.send(:runtime_data_view_options_supported?, candidate)).to be(false)
    end
    expect(exporter.send(:runtime_data_view_options_supported?, invalid_options.last)).to be(true)

    valid_sources = [
      { 'kind' => 'context', 'entity' => 'Sales.Order' },
      { 'kind' => 'microflow', 'name' => 'Sales.Load', 'mappings' => [] },
      { 'kind' => 'nanoflow', 'name' => 'Sales.LoadClient', 'mappings' => [] },
      { 'kind' => 'listen', 'target' => 'Grid' },
      { 'kind' => 'native', 'native_type' => 'Forms$Native' }
    ]
    valid_sources.each { expect(exporter.send(:runtime_data_view_source_supported?, _1)).to be(true) }
    [
      nil, { 'kind' => 'unknown' }, { 'kind' => 'context', 'entity' => '', 'bad' => 1 },
      { 'kind' => 'context', 'entity' => '' }, { 'kind' => 'association', 'entity' => '' },
      { 'kind' => 'microflow', 'name' => '' }, { 'kind' => 'nanoflow', 'name' => '' },
      { 'kind' => 'listen', 'target' => '' },
      { 'kind' => 'context', 'entity' => 'E', 'variable' => { 'kind' => 'bad' } },
      { 'kind' => 'association', 'entity' => 'E', 'steps' => {} },
      { 'kind' => 'microflow', 'name' => 'M.F', 'mappings' => {} }
    ].each { expect(exporter.send(:runtime_data_view_source_supported?, _1)).to be(false) }

    expect(exporter.send(:runtime_page_variable_supported?, nil)).to be(true)
    expect(exporter.send(:runtime_page_variable_supported?, { 'kind' => 'current' })).to be(true)
    %w[page_parameter snippet_parameter local_variable widget].each do |kind|
      expect(exporter.send(:runtime_page_variable_supported?, { 'kind' => kind, 'name' => 'Value' })).to be(true)
    end
    expect(exporter.send(:runtime_page_variable_supported?, { 'kind' => 'page_parameter' })).to be(false)
    expect(exporter.send(:runtime_page_variable_supported?, { 'kind' => 'bad', 'name' => 'X' })).to be(false)
    expect(exporter.send(:runtime_page_variable_supported?, { 'name' => 'X', 'bad' => 1 })).to be(false)

    expect(exporter.send(:runtime_data_view_steps_supported?, nil)).to be(true)
    expect(exporter.send(:runtime_data_view_steps_supported?, [])).to be(true)
    [
      {}, [{ 'association' => '', 'entity' => 'E' }], [{ 'association' => 'A', 'entity' => '' }],
      [{ 'association' => 'A', 'entity' => 'E', 'bad' => 1 }]
    ].each { expect(exporter.send(:runtime_data_view_steps_supported?, _1)).to be(false) }
    expect(exporter.send(:runtime_data_view_mappings_supported?, nil)).to be(true)
    expect(exporter.send(
             :runtime_data_view_mappings_supported?,
             [{ 'parameter' => 'Input', 'expression' => '$Order', 'variable' => { 'kind' => 'current' } }]
           )).to be(true)
    [
      {}, [{ 'parameter' => '' }], [{ 'parameter' => 'P', 'bad' => 1 }],
      [{ 'parameter' => 'P', 'variable' => { 'kind' => 'bad' } }]
    ].each { expect(exporter.send(:runtime_data_view_mappings_supported?, _1)).to be(false) }

    expect(exporter.send(:runtime_data_view_condition_supported?, {})).to be(true)
    [
      { 'bad' => 1 }, { 'source_variable' => { 'kind' => 'bad' } }, { 'expression' => 1 },
      { 'attribute' => 1 }, { 'roles' => [1] }, { 'conditions' => {} },
      { 'ignore_security' => nil }, { 'unknown_native' => [] }
    ].each { expect(exporter.send(:runtime_data_view_condition_supported?, _1)).to be(false) }

    expect(exporter.send(:runtime_design_properties_supported?, options['design_properties'])).to be(true)
    expect(exporter.send(:runtime_design_properties_supported?, [])).to be(false)
    expect(exporter.send(:runtime_design_properties_supported?, [{}])).to be(false)
    fallback = exporter.send(
      :runtime_data_view_body_source, view,
      options.merge('design_properties' => [{ 'future' => true }]), 0
    )
    expect(fallback.join("\n")).to include('design_properties({"future" => true})')
  end

  it 'emits typed grid columns, gallery sorting, data grids, and safe generic fallbacks' do
    columns = [
      { 'name' => 'Name', 'attribute' => 'Name', 'caption' => 'Customer', 'filter' => 'text' },
      { 'name' => 'City' }
    ]
    column_source = exporter.send(:runtime_grid_columns_expression, columns)
    expect(column_source).to include('grid_column("Name"', 'grid_column("City")')
    expect(exporter.send(:runtime_grid_columns_expression, {})).to be_nil
    expect(exporter.send(:runtime_grid_columns_expression, [nil])).to be_nil
    expect(exporter.send(:runtime_grid_columns_expression, [{ 'name' => 1 }])).to be_nil
    expect(exporter.send(:runtime_grid_columns_expression, [{ 'name' => 'X', 'bad' => 1 }])).to be_nil
    expect(exporter.send(:runtime_grid_columns_expression, [{ 'name' => 'X', 'filter' => nil }])).to be_nil

    sort = [
      { 'attribute' => 'Name', 'direction' => 'asc' },
      { 'attribute' => 'CreatedDate', 'direction' => 'desc' }
    ]
    expect(exporter.send(:runtime_gallery_sort_expression, sort))
      .to include('sort_by("Name", direction: "asc")')
    expect(exporter.send(:runtime_gallery_sort_expression, {})).to be_nil
    expect(exporter.send(:runtime_gallery_sort_expression, [nil])).to be_nil
    expect(exporter.send(:runtime_gallery_sort_expression, [{ 'attribute' => 'X' }])).to be_nil
    expect(exporter.send(
             :runtime_gallery_sort_expression, [{ 'attribute' => 'X', 'direction' => :asc }]
           )).to be_nil

    event = {
      'event' => 'on_click', 'kind' => 'microflow', 'handler' => 'Sales.Open', 'arguments' => {}
    }
    grid = {
      'type' => 'data_grid', 'name' => 'Orders',
      'options' => { 'entity' => 'Sales.Order', 'selection' => 'single', 'columns' => columns },
      'events' => [event], 'children' => []
    }
    expect(exporter.send(:runtime_data_grid_supported?, :data_grid, grid['options'], grid)).to be(true)
    source = exporter.send(:runtime_widget_call_source, grid, 0, generic_sink: true)
    expect(source).to include('data_grid "Orders"', 'entity: "Sales.Order"', 'column "Name"')
    expect(source).to include('on_click microflow: "Sales.Open"')
    [
      [:gallery, grid['options'], grid],
      [:data_grid, grid['options'].merge('bad' => 1), grid],
      [:data_grid, grid['options'], grid.merge('children' => [{}])],
      [:data_grid, grid['options'], grid.merge('body' => [])],
      [:data_grid, grid['options'], grid.merge('events' => 'bad')],
      [:data_grid, grid['options'].merge('columns' => [{}]), grid]
    ].each do |type, options, widget|
      expect(exporter.send(:runtime_data_grid_supported?, type, options, widget)).to be(false)
    end

    expect(exporter.send(:non_negative_integer?, 0)).to be(true)
    expect(exporter.send(:non_negative_integer?, '2')).to be(true)
    expect(exporter.send(:non_negative_integer?, -1)).to be(false)
    expect(exporter.send(:non_negative_integer?, 'bad')).to be(false)
    expect(exporter.send(:runtime_alignment?, :center)).to be(true)
    expect(exporter.send(:runtime_alignment?, :baseline)).to be(false)
    expect(exporter.send(:runtime_grid_weight?, :grow)).to be(true)
    expect(exporter.send(:runtime_grid_weight?, :auto)).to be(true)
    expect(exporter.send(:runtime_grid_weight?, 1)).to be(true)
    expect(exporter.send(:runtime_grid_weight?, 12)).to be(true)
    expect(exporter.send(:runtime_grid_weight?, 13)).to be(false)
    expect(exporter.send(:runtime_grid_weight?, 'bad')).to be(false)
    expect(exporter.send(:runtime_keys?, {}, [])).to be(true)
    expect(exporter.send(:runtime_keys?, [], [])).to be(false)
    expect(exporter.send(:runtime_keywords_safe?, 'class' => 'x', 'caption' => 'x')).to be(true)
    expect(exporter.send(:runtime_keywords_safe?, 'bad-key' => 1)).to be(false)
    expect(exporter.send(:runtime_keywords_safe?, 'events' => [])).to be(false)

    generic = {
      'type' => 'future_widget', 'name' => 'Future', 'options' => { 'bad-key' => true },
      'events' => 'opaque', 'children' => []
    }
    expect(exporter.send(:runtime_widget_call_source, generic, 0, generic_sink: true))
      .to include('widget :future_widget', 'options:', 'events: "opaque"')

    positional = exporter.send(:runtime_widget_declaration, 'unknown_native', ['{"x"=>1}'], 2, false)
    expect(positional).to eq('  unknown_native({"x"=>1})')
    multiline = exporter.send(
      :runtime_widget_declaration, 'widget', ['"Name"', %(value: "#{'x' * 100}")], 0, true
    )
    expect(multiline).to include("widget(\n", "\n) do")
  end
end
# rubocop:enable Metrics/BlockLength
