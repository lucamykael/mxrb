# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/forms/node'

RSpec.describe Mxrb::Forms::Node do # rubocop:disable Metrics/BlockLength
  subject(:catalog) { Mxrb::Forms::Catalog.for('11.12.1') }

  it 'builds an idiomatic, schema-checked widget tree without public hashes' do
    button = described_class.build(:action_button, catalog:) do
      name 'save'
      button_style :primary
      caption do
        template 'Save'
      end
    end

    expect(button.schema_type.name).to eq('ActionButton')
    expect(button.name).to eq('save')
    expect(button.button_style).to be_a(Mxrb::Forms::EnumValue)
    expect(button.button_style.to_sym).to eq(:primary)
    expect(button.caption).to be_a(described_class)
    expect(button.caption.template).to be_a(Mxrb::Forms::Text)
    expect(button.caption.template.to_s).to eq('Save')
    expect(button.assignments).to all(be_a(Mxrb::Forms::Assignment))
    expect(button).not_to respond_to(:to_h)
  end

  it 'builds heterogeneous widget collections through declared inheritance' do
    data_view = described_class.build(:data_view, catalog:) do
      widgets(:text_box) { name 'customer_name' }
      widgets(:action_button) { name 'save' }
    end

    expect(data_view.widgets.map { _1.schema_type.name }).to eq(%w[TextBox ActionButton])
  end

  it 'normalizes references and external semantic values' do
    page = described_class.build(:page, catalog:) do
      parameter 'MyModule.PageParameter'
      title 'Welcome'
      url '/home'
    end

    expect(page.parameter).to eq(Mxrb::Forms::Reference.to('MyModule.PageParameter'))
    expect(page.title).to be_a(Mxrb::Forms::Text)
    expect(page.title.to_s).to eq('Welcome')
  end

  it 'rejects invalid properties, values, cardinalities, and concrete types' do
    button = described_class.new(:action_button, catalog:)
    expect { button.set(:missing, true) }.to raise_error(KeyError)
    expect { button.tab_index('zero') }.to raise_error(TypeError, /expects integer/)
    expect { button.button_style(:not_a_style) }.to raise_error(ArgumentError, /invalid ButtonStyle/)
    expect { button.set(:name, %w[a b]) }.to raise_error(TypeError, /expects string/)
    expect { described_class.new(:button_style, catalog:) }.to raise_error(ArgumentError, /enum/)
  end
end
