# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Flow annotation certification' do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'authors, edits, and removes annotations while retaining valid annotation flows' do
    Dir.mktmpdir('mxrb-flow-annotations-') do |dir|
      source = File.join(dir, 'Source.mpr')
      build_source(source)
      add_annotation_flows(source)
      baseline = annotation_snapshot(source)

      ruby_app = File.join(dir, 'ruby-app')
      added = File.join(dir, 'Added.mpr')
      edited = File.join(dir, 'Edited.mpr')
      Mxrb::Exporter.new(source, ruby_app, mode: :ruby).export!
      service = service_path(ruby_app)
      ruby_source = File.read(service)
      expect(ruby_source).to include(
        'annotations_authoritative',
        'annotation "First note", position: "20;30", size: "240;80"',
        'annotation "Second note", position: "20;140", size: "240;60"'
      )
      expect(ruby_source).not_to include('native_document', 'deep_structure:', 'bson_binary(')
      File.write(
        service,
        ruby_source.sub('First note', 'Edited note').sub(
          /(\s+annotation "Second note"[^\n]*\n)/,
          "\\1    annotation \"Third note\", position: \"20;220\", size: \"240;60\"\n"
        )
      )

      Mxrb::RubyApp.compile(ruby_app, added)
      added_snapshot = annotation_snapshot(added)
      expect(added_snapshot.fetch(:annotations)).to include(
        'Edited note' => baseline.dig(:annotations, 'First note').merge(caption: 'Edited note'),
        'Second note' => baseline.dig(:annotations, 'Second note'),
        'Third note' => include(caption: 'Third note', position: '20;220', size: '240;60')
      )
      expect(added_snapshot.fetch(:flows)).to eq(
        baseline.fetch(:flows).each_with_index.map do |flow, index|
          index.zero? ? flow.merge(origin_caption: 'Edited note') : flow
        end
      )

      removal_app = File.join(dir, 'removal-app')
      Mxrb::Exporter.new(added, removal_app, mode: :ruby).export!
      removal_service = service_path(removal_app)
      File.write(
        removal_service,
        File.read(removal_service).lines.reject do |line|
          line.include?('Second note') || line.include?('Third note')
        end.join
      )
      Mxrb::RubyApp.compile(removal_app, edited)
      edited_snapshot = annotation_snapshot(edited)
      expect(edited_snapshot.fetch(:annotations)).to eq(
        'Edited note' => baseline.dig(:annotations, 'First note').merge(caption: 'Edited note')
      )
      expect(edited_snapshot.fetch(:flows)).to eq(
        [baseline.fetch(:flows).first.merge(origin_caption: 'Edited note')]
      )
      expect(Mxrb.validate(edited)).to be_valid

      ruby_round_trip = File.join(dir, 'ruby-round-trip')
      ruby_rebuilt = File.join(dir, 'RubyRebuilt.mpr')
      Mxrb::Exporter.new(edited, ruby_round_trip, mode: :ruby).export!
      Mxrb::RubyApp.compile(ruby_round_trip, ruby_rebuilt)
      expect(Mxrb.compare(edited, ruby_rebuilt)).to be_identical
      expect(annotation_snapshot(ruby_rebuilt)).to eq(edited_snapshot)

      current = ruby_rebuilt
      2.times do |index|
        exported = File.join(dir, "regular-#{index}")
        rebuilt = File.join(dir, "RegularRebuilt#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(annotation_snapshot(rebuilt)).to eq(edited_snapshot)
        current = rebuilt
      end
    end
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        page(:Home) { title 'Home' }
        microflow :Annotated do
          annotation 'First note', position: '20;30', size: '240;80'
          annotation 'Second note', position: '20;140', size: '240;60'
          show_home_page
        end
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', app_title: 'Flow annotation certification'
      end
    end
  end

  def add_annotation_flows(path)
    mpr = Mxrb::IO::MprFile.open(path, readonly: false)
    raw = mpr.all_units.find do |unit|
      document = mpr.parse_contents(unit)
      document['$Type'] == 'Microflows$Microflow' && document['Name'] == 'Annotated'
    end
    document = mpr.parse_contents(raw)
    objects = native_items(document.dig('ObjectCollection', 'Objects'))
    annotations = objects.select { _1['$Type'] == 'Microflows$Annotation' }
    target = objects.find { _1['$Type'] == 'Microflows$ActionActivity' }
    flows = native_items(document['Flows'])
    flows.concat(annotations.map { annotation_flow(_1.fetch('$ID'), target.fetch('$ID')) })
    document['Flows'] = Mxrb::IO::BsonCodec.build_array(flows)
    mpr.transaction { mpr.update_unit(raw.fetch('UnitID'), document) }
  ensure
    mpr&.close
  end

  def annotation_flow(origin, destination)
    {
      '$ID' => SecureRandom.uuid, '$Type' => 'Microflows$AnnotationFlow',
      'DestinationConnectionIndex' => 0, 'DestinationPointer' => destination,
      'Line' => {
        '$ID' => SecureRandom.uuid, '$Type' => 'Microflows$BezierCurve',
        'DestinationControlVector' => '0;-30', 'OriginControlVector' => '0;0'
      },
      'OriginConnectionIndex' => 1, 'OriginPointer' => origin
    }
  end

  def annotation_snapshot(path)
    Mxrb.open(path) do |project|
      flow = project.modules.find { _1.name == 'App' }.microflows.find { _1.name == 'Annotated' }
      annotations = flow.objects.select { _1['$Type'] == 'Microflows$Annotation' }
      captions_by_id = annotations.to_h { |item| [native_id(item.fetch('$ID')), item.fetch('Caption')] }
      {
        annotations: annotations.to_h do |item|
          [item.fetch('Caption'), {
            id: native_id(item.fetch('$ID')), caption: item.fetch('Caption'),
            position: item.fetch('RelativeMiddlePoint'), size: item.fetch('Size')
          }]
        end,
        flows: flow.flows.filter_map do |item|
          next unless item['$Type'] == 'Microflows$AnnotationFlow'

          {
            id: native_id(item.fetch('$ID')), line_id: native_id(item.dig('Line', '$ID')),
            origin_caption: captions_by_id[native_id(item.fetch('OriginPointer'))],
            destination_id: native_id(item.fetch('DestinationPointer'))
          }
        end
      }
    end
  end

  def service_path(root) = File.join(root, 'app', 'services', 'app', 'annotated.rb')
  def native_items(value) = Mxrb::IO::BsonCodec.parse_array(value)[:items]
  def native_id(value) = Mxrb::IO::BsonCodec.extract_id(value)

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
