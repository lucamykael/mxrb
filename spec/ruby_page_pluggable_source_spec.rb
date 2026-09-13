# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'runtime page pluggable property blocks' do
  let(:page_id) { 'd858dba7-4018-413f-9b71-2734f31c4744' }
  let(:widget_id) { 'com.example.TypedWidget' }
  let(:catalog) { Mxrb::Pluggable::Catalog.new }
  let(:schema) do
    Mxrb::Pluggable.widget_type(widget_id, catalog:) do
      properties do
        property :title, :string
        property :enabled, :boolean
        property :count, :integer
      end
    end
  end
  let(:document) do
    node = Mxrb::Pluggable::Node.new(schema, catalog:)
    forms_codec = Mxrb::Forms::MprCodec.new(pluggable_catalog: catalog)
    codec = Mxrb::Pluggable::MprCodec.new(forms_codec:, catalog:)
    { '$Type' => 'Forms$Page', 'Widgets' => [codec.encode(node).merge('Name' => 'custom')] }
  end
  let(:mpr) do
    double('private MPR').tap do |value|
      allow(value).to receive(:unit).with(page_id).and_return(:page)
      allow(value).to receive(:parse_contents).with(:page).and_return(document)
    end
  end
  let(:widget) do
    {
      'type' => 'pluggable_widget', 'name' => 'custom',
      'options' => { 'widget_id' => widget_id, 'widget_name' => 'Custom',
                     'properties' => { 'title' => '', 'enabled' => false, 'count' => nil } }
    }
  end

  def with_context(&block)
    Mxrb::RubyApp::PluggableProperties.with_mpr(mpr) do
      Mxrb::RubyApp::PluggableProperties.with_page(page_id, &block)
    end
  end

  def emit(value = widget, generic_sink: false)
    Mxrb::RubyApp::Exporter.allocate.send(:runtime_widget_dsl_source, [value], 0, generic_sink:)
  end

  it 'emits schema-checked properties without a Hash and retains the full runtime projection' do
    with_context do
      source = emit
      expect(source).to include('properties do', 'set "title", ""', 'set "enabled", false', 'set "count", nil')
      expect(source).not_to include('properties:', '{', page_id)
      tree = Mxrb::RubyApp::Page::WidgetTree.new
      tree.instance_eval(source)
      expect(tree.widgets).to eq([widget])
      expect(tree.widgets.first.dig('options', 'properties').keys).to eq(%w[title enabled count])
    end
  end

  it 'supports existing native widget sinks without changing their projection contract' do
    with_context do
      builder = Mxrb::Dsl::WidgetSlotBuilder.new
      builder.instance_eval(emit(generic_sink: true))
      baseline = Mxrb::Dsl::WidgetSlotBuilder.new
      baseline.pluggable_widget(
        'custom', widget_id:, widget_name: 'Custom', properties: widget.dig('options', 'properties')
      )
      expect(builder.widgets).to eq(baseline.widgets)
    end
  end

  it 'falls back during emission without a baseline, but fails before installing an authored typed widget' do
    expect(emit).to include('properties:')
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    expect do
      tree.pluggable_widget('custom', widget_id:) { properties { set 'title', 'New' } }
    end.to raise_error(Mxrb::ValidationError, /baseline/)
    expect(tree.widgets).to eq([])
  end

  it 'rejects mixed legacy and typed syntax and rolls back failed widgets in both builders' do
    with_context do
      [Mxrb::RubyApp::Page::WidgetTree.new, Mxrb::Dsl::WidgetSlotBuilder.new].each do |tree|
        expect do
          tree.pluggable_widget('custom', widget_id:, properties: {}) { properties { set 'title', 'New' } }
        end.to raise_error(ArgumentError, /either properties:/)
        expect do
          tree.pluggable_widget('custom', widget_id:) do
            properties do
              set 'title', 'Partial'
              set 'count', 'invalid'
            end
          end
        end.to raise_error(TypeError)
        expect do
          tree.pluggable_widget('custom', widget_id:) do
            properties { set 'title', 'First' }
            properties { set 'title', 'Second' }
          end
        end.to raise_error(ArgumentError, /only one properties block/)
        expect(tree.widgets).to eq([])
      end
    end
  end

  it 'keeps a page native declaration unchanged when configuring typed runtime properties' do
    klass = Class.new(Mxrb::RubyApp::Page)
    klass.mendix_name('Example.Detail', id: page_id)
    klass.native { title 'Native title' }
    original = klass.native_definition
    Mxrb::RubyApp::PluggableProperties.with_mpr(mpr) do
      klass.configure(title: 'Runtime title') do
        pluggable_widget('custom', widget_id: 'com.example.TypedWidget') { properties { set 'enabled', false } }
      end
    end
    expect(klass.native_definition).to equal(original)
    expect(klass.widgets.first.dig('options', 'properties')).to eq('enabled' => false)
  ensure
    Mxrb::RubyApp::Registry.reset!
  end

  it 'preserves the complete prior page configuration when a typed property block fails' do
    klass = Class.new(Mxrb::RubyApp::Page)
    klass.mendix_name('Example.Detail', id: page_id)
    klass.native { title 'Native title' }
    original_source = { kind: 'context', entity: 'Example.Item' }
    klass.configure(title: 'Original', widgets: [], appearance_class: 'original-class',
                    appearance_style: 'original-style', data_source: original_source)
    snapshot = lambda do
      [klass.title, klass.widgets, klass.appearance_class, klass.appearance_style,
       klass.data_source, klass.native_definition]
    end
    original = snapshot.call
    configure = lambda do
      klass.configure(title: 'Changed', appearance_class: 'changed-class',
                      appearance_style: 'changed-style', data_source: nil) do
        pluggable_widget('custom', widget_id: 'com.example.TypedWidget') do
          properties { set 'typo', false }
        end
      end
    end
    expect { configure.call }.to raise_error(Mxrb::ValidationError, /baseline/)
    expect(snapshot.call).to eq(original)
    with_context do
      expect { configure.call }.to raise_error(KeyError)
      expect(snapshot.call).to eq(original)
    end
    expect(klass.widgets).to equal(original[1])
    expect(klass.data_source).to equal(original_source)
    expect(klass.native_definition).to equal(original.last)
  ensure
    Mxrb::RubyApp::Registry.reset!
  end

  it 'preserves deferred identity restoration and prior configuration when design resolution fails' do
    manifest = double(modules: [{ 'pages' => [{ 'id' => page_id, 'widgets' => [] }] }])
    klass = Class.new(Mxrb::RubyApp::Page)
    klass.configure(title: 'Original', widgets: [])
    original = [{ 'type' => 'text', 'name' => 'pending' }]
    invalid = [{ 'type' => 'data_view', 'name' => 'new_widget',
                 'options' => { 'design_properties' => [{ 'key' => 'Style', 'option' => 'New' }] } }]
    context = Mxrb::RubyApp::PageDesignIdentity.new(manifest)
    context.configure(klass, original)
    klass.mendix_name('Example.Detail', id: page_id)
    expect { context.configure(klass, invalid) }.to raise_error(Mxrb::ValidationError, /design properties/)
    context.finalize!
    expect(klass.widgets).to eq(original)

    Mxrb::RubyApp::PageDesignIdentity.with(manifest) do
      expect { klass.configure(title: 'Changed', widgets: invalid) }
        .to raise_error(Mxrb::ValidationError, /design properties/)
      expect(klass.title).to eq('Original')
      expect(klass.widgets).to eq(original)
    end
  ensure
    Mxrb::RubyApp::Registry.reset!
  end
end
# rubocop:enable Metrics/BlockLength
