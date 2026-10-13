# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'design properties declared in Ruby' do
  let(:definitions) do
    {
      'Widget' => [{ 'name' => 'Spacing', 'type' => 'Spacing',
                     'margin' => [{ 'name' => 'M', 'top' => { 'class' => 'spacing-outer-top-medium' } }] }],
      'Button' => [{ 'name' => 'Size', 'type' => 'Dropdown',
                     'options' => [{ 'name' => 'Large', 'class' => 'btn-lg' }] },
                   { 'name' => 'Block', 'type' => 'Toggle', 'class' => 'btn-block' }],
      'LayoutGridRow' => [{ 'name' => 'Cards style', 'type' => 'Toggle', 'class' => 'row-cards' }],
      'LayoutGridColumn' => [{ 'name' => 'Centered', 'type' => 'Toggle', 'class' => 'col-center' }],
      'com.mendix.widget.web.datagrid.Datagrid' => [{ 'name' => 'Hover', 'type' => 'Toggle',
                                                      'class' => 'table-hover' }],
      'com.mendix.widget.web.gallery.Gallery' => [{ 'name' => 'Lines', 'type' => 'Toggle', 'class' => 'lines' }],
      'com.example.Badge' => [{ 'name' => 'Pill', 'type' => 'Toggle', 'class' => 'badge-pill' }],
      'DataGrid' => [{ 'name' => 'Striped', 'type' => 'Toggle', 'class' => 'table-striped' }]
    }
  end

  def stored(key, value) = { 'Key' => key, 'Value' => value }
  def toggle(key) = stored(key, { '$Type' => 'Forms$ToggleDesignPropertyValue' })
  def option(key, name) = stored(key, { '$Type' => 'Forms$OptionDesignPropertyValue', 'Option' => name })

  it 'reads the declared design of widgets, layout grid rows and columns' do
    spacing = stored('Spacing', { '$Type' => 'Forms$CompoundDesignPropertyValue',
                                  'Properties' => [2, { 'Key' => 'margin-top', 'Value' => { 'Option' => 'M' } }] })
    document = { 'Widgets' => [2,
                               { '$Type' => 'Forms$ActionButton', 'Name' => 'save',
                                 'Appearance' => { 'DesignProperties' => [3, option('Size', 'Large'), toggle('Block'),
                                                                          spacing, 'raw'] } },
                               { '$Type' => 'Forms$ActionButton', 'Name' => 'plain' },
                               { '$Type' => 'Forms$LayoutGrid', 'Name' => 'grid',
                                 'Rows' => [2, { 'Appearance' => { 'DesignProperties' => [3, toggle('Cards style')] },
                                                 'Columns' => [2, { 'Appearance' => {
                                                   'DesignProperties' => [3, toggle('Centered')]
                                                 } }] }] }] }

    expect(Mxrb::RubyApp::DesignDeclarations.declared(document)).to eq(
      'save' => { 'Size' => 'Large', 'Block' => true, 'Spacing' => { 'margin-top' => 'M' } },
      'grid/rows/0' => { 'Cards style' => true }, 'grid/rows/0/columns/0' => { 'Centered' => true }
    )
  end

  it 'adds declared designs to projected widgets and grid rows' do
    designs = { 'save' => { 'Size' => 'Large' }, 'grid/rows/0' => { 'Cards style' => true },
                'grid/rows/0/columns/1' => { 'Centered' => true } }
    projected = [
      { 'type' => 'button', 'name' => 'save' }, { 'name' => 'not a widget' }, 'raw',
      { 'type' => 'layout_grid', 'name' => 'grid', 'options' => {
        'rows' => [{ 'columns' => [{ 'widgets' => [] }, { 'options' => {} }] }]
      } },
      { 'type' => 'layout_grid', 'name' => 'bare' },
      { 'type' => 'native_widget', 'name' => 'fragment', 'options' => { 'native_type' => 'Forms$Header' } }
    ]
    injected = Mxrb::RubyApp::DesignDeclarations.inject(projected, designs.merge('fragment' => { 'Size' => 'Large' }))

    expect(injected[0]).to eq('type' => 'button', 'name' => 'save', 'options' => { 'design' => { 'Size' => 'Large' } })
    expect(injected[1..2]).to eq([{ 'name' => 'not a widget' }, 'raw'])
    row = injected[3].dig('options', 'rows', 0)
    expect(row['options']).to eq('design' => { 'Cards style' => true })
    expect(row['columns']).to eq([{ 'widgets' => [] }, { 'options' => { 'design' => { 'Centered' => true } } }])
    expect(injected[4]).to eq('type' => 'layout_grid', 'name' => 'bare', 'options' => { 'rows' => [] })
    expect(injected[5]).to eq(projected[5])
    expect(Mxrb::RubyApp::DesignDeclarations.inject(projected, {})).to equal(projected)
  end

  it 'declares designs on Ruby widgets, rows and columns and rejects malformed ones' do
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.button 'save', caption: 'Save', design: tree.design_values(Size: :Large, Block: true)
    tree.layout_grid('grid') do
      row(design: { 'Cards style' => true }) do
        column(design: design_values(Centered: true)) do
          text :title, caption: 'Title', design: design_values(Spacing: design_sides('margin-top': 'M'))
        end
      end
    end

    expect(tree.widgets[0]['options']['design']).to eq('Size' => 'Large', 'Block' => true)
    row = tree.widgets[1].dig('options', 'rows', 0)
    expect(row.dig('options', 'design')).to eq('Cards style' => true)
    expect(row.dig('columns', 0, 'options', 'design')).to eq('Centered' => true)
    expect(row.dig('columns', 0, 'widgets', 0, 'options', 'design')).to eq('Spacing' => { 'margin-top' => 'M' })
    expect { tree.button 'bad', design: 'Large' }.to raise_error(ArgumentError, /requires a Hash/)
    expect { tree.button 'bad', design: { Size: 1 } }.to raise_error(ArgumentError, /design property Size requires/)
    builder = Mxrb::Dsl::WidgetSlotBuilder.new
    expect { builder.association_path(%w[A.B A.C], design: { Size: 'Large' }) }
      .to raise_error(ArgumentError, /must accompany a widget declaration/)
  end

  it 'resolves declared designs to the classes of their theme type when served' do
    served = [
      { 'type' => 'button', 'name' => 'save', 'options' => { 'caption' => 'Save',
                                                             'design' => { 'Size' => 'Large', 'Block' => true } } },
      { 'type' => 'button', 'name' => 'emptied', 'options' => { 'design' => {} } },
      { 'type' => 'data_grid', 'name' => 'grid2', 'options' => { 'presentation' => 'datagrid2',
                                                                 'design' => { 'Hover' => true } } },
      { 'type' => 'data_grid', 'name' => 'classic', 'options' => { 'design' => { 'Striped' => true } } },
      { 'type' => 'gallery', 'name' => 'cards', 'options' => { 'design' => { 'Lines' => true } } },
      { 'type' => 'pluggable_widget', 'name' => 'badge',
        'options' => { 'widget_id' => 'com.example.Badge', 'design' => { 'Pill' => true } } },
      { 'type' => 'future_widget', 'name' => 'next',
        'options' => { 'design' => { 'Spacing' => { 'margin-top' => 'M' } } } },
      { 'type' => 'layout_grid', 'name' => 'grid', 'options' => {
        'rows' => [{ 'options' => { 'design' => { 'Cards style' => true } },
                     'columns' => [{ 'options' => { 'design' => { 'Centered' => true } } }, { 'widgets' => [] }] }]
      } },
      { 'type' => 'layout_grid', 'name' => 'bare' }, { 'name' => 'not a widget' }, 'raw'
    ]
    resolved = Mxrb::RubyApp::DesignDeclarations.resolve(served, definitions)

    expect(resolved.first(7).map { _1['options'] }).to eq(
      [{ 'caption' => 'Save', 'design_class' => 'btn-lg btn-block' }, {},
       { 'presentation' => 'datagrid2', 'design_class' => 'table-hover' }, { 'design_class' => 'table-striped' },
       { 'design_class' => 'lines' }, { 'widget_id' => 'com.example.Badge', 'design_class' => 'badge-pill' },
       { 'design_class' => 'spacing-outer-top-medium' }]
    )
    row = resolved[7].dig('options', 'rows', 0)
    expect(row['options']).to eq('design_class' => 'row-cards')
    expect(row['columns']).to eq([{ 'options' => { 'design_class' => 'col-center' } }, { 'widgets' => [] }])
    expect(resolved[8..]).to eq([{ 'type' => 'layout_grid', 'name' => 'bare', 'options' => { 'rows' => [] } },
                                 { 'name' => 'not a widget' }, 'raw'])
  end

  it 'resolves the typed design properties data views declare and leaves them out of injection' do
    properties = [{ 'id' => 'a', 'key' => 'Size', 'value_id' => 'b', 'option' => 'Large' },
                  { 'id' => 'c', 'key' => 'Block', 'value_id' => 'd', 'toggle' => true },
                  { 'id' => 'e', 'key' => 'Spacing', 'value_id' => 'f',
                    'properties' => [{ 'key' => 'margin-top', 'option' => 'M' }] }, 'raw']
    view = { 'type' => 'data_view', 'name' => 'view', 'options' => { 'design_properties' => properties } }
    designs = { 'view' => { 'Size' => 'Large' } }
    expect(Mxrb::RubyApp::DesignDeclarations.inject([view], designs)).to eq([view])
    expect(Mxrb::RubyApp::DesignDeclarations.injected_keys([view], designs)).to eq(['view'])
    view_definitions = definitions.merge('DataView' => definitions.fetch('Button'))
    resolved = Mxrb::RubyApp::DesignDeclarations.resolve([view], view_definitions).first
    expect(resolved.dig('options', 'design_class')).to eq('btn-lg btn-block spacing-outer-top-medium')
    expect(resolved.dig('options', 'design_properties')).to eq(properties)
  end

  it 'exports tab control designs and records classes only for undeclared widgets' do
    exporter = Mxrb::RubyApp::Exporter.allocate
    tab_control = { 'type' => 'tab_control', 'name' => 'tabs', 'options' => {
      'design' => { 'Style' => 'Pills' }, 'tabs' => [{ 'name' => 'one', 'caption' => 'One', 'widgets' => [] }]
    } }
    expect(exporter.send(:runtime_tab_control_supported?, tab_control['options'], tab_control)).to be(true)
    expect(exporter.send(:runtime_tab_control_source, tab_control, 0))
      .to start_with('tab_control "tabs", design: design_values(Style: "Pills") do')
    expect(exporter.send(:runtime_design_expression, { 'Row gap' => 'M', 'Spacing' => { 'margin-top' => 'M' } }))
      .to eq('design_values("Row gap": "M", Spacing: design_sides("margin-top": "M"))')

    exporter.instance_variable_set(:@mpr_path, '/project/App.mpr')
    allow(Mxrb::RubyApp::DesignClasses).to receive(:collect).and_return(
      'App.Home' => { 'save' => 'btn-lg', 'fragment' => 'fragment-class' }, 'App.Shell' => { 'bar' => 'flex-row' }
    )
    allow(exporter).to receive(:write)
    exporter.send(:record_declared_designs, 'App.Home', ['save'])
    exporter.send(:record_declared_designs, 'App.Shell', [])
    exporter.send(:record_declared_designs, 'App.Shell', ['bar'])
    exporter.send(:write_design_classes, double('project'))
    expect(exporter).to have_received(:write).with(
      Mxrb::RubyApp::DesignClasses::PATH, "#{JSON.pretty_generate('App.Home' => { 'fragment' => 'fragment-class' })}\n"
    )
  end

  it 'serves the classes of the current Ruby declarations instead of recorded ones' do
    Dir.mktmpdir do |root|
      themes = File.join(root, 'frontend', 'src', 'generated', 'platform', 'themesource', 'atlas', 'web')
      FileUtils.mkdir_p(themes)
      File.write(File.join(themes, 'design-properties.json'), JSON.generate(definitions))
      tree = Mxrb::RubyApp::Page::WidgetTree.new
      tree.button 'save', caption: 'Save'
      tree.button 'cancel', caption: 'Cancel', design: { Size: 'Large' }
      implementation = double('page', mendix_name: 'App.Home', mendix_id: 'home', title: 'Home',
                                      appearance_class: '', appearance_style: '', data_source: nil,
                                      presentation_contract: nil, widgets: tree.widgets, native_definition: nil)
      application = Mxrb::RubyApp::Application.allocate
      application.instance_variable_set(:@root, root)
      application.instance_variable_set(:@design_classes, {})
      allow(Mxrb::RubyApp::Registry).to receive(:fetch).and_call_original
      allow(Mxrb::RubyApp::Registry).to receive(:fetch).with(:page, 'App.Home').and_return(implementation)
      allow(application).to receive(:authorize_document!)

      widgets = application.page('App.Home')[:widgets]
      expect(widgets.map { _1.dig('options', 'design_class') }).to eq([nil, 'btn-lg'])
      allow(Mxrb::RubyApp::Registry).to receive(:all).with(:presentation).and_return(
        'App.Shell' => { kind: 'layout', widgets: [{ 'type' => 'button', 'name' => 'b',
                                                     'options' => { 'design' => { 'Size' => 'Large' } } }] }
      )
      expect(application.send(:design_classed_presentation).dig('App.Shell', :widgets, 0, 'options'))
        .to eq('design_class' => 'btn-lg')
    end
  ensure
    Mxrb::RubyApp::Registry.reset!
  end
end
# rubocop:enable Metrics/BlockLength
