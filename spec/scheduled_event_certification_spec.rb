# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Scheduled event certification' do
  it 'keeps every Mendix 11 schedule kind editable and identity-stable for two cycles' do
    Dir.mktmpdir('mxrb-scheduled-events-') do |dir|
      current = File.join(dir, 'Events.mpr')
      build_source(current)
      baseline_ids = event_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = Dir[File.join(exported, 'modules/Jobs/application/jobs/scheduled_events/*.rb')]
                 .map { File.read(_1) }.join("\n")
        expect(source).to include(
          'schedule: :minute', 'schedule: :hour', 'schedule: :day', 'schedule: :week',
          'weekdays:', ':monday', ':friday', 'schedule_id:'
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(event_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :Jobs do
        page(:Home) { title 'Scheduled events' }
        microflow(:Run) { log_message 'scheduled' }
        scheduled_event(
          :EveryFiveMinutes, microflow: 'Jobs.Run', interval: 5, unit: :minutes,
                             schedule: :minute, multiplier: 5
        )
        scheduled_event(
          :EveryTwoHours, microflow: 'Jobs.Run', interval: 2, unit: :hours,
                          schedule: :hour, multiplier: 2, minute_offset: 15
        )
        scheduled_event :Daily, microflow: 'Jobs.Run', interval: 1, unit: :days,
                                schedule: :day, hour_of_day: 3, minute_of_hour: 30
        scheduled_event :Weekly, microflow: 'Jobs.Run', interval: 1, unit: :weeks,
                                 schedule: :week, hour_of_day: 4, minute_of_hour: 45,
                                 weekdays: %i[monday friday], on_overlap: 'DelayNext'
      end
      navigation do
        profile :Responsive, home_page: 'Jobs.Home', app_title: 'Scheduled events'
      end
    end
  end

  def event_ids(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        next unless document['$Type'] == 'ScheduledEvents$ScheduledEvent'

        [
          document.fetch('Name'), unit.fetch('UnitID').to_s,
          Mxrb::IO::BsonCodec.extract_id(document.fetch('Schedule').fetch('$ID'))
        ]
      end.sort
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
