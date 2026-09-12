# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'remaining semantic documents' do
  let(:types) do
    %w[ScheduledEvents$ScheduledEvent Rest$ConsumedODataService
       MessageDefinitions$MessageDefinitionCollection]
  end

  it 'exports schedules, consumed OData, and message definitions without opaque BSON' do
    Dir.mktmpdir('mxrb-semantic-remaining-') do |dir|
      source = File.join(dir, 'SemanticRemaining.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt', 'SemanticRemaining.mpr')
      build_source(source)

      Mxrb::Exporter.new(source, exported).export!
      ruby = Dir[File.join(exported, 'modules', 'Integration', '**', '*.rb')]
             .map { File.read(_1) }.join("\n")
      expect(ruby).to include(
        'scheduled_event :WeeklyCleanup', 'consumed_odata_service :Directory',
        'message_definition_collection :Contacts', 'entity_message :Contact',
        'exposed_attribute :Email'
      )
      expect(ruby).not_to match(/^\s*native_document\b/)
      expect(ruby).not_to include('deep_structure:', 'bson_binary(', 'native_fragment(')

      FileUtils.mkdir_p(File.dirname(rebuilt))
      generate(exported, rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(documents(rebuilt)).to eq(documents(source))
    end
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Integration) do
        microflow(:Cleanup) { log_message 'cleanup' }
        scheduled_event :WeeklyCleanup, microflow: 'Integration.Cleanup', interval: 0,
                                        unit: :weeks, interval_type: 'Week',
                                        start_at: '2026-01-04T03:15:00.000Z',
                                        on_overlap: 'DelayNext', schedule: :week,
                                        schedule_id: SecureRandom.uuid,
                                        hour_of_day: 3, minute_of_hour: 15,
                                        weekdays: [:sunday]
        consumed_odata_service :Directory, service_name: 'Directory', version: '2.0.0',
                                           odata_version: '4.0', metadata: '<edmx />',
                                           icon_base64: Base64.strict_encode64('icon'),
                                           http_configuration_id: SecureRandom.uuid
        message_definition_collection :Contacts do
          entity_message :Contact, id: SecureRandom.uuid,
                                   exposed_entity_id: SecureRandom.uuid,
                                   entity: 'Integration.Contact', exposed_name: 'Contact' do
            exposed_attribute :Email, id: SecureRandom.uuid,
                                      attribute: 'Integration.Contact.Email',
                                      primitive_type: :string
          end
        end
      end
    end
  end

  def documents(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        [[document['$Type'], document['Name']], document] if types.include?(document['$Type'])
      end.to_h
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
