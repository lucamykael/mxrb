# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'private Ruby page configuration' do
  let(:page_id) { '11111111-1111-4111-8111-111111111111' }
  let(:property_id) { '22222222-2222-4222-8222-222222222222' }
  let(:value_id) { '33333333-3333-4333-8333-333333333333' }
  let(:exporter) { Mxrb::RubyApp::Exporter.allocate }
  let(:source_spec) do
    { 'kind' => 'context', 'entity' => 'App.Item',
      'variable' => { 'kind' => 'page_parameter', 'name' => 'Item' } }
  end
  let(:design) { { 'id' => property_id, 'value_id' => value_id, 'key' => 'Spacing', 'option' => 'Large' } }
  let(:widget) do
    {
      'type' => 'data_view', 'name' => 'details',
      'options' => {
        'source' => source_spec, 'editable' => 'always', 'read_only_style' => 'control',
        'label_width' => 0, 'show_footer' => true, 'no_entity_message' => '', 'tab_index' => 0,
        'design_properties' => [design]
      }, 'body' => [], 'footer' => []
    }
  end

  before { Mxrb::RubyApp::Registry.reset! }
  after { Mxrb::RubyApp::Registry.reset! }

  def manifest(widgets, identifier = page_id)
    Mxrb::RubyApp::Manifest.new('/tmp/page-config', 'mode' => 'ruby', 'modules' => [{
      'name' => 'App', 'pages' => [{ 'id' => identifier, 'widgets' => widgets }]
    }])
  end

  def emitted_widgets(widgets)
    source = exporter.send(:runtime_widget_dsl_source, widgets, 0)
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.instance_eval(source, 'page_configuration.rb')
    [source, tree.widgets]
  end

  def normalize(value)
    case value
    when Hash then value.to_h { |key, item| [key.to_s, normalize(item)] }
    when Array then value.map { normalize(_1) }
    when Symbol then value.to_s
    else value
    end
  end

  it 'emits semantic design properties without UUIDs and restores private identities exactly' do
    source, projection = emitted_widgets([widget])
    expect(source).to include('design_property "Spacing", option: "Large"', 'from: context(')
    expect(source).not_to include(property_id, value_id, 'design_properties(', 'from: {')
    Mxrb::RubyApp::PageDesignIdentity.with(manifest([widget])) do
      restored = Mxrb::RubyApp::PageDesignIdentity.restore(page_id, projection)
      expect(restored).to eq([widget])
    end
    expect(projection.first.dig('options', 'design_properties', 0, 'id')).to be_nil
  end

  it 'keeps authored option changes while restoring IDs through Page.configure' do
    source, = emitted_widgets([widget])
    source = source.sub('option: "Large"', 'option: "Small"')
    klass = Class.new(Mxrb::RubyApp::Page)
    klass.mendix_name('App.Detail', id: page_id)
    Mxrb::RubyApp::PageDesignIdentity.with(manifest([widget])) do
      klass.configure(title: 'Detail') { instance_eval(source, 'edited_page.rb') }
    end
    expect(klass.widgets.first.dig('options', 'design_properties')).to eq([design.merge('option' => 'Small')])
    expect(widget.dig('options', 'design_properties')).to eq([design])
    expect(klass.native_definition).to be_nil
  end

  it 'preserves identity after widget reordering and within nested structural regions' do
    nested = { 'type' => 'container', 'name' => 'wrapper', 'children' => [widget] }
    other = { 'type' => 'text', 'name' => 'heading', 'options' => { 'caption' => 'Title' } }
    _, projection = emitted_widgets([other, nested])
    Mxrb::RubyApp::PageDesignIdentity.with(manifest([nested, other])) do
      restored = Mxrb::RubyApp::PageDesignIdentity.restore(page_id, projection)
      expect(restored.last.dig('children', 0, 'options', 'design_properties')).to eq([design])
    end
  end

  it 'rejects ambiguous widget names and conflicting legacy property IDs' do
    _, projection = emitted_widgets([widget])
    Mxrb::RubyApp::PageDesignIdentity.with(manifest([widget, widget])) do
      expect { Mxrb::RubyApp::PageDesignIdentity.restore(page_id, projection) }
        .to raise_error(Mxrb::ValidationError, /ambiguous page widget/)
    end
    projection.first.dig('options', 'design_properties').first['id'] = value_id
    Mxrb::RubyApp::PageDesignIdentity.with(manifest([widget])) do
      expect { Mxrb::RubyApp::PageDesignIdentity.restore(page_id, projection) }
        .to raise_error(Mxrb::ValidationError, /identity mismatch/)
    end
  end

  it 'fails closed for missing identity baselines instead of generating replacement UUIDs' do
    _, projection = emitted_widgets([widget])
    Mxrb::RubyApp::PageDesignIdentity.with(manifest(nil)) do
      expect { Mxrb::RubyApp::PageDesignIdentity.restore(page_id, projection) }
        .to raise_error(Mxrb::ValidationError, /private widget identity baseline/)
    end
    broken = Marshal.load(Marshal.dump(widget))
    broken.dig('options', 'design_properties').first.delete('value_id')
    Mxrb::RubyApp::PageDesignIdentity.with(manifest([broken])) do
      expect { Mxrb::RubyApp::PageDesignIdentity.restore(page_id, projection) }
        .to raise_error(Mxrb::ValidationError, /missing private design property identity/)
    end
  end

  it 'fails safely for an unrecognized new widget in an existing page' do
    _, projection = emitted_widgets([widget])
    projection.first['name'] = 'newDetails'
    Mxrb::RubyApp::PageDesignIdentity.with(manifest([widget])) do
      expect { Mxrb::RubyApp::PageDesignIdentity.restore(page_id, projection) }
        .to raise_error(Mxrb::ValidationError, /renamed, new or ambiguous page widget/)
    end
  end

  it 'restores designs when configure precedes the page identity declaration' do
    source, = emitted_widgets([widget])
    klass = Class.new(Mxrb::RubyApp::Page)
    Mxrb::RubyApp::PageDesignIdentity.with(manifest([widget])) do
      klass.configure(title: 'Detail') { instance_eval(source, 'reordered_page.rb') }
      klass.mendix_name('App.Detail', id: page_id)
    end
    expect(klass.widgets.first.dig('options', 'design_properties')).to eq([design])
  end

  it 'does not infer design-key renames from position' do
    _, projection = emitted_widgets([widget])
    projection.first.dig('options', 'design_properties').first['key'] = 'Changed key'
    Mxrb::RubyApp::PageDesignIdentity.with(manifest([widget])) do
      expect { Mxrb::RubyApp::PageDesignIdentity.restore(page_id, projection) }
        .to raise_error(Mxrb::ValidationError, %r{rename from removal/insertion})
    end
  end

  it 'restores nested project contexts after exceptions without leaking IDs between applications' do
    _, projection = emitted_widgets([widget])
    changed = Marshal.load(Marshal.dump(widget))
    changed.dig('options', 'design_properties').first['id'] = page_id
    Mxrb::RubyApp::PageDesignIdentity.with(manifest([widget])) do
      expect do
        Mxrb::RubyApp::PageDesignIdentity.with(manifest([changed])) do
          restored = Mxrb::RubyApp::PageDesignIdentity.restore(page_id, projection)
          expect(restored.first.dig('options', 'design_properties', 0, 'id')).to eq(page_id)
          raise 'inner failure'
        end
      end.to raise_error('inner failure')
      restored = Mxrb::RubyApp::PageDesignIdentity.restore(page_id, projection)
      expect(restored.first.dig('options', 'design_properties', 0, 'id')).to eq(property_id)
    end
    expect(Mxrb::RubyApp::PageDesignIdentity.restore(page_id, projection)).to equal(projection)
  end

  it 'retains unknown design property structures through the legacy API' do
    unknown = widget.merge('options' => widget.fetch('options').merge(
      'design_properties' => [design.merge('future_option' => false)]
    ))
    source, projection = emitted_widgets([unknown])
    expect(source).to include('design_properties(', '"future_option" => false', property_id)
    expect(projection.first.dig('options', 'design_properties')).to eq([design.merge('future_option' => false)])
  end

  it 'emits configure data sources on the page class with the exact original Ruby shape' do
    original = { kind: :context, entity: 'App.Item', variable: { kind: :page_parameter, name: 'Item' } }
    source = exporter.send(
      :page_source, 'App', 'DetailPage', 'App.Detail', page_id, 'Detail', [],
      appearance_class: '', appearance_style: '', data_source: original
    )
    expect(source).to include('data_source: context(')
    expect(source).not_to include('data_source: {')
    namespace = Module.new
    namespace.module_eval(source, 'configured_page.rb')
    klass = namespace.const_get(:App).const_get(:DetailPage)
    expect(klass.data_source).to eq(original)
  end

  it 'preserves explicit false and unknown configure source fields through the legacy fallback' do
    definition = source_spec.merge('force_full_objects' => false, 'future_setting' => nil)
    source = exporter.send(
      :page_source, 'App', 'DetailPage', 'App.Detail', page_id, 'Detail', [],
      appearance_class: '', appearance_style: '', data_source: definition
    )
    expect(source).to include('data_source: {')
    namespace = Module.new
    namespace.module_eval(source, 'legacy_configured_page.rb')
    expect(namespace.const_get(:App).const_get(:DetailPage).data_source).to eq(definition)
  end

  it 'keeps flow variable mappings semantic when the source is configured at class scope' do
    klass = Class.new(Mxrb::RubyApp::Page)
    definition = klass.nanoflow_source('App.Read', pass: [['Item', klass.page_variable('Item')]])
    expect(definition).to eq(
      kind: :nanoflow, name: 'App.Read', mappings: [
        { parameter: 'Item', variable: { kind: :page_parameter, name: 'Item' } }
      ]
    )
  end

  it 'emits typed grid columns without changing legacy data_grid block semantics' do
    columns = [{ 'name' => 'Name', 'attribute' => 'App.Item.Name', 'caption' => 'Name' }]
    grid = { 'type' => 'data_grid', 'name' => 'items', 'options' => {
      'columns' => columns, 'entity' => 'App.Item', 'selection' => 'single'
    } }
    source, actual = emitted_widgets([grid])
    expect(source).to include('grid_column(', 'entity: "App.Item"', 'selection: "single"')
    expect(source).not_to include('"name" =>')
    expect(actual).to eq([grid])
  end

  it 'retains non-equivalent grid column fields including explicit nil and future settings' do
    columns = [
      { 'name' => 'Name', 'attribute' => nil },
      { 'name' => 'Code', 'future_setting' => false }
    ]
    grid = { 'type' => 'data_grid', 'name' => 'items', 'options' => { 'columns' => columns } }
    source, actual = emitted_widgets([grid])
    expect(source).not_to include('grid_column(')
    expect(actual).to eq([grid])
  end

  [
    { 'kind' => 'context', 'entity' => 'App.Item', 'variable' => { 'kind' => 'page_parameter', 'name' => 'Item' } },
    { 'kind' => 'context', 'entity' => 'App.Item', 'variable' => { 'kind' => 'current' } },
    { 'kind' => 'association', 'entity' => 'App.Other',
      'steps' => [{ 'association' => 'App.Item_Other', 'entity' => 'App.Other' }] },
    { 'kind' => 'microflow', 'name' => 'App.Read', 'mappings' => [{ 'parameter' => 'Item', 'expression' => '$Item' }] },
    { 'kind' => 'microflow', 'name' => 'App.Read', 'settings_native' => { 'UseAllPages' => false } },
    { 'kind' => 'nanoflow', 'name' => 'App.Read', 'mappings' => [
      { 'parameter' => 'Item', 'variable' => { 'kind' => 'page_parameter', 'name' => 'Item' } }
    ] },
    { 'kind' => 'listen', 'target' => 'grid', 'force_full_objects' => true }
  ].each do |definition|
    it "uses exact existing semantic DSL for #{definition.inspect}" do
      source = Mxrb::RubyApp::PageDataSources.source_expression(definition)
      expect(source).to be_a(String)
      expect(source).not_to include('{')
      receiver = Mxrb::RubyApp::Page::WidgetTree.new
      expect(normalize(receiver.instance_eval(source, 'page_data_source.rb'))).to eq(definition)
    end
  end

  [
    { 'kind' => 'context', 'entity' => 'App.Item', 'variable' => nil },
    { 'kind' => 'context', 'entity' => 'App.Item', 'force_full_objects' => false },
    { 'kind' => 'microflow', 'name' => 'App.Read', 'mappings' => [] },
    { 'kind' => 'listen', 'target' => 'grid', 'future_setting' => false },
    { 'kind' => 'native', 'native_type' => 'Forms$FutureSource' }
  ].each do |definition|
    it "retains fallback for non-equivalent source #{definition.inspect}" do
      expect(Mxrb::RubyApp::PageDataSources.source_expression(definition)).to be_nil
    end
  end
end
# rubocop:enable Metrics/BlockLength
