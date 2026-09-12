# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/mpr_codec'

RSpec.describe 'Forms selection listeners' do # rubocop:disable Metrics/BlockLength
  let(:widget_id) { 'com.example.SelectableGrid' }

  before do
    Mxrb::Pluggable.widget_type(widget_id) do
      properties do
        property 'selection', :selection
      end
    end
  end

  it 'preserves selectable sibling grids and their listeners through editable Ruby' do
    grid = Mxrb::Pluggable.widget(widget_id) do
      identifier 'orders_grid'
      properties { selection 'Single' }
    end
    view = Mxrb::Forms.data_view do
      name 'order_details'
      data_source :listen_target_source do
        listen_target 'orders_grid'
      end
    end
    root = Mxrb::Forms.data_view
    root.set(:widgets, [grid, view])
    codec = Mxrb::Forms::MprCodec.new
    original = codec.encode(root)

    # The source fixture must retain Single independently of the encoder under
    # test: a broken encoder must not make both halves of this regression agree.
    original.dig('Widgets', 1, 'Object', 'Properties', 1, 'Value')['Selection'] = 'Single'
    source = Mxrb::Forms::SourceEmitter.new.emit(codec.decode(original))
    restored = eval(source) # rubocop:disable Security/Eval
    rebuilt = codec.encode(restored, baseline: original)
    rebuilt_grid, rebuilt_view = rebuilt.fetch('Widgets').drop(1)

    expect(rebuilt_grid.dig('Object', 'Properties', 1, 'Value', 'Selection')).to eq('Single')
    expect(rebuilt_view.dig('DataSource', 'ListenTarget')).to eq(rebuilt_grid.fetch('Name'))
    expect(rebuilt_view.fetch('Name')).to eq('order_details')
    expect(source).to include('selection "Single"', 'listen_target "orders_grid"')
  end
end
