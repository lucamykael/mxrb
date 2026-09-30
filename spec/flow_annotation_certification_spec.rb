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
        'annotation "Second note", position: "20;140", size: "240;60"',
        'as_node "annotation:',
        'annotation_flow from: "annotation:'
      )
      expect(ruby_source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

      compatibility_app = File.join(dir, 'compatibility-app')
      compatibility_mpr = File.join(dir, 'Compatibility.mpr')
      Mxrb::Exporter.new(source, compatibility_app, mode: :ruby).export!
      compatibility_service = service_path(compatibility_app)
      File.write(
        compatibility_service,
        File.read(compatibility_service).lines.reject { _1.include?('annotation_flow from:') }.join
      )
      Mxrb::RubyApp.compile(compatibility_app, compatibility_mpr)
      expect(annotation_snapshot(compatibility_mpr)).to eq(baseline)

      first_removal_app = File.join(dir, 'first-removal-app')
      first_removal_mpr = File.join(dir, 'FirstRemoval.mpr')
      Mxrb::Exporter.new(source, first_removal_app, mode: :ruby).export!
      first_removal_service = service_path(first_removal_app)
      File.write(
        first_removal_service,
        without_connected_annotation(File.read(first_removal_service), 'First note')
      )
      Mxrb::RubyApp.compile(first_removal_app, first_removal_mpr)
      expect(annotation_snapshot(first_removal_mpr).fetch(:annotations)).to eq(
        'Second note' => baseline.dig(:annotations, 'Second note')
      )

      File.write(
        service,
        ruby_source.sub('First note', 'Edited note').sub(
          /(\s+annotation "Second note"[^\n]*\n\s+as_node [^\n]+\n)/,
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
      removal_source = File.read(removal_service)
      File.write(
        removal_service,
        without_connected_annotation(removal_source, 'Second note')
          .lines.reject { _1.include?('Third note') }.join
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

  it 'creates authoritative annotation flows from node references' do
    Dir.mktmpdir('mxrb-annotation-flow-create-') do |dir|
      path = File.join(dir, 'Created.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module :App do
          page(:Home) { title 'Home' }
          microflow :Connected do
            annotation 'Created note', position: '20;30', size: '240;80'
            as_node :note
            show_home_page
            as_node :home
            annotation_flow from: :note, to: :home
          end
        end
        navigation { profile :Responsive, home_page: 'App.Home', app_title: 'Created flow' }
      end

      snapshot = annotation_snapshot(path, flow_name: 'Connected')
      expect(snapshot.fetch(:flows).size).to eq(1)
      expect(snapshot.dig(:flows, 0, :origin_caption)).to eq('Created note')
      expect(Mxrb.validate(path)).to be_valid
    end
  end

  it 'fails closed for missing and duplicate node references' do
    Dir.mktmpdir('mxrb-annotation-flow-invalid-') do |dir|
      expect do
        build_invalid_flow(File.join(dir, 'Missing.mpr'), duplicate: false)
      end.to raise_error(Mxrb::ValidationError, /unknown annotation_flow node reference: missing/)
      expect do
        build_invalid_flow(File.join(dir, 'Duplicate.mpr'), duplicate: true)
      end.to raise_error(Mxrb::ValidationError, /duplicate flow node reference: note/)
      expect do
        build_invalid_flow(File.join(dir, 'MissingDestination.mpr'), missing_destination: true)
      end.to raise_error(Mxrb::ValidationError, /unknown annotation_flow node reference: missing/)
      expect do
        build_nested_flow(File.join(dir, 'Nested.mpr'))
      end.to raise_error(Mxrb::ValidationError, /must be at the flow root/)
    end
  end

  it 'rejects incomplete declarations and unsupported native endpoints' do
    builder = Mxrb::Dsl::FlowBuilder.new(
      :Invalid, runtime: :server, kind: :use_case, public: false
    )
    expect { builder.as_node(:missing) }
      .to raise_error(ArgumentError, /requires a preceding flow node/)
    builder.annotation 'Note'
    expect { builder.as_node('') }.to raise_error(ArgumentError, /cannot be empty/)
    expect { builder.annotation_flow(from: '', to: :note) }
      .to raise_error(ArgumentError, /references cannot be empty/)
    builder.annotation_flow(from: :note, to: :home)
    expect { builder.as_node(:flow) }
      .to raise_error(ArgumentError, /requires a preceding flow node/)

    exporter = Mxrb::Exporter.new('input.mpr', Dir.mktmpdir)
    flow = {
      '$Type' => 'Microflows$AnnotationFlow',
      'OriginPointer' => 'start', 'DestinationPointer' => 'missing'
    }
    expect do
      exporter.send(
        :annotation_flow_endpoint_refs,
        [{ '$ID' => 'start', '$Type' => 'Microflows$StartEvent' }], [flow]
      )
    end.to raise_error(Mxrb::SerializationError, /unsupported annotation flow endpoint/)
    flow['OriginPointer'] = 'missing'
    expect do
      exporter.send(:annotation_flow_endpoint_refs, [], [flow])
    end.to raise_error(Mxrb::SerializationError, /references a missing object/)
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

  def build_invalid_flow(path, duplicate: false, missing_destination: false)
    origin_reference = duplicate || missing_destination ? :note : :missing
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        microflow :Invalid do
          annotation 'One'
          as_node :note
          if duplicate
            annotation 'Two'
            as_node :note
          end
          show_home_page
          as_node :home
          annotation_flow from: origin_reference,
                          to: missing_destination ? :missing : :home
        end
      end
    end
  end

  def build_nested_flow(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        microflow :Nested do
          decision 'true' do
            on(true) { annotation_flow from: :note, to: :home }
            on(false) { end_flow }
          end
        end
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

  def without_connected_annotation(source, caption)
    reference = source.lines.each_cons(2).find do |annotation, _reference|
      annotation.include?(caption)
    end.last[/as_node "([^"]+)"/, 1]
    source.lines.reject do |line|
      line.include?(caption) || line.include?("as_node \"#{reference}\"") ||
        (line.include?('annotation_flow') && line.include?(reference))
    end.join
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

  def annotation_snapshot(path, flow_name: 'Annotated')
    Mxrb.open(path) do |project|
      flow = project.modules.find { _1.name == 'App' }.microflows.find { _1.name == flow_name }
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
