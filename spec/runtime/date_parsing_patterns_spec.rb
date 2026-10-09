# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Date parsing with SimpleDateFormat patterns' do
  let(:fixture) { 'spec/fixtures/native_date_parsing' }
  let(:cases) { JSON.parse(File.read(File.join(fixture, 'cases.json'))) }
  let(:parsing) { Mxrb::Runtime::DateParsing }

  around do |example|
    Dir.mktmpdir do |directory|
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = File.join(directory, 'Parsing.mpr')
      load File.join(fixture, 'project.rb')
      @project = Mxrb.open(ENV.fetch('MXRB_OUTPUT_PATH'))
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @project&.close
    end
  end

  it 'parses names, two-digit years, 12-hour clocks, weeks and zones as the native Mendix 11.12.1 Runtime' do
    interpreter = Mxrb::Runtime::Native::Interpreter.new(@project)
    expect(interpreter.call('Views.RunAll')).to be(true)
    logged = interpreter.instance_variable_get(:@log).to_h { _1.delete_prefix('ORACLE ').split('=', 2) }
    cases.each { |item| expect(logged.fetch(item.fetch('name'))).to eq(item.fetch('expected')), item.fetch('name') }
  end

  it 'refuses dates before the 1582 calendar reform instead of shifting them' do
    [['10/03/24', 'dd/MM/yyyy'], ['0001-05-01', 'yyyy-MM-dd'], ['10 Mar 2024 BC', 'dd MMM yyyy G'],
     ['10/03/5', 'dd/MM/yy']].each do |input, pattern|
      expect { parsing.invoke([input, pattern, nil]) }.to raise_error(ArgumentError, /1582/), input
    end
  end

  it 'reads local text in the session time zone and resolves two-digit years from the current date' do
    expression = Mxrb::Runtime::Native::Expression.new(time_zone: 'America/Sao_Paulo')
    expect(expression.evaluate("parseDateTime('2024-03-10 07:05', 'yyyy-MM-dd HH:mm')", {}))
      .to eq(Time.utc(2024, 3, 10, 10, 5))
    expect(expression.evaluate("parseDateTime('2024-03-10 07:05 Z', 'yyyy-MM-dd HH:mm X')", {}))
      .to eq(Time.utc(2024, 3, 10, 7, 5))
    now = Time.utc(2026, 10, 9)
    { '10/03/46' => 2046, '10/11/46' => 1946, '10/03/45' => 2045, '10/03/99' => 1999 }.each do |text, year|
      expect(parsing.invoke([text, 'dd/MM/yy'], now:).year).to eq(year), text
    end
  end

  it 'rejects out-of-range clock fields and unknown names' do
    [['13:05 PM', 'h:mm a'], ['12:05 PM', 'K:mm a'], ['25:00', 'kk:mm'], ['10 Foo 2024', 'dd MMM yyyy'],
     ['Sun, 31 Feb 2024', 'EEE, dd MMM yyyy'], ['2023-366', 'yyyy-DDD'], ['10:61', 'HH:mm']].each do |input, pattern|
      expect(parsing.invoke([input, pattern, nil])).to be_nil, input
    end
    expect(parsing.invoke(['2024 EST', 'yyyy z'])).to eq(Time.utc(2024, 1, 1, 5))
  end
end
# rubocop:enable Metrics/BlockLength
