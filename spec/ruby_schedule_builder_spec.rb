# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::ScheduleBuilder do
  let(:schedule_id) { '11111111-1111-4111-8111-111111111111' }
  let(:event_id) { '22222222-2222-4222-8222-222222222222' }
  let(:exporter) { Mxrb::RubyApp::Exporter.allocate }
  let(:writer) { Mxrb::Writer.new('/tmp/schedule-builder.mpr', version: '11.12.1', modules: []) }

  before { Mxrb::RubyApp::Registry.reset! }
  after { Mxrb::RubyApp::Registry.reset! }

  def declaration(schedule)
    {
      id: event_id, name: 'Cleanup', microflow: 'App.Cleanup', schedule:,
      documentation: '', export_level: 'Hidden', start_at: Time.utc(2026, 9, 5),
      time_zone: 'UTC', on_overlap: 'SkipNext', enabled: true,
      interval_type: 'Day', interval: 1
    }
  end

  def source_class(schedule_definition)
    source = exporter.send(:schedule_source, schedule_definition)
    klass = Class.new(Mxrb::RubyApp::ScheduledEvent)
    klass.class_eval(source, 'schedule_source.rb')
    [source, klass]
  end

  it 'keeps absent, nil and false fields distinct without introducing defaults' do
    builder = described_class.new(:week, id: schedule_id).evaluate do
      hour_of_day nil
      monday false
      tuesday true
    end
    expect(builder.build.to_h).to eq(
      type: 'ScheduledEvents$WeekSchedule', id: schedule_id,
      properties: { 'HourOfDay' => nil, 'Monday' => false, 'Tuesday' => true }
    )
    expect(builder.properties).not_to have_key('MinuteOfHour')
    expect(builder.properties).not_to have_key('Wednesday')
    expect(builder.build).to be_frozen
    expect(builder.properties).to be_frozen
  end

  it 'supports explicit receiver blocks and retains the seed hash unchanged' do
    properties = { 'Multiplier' => 2 }.freeze
    builder = described_class.new('ScheduledEvents$HourSchedule', properties:)
    builder.evaluate { |schedule| schedule.minute_offset(15) }
    expect(properties).to eq('Multiplier' => 2)
    expect(builder.properties).to eq('Multiplier' => 2, 'MinuteOffset' => 15)
  end

  it 'rolls back the entire block on invalid values or fields' do
    builder = described_class.new(:day, properties: { 'HourOfDay' => 8 })
    expect do
      builder.evaluate do
        hour_of_day 10
        minute_of_hour 60
      end
    end.to raise_error(ArgumentError, /invalid schedule minute_of_hour/)
    expect(builder.properties).to eq('HourOfDay' => 8)
    expect { builder.monday(false) }.to raise_error(ArgumentError, /not a property/)
    expect { builder.hour_of_day('8') }.to raise_error(TypeError, /Integer or nil/)
    expect { described_class.new(:week).monday(1) }.to raise_error(TypeError, /true, false or nil/)
  end

  it 'rejects invented types, duplicate aliases and unsupported fields in typed blocks' do
    expect { described_class.new(:daily) }.to raise_error(ArgumentError, /legacy properties API/)
    expect do
      described_class.new(:minute, properties: { 'Multiplier' => 2, multiplier: 3 })
    end.to raise_error(ArgumentError, /duplicate schedule property/)
    expect do
      described_class.new(:minute, properties: { 'FutureOption' => false })
    end.to raise_error(ArgumentError, /legacy properties API/)
  end

  {
    'ScheduledEvents$MinuteSchedule' => { 'Multiplier' => 5 },
    'ScheduledEvents$HourSchedule' => { 'Multiplier' => 2, 'MinuteOffset' => 15 },
    'ScheduledEvents$DaySchedule' => { 'HourOfDay' => nil, 'MinuteOfHour' => 0 },
    'ScheduledEvents$WeekSchedule' => { 'Monday' => false, 'Tuesday' => nil, 'Sunday' => true }
  }.each do |type, properties|
    it "emits and evaluates the exact #{type} properties without public IDs" do
      source, klass = source_class('type' => type, 'id' => schedule_id, 'properties' => properties)
      expect(source).to include("schedule #{described_class.kind(type).inspect} do")
      expect(source).not_to include('properties:', 'id:', schedule_id)
      expect(klass.native_definition.fetch(:schedule)).to eq(type:, id: '', properties:)
    end
  end

  [
    ['ScheduledEvents$FutureSchedule', { 'FutureOption' => nil, 'Enabled' => false }],
    ['ScheduledEvents$DaySchedule', { 'HourOfDay' => 8, 'FutureOption' => false }],
    ['ScheduledEvents$DaySchedule', { 'hour_of_day' => 8 }],
    ['ScheduledEvents$MinuteSchedule', { 'Multiplier' => '5' }]
  ].each do |type, properties|
    it "retains legacy properties verbatim for #{type} #{properties.inspect}" do
      expect(described_class.compatible?(type, properties)).to be(false)
      source, klass = source_class('type' => type, 'id' => schedule_id, 'properties' => properties)
      expect(source).to include('properties:')
      expect(source).not_to include('id:', schedule_id)
      expect(klass.native_definition.fetch(:schedule)).to eq(type:, id: '', properties:)
    end
  end

  it 'preserves the explicitly supplied legacy schedule ID and unknown values' do
    klass = Class.new(Mxrb::RubyApp::ScheduledEvent)
    klass.schedule('ScheduledEvents$FutureSchedule', id: schedule_id, properties: { 'Flag' => false, 'Missing' => nil })
    expect(klass.native_definition.fetch(:schedule)).to eq(
      type: 'ScheduledEvents$FutureSchedule', id: schedule_id,
      properties: { 'Flag' => false, 'Missing' => nil }
    )
  end

  it 'changes Hour to Day without inheriting residual properties or replacing the baseline ID' do
    original = declaration(
      type: 'ScheduledEvents$HourSchedule', id: schedule_id,
      properties: { 'Multiplier' => 2, 'MinuteOffset' => 15 }
    )
    previous = writer.send(:ruby_scheduled_event_doc, original, nil, 'App')
    klass = Class.new(Mxrb::RubyApp::ScheduledEvent)
    klass.schedule(:day) do
      hour_of_day 9
      minute_of_hour 30
    end
    changed = declaration(klass.native_definition.fetch(:schedule))
    result = writer.send(:ruby_scheduled_event_doc, changed, previous, 'App')
    expect(result.fetch('Schedule')).to eq(
      '$ID' => schedule_id, '$Type' => 'ScheduledEvents$DaySchedule',
      'HourOfDay' => 9, 'MinuteOfHour' => 30
    )
  end

  it 'keeps existing unknown fields when editing properties of the same schedule type' do
    original = declaration(
      type: 'ScheduledEvents$DaySchedule', id: schedule_id,
      properties: { 'HourOfDay' => 8, 'FutureOption' => false }
    )
    previous = writer.send(:ruby_scheduled_event_doc, original, nil, 'App')
    edited = declaration(described_class.new(:day).evaluate { hour_of_day 9 }.build.to_h)
    result = writer.send(:ruby_scheduled_event_doc, edited, previous, 'App')
    expect(result.fetch('Schedule')).to include('HourOfDay' => 9, 'FutureOption' => false, '$ID' => schedule_id)
  end

  it 'roundtrips public source using private top-level identity and the real nested baseline ID' do
    schedule = {
      'type' => 'ScheduledEvents$WeekSchedule', 'id' => schedule_id,
      'properties' => { 'HourOfDay' => nil, 'Monday' => false, 'Sunday' => true }
    }
    original = declaration(schedule.transform_keys(&:to_sym))
    previous = writer.send(:ruby_scheduled_event_doc, original, nil, 'App')
    event = original.transform_keys(&:to_s).merge(
      'name' => 'App.Cleanup', 'schedule' => schedule,
      'start_at' => original.fetch(:start_at).iso8601,
      'path' => 'app/scheduled_events/app/cleanup.rb', 'ruby_class' => 'App::Cleanup'
    )
    manifest_data = { 'mode' => 'ruby', 'modules' => [{ 'name' => 'App', 'scheduled_events' => [event] }] }
    manifest = Mxrb::RubyApp::Manifest.new('/tmp/schedule-source', manifest_data)
    source = exporter.send(:scheduled_event_source, 'App', 'Cleanup', event)
    expect(source).not_to include('id:', event_id, schedule_id)
    namespace = Module.new
    Mxrb::RubyApp::SourceIdentity.with(manifest) do |identities|
      identities.load_file(File.join(manifest.root, event.fetch('path'))) do
        namespace.module_eval(source, event.fetch('path'))
      end
      identities.finalize!
    end
    klass = namespace.const_get(:App).const_get(:Cleanup)
    expect(klass.mendix_id).to eq(event_id)
    expect(klass.native_definition.dig(:schedule, :id)).to eq('')
    result = writer.send(:ruby_scheduled_event_doc, klass.native_definition, previous, 'App')
    expect(result).to eq(previous)
    expect(result.dig('Schedule', '$ID')).to eq(schedule_id)
  end
end
# rubocop:enable Metrics/BlockLength
