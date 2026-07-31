# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Writer, 'modern storage edge contracts' do
  subject(:writer) { described_class.new('model.mpr', version: '11.12.1', modules: []) }

  it 'repairs an empty project security document' do
    security = { 'UnitID' => 'security', 'ContainmentName' => 'ProjectDocuments' }
    navigation = { 'UnitID' => 'navigation', 'ContainmentName' => 'ProjectDocuments' }
    documents = {
      'security' => { '$Type' => 'Security$ProjectSecurity', 'UserRoles' => [2] },
      'navigation' => { '$Type' => 'Navigation$NavigationDocument', 'Profiles' => [2] }
    }
    mpr = double(children_of: [security, navigation])
    allow(mpr).to receive(:parse_contents) { |raw| documents.fetch(raw['UnitID']) }
    expect(writer).to receive(:write_project_security).with(mpr, 'root', {})
    writer.send(:ensure_project_documents, mpr, 'root')
  end

  it 'inserts absent security and navigation project documents' do
    mpr = double(children_of: [])
    expect(mpr).to receive(:insert_unit).with(
      container_uuid: 'root', containment_name: 'ProjectDocuments',
      contents_doc: hash_including('$Type' => 'Security$ProjectSecurity')
    )
    writer.send(:write_project_security, mpr, 'root', user_roles: [])

    expect(mpr).to receive(:insert_unit).with(
      container_uuid: 'root', containment_name: 'ProjectDocuments',
      contents_doc: hash_including('$Type' => 'Navigation$NavigationDocument')
    )
    writer.send(:write_project_navigation, mpr, 'root', profiles: [])
  end

  it 'preserves legacy page widgets only for generated shallow structures' do
    existing = {
      '$ID' => 'page', '$Type' => 'Pages$Page', 'Widgets' => [3, { 'Name' => 'Native' }],
      'Parameters' => [3, { 'Name' => 'Object' }]
    }
    shallow = {
      '$ID' => 'new', '$Type' => 'Pages$Page', '__mxrb_deep_structure_declared' => false
    }
    merged = writer.send(:merge_existing_document, existing, shallow)
    expect(merged).to include('Widgets' => existing['Widgets'], 'Parameters' => existing['Parameters'])

    deep = shallow.merge(
      '__mxrb_deep_structure_declared' => true,
      'Widgets' => [3, { 'Name' => 'Generated' }]
    )
    expect(writer.send(:merge_existing_document, existing, deep)['Widgets'])
      .to eq(deep['Widgets'])
  end

  it 'replaces modern typed page content while preserving unsupported metadata' do
    existing = {
      '$ID' => 'page', '$Type' => 'Forms$Page',
      'FormCall' => { 'Form' => 'Ui.OldLayout' },
      'Title' => { 'Items' => [3, { 'Text' => 'Old title' }] },
      'PopupWidth' => 300, 'Parameters' => [3, { 'Name' => 'Context' }],
      'Appearance' => { 'Class' => 'native-page' }, 'MarkAsUsed' => true
    }
    generated = {
      '$ID' => 'new', '$Type' => 'Forms$Page',
      'FormCall' => { 'Form' => 'Ui.ApplicationLayout' },
      'Title' => { 'Items' => [3, { 'Text' => 'New title' }] },
      'PopupWidth' => 0, '__mxrb_deep_structure_declared' => false
    }

    merged = writer.send(:merge_existing_document, existing, generated)

    expect(merged.dig('FormCall', 'Form')).to eq('Ui.ApplicationLayout')
    expect(merged.dig('Title', 'Items', 1, 'Text')).to eq('New title')
    expect(merged['PopupWidth']).to eq(0)
    expect(merged).to include(
      'Parameters' => existing['Parameters'],
      'Appearance' => existing['Appearance'], 'MarkAsUsed' => true
    )
  end

  it 'writes modern visible text content and div containers' do
    text = writer.send(
      :widget_doc,
      type: :text, name: 'heading', options: { caption: 'Visible heading' }, events: []
    )
    container = writer.send(
      :widget_doc,
      type: :container, name: 'card', options: { class: 'dashboard-card' }, children: [], events: []
    )

    expect(text).to include('$Type' => 'Forms$DynamicText')
    expect(text.dig('Content', '$Type')).to eq('Forms$ClientTemplate')
    expect(text.dig('Content', 'Template', 'Items', 1, 'Text')).to eq('Visible heading')
    expect(container).to include('$Type' => 'Forms$DivContainer')
    expect(container.dig('Appearance', 'Class')).to eq('dashboard-card')
  end

  it 'does not duplicate existing parameters generated with the same name' do
    parameter = {
      '$ID' => 'old', '$Type' => 'Microflows$MicroflowParameter', 'Name' => 'Animal'
    }
    annotation = { '$ID' => 'note', '$Type' => 'Microflows$Annotation' }
    target = {
      'ObjectCollection' => { 'Objects' => [3, {
        '$ID' => 'new', '$Type' => 'Microflows$MicroflowParameter', 'Name' => 'Animal'
      }] }, 'Flows' => [3]
    }
    source = { 'ObjectCollection' => { 'Objects' => [3, parameter, annotation] }, 'Flows' => [3] }
    writer.send(:preserve_flow_auxiliary_objects, target, source)
    objects = Mxrb::IO::BsonCodec.parse_array(target.dig('ObjectCollection', 'Objects'))[:items]
    expect(objects.count { _1['$Type'] == 'Microflows$MicroflowParameter' }).to eq(1)
    expect(objects.map { _1['$Type'] }).to include('Microflows$Annotation')
  end

  it 'writes supported schedules and rejects unsupported intervals and units' do
    expect(writer.send(:scheduled_event_schedule_doc, unit: :minutes, interval: 5))
      .to include('$Type' => 'ScheduledEvents$MinuteSchedule', 'Multiplier' => 5)
    expect(writer.send(:scheduled_event_schedule_doc, unit: :hours, interval: 2))
      .to include('$Type' => 'ScheduledEvents$HourSchedule', 'MinuteOffset' => 0)
    expect(writer.send(:scheduled_event_schedule_doc, unit: :days, interval: 1))
      .to include('$Type' => 'ScheduledEvents$DaySchedule')
    expect do
      writer.send(:scheduled_event_schedule_doc, unit: :days, interval: 2)
    end.to raise_error(ArgumentError, /interval/)
    expect do
      writer.send(:scheduled_event_schedule_doc, unit: :weeks, interval: 1)
    end.to raise_error(ArgumentError, /modern schedules/)
  end
end
# rubocop:enable Metrics/BlockLength
