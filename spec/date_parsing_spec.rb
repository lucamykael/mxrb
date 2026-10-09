# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Mxrb::Runtime::DateParsing do # rubocop:disable Metrics/BlockLength
  let(:expression) { Mxrb::Runtime::Native::Expression.new(time_zone: 'America/New_York') }
  let(:cases) { JSON.parse(File.read(File.join(__dir__, 'fixtures/native_parse_datetime/cases.json'))) }

  it 'matches numeric UTC parsing, strict calendar validation, offsets and fallbacks from the native oracle' do
    cases.each do |item|
      parsed = described_class.invoke([item.fetch('input'), item.fetch('format'), Time.utc(2000)])
      expect((parsed.to_r * 1000).to_i.to_s).to eq(item.fetch('expected')), item.fetch('name')
    end
  end

  it 'parses the actual expression independently of the user time zone' do
    actual = expression.evaluate("parseDateTimeUTC('2026-01-02 03:04:05', 'yyyy-MM-dd HH:mm:ss')", {})
    expect(actual).to eq(Time.utc(2026, 1, 2, 3, 4, 5))
    expect(expression.evaluate("parseDateTimeUTC('bad', 'yyyy-MM-dd', empty)", {})).to be_nil
    expect { expression.evaluate("parseDateTimeUTC('bad', 'yyyy-MM-dd')", {}) }.to raise_error(Mxrb::NativeRuntimeError)
  end

  it 'preserves quoted literals, escaped quotes and adjacent numeric field widths' do
    expect(described_class.invoke(["2024 o'clock 12", "yyyy 'o''clock' HH"]))
      .to eq(Time.utc(2024, 1, 1, 12))
    expect(described_class.invoke(["2024'01", "yyyy''MM"])).to eq(Time.utc(2024))
    expect(described_class.invoke(%w[2024Z yyyyX])).to eq(Time.utc(2024))
    expect(described_class.invoke(%w[20240102030405 yyyyMMddHHmmss])).to eq(Time.utc(2024, 1, 2, 3, 4, 5))
    expect(described_class.invoke(['literal', "'literal'"])).to eq(Time.utc(1970))
  end

  it 'falls back for unparseable values, invalid offsets, year zero and an empty pattern' do
    [['2024-01-02+2400', 'yyyy-MM-ddZ'], ['2024-01-02+0299', 'yyyy-MM-ddZ'],
     ['0000', 'yyyy'], ['ignored', '']].each do |input, pattern|
      expect(described_class.invoke([input, pattern, Time.utc(2000)])).to eq(Time.utc(2000))
    end
    expect(described_class.invoke(%w[1799 yyyy])).to eq(Time.utc(1799))
    expect(described_class.invoke(%w[10000 yyyy])).to eq(Time.utc(10_000))
  end

  it 'rejects unsupported patterns and malformed literals even when a fallback exists' do
    ['yyyy-MM-dd Q', 'yyyy-MM-dd F', "yyyy-MM-dd'", "yyyy 'unfinished"].each do |pattern|
      expect { described_class.invoke(['input', pattern, Time.utc(2000)]) }.to raise_error(ArgumentError)
    end
  end

  it 'rejects missing arguments and non-string inputs' do
    [[], ['date'], ['date', 'pattern', nil, nil], [nil, 'yyyy'], ['2024', nil]].each do |arguments|
      expect { described_class.invoke(arguments) }.to raise_error(ArgumentError)
    end
    expect { described_class.invoke(['bad', 'yyyy', 42]) }.to raise_error(ArgumentError, /date fallback/)
    expect(described_class.invoke(['bad', 'yyyy', DateTime.new(2000)])).to eq(DateTime.new(2000))
  end

  it 'executes exported microflows with the original model unavailable' do
    Mxrb::RubyApp::Registry.reset!
    Dir.mktmpdir do |directory|
      source = File.join(directory, 'Application.mpr')
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(source)
      load File.join(__dir__, 'fixtures/native_parse_datetime/project.rb')
      target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR access prohibited')
      application = Mxrb::RubyApp::Application.new(target)
      cases.each do |item|
        expect(application.call_service("Dates.#{item.fetch('name')}")).to eq(item.fetch('expected'))
      end
    ensure
      application&.close
    end
  ensure
    Mxrb::RubyApp::Registry.reset!
  end
end
