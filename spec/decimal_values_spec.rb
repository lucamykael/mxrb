# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Mxrb::Runtime::DecimalValues do
  it 'uses lossless canonical decimal strings for JSON values' do
    %w[0 -0 0.00].each { expect(described_class.text(_1)).to eq('0') }
    expect(described_class.text('100.00')).to eq('100')
    expect(described_class.text('9007199254740993.12345678')).to eq('9007199254740993.12345678')
    tag = described_class.encode(BigDecimal('0.100'))
    expect(described_class.tagged?(tag)).to be(true)
    expect(described_class.parse(JSON.parse(JSON.generate(tag)).fetch('__mxrb_decimal'))).to eq(BigDecimal('0.1'))
    expect(described_class.tagged?('__mxrb_decimal' => '1', 'extra' => true)).to be(false)
    expect(described_class.tagged?('1')).to be(false)
    %w[NaN Infinity nope].each { expect { described_class.parse(_1) }.to raise_error(ArgumentError) }
  end
end

RSpec.describe Mxrb::Runtime::DecimalContext do
  it 'rounds division once at the configured significant digit and preserves exact later arithmetic' do
    context = described_class.new
    result = context.divide(3, 7)
    expect(result.to_s('F')).to eq('0.42857142857142857142857142857142857143')
    expect((result * 7).ceil).to eq(4)
    expect(context.divide(0, 3)).to eq(0)
    expect(context.divide(10, 2)).to eq(5)
    expect { context.divide(1, 0) }.to raise_error(ArgumentError)
    even = described_class.new(precision: 2, rounding: 'HalfEven')
    expect(even.divide(1, 8)).to eq(BigDecimal('0.12'))
    expect(even.divide(-27, 200)).to eq(BigDecimal('-0.14'))
    expect(described_class.new(precision: 2).divide(1, 8)).to eq(BigDecimal('0.13'))
    expect(context.divide(1, 10**50)).to eq(BigDecimal('1e-50'))
    expect(context.divide(10**50, 1)).to eq(BigDecimal('1e50'))
  end
end

RSpec.describe Mxrb::Runtime::DecimalContext do
  it 'applies project rounding and storage scale including boundary carry' do
    context = described_class.new
    expect(context.round('-2.5')).to eq(-3)
    expect(context.round('88.725', 2)).to eq(BigDecimal('88.73'))
    expect(context.round('1250', -2)).to eq(BigDecimal('1300'))
    expect { context.round('1', 1.5) }.to raise_error(ArgumentError)
    expect(context.persist('0.123456785')).to eq(BigDecimal('0.12345679'))
    expect(context.persist(10**20)).to eq(10**20)
    expect { context.persist('100000000000000000000.00000001') }.to raise_error(ArgumentError)
    even = described_class.new(scale: 2, rounding: 'HalfEven')
    expect(even.round('88.725', 2)).to eq(BigDecimal('88.72'))
    expect(even.persist('1.005')).to eq(1)
  end
end

RSpec.describe Mxrb::Runtime::DecimalContext do
  it 'reads both modern model parts and legacy project settings' do
    project = Struct.new(:all_units) { def parse_bson(value) = value }.new([])
    expect(described_class.settings(project)).to eq({})
    expect(described_class.settings(Object.new)).to eq({})
    root = { '$Type' => 'Settings$ProjectSettings', 'RoundingMode' => 'HalfEven' }
    project.all_units << root
    expect(described_class.settings(project)).to eq('scale' => 8, 'rounding' => 'HalfEven')
    root['Settings'] = [2, { '$Type' => 'Settings$ModelSettings', 'DecimalScale' => 12 }]
    expect(described_class.settings(project)).to eq('scale' => 12, 'rounding' => 'HalfUp')
    runtime = Struct.new(:decimal_settings).new({ 'scale' => 4 })
    expect(described_class.settings(runtime)).to eq('scale' => 4)
  end
end

RSpec.describe Mxrb::Runtime::Native::Expression do
  it 'keeps decimal literals, division, parsing, rounding and string output exact' do
    expression = described_class.new
    {
      'toString(0.1 + 0.2)' => '0.3',
      'toString(9007199254740993.00000001 + 0.00000001)' => '9007199254740993.00000002',
      'floor(-1.2)' => -2, 'ceil(-1.2)' => -1, 'abs(-1.2)' => BigDecimal('1.2'),
      "parseDecimal('no', empty)" => nil, "parseDecimal('no', 1.25)" => BigDecimal('1.25'),
      'round(88.725, 2)' => BigDecimal('88.73'), '12.5 mod 2' => BigDecimal('0.5')
    }.each { |source, expected| expect(expression.evaluate(source, {})).to eq(expected) }
    ["parseDecimal('NaN')", 'parseDecimal()', "parseDecimal('1', '#.0')", 'parseDecimal(1, 2, 3)'].each do |source|
      expect { expression.evaluate(source, {}) }.to raise_error(Mxrb::NativeRuntimeError)
    end
  end
end
