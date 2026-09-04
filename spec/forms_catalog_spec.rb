# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/catalog'

RSpec.describe Mxrb::Forms::Catalog do # rubocop:disable Metrics/BlockLength
  subject(:catalog) { described_class.for('11.12.1') }

  it 'exposes the exact Studio 11.12.1 inventory as immutable Ruby values' do
    expect(catalog.version).to eq('11.12.1')
    expect(catalog.types.size).to eq(235)
    expect(catalog.enum_types.size).to eq(52)
    expect(catalog.widgets.size).to eq(57)
    expect(catalog.concrete_widgets.size).to eq(41)
    expect(catalog.property_occurrences).to eq(455)
    expect(catalog).to be_frozen
    expect(catalog.types).to be_frozen
  end


  it 'includes the canonical Projects.Document base inherited by forms' do
    page = catalog.fetch_type(:page)

    expect(page.fetch_property(:name).declared_by).to eq('Projects.Document')
    expect(page.fetch_property(:documentation).type_name).to eq('string')
    expect(page.fetch_property(:excluded).type_name).to eq('boolean')
    expect(page.fetch_property(:export_level).type_name).to eq('ExportLevel')
  end

  it 'resolves Mendix and idiomatic Ruby names without returning transport hashes' do
    action_button = catalog.fetch_type(:action_button)
    caption = action_button.fetch_property(:caption)

    expect(action_button).to be_a(Mxrb::Forms::Type)
    expect(action_button.name).to eq('ActionButton')
    expect(action_button).to be_widget.and be_concrete
    expect(action_button.base_name).to eq('Button')
    expect(caption).to be_a(Mxrb::Forms::Property)
    expect(caption.type_name).to eq('ClientTemplate')
    expect(caption.declared_by).to eq('Button')
    expect(caption).to be_one.and be_required.and be_default
    expect(caption.default_value).to eq(Mxrb::Forms::DefaultValue.new(:factory, 'ClientTemplate'))
    expect(action_button.all_properties).not_to include(a_kind_of(Hash))
  end

  it 'models inheritance and cardinality explicitly' do
    data_view = catalog.fetch_type('DataView')
    widgets = data_view.fetch_property(:widgets)

    expect(catalog.descendant?(:data_view, :widget)).to be(true)
    expect(widgets.type_name).to eq('Widget')
    expect(widgets).to be_many
  end

  it 'fails clearly for unsupported schema versions and unknown members' do
    expect { described_class.for('11.99.0') }.to raise_error(ArgumentError, /available: 11\.12\.1/)
    expect { catalog.fetch_type(:missing) }.to raise_error(KeyError, /unknown Forms type/)
    expect { catalog.fetch_type(:action_button).fetch_property(:missing) }
      .to raise_error(KeyError, /unknown ActionButton property/)
  end
end
