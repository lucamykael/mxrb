# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Runs the decimal parsing oracle fixture in the Ruby interpreter. The expected values
# were logged by the Mendix 11.12.1 Runtime (docs/evidence/decimal-edges-2026-10-14.json).
# rubocop:disable Metrics/BlockLength
RSpec.describe 'parseDecimal and random against the native Runtime' do
  let(:fixture) { 'spec/fixtures/native_decimal_parsing' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = File.join(directory, 'DecimalParsing.mpr')
      load File.join(fixture, 'project.rb')
      @project = Mxrb.open(ENV.fetch('MXRB_OUTPUT_PATH'))
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @project&.close
    end
  end

  it 'parses Java DecimalFormat patterns, defaults and random decimals as the native Runtime' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project)
    expect(interpreter.call('Views.RunAll')).to be(true)
    logged = interpreter.instance_variable_get(:@log).to_h { _1.delete_prefix('ORACLE ').split('=', 2) }
    cases.select { _1.key?('expected') }.each do |item|
      expect(logged.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name')
    end
    expect(logged.fetch('RandomText')).to match(/\A0\.\d+\z/)
    expect(logged.fetch('RandomScaled')).to eq('0')
  end

  it 'returns nil from the pattern parser when nothing matches' do
    parsing = Mxrb::Runtime::DecimalParsing
    expect(parsing.parse('abc', '0.00')).to be_nil
    expect(parsing.parse('5', '$0')).to be_nil
    expect(parsing.parse('5 g', '0 kg')).to be_nil
    expect(parsing.parse('1,', '#,##0')).to eq(1)
  end

  it 'rejects wrong arities and non-numeric defaults' do
    expression = Mxrb::Runtime::Native::Expression.new
    ['parseDecimal()', "parseDecimal('1', '0', 1, 2)", "parseDecimal('x', '0', 'y')",
     "parseDecimal('x', '0')", "parseDecimal('x')"].each do |text|
      expect { expression.evaluate(text, {}) }.to raise_error(Mxrb::NativeRuntimeError), text
    end
  end
end
# rubocop:enable Metrics/BlockLength
