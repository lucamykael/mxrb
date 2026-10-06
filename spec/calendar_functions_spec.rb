# frozen_string_literal: true

require 'spec_helper'

module CalendarExpressionHelpers
  def evaluate(source, zone = 'UTC', variables = {})
    Mxrb::Runtime::Native::Expression.new(time_zone: zone).evaluate(source, variables)
  end
end

RSpec.describe Mxrb::Runtime::CalendarFunctions do
  include CalendarExpressionHelpers

  it 'refuses to invent an offset when timezone data cannot resolve a local date' do
    zone = instance_double(TZInfo::Timezone, periods_for_local: [], transitions_up_to: [])
    allow(TZInfo::Timezone).to receive(:get).with('UTC').and_return(zone)
    expect { evaluate('dateTimeUTC(2024)') }.to raise_error(Mxrb::NativeRuntimeError)
  end
end

RSpec.describe Mxrb::Runtime::CalendarFunctions do
  include CalendarExpressionHelpers

  it 'clamps calendar months and years while preserving fractional seconds' do
    expect(evaluate('addMonthsUTC(dateTimeUTC(2024, 1, 31, 12), 1)')).to eq(Time.utc(2024, 2, 29, 12))
    expect(evaluate('addYearsUTC(dateTimeUTC(2024, 2, 29), 1)')).to eq(Time.utc(2025, 2, 28))
    expect(evaluate('subtractQuartersUTC(dateTimeUTC(2024, 5, 31), 1)')).to eq(Time.utc(2024, 2, 29))
    expect(evaluate('addWeeksUTC(dateTimeUTC(2024, 12, 25), 1)')).to eq(Time.utc(2025))
    expect(evaluate('subtractMilliseconds(addMonthsUTC($date, 1), 1)', 'UTC',
                    'date' => Time.utc(2024, 1, 31) + Rational(123, 1000)))
      .to eq(Time.utc(2024, 2, 29) + Rational(122, 1000))
  end
end

RSpec.describe Mxrb::Runtime::CalendarFunctions do
  include CalendarExpressionHelpers

  it 'distinguishes elapsed hours from calendar days across spring and autumn DST' do
    zone = 'America/New_York'
    expect(evaluate('addDays(dateTime(2024, 3, 9, 12), 1)', zone)).to eq(Time.utc(2024, 3, 10, 16))
    expect(evaluate('addHours(dateTime(2024, 3, 9, 12), 24)', zone)).to eq(Time.utc(2024, 3, 10, 17))
    expect(evaluate('addDaysUTC(dateTime(2024, 3, 9, 12), 1)', zone)).to eq(Time.utc(2024, 3, 10, 17))
    expect(evaluate('subtractDays(dateTime(2024, 11, 3, 12), 1)', zone)).to eq(Time.utc(2024, 11, 2, 16))
    expect(evaluate('addDays(dateTime(2024, 3, 9, 2, 30), 1)', zone)).to eq(Time.utc(2024, 3, 10, 6, 30))
    expect(evaluate('dateTime(2024, 11, 3, 1, 30)', zone)).to eq(Time.utc(2024, 11, 3, 6, 30))
    expect(evaluate('addDays(dateTime(2024, 11, 2, 1, 30), 1)', zone)).to eq(Time.utc(2024, 11, 3, 5, 30))
  end
end

RSpec.describe Mxrb::Runtime::CalendarFunctions do
  include CalendarExpressionHelpers

  it 'uses real transition offsets for half-hour and skipped-day gaps' do
    expect(evaluate('dateTime(2024, 10, 6, 2, 15)', 'Australia/Lord_Howe')).to eq(Time.utc(2024, 10, 5, 15, 45))
    expect(evaluate('dateTime(2011, 12, 30, 12)', 'Pacific/Apia')).to eq(Time.utc(2011, 12, 30, 22))
    expect(evaluate('addDays(dateTime(2024, 10, 5, 2, 15), 1)', 'Australia/Lord_Howe'))
      .to eq(Time.utc(2024, 10, 5, 15, 15))
    expect(evaluate('addDays(dateTime(2011, 12, 29, 12), 1)', 'Pacific/Apia'))
      .to eq(Time.utc(2011, 12, 30, 22))
    expect(evaluate('subtractDays(dateTime(2024, 3, 11, 2, 30), 1)', 'America/New_York'))
      .to eq(Time.utc(2024, 3, 10, 7, 30))
    expect(evaluate('addMonths(dateTime(2024, 2, 10, 2, 30), 1)', 'America/New_York'))
      .to eq(Time.utc(2024, 3, 10, 7, 30))
    expect(evaluate('addMonths(dateTime(2024, 10, 3, 1, 30), 1)', 'America/New_York'))
      .to eq(Time.utc(2024, 11, 3, 6, 30))
  end
end

RSpec.describe Mxrb::Runtime::CalendarFunctions do
  include CalendarExpressionHelpers

  it 'trims in the chosen calendar using the native later overlap occurrence' do
    input = Time.utc(2024, 11, 3, 5, 45, 30) + Rational(123, 1000)
    zone = 'America/New_York'
    {
      'Seconds' => Time.utc(2024, 11, 3, 6, 45, 30),
      'Minutes' => Time.utc(2024, 11, 3, 6, 45),
      'Hours' => Time.utc(2024, 11, 3, 6),
      'Days' => Time.utc(2024, 11, 3, 4),
      'Months' => Time.utc(2024, 11, 1, 4),
      'Years' => Time.utc(2024, 1, 1, 5)
    }.each do |unit, expected|
      expect(evaluate("trimTo#{unit}($date)", zone, 'date' => input)).to eq(expected)
    end
    expect(evaluate('trimToDaysUTC($date)', zone, 'date' => input)).to eq(Time.utc(2024, 11, 3))
  end

  it 'roundtrips negative epoch milliseconds and accepts DateTime values' do
    expect(evaluate('dateTimeToEpoch(epochToDateTime(-123))')).to eq(-123)
    expect(evaluate('dateTimeToEpoch($date)', 'UTC', 'date' => DateTime.new(1970))).to eq(0)
    expect(evaluate('dateTimeUTC(2024)')).to eq(Time.utc(2024))
  end
end

RSpec.describe Mxrb::Runtime::CalendarFunctions do
  include CalendarExpressionHelpers

  it 'rejects invalid arity, dates, types and zones instead of normalizing input' do
    ['dateTimeUTC()', 'dateTimeUTC(2024, 1, 1, 0, 0, 0, 0)', 'dateTimeUTC(2023, 2, 29)',
     'dateTimeUTC(1799)', 'dateTimeUTC(2024, 1, 1, 24)', 'dateTimeUTC(2024, 1, 1, 0, 60)',
     'dateTimeUTC(2024, 1, 1, 0, 0, 60)', "dateTimeUTC('2024')", 'epochToDateTime(1.5)',
     'addDays(empty, 1)', 'addDays(dateTimeUTC(2024))', 'trimToDays()', 'dateTimeToEpoch()',
     'epochToDateTime()'].each do |source|
      expect { evaluate(source) }.to raise_error(Mxrb::NativeRuntimeError)
    end
    expect { evaluate('dateTime(2024)', 'invalid-zone') }.to raise_error(Mxrb::NativeRuntimeError)
  end
end
