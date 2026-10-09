# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::ExpressionFunctions do
  let(:fixture) { 'spec/fixtures/native_expression_functions' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }
  let(:expression) { Mxrb::Runtime::Native::Expression.new }

  around do |example|
    Dir.mktmpdir do |directory|
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = File.join(directory, 'Functions.mpr')
      load File.join(fixture, 'project.rb')
      @project = Mxrb.open(ENV.fetch('MXRB_OUTPUT_PATH'))
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @project&.close
    end
  end

  it 'evaluates string, regular expression, number and format functions as the native Runtime' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project)
    expect(interpreter.call('Views.RunAll')).to be(true)
    logged = interpreter.instance_variable_get(:@log).to_h { _1.delete_prefix('ORACLE ').split('=', 2) }
    cases.each { |item| expect(logged.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'keeps backslashes and dollars of template parameters' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project)
    template = { 'Text' => 'v={1}', 'Parameters' => [{ 'Expression' => '$value' }] }
    expect(interpreter.send(:render_template, template, { 'value' => 'a\\b $1 \\0' })).to eq('v=a\\b $1 \\0')
  end

  it 'rejects joins with other types, invalid arguments and unparseable integers' do
    ["'a' + true", "replaceAll('a', 'b')", "isMatch('a', '[')", 'max(1)', "parseInteger('x')", "pow('2', 2)",
     "parseInteger('1', 2, 3)", "formatDecimal(1, 'x')"].each do |text|
      expect { expression.evaluate(text, {}) }.to raise_error(Mxrb::NativeRuntimeError), text
    end
    expect(expression.evaluate("parseInteger('99999999999999999999', 7)", {})).to eq(7)
    expect(expression.evaluate("formatDecimal(-0.5, '0.0E00')", {})).to eq('-5.0E-01')
    expect(expression.evaluate("formatDecimal(0, '0.0E0')", {})).to eq('0.0E0')
    expect(expression.evaluate('sqrt(0)', {})).to eq(0)
  end
end
# rubocop:enable Metrics/BlockLength
