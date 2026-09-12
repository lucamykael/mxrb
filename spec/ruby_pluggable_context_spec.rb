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
end
# rubocop:enable Metrics/BlockLength
