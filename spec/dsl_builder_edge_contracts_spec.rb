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
end
# rubocop:enable Metrics/BlockLength
