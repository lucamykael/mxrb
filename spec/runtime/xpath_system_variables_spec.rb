# frozen_string_literal: true

require 'spec_helper'
require_relative '../../lib/mxrb/runtime/xpath'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::XPath, 'system variables' do
  let(:store) { Mxrb::Runtime::Native::Store.new }
  let(:record) { store.create('App.Item') }
  let(:context) { Mxrb::Runtime::SecurityContext.new(user: { id: 'user-1' }) }

  def matches(source, variables = {})
    described_class.new(source, store:, context:).match?(record, variables)
  end

  it 'resolves contextual identities without treating each candidate as the current object' do
    record.members['Owner'] = 'user-1'
    expect(matches('[Owner = [%CurrentUser%]]')).to be(true)
    expect(matches("[id = '[%CurrentObject%]']", 'currentObject' => record)).to be(true)
    expect(matches('[id = [%CurrentObject%]]', 'currentObject' => record.id)).to be(true)
    expect { matches('[id = [%CurrentObject%]]') }.to raise_error(ArgumentError, /unknown XPath variable/)
    role = store.create('System.UserRole')
    role.members['Name'] = 'Administrator'
    record.members['Role'] = role
    expect(matches("[Role = '[%UserRole_Administrator%]']")).to be(true)
    expect { matches('[Role = [%UserRole_Unknown%]]') }.to raise_error(ArgumentError, /unknown or unreadable/)
    other = Mxrb::Runtime::SecurityContext.new(user: { 'id' => 'user-1' })
    expect(described_class.new('[Owner = [%CurrentUser%]]', store:, context: other).match?(record)).to be(true)
    expect(described_class.new('[Owner = [%CurrentUser%]]', store:).match?(record)).to be(false)
    policy = instance_double(Mxrb::Runtime::AccessControl)
    allow(policy).to receive(:entity_allowed?).and_return(true)
    allow(policy).to receive(:entity_allowed?).with('System.UserRole', anything).and_return(false)
    allow(policy).to receive(:authorize!).and_return(true)
    expect { described_class.new('[Role = [%UserRole_Administrator%]]', store:, context:, policy:).match?(record) }
      .to raise_error(ArgumentError, /unknown or unreadable/)
  end

  it 'supports quoted and unquoted calendar tokens and period arithmetic' do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 10, 5, 12, 34, 56))
    ranges = {
      'CurrentMinute' => [Time.utc(2026, 10, 5, 12, 34), Time.utc(2026, 10, 5, 12, 35)],
      'CurrentHour' => [Time.utc(2026, 10, 5, 12), Time.utc(2026, 10, 5, 13)],
      'CurrentDay' => [Time.utc(2026, 10, 5), Time.utc(2026, 10, 6)],
      'Yesterday' => [Time.utc(2026, 10, 4), Time.utc(2026, 10, 5)],
      'Tomorrow' => [Time.utc(2026, 10, 6), Time.utc(2026, 10, 7)],
      'CurrentWeek' => [Time.utc(2026, 10, 5), Time.utc(2026, 10, 12)],
      'CurrentMonth' => [Time.utc(2026, 10, 1), Time.utc(2026, 11, 1)],
      'CurrentYear' => [Time.utc(2026), Time.utc(2027)]
    }
    ranges.each do |period, (first, last)|
      record.members['Start'] = first
      record.members['End'] = last - Rational(1, 1000)
      expect(matches("[Start = '[%BeginOf#{period}UTC%]'][End = [%EndOf#{period}%]]")).to be(true), period
    end
    record.members['Created'] = Time.utc(2023, 10, 5)
    expect(matches("[Created = '[%BeginOfCurrentDay%] - 3 * [%YearLength%]']")).to be(true)
    record.members['Created'] = Time.utc(2026, 11, 6, 1, 1, 1)
    expect(matches("[Created = '[%BeginOfCurrentDay%] + [%MonthLength%] + [%DayLength%] + " \
                   "[%HourLength%] + [%MinuteLength%] + [%SecondLength%]']")).to be(true)
    record.members['Created'] = Time.now - 604_800
    expect(matches("[Created = '[%CurrentDateTime%] - [%WeekLength%]']")).to be(true)
  end

  it 'uses the session timezone and preserves day boundaries across DST' do
    now = Time.utc(2026, 3, 8, 16)
    allow(Time).to receive(:now).and_return(now)
    local = Mxrb::Runtime::SecurityContext.new(attributes: { 'time_zone' => 'America/New_York' })
    record.members['Start'] = Time.utc(2026, 3, 8, 5)
    record.members['End'] = Time.utc(2026, 3, 9, 4) - Rational(1, 1000)
    query = described_class.new('[Start = [%BeginOfCurrentDay%]][End = [%EndOfCurrentDay%]]', store:, context: local)
    expect(query.match?(record)).to be(true)
  end

  it 'rejects unknown tokens, invalid zones and executable or malformed date arithmetic' do
    ['[%NoSuchToken%]', '[%CurrentDateTime%] garbage', '[%CurrentDateTime%] + [%BadLength%]',
     '[%CurrentDateTime%] + Kernel.exit', '[%CurrentDateTime%] + (2 * [%DayLength%])', '[%invalid'].each do |value|
      expect { matches("[Created = '#{value}']") }.to raise_error(ArgumentError)
    end
    bad = Mxrb::Runtime::SecurityContext.new(attributes: { 'time_zone' => 'bad/zone' })
    expect { described_class.new('[Created = [%CurrentDateTime%]]', store:, context: bad).match?(record) }
      .to raise_error(ArgumentError, /session time zone/)
  end
end
# rubocop:enable Metrics/BlockLength
