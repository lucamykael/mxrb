# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Mxrb::Caption do
  it 'copies and deeply freezes structured parameters and translations' do
    attribute = +'App.Item.Amount'
    pattern = +'yyyy-MM-dd'
    value = described_class.parameter(
      'attribute' => attribute,
      'source' => { 'kind' => 'page_parameter', 'name' => 'App.Home.Owner', 'sub_key' => '', 'use_all_pages' => true },
      'format' => { 'decimal_precision' => 3, 'group_digits' => true, 'date_format' => 'Custom',
                    'custom_date_format' => pattern, 'enum_format' => 'Text' }
    )
    attribute.replace('changed')
    pattern.replace('changed')
    expect(value[:attribute]).to eq('App.Item.Amount')
    expect(value.dig(:format, :custom_date_format)).to eq('yyyy-MM-dd')
    expect { value[:source][:name].replace('changed') }.to raise_error(FrozenError)
    expect { value[:format][:decimal_precision] = 8 }.to raise_error(FrozenError)
  end
end

RSpec.describe Mxrb::Caption do
  it 'retains translations and optional parameter settings immutably' do
    text = +'Valor {1}'
    translations = described_class.translations(pt_BR: text)
    text.clear
    expect(translations).to eq('pt_BR' => 'Valor {1}')
    expect(translations.values.first).to be_frozen
    expect(described_class.parameter(expression: "'literal'", source: { kind: :current })).to eq(
      expression: "'literal'", source: { kind: 'current' }
    )
    expect(described_class.format(group_digits: false, decimal_precision: 0)).to eq(
      group_digits: false, decimal_precision: 0
    )
    expect(described_class.source(kind: :widget, name: 'Chart', use_all_pages: false)).to include(use_all_pages: false)
  end
end

RSpec.describe Mxrb::Caption do
  it 'rejects malformed or unknown metadata instead of silently dropping it' do
    [nil, 1, {}, { expression: 'x', attribute: 'y' }, { attribute: 1 }, { expression: 'x', extra: true },
     { 'expression' => 'x', expression: 'y' }, { attribute: 'A', source: [] },
     { attribute: 'A', source: { kind: :missing } }, { attribute: 'A', source: { kind: :current, use_all_pages: 1 } },
     { attribute: 'A', source: { kind: :current, name: nil } }, { attribute: 'A', format: [] },
     { attribute: 'A', format: { unknown_native: true } }, { attribute: 'A', format: { decimal_precision: -1 } },
     { attribute: 'A', format: { decimal_precision: 101 } }, { attribute: 'A', format: { decimal_precision: 1.5 } },
     { attribute: 'A', format: { group_digits: 1 } }, { attribute: 'A', format: { date_format: 'Unknown' } },
     { attribute: 'A', format: { date_format: nil } }].each do |value|
      expect { described_class.parameter(value) }.to raise_error(ArgumentError)
    end
    [nil, [1], [['pt_BR']]].each do |value|
      expect { described_class.translations(value) }.to raise_error(ArgumentError)
    end
    expect { described_class.translations('en_US' => nil) }.to raise_error(ArgumentError)
  end
end

module CaptionSpecSamples
  def self.template
    parameters = [
      { attribute: 'App.Item.Amount', source: { kind: :page_parameter, name: 'App.Home.Owner' },
        format: { decimal_precision: 3, group_digits: true } },
      { expression: "'ready'", format: { date_format: 'Time' } }
    ]
    Mxrb::Writer.allocate.send(
      :client_template_doc, 'Amount {1}', parameters:,
                                          translations: { 'pt_BR' => 'Valor {1}' }, fallback: 'No owner'
    )
  end
end

RSpec.describe Mxrb::Caption do
  it 'roundtrips native format, source variables, translations and fallback text' do
    template = CaptionSpecSamples.template
    parameters = Mxrb::IO::BsonCodec.parse_array(template['Parameters']).fetch(:items)
    expect(parameters.first.dig('FormattingInfo', 'DecimalPrecision')).to eq(3)
    expect(parameters.first.dig('SourceVariable', 'PageParameter')).to eq('App.Home.Owner')
    projected = Mxrb::Model::Page.allocate.send(:pluggable_template, template)
    expect(projected).to eq(
      text: 'Amount {1}', translations: { 'pt_BR' => 'Valor {1}' }, fallback: 'No owner', parameters: [
        { attribute: 'App.Item.Amount', source: { kind: :page_parameter, name: 'App.Home.Owner' },
          format: { decimal_precision: 3, group_digits: true } },
        { expression: "'ready'", format: { date_format: 'Time' } }
      ]
    )
    rebuilt = Mxrb::Writer.allocate.send(:client_template_doc, projected.fetch(:text), **projected.except(:text))
    expect(Mxrb::Model::Page.allocate.send(:pluggable_template, rebuilt)).to eq(projected)
  end
end

RSpec.describe Mxrb::Caption do
  it 'keeps unknown native formatting visible for a lossless fallback' do
    template = CaptionSpecSamples.template
    parameters = Mxrb::IO::BsonCodec.parse_array(template['Parameters']).fetch(:items)
    parameters.first['FormattingInfo']['FutureFormat'] = 'retain me'
    parameter = Mxrb::Model::Page.allocate.send(:pluggable_template, template).fetch(:parameters).first
    expect(parameter.dig(:format, :unknown_native)).to eq('FutureFormat' => 'retain me')
    expect { described_class.parameter(parameter) }.to raise_error(ArgumentError)
  end
end

RSpec.describe Mxrb::Caption do
  it 'reads native parameters without optional formatting metadata' do
    template = CaptionSpecSamples.template
    parameters = Mxrb::IO::BsonCodec.parse_array(template['Parameters']).fetch(:items)
    parameters.first.delete('FormattingInfo')
    projected = Mxrb::Model::Page.allocate.send(:pluggable_template, template)
    expect(projected.fetch(:parameters).first).to eq(
      attribute: 'App.Item.Amount', source: { kind: :page_parameter, name: 'App.Home.Owner' }
    )
  end
end
