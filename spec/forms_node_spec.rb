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

  it 'copies text values without freezing or retaining mutable caller input' do
    language = +'pt_BR'
    caption = +'Salvar'
    translations = [Mxrb::Forms::Translation.new(language, caption)]
    text = Mxrb::Forms::Text.coerce(translations)
    page = described_class.build(:page, catalog:) { title text }

    language.replace('en_US')
    caption.replace('Save')
    translations.clear

    expect(page.title.to_s).to eq('Salvar')
    expect(page.title.translations.first.language).to eq('pt_BR')
    expect(page.title.translations).to be_frozen
    expect(page.title.translations.first.text).to be_frozen
  end

  it 'supports assignment inspection, replacement, removal, and explicit receivers' do
    button = described_class.build(:action_button, catalog:) { |node| node.name('save') }
    expect(button).to be_assigned(:name)
    expect(button.inspect).to include('ActionButton', 'name="save"')
    expect(button.set(:name, 'replace').fetch(:name)).to eq('replace')
    expect(button.unset(:name)).to equal(button)
    expect(button).not_to be_assigned(:name)
  end

  it 'rejects invalid dynamic calls, collection shapes, nils, and nested node families' do
    button = described_class.new(:action_button, catalog:)
    expect { button.append(:name, 'invalid') }.to raise_error(ArgumentError, /not a collection/)
    expect { button.missing_property }.to raise_error(NoMethodError)
    expect { button.caption(:client_template, :extra) {} }
      .to raise_error(ArgumentError, /at most one type/)
    expect { button.name }.not_to raise_error
    expect { button.name('one', 'two') }.to raise_error(ArgumentError, /exactly one value/)
    expect { button.set(:name, nil) }.to raise_error(TypeError, /cannot be nil/)

    data_view = described_class.new(:data_view, catalog:)
    expect { data_view.set(:widgets, 'not an array') }.to raise_error(TypeError, /requires an Array/)
    wrong_nested = described_class.new(:text_box, catalog:)
    expect { button.set(:caption, wrong_nested) }.to raise_error(TypeError, /expects ClientTemplate/)
    expect { button.set(:caption, Object.new) }.to raise_error(TypeError, /expects ClientTemplate/)
    page = described_class.new(:page, catalog:)
    expect { page.set(:title, Object.new) }.to raise_error(TypeError, /expects Text/)
  end

  it 'rejects an unknown scalar type even when supplied through a valid schema property' do
    property = Mxrb::Forms::Property.new(
      'Future', 'future', 'FutureWidget', 'future_scalar', [].freeze,
      :one, false, nil, nil
    )
    type = Mxrb::Forms::Type.new(
      'FutureWidget', 'future_widget', :element, false, nil,
      [property].freeze, [property].freeze, [].freeze, true
    )
    fake_catalog = Object.new
    fake_catalog.define_singleton_method(:fetch_type) { |_identifier| type }
    fake_catalog.define_singleton_method(:type) { |_identifier| nil }

    expect { described_class.new(:future_widget, catalog: fake_catalog).set(:future, 'value') }
      .to raise_error(TypeError, /expects future_scalar/)
  end
end
