# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'typed runtime page events' do
  let(:exporter) { Mxrb::RubyApp::Exporter.allocate }

  def projection(events)
    {
      'type' => 'button', 'name' => 'open', 'options' => { 'caption' => 'Open' },
      'caption' => 'Open', 'events' => events
    }
  end

  def emit(widget)
    source = exporter.send(:runtime_widget_dsl_source, [widget], 0)
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    tree.instance_eval(source, 'typed_page_events.rb')
    [source, tree.widgets.first]
  end

  def event(arguments = Mxrb::Dsl::UNSET)
    value = { 'event' => 'on_click', 'kind' => 'microflow', 'handler' => 'App.Open' }
    value['arguments'] = arguments unless arguments.equal?(Mxrb::Dsl::UNSET)
    value
  end

  it 'distinguishes missing arguments from a present empty argument collection' do
    absent_source, absent = emit(projection([event]))
    empty_source, empty = emit(projection([event({})]))
    expect(absent_source).to include('on_click microflow: "App.Open"')
    expect(absent_source).not_to include('on_click microflow: "App.Open" do')
    expect(empty_source).to include("on_click microflow: \"App.Open\" do\n  end")
    expect(absent.fetch('events')).to eq([event])
    expect(empty.fetch('events')).to eq([event({})])
    expect(empty_source).not_to include('events:', 'pass:', '{}')
  end

  it 'uses semantic variables and preserves scalars and parameter order exactly' do
    arguments = {
      'Item' => { 'kind' => 'page_parameter', 'name' => 'Item' },
      'Disabled' => false, 'Missing' => nil, 'Empty' => '', 'Expression' => '$Item/Name'
    }
    source, actual = emit(projection([event(arguments)]))
    expect(source).to include('argument "Item", page_variable("Item", kind: :page_parameter)',
                              'argument "Disabled", false', 'argument "Missing", nil')
    expect(source).not_to include('events:', 'pass:', '{')
    expect(actual).to eq(projection([event(arguments)]))
    expect(actual.fetch('events').first.fetch('arguments').keys).to eq(arguments.keys)
  end

  it 'keeps event, child, body and named-region structure independent' do
    child = { 'type' => 'text', 'name' => 'caption', 'caption' => 'Child', 'options' => { 'caption' => 'Child' } }
    widget = projection([event({})]).merge('children' => [child], 'body' => [], 'regions' => { 'aside' => [child] })
    _, actual = emit(widget)
    expect(actual).to eq(widget)
  end

  it 'supports explicit receiver argument blocks in existing native widget builders' do
    builder = Mxrb::Dsl::WidgetBuilder.new(:button, 'open', caption: 'Open')
    builder.on_click(microflow: 'App.Open') do |arguments|
      arguments.argument('Item', arguments.page_variable('Item'))
    end
    expect(builder.to_h.fetch(:events)).to eq([{
      event: :on_click, kind: :microflow, handler: 'App.Open',
      arguments: { 'Item' => { kind: :page_parameter, name: 'Item' } }
    }])
  end

  it 'preserves the established empty-mapping omission in existing native-widget sinks' do
    source = exporter.send(:runtime_widget_dsl_source, [projection([event({})])], 0, generic_sink: true)
    expect(source).not_to include('on_click microflow: "App.Open" do')
    builder = Mxrb::Dsl::WidgetSlotBuilder.new
    builder.instance_eval(source, 'native_sink_projection.rb')
    expect(builder.widgets.first.fetch(:events).first).not_to have_key(:arguments)

    explicit = Mxrb::Dsl::WidgetBuilder.new(:button, 'open')
    explicit.on_click(microflow: 'App.Open') {}
    expect(explicit.to_h.fetch(:events).first.fetch(:arguments)).to eq({})
  end

  it 'retains legacy pass empty/absent behavior and rejects mixed event argument syntax' do
    builder = Mxrb::Dsl::WidgetBuilder.new(:button, 'open')
    builder.on_click(microflow: 'App.Open', pass: {})
    expect(builder.to_h.fetch(:events).first).not_to have_key(:arguments)
    expect { builder.on_click(microflow: 'App.Open', pass: {}) {} }
      .to raise_error(ArgumentError, /either pass:/)
    expect { builder.on_click(microflow: 'App.Open', pass: nil) {} }
      .to raise_error(ArgumentError, /either pass:/)
    expect(builder.to_h.fetch(:events).size).to eq(1)
  end

  it 'rejects duplicate parameters and failed blocks atomically' do
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    expect do
      tree.button('open') do
        on_click(microflow: 'App.Open') do
          argument 'Item', 'one'
          argument :Item, 'two'
        end
      end
    end.to raise_error(ArgumentError, /duplicate widget argument Item/)
    expect(tree.widgets).to eq([])
    expect do
      tree.button('open') do
        on_click(microflow: 'App.Open') do
          argument 'Item', 'one'
          raise 'interrupted'
        end
      end
    end.to raise_error('interrupted')
    expect(tree.widgets).to eq([])
  end

  it 'rejects events at the page root and mixtures with explicit legacy events arrays' do
    tree = Mxrb::RubyApp::Page::WidgetTree.new
    expect { tree.on_click(microflow: 'App.Open') }.to raise_error(ArgumentError, /belong to a widget/)
    expect do
      tree.button('open', events: []) { on_click(microflow: 'App.Open') }
    end.to raise_error(ArgumentError, /either events:/)
    expect(tree.widgets).to eq([])
  end

  it 'snapshots argument values and handlers without exposing installed mutable collections' do
    value = [+'before']
    handler = +'App.Open'
    captured = nil
    builder = Mxrb::Dsl::WidgetBuilder.new(:button, 'open')
    builder.on_click(microflow: handler) do |arguments|
      captured = arguments
      arguments.argument('Item', value)
    end
    value.first.replace('after')
    handler.replace('App.Changed')
    captured.argument('Later', true)
    expect(builder.to_h.fetch(:events).first).to eq(
      event: :on_click, kind: :microflow, handler: 'App.Open', arguments: { 'Item' => ['before'] }
    )
    expect { captured.arguments['Item'] << 'mutation' }.to raise_error(FrozenError)
  end

  it 'rolls back reusable argument collection blocks and rejects non-serializable objects' do
    arguments = Mxrb::Dsl::WidgetEventArguments.new
    arguments.argument('Existing', nil)
    expect do
      arguments.evaluate do
        argument 'Partial', false
        argument 'Unsupported', Object.new
      end
    end.to raise_error(TypeError, /serializable/)
    expect(arguments.arguments).to eq('Existing' => nil)
  end

  it 'retains unknown event shapes and non-equivalent variable properties in the legacy projection' do
    unknown = event({}).merge('future_setting' => false)
    source, actual = emit(projection([unknown]))
    expect(source).to include('events:', '"future_setting" => false')
    expect(actual).to eq(projection([unknown]))
    arguments = { 'Item' => { 'kind' => 'page_parameter', 'name' => 'Item', 'use_all_pages' => false } }
    source, actual = emit(projection([event(arguments)]))
    expect(source).not_to include('page_variable(')
    expect(actual).to eq(projection([event(arguments)]))
  end

  it 'never installs or changes a native page declaration when configure declares events' do
    source, = emit(projection([event({})]))
    klass = Class.new(Mxrb::RubyApp::Page)
    klass.mendix_name('App.Detail')
    klass.configure(title: 'Detail') { instance_eval(source) }
    expect(klass.native_definition).to be_nil
    klass.native { title 'Native definition' }
    original = klass.native_definition
    klass.configure(title: 'Runtime title') { instance_eval(source) }
    expect(klass.native_definition).to equal(original)
    expect(klass.native_definition.fetch(:title)).to eq('Native definition')
  ensure
    Mxrb::RubyApp::Registry.reset!
  end
end
# rubocop:enable Metrics/BlockLength
