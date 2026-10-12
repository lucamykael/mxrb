# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::DateFormatting do
  let(:fixture) { 'spec/fixtures/native_date_formatting' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }

  around do |example|
    Dir.mktmpdir do |directory|
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = File.join(directory, 'Dates.mpr')
      load File.join(fixture, 'project.rb')
      @project = Mxrb.open(ENV.fetch('MXRB_OUTPUT_PATH'))
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @project&.close
    end
  end

  it 'formats every pattern and default form as the native Mendix 11.12.1 Runtime' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project)
    expect(interpreter.call('Views.RunAll')).to be(true)
    logged = interpreter.instance_variable_get(:@log).to_h { _1.delete_prefix('ORACLE ').split('=', 2) }
    cases.each { |item| expect(logged.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'shows local forms in the session time zone and offsets beyond UTC' do
    expression = Mxrb::Runtime::Native::Expression.new(time_zone: 'America/Sao_Paulo')
    instant = Time.utc(2024, 3, 10, 7, 5, 9)
    expect(expression.evaluate("formatDateTime($t, 'yyyy-MM-dd HH:mm Z X XX XXX')", { 't' => instant }))
      .to eq('2024-03-10 04:05 -0300 -03 -0300 -03:00')
    expect(expression.evaluate("formatDateTimeUTC($t, 'HH:mm')", { 't' => instant })).to eq('07:05')
    expect(expression.evaluate('toString($t)', { 't' => instant })).to eq('3/10/24, 4:05 AM')
    expect(expression.evaluate("formatDateTime($t, 'h')", { 't' => Time.utc(2024, 3, 10, 15) })).to eq('12')
    expect(described_class.format(Time.utc(2024, 1, 1, 12, 30), 'K h a', zone: 'UTC')).to eq('0 12 PM')
    expect(described_class.format(Time.utc(-5, 1, 1), 'G', zone: 'UTC')).to eq('BC')
    expect { expression.invoke('formatDate', []) }.to raise_error(ArgumentError, /requires a date/)
  end

  it 'refuses unknown letters, unverified zone names and wrong arities' do
    expression = Mxrb::Runtime::Native::Expression.new(time_zone: 'America/Sao_Paulo')
    variables = { 't' => Time.utc(2024, 3, 10) }
    ["formatDateTimeUTC($t, 'Q')", "formatDateTime($t, 'z')", "formatDate($t, 'yyyy')",
     "formatTime($t, 'HH', 'x')"].each do |text|
      expect { expression.evaluate(text, variables) }.to raise_error(Mxrb::NativeRuntimeError), text
    end
  end
end
# rubocop:enable Metrics/BlockLength
