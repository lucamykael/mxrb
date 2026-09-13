# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/storage_naming'

RSpec.describe Mxrb::Forms::StorageNaming do # rubocop:disable Metrics/BlockLength
  subject(:catalog) { Mxrb::Forms::Catalog.for('11.12.1') }

  it 'maps ordinary schema properties by the Mendix storage convention' do
    property = catalog.fetch_type(:action_button).fetch_property(:button_style)
    mapping = described_class.resolve(property)

    expect(mapping).to be_a(Mxrb::Forms::StorageProperty)
    expect(mapping.name).to eq('ButtonStyle')
    expect(mapping.evidence).to eq(:schema_convention)
  end

  it 'writes current names while retaining explicit physical aliases' do
    caption = described_class.resolve(catalog.fetch_type(:action_button).fetch_property(:caption))
    editability = described_class.resolve(catalog.fetch_type(:data_view).fetch_property(:editability))
    snippet = described_class.resolve(catalog.fetch_type(:snippet_call_widget).fetch_property(:snippet_call))
    columns = described_class.resolve(catalog.fetch_type(:table).fetch_property(:columns))
    column_width = described_class.resolve(catalog.fetch_type(:table_column).fetch_property(:width))
    group_caption = described_class.resolve(catalog.fetch_type(:group_box).fetch_property(:caption))
    add_page = described_class.resolve(catalog.fetch_type(:data_grid_add_button).fetch_property(:page_settings))
    specialization = described_class.resolve(catalog.fetch_type(:list_view_template).fetch_property(:specialization))

    expect(caption.name).to eq('CaptionTemplate')
    expect(editability.name).to eq('Editability')
    expect(snippet.name).to eq('FormCall')
    expect(columns.name).to eq('ColumnWidths')
    expect(column_width.name).to eq('Value')
    expect(group_caption.name).to eq('CaptionTemplate')
    expect(add_page.name).to eq('FormSettings')
    expect(specialization.name).to eq('Entity')
    expect([caption, snippet, columns, column_width, group_caption, add_page, specialization]).to all(be_observed)
    expect(editability.evidence).to eq(:schema_convention)
  end

  it 'produces a typed physical name for all concrete widget properties' do
    mappings = catalog.concrete_widgets.flat_map do |widget|
      widget.all_properties.map { described_class.resolve(_1) }
    end

    expect(mappings.size).to eq(455)
    expect(mappings).to all(be_a(Mxrb::Forms::StorageProperty))
    expect(mappings.map(&:name)).to all(match(/\A[A-Z]/))
  end

  it 'maps renamed element types in both directions' do
    expect(described_class.schema_type_name('NoAction')).to eq('NoClientAction')
    expect(described_class.storage_type_name('NoClientAction')).to eq('NoAction')
    expect(described_class.schema_type_name('TabControl')).to eq('TabContainer')
    expect(described_class.storage_type_name('DynamicImageViewer')).to eq('ImageViewer')
    expect(described_class.schema_type_name('MobileDropDownButton')).to eq('DropDownButton')
    expect(described_class.storage_type_name('DropDownButton')).to eq('MobileDropDownButton')
    expect(described_class.schema_type_name('DbTableCell')).to eq('TableCell')
    expect(described_class.storage_type_name('TableCell')).to eq('DbTableCell')
    expect(described_class.schema_type_name('FormForSpecialization')).to eq('PageForSpecialization')
    expect(described_class.storage_type_name('PageForSpecialization')).to eq('PageForSpecialization')
  end

  it 'accepts both observed legacy aliases and modern schema-convention names' do
    property = catalog.fetch_type(:data_view).fetch_property(:editability)

    expect(described_class.candidates(property)).to eq(%w[Editability Editable])
  end
end
