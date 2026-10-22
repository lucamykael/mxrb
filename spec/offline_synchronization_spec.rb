# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The synchronization an offline profile runs against /api/sync: uploads of
# created, changed and deleted objects in one transaction, then the download
# of the entities the profile synchronizes under their constraints.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::Application::OfflineSynchronization do
  let(:fixture) { 'spec/fixtures/native_nanoflow_data' }

  around do |example|
    Dir.mktmpdir do |directory|
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      source = File.join(directory, 'Nanoflows.mpr')
      ENV['MXRB_OUTPUT_PATH'] = source
      load File.join(fixture, 'project.rb')
      @target = File.join(directory, 'ruby')
      Mxrb::Exporter.new(source, @target, mode: :ruby).export!
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def application(profiles)
    @application = Mxrb::RubyApp::Application.new(@target, process: {})
    navigation = { 'profiles' => profiles }
    allow(@application.manifest).to(receive(:data).and_wrap_original { _1.call.merge('navigation' => navigation) })
    @application
  end

  # The native profile reaches the manifest the way the exporter writes the
  # typed navigation document: JSON with string keys.
  let(:native_profile) do
    document = {
      'Name' => 'NativePhone', 'OfflineEntityConfigs' => [
        3, { 'Entity' => 'Probe.Row', 'SyncMode' => 'All', 'Constraint' => '[Rank >= 2]' },
        { 'Entity' => 'Probe.Item', 'SyncMode' => 'NoneAndPreserveData' }
      ]
    }
    JSON.parse(JSON.generate(Mxrb::Model::NativeNavigationProfile.new(document).to_h))
  end

  let(:profiles) do
    [
      { 'name' => 'Responsive', 'kind' => 'Responsive' },
      native_profile,
      { 'name' => 'Field', 'kind' => 'Phone', 'offline' => true, 'offline_entities' => [
        { 'entity' => 'Probe.Item', 'sync_mode' => 'None' }
      ] },
      { 'name' => 'Desk', 'kind' => 'ResponsiveOffline', 'offline' => true, 'offline_entities' => [
        { 'entity' => 'Probe.Row', 'sync_mode' => 'All', 'constraint' => '' }
      ] },
      { 'name' => 'Bare', 'kind' => 'Native' }
    ]
  end

  it 'describes the offline profiles and refuses what it does not have' do
    app = application(profiles)
    configuration = app.offline_configuration
    expect(configuration).to include(profile: 'NativePhone')
    expect(configuration[:entities]).to eq([
                                             { entity: 'Probe.Row', sync_mode: 'All', constraint: '[Rank >= 2]' },
                                             { entity: 'Probe.Item', sync_mode: 'NoneAndPreserveData',
                                               constraint: '' }
                                           ])
    expect(Time.iso8601(configuration[:synchronized_at])).to be_within(60).of(Time.now)
    expect(app.offline_configuration(profile: 'Field')[:entities].map { _1[:sync_mode] }).to eq(['None'])
    expect(app.offline_configuration(profile: 'Bare')).to include(profile: 'Bare', entities: [])
    expect { app.offline_configuration(profile: 'Responsive') }
      .to raise_error(Mxrb::NotFoundError, /no offline profile Responsive/)
    expect { application([]).offline_configuration }.to raise_error(Mxrb::NotFoundError, /no offline profile/)
    odd = [{ 'entity' => 'Probe.Row', 'sync_mode' => 'Some' }]
    broken = application([{ 'name' => 'Odd', 'offline_entities' => odd }])
    expect { broken.offline_configuration }.to raise_error(ArgumentError, /unknown offline sync mode "Some"/)
  end

  it 'uploads changes in one transaction, maps new identities and downloads the constrained entities' do
    app = application(profiles)
    item = app.call_service('Probe.Load')
    rows = app.records('Probe.Row')
    north = rows.find { _1[:attributes]['Name'] == 'North' }
    south = rows.find { _1[:attributes]['Name'] == 'south' }
    result = app.synchronize_offline({
                                       'profile' => 'NativePhone',
                                       'changes' => [
                                         { 'type' => 'Probe.Row', 'id' => 'local-1', 'new_record' => true,
                                           'attributes' => { 'Name' => 'Fresh', 'Rank' => 9,
                                                             'Row_Item' => { 'type' => 'Probe.Item',
                                                                             'id' => item[:id] } } },
                                         { 'type' => 'Probe.Row', 'id' => north[:id],
                                           'attributes' => { 'Name' => 'Renamed' } },
                                         { 'type' => 'Probe.Row', 'id' => 'gone',
                                           'attributes' => { 'Name' => 'Lost' } },
                                         { 'type' => 'Probe.Row', 'id' => south[:id], 'deleted' => true },
                                         { 'type' => 'Probe.Row', 'id' => 'already-gone', 'deleted' => true }
                                       ]
                                     })
    expect(result).to include(ok: true, profile: 'NativePhone',
                              conflicts: [{ type: 'Probe.Row', id: 'gone', reason: 'deleted' }])
    fresh_id = result[:guid_map].fetch('local-1')
    expect(result[:uploaded].map { _1[:attributes]['Name'] }).to eq(%w[Fresh Renamed])
    expect(result[:uploaded].first).not_to have_key(:draft_id)
    downloaded = result[:entities]
    expect(downloaded.map { _1[:entity] }).to eq(['Probe.Row', 'Probe.Item'])
    expect(downloaded.last).to eq(entity: 'Probe.Item', sync_mode: 'NoneAndPreserveData', constraint: '')
    names = downloaded.first[:records].map { _1[:attributes]['Name'] }
    expect(names).to include('Fresh', 'Renamed')
    expect(names).not_to include('south')
    expect(app.record('Probe.Row', fresh_id)[:attributes]).to include('Name' => 'Fresh', 'Rank' => 9)
    expect(app.record('Probe.Row', south[:id])).to be_nil

    everything = app.synchronize_offline({ 'profile' => 'Desk', 'changes' => [] })[:entities].first
    expect(everything[:records].map { _1[:attributes]['Name'] }).to include('Fresh', 'Renamed')

    subset = app.synchronize_offline({ 'profile' => 'NativePhone', 'changes' => [], 'entities' => ['Probe.Item'] })
    expect(subset[:entities].map { _1[:entity] }).to eq(['Probe.Item'])
    objects = app.synchronize_offline({
                                        'profile' => 'NativePhone',
                                        'changes' => [{ 'type' => 'Probe.Row', 'id' => fresh_id,
                                                        'attributes' => { 'Name' => 'Fresher' } }],
                                        'objects' => [{ 'type' => 'Probe.Row', 'id' => fresh_id },
                                                      { 'type' => 'Probe.Row', 'id' => 'missing' }]
                                      })
    expect(objects[:objects].map { _1 && _1[:attributes]['Name'] }).to eq(['Fresher', nil])
    expect(objects).not_to have_key(:entities)
  end

  it 'keeps every change pending when one of them is invalid and rejects malformed payloads' do
    app = application(profiles)
    app.call_service('Probe.Load')
    before = app.records('Probe.Row').map { _1[:id] }.sort
    expect do
      app.synchronize_offline({
                                'profile' => 'NativePhone',
                                'changes' => [
                                  { 'type' => 'Probe.Row', 'id' => 'local-2', 'new_record' => true,
                                    'attributes' => { 'Name' => 'Pending', 'Rank' => 1 } },
                                  { 'type' => 'Probe.Row', 'id' => before.first, 'deleted' => true },
                                  { 'type' => 'Probe.Row', 'id' => 'local-3', 'new_record' => true,
                                    'attributes' => { 'Name' => 'Broken', 'Rank' => 'x' } }
                                ]
                              })
    end.to raise_error(StandardError)
    expect(app.records('Probe.Row').map { _1[:id] }.sort).to eq(before)
    expect { app.synchronize_offline('changes') }.to raise_error(ArgumentError, /payload must be an object/)
    expect { app.synchronize_offline({ 'changes' => [{ 'type' => 'Probe.Row' }] }) }
      .to raise_error(ArgumentError, /changes must be objects/)
    expect { app.synchronize_offline({ 'changes' => [], 'entities' => 'Probe.Row' }) }
      .to raise_error(ArgumentError, /entities must be a list/)
    expect { app.synchronize_offline({ 'changes' => [], 'objects' => [{ 'type' => 'Probe.Row' }] }) }
      .to raise_error(ArgumentError, /objects must have type and id/)
  end

  it 'hides the entities a user may not read' do
    app = application(profiles)
    allow(app).to receive(:access_control).and_return(double(entity_allowed?: false))
    context = double(user: 'ada')
    expect(app.offline_configuration(context:)[:entities]).to eq([])
    denied = double
    allow(denied).to receive(:entity_allowed?).and_raise(Mxrb::Runtime::AuthorizationError, 'no')
    allow(app).to receive(:access_control).and_return(denied)
    expect(app.offline_configuration(context:)[:entities]).to eq([])
  end
end
# rubocop:enable Metrics/BlockLength
