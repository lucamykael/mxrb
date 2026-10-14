# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Decimal pattern parsing and Long precision edges' do
  it 'reads quoted pattern literals, a missing whole part and negative exponents' do
    parsing = Mxrb::Runtime::DecimalParsing
    expect(parsing.parse('#5', "'#'0")).to eq(5)
    expect(parsing.parse("5'", "0''")).to eq(5)
    expect(parsing.parse('1;', "0';'")).to eq(1)
    expect(parsing.parse('.5', '0.0')).to eq(BigDecimal('0.5'))
    expect(parsing.parse('1.5E-3', '0.###E0')).to eq(BigDecimal('0.0015'))
  end

  it 'keeps integers beyond 2**53 - 1 exact through the browser transport and storage' do
    application = Mxrb::RubyApp::Application.allocate
    long = (2**53) + 1
    expect(application.send(:serialize, { 'Count' => long, 'Small' => 7 })).to eq(
      'Count' => { '__mxrb_decimal' => '9007199254740993' }, 'Small' => 7
    )
    expect(application.send(:deserialize, '__mxrb_decimal' => '9007199254740993')).to eq(long)
    expect(application.send(:deserialize, '__mxrb_decimal' => '9007199254740993.0')).to eq(BigDecimal(long))
    expect(application.send(:deserialize, '__mxrb_decimal' => '12')).to eq(BigDecimal(12))

    store = Mxrb::Runtime::SQLiteStore.allocate
    expect(store.send(:serialize, BigDecimal(long), :long)).to eq(long)
    expect(store.send(:serialize, long, :long)).to eq(long)
  end
end
