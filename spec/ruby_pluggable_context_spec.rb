# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::PluggableContext do
  let(:bridge) { Mxrb::RubyApp::PluggableProperties }
  let(:widget_id) { 'com.example.Revision' }

  def widget(kind, name: 'example')
    catalog = Mxrb::Pluggable::Catalog.new
    schema = Mxrb::Pluggable.widget_type(widget_id, catalog:) do
      properties { property :value, kind }
    end
    node = Mxrb::Pluggable::Node.new(schema, catalog:)
    forms_codec = Mxrb::Forms::MprCodec.new(pluggable_catalog: catalog)
    Mxrb::Pluggable::MprCodec.new(forms_codec:, catalog:).encode(node).merge('Name' => name)
  end

  def mpr_for(documents)
    double('private baseline').tap do |mpr|
      allow(mpr).to receive(:unit) { |id| id if documents.key?(id) }
      allow(mpr).to receive(:parse_contents) { |id| documents.fetch(id) }
    end
  end

  def page(*widgets)
    { '$Type' => 'Forms$Page', 'Widgets' => widgets }
  end

  def resolve(value, name: 'example')
    bridge.for_widget(name, widget_id:).tap { _1.set(:value, value) }.to_projection
  end

  it 'loads nested Forms pluggable widgets with document-local schemas and restores the catalog' do
    original = Mxrb::Pluggable::Catalog.default
    bridge.with_mpr(nil) do
      context = described_class.current
      context.with_document('Outer', page(widget(:boolean))) do
        outer = Mxrb::Pluggable::Catalog.default
        node = Mxrb::Forms::Node.build(:div_container) do
          widgets('com.example.Revision') do
            identifier 'nested'
            properties { value false }
          end
        end
        expect(node).to be_a(Mxrb::Forms::Node)
        expect do
          context.with_document('Inner', page(widget(:string))) do
            nested = Mxrb::Pluggable::Node.build(widget_id)
            expect { nested.properties { value 'text' } }.not_to raise_error
            raise 'restore catalog'
          end
        end.to raise_error('restore catalog')
        expect(Mxrb::Pluggable::Catalog.default).to equal(outer)
      end
    end
    expect(Mxrb::Pluggable::Catalog.default).to equal(original)
  end

  it 'resolves the exact page and widget revision, never the package union' do
    mpr = mpr_for('one' => page(widget(:boolean), widget(:integer, name: 'second')),
                  'two' => page(widget(:string)))
    bridge.with_mpr(mpr) do
      bridge.with_page('one') do
        expect(resolve(false)).to eq('value' => false)
        expect(resolve(7, name: 'second')).to eq('value' => 7)
        expect { resolve(7) }.to raise_error(TypeError)
        bridge.with_page('two') { expect(resolve('text')).to eq('value' => 'text') }
        expect(resolve(true)).to eq('value' => true)
      end
    end
    expect(described_class.current).to be_nil
  end

  it 'leaves borrowed document schemas mutable when loading nested Forms widgets' do
    document = Marshal.load(Marshal.dump(page(widget(:boolean))))
    original = Marshal.dump(document)
    bridge.with_mpr(nil) do
      described_class.current.with_document('App.Shared', document) do
        expect(resolve(false)).to eq('value' => false)
        expect(Mxrb::Pluggable::Node.build(widget_id)).to be_a(Mxrb::Pluggable::Node)
      end
    end
    expect(document.dig('Widgets', 0, 'Type', 'WidgetId')).not_to be_frozen
    expect(Marshal.dump(document)).to eq(original)
  end

  it 'rejects ambiguous identity during loading and retains legacy emission' do
    mpr = mpr_for('one' => page(widget(:boolean), widget(:boolean)))
    bridge.with_mpr(mpr) do
      bridge.with_page('one') do
        expect { resolve(false) }.to raise_error(Mxrb::ValidationError, /ambiguous/)
        expect(bridge.try_for_widget('example', widget_id:, properties: { 'value' => false })).to be_nil
      end
    end
  end

  it 'rejects absent and wrong-family baselines without guessing another page' do
    mpr = mpr_for('wrong' => { '$Type' => 'Microflows$Microflow' }, 'one' => page(widget(:boolean)))
    bridge.with_mpr(mpr) do
      expect { resolve(false) }.to raise_error(Mxrb::ValidationError, /page identity/)
      bridge.with_page('missing') { expect { resolve(false) }.to raise_error(Mxrb::ValidationError, /unavailable/) }
      bridge.with_page('wrong') { expect { resolve(false) }.to raise_error(Mxrb::ValidationError, /not a page/) }
      bridge.with_page('one') do
        expect { resolve(false, name: 'missing') }.to raise_error(Mxrb::ValidationError, /missing or ambiguous/)
      end
    end
  end

  it 'restores nested application and page contexts after errors without closing borrowed handles' do
    first = mpr_for('one' => page(widget(:boolean)))
    second = mpr_for('one' => page(widget(:integer)))
    expect(first).not_to receive(:close)
    expect(second).not_to receive(:close)
    bridge.with_mpr(first) do
      outer = described_class.current
      bridge.with_page('one') do
        expect do
          bridge.with_mpr(second) do
            bridge.with_page('one') do
              expect(resolve(7)).to eq('value' => 7)
              raise 'deliberate failure'
            end
          end
        end.to raise_error('deliberate failure')
        expect(described_class.current).to equal(outer)
        expect(resolve(false)).to eq('value' => false)
        expect { bridge.with_page('missing') { raise 'page failure' } }.to raise_error('page failure')
        expect(resolve(true)).to eq('value' => true)
      end
    end
    expect(described_class.current).to be_nil
  end

  it 'does not freeze or mutate the borrowed schema document or identity inputs' do
    document = Marshal.load(Marshal.dump(page(widget(:boolean))))
    before = Marshal.dump(document)
    package = document.dig('Widgets', 0, 'Type', 'WidgetId')
    id = +'one'
    name = +'example'
    bridge.with_mpr(mpr_for('one' => document)) do
      bridge.with_page(id) do
        id.replace('different')
        expect(resolve(false, name:)).to eq('value' => false)
        name.replace('changed')
        expect(resolve(true)).to eq('value' => true)
      end
    end
    expect(package).not_to be_frozen
    expect(Marshal.dump(document)).to eq(before)
  end

  it 'opens only the private runtime baseline read-only and closes owned handles after failure' do
    Dir.mktmpdir('mxrb-pluggable-context-') do |directory|
      path = File.join(directory, 'Private.mpr')
      native = widget(:boolean)
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:Example) do
          page(:Home) { native_widget 'example', type: 'CustomWidgets$CustomWidget', deep_structure: native }
        end
      end
      before = File.binread(path)
      manifest = Mxrb::RubyApp::Manifest.new(directory, 'mode' => 'ruby',
                                                        'round_trip' => { 'runtime_mpr' => 'Private.mpr' })
      handles = []
      allow(Mxrb::IO::MprFile).to receive(:open).with(path, readonly: true).and_wrap_original do |original, *args, **kw|
        original.call(*args, **kw).tap { handles << _1 }
      end
      expect do
        bridge.with(manifest) do
          mpr = described_class.current.send(:mpr)
          unit = mpr.all_units.find { mpr.parse_contents(_1)['$Type'] == 'Forms$Page' }
          bridge.with_page(unit.fetch('UnitID')) do
            expect(resolve(false)).to eq('value' => false)
            raise 'deliberate failure'
          end
        end
      end.to raise_error('deliberate failure')
      expect(handles.size).to eq(1)
      expect { handles.first.all_units }.to raise_error(ArgumentError, /closed database/)
      expect(File.binread(path)).to eq(before)
      expect(described_class.current).to be_nil
    end
  end

  it 'does not require a baseline for applications without typed properties' do
    manifest = double('legacy manifest')
    expect(manifest).not_to receive(:absolute_path)
    bridge.with(manifest) { bridge.with_page(nil) { expect(described_class.current).to be_a(described_class) } }
  end

  it 'loads exact page and shared-resource schemas without an MPR, and refuses missing snapshots' do
    Dir.mktmpdir do |directory|
      bridge.with_mpr(mpr_for('one' => page(widget(:boolean)))) do |context|
        bridge.with_page('one') { expect(resolve(false)).to eq('value' => false) }
        context.with_document('App.Layout', page(widget(:string))) do
          expect(resolve('shared')).to eq('value' => 'shared')
        end
        context.export_schemas(directory)
      end
      manifest = Mxrb::RubyApp::Manifest.new(directory, 'mode' => 'ruby', 'runtime_model' => 'ruby')
      expect(Mxrb::IO::MprFile).not_to receive(:open)
      bridge.with(manifest) do
        bridge.with_page('one') do
          expect(resolve(true)).to eq('value' => true)
          expect { resolve('wrong revision') }.to raise_error(TypeError)
        end
        bridge.with_page('App.Layout') { expect(resolve('edited')).to eq('value' => 'edited') }
        bridge.with_page('missing') do
          expect { resolve(false) }.to raise_error(Mxrb::ValidationError, /snapshot is unavailable/)
        end
      end
    end
  end

  it 'restores the prior thread context when context construction itself fails' do
    previous = Object.new
    Thread.current[described_class::THREAD_KEY] = previous
    allow(described_class).to receive(:new).and_raise(ArgumentError, 'invalid context')

    expect { described_class.with {} }.to raise_error(ArgumentError, 'invalid context')
    expect(described_class.current).to equal(previous)
  ensure
    Thread.current[described_class::THREAD_KEY] = nil
  end

  it 'normalizes invalid runtime paths and unsupported embedded schemas' do
    manifest = double('invalid manifest', data: {})
    allow(manifest).to receive(:absolute_path).and_raise(KeyError, 'missing')
    context = described_class.new(manifest:)
    context.with_page('one') do
      expect { context.for_widget('example', widget_id:) }
        .to raise_error(Mxrb::ValidationError, /path is unavailable or invalid/)
    end

    context = described_class.new(mpr: mpr_for('one' => page(widget(:boolean))))
    allow(context).to receive(:widget_type).and_return({})
    context.with_page('one') do
      expect { context.for_widget('example', widget_id:) }
        .to raise_error(Mxrb::ValidationError, /schema is unsupported/)
    end
  end
end
# rubocop:enable Metrics/BlockLength
