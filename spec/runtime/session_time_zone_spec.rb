# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# A session runs in its user's System.TimeZone when set, otherwise in the zone the
# browser reports, otherwise UTC; new users get the project's default time zone
# ("Default time zone determines the time zone for newly created users").
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Runtime::TimeZones do
  let(:store) { Mxrb::Runtime::Native::Store.new }

  it 'reads the default time zone of a project and of a Ruby application' do
    project = Object.new
    unit = { 'type' => 'settings' }
    settings = {
      '$Type' => 'Settings$ProjectSettings',
      'Settings' => Mxrb::IO::BsonCodec.build_array([{ '$Type' => 'Settings$ModelSettings',
                                                       'DefaultTimeZoneCode' => 'Europe/Amsterdam' }])
    }
    project.define_singleton_method(:all_units) { [unit] }
    project.define_singleton_method(:parse_bson) { |_unit| settings }
    expect(described_class.settings(project)).to eq('default' => 'Europe/Amsterdam')

    settings['Settings'] = Mxrb::IO::BsonCodec.build_array([{ '$Type' => 'Settings$ModelSettings' }])
    expect(described_class.settings(project)).to eq({})
    project.define_singleton_method(:parse_bson) { |_unit| { '$Type' => 'Other' } }
    expect(described_class.settings(project)).to eq({})
    expect(described_class.settings(Object.new)).to eq({})
    runtime = Struct.new(:time_zone_settings).new({ 'default' => 'Asia/Tokyo' })
    expect(described_class.settings(runtime)).to eq('default' => 'Asia/Tokyo')
  end

  it 'accepts IANA identifiers only' do
    expect(described_class.valid(' America/Sao_Paulo ')).to eq('America/Sao_Paulo')
    expect(described_class.valid('Mars/Olympus')).to be_nil
    expect(described_class.valid(nil)).to be_nil
  end

  it 'creates the missing System.TimeZone objects once, with Mendix-style descriptions' do
    described_class.synchronize(store, identifiers: %w[UTC America/New_York Asia/Kolkata])
    zones = store.retrieve('System.TimeZone').to_h { [_1.members['Code'], _1.members] }
    expect(zones.fetch('America/New_York')).to include('Description' => '(GMT-05:00) America/New_York',
                                                       'RawOffset' => -18_000_000)
    expect(zones.fetch('Asia/Kolkata')['Description']).to eq('(GMT+05:30) Asia/Kolkata')
    described_class.synchronize(store, identifiers: %w[UTC America/New_York])
    expect(store.retrieve('System.TimeZone').size).to eq(3)
  end

  it 'assigns the default zone only to new users without one' do
    schema = Object.new
    schema.define_singleton_method(:assignable?) { |entity, parent| entity == 'App.Account' && parent == 'System.User' }
    store.define_singleton_method(:schema) { schema }
    described_class.synchronize(store, identifiers: %w[Asia/Tokyo])
    tokyo = store.retrieve('System.TimeZone').first
    account = store.create('App.Account')
    described_class.assign_default(store, account, 'Asia/Tokyo')
    expect(account.members['User_TimeZone']).to eq(tokyo)

    other = store.create('App.Note')
    described_class.assign_default(store, other, 'Asia/Tokyo')
    chosen = store.create('App.Account').tap { _1.members['User_TimeZone'] = :chosen }
    described_class.assign_default(store, chosen, 'Asia/Tokyo')
    unknown = store.create('App.Account')
    described_class.assign_default(store, unknown, 'Europe/Oslo')
    described_class.assign_default(store, unknown, nil)
    expect([other, chosen, unknown].map { _1.members['User_TimeZone'] }).to eq([nil, :chosen, nil])
  end

  it 'resolves the session zone from the user, then the browser, then UTC' do
    resolver = Mxrb::RubyApp::SessionTimeZone.new(->(user) { user == 'u1' ? 'Europe/Lisbon' : nil })
    expect(resolver.call('u1', 'Asia/Tokyo')).to eq('Europe/Lisbon')
    expect(resolver.call('u2', 'Asia/Tokyo')).to eq('Asia/Tokyo')
    expect(resolver.call(nil, 'Invalid/Zone')).to eq('UTC')
    expect(Mxrb::RubyApp::SessionTimeZone.new(nil).call('u1', nil)).to eq('UTC')
  end

  context 'with the Sudoku acceptance project exported to Ruby' do
    around do |example|
      path = ENV.fetch('MXRB_ACCEPTANCE_MPRS', '').split(File::PATH_SEPARATOR)
                .find { File.basename(_1) == 'Sudoku.mpr' && File.file?(_1) }
      skip 'the Sudoku acceptance project is not present in this environment' unless path

      Dir.mktmpdir do |directory|
        FileUtils.cp_r(File.dirname(path), File.join(directory, 'source'))
        target = File.join(directory, 'ruby')
        Mxrb::Exporter.new(File.join(directory, 'source', 'Sudoku.mpr'), target, mode: :ruby).export!
        manifest = File.join(target, '.mxrb', 'ruby-app.json')
        data = JSON.parse(File.read(manifest))
        File.write(manifest, JSON.generate(data.merge('time_zone' => { 'default' => 'America/Sao_Paulo' })))
        @application = Mxrb::RubyApp::Application.new(
          target, process: { 'MXRB_DATABASE_PATH' => ':memory:', 'MXRB_ADMIN_PASSWORD' => 'Adm1n!Pass#2026' }
        )
        example.run
      ensure
        @application&.close
        Mxrb::RubyApp::Registry.reset!
      end
    end

    it 'gives new users the default zone and runs their sessions in it' do
      store = @application.send(:bridge).store
      expect(store.retrieve('System.TimeZone').size).to be > 300
      account = store.create('Administration.Account')
      account.members.merge!('Name' => 'zoned', 'Password' => 'Zoned#Pass2026',
                             'UserRoles' => store.retrieve('System.UserRole').select { _1.members['Name'] == 'User' })
      store.commit(account)
      expect(store.retrieve_association('User_TimeZone', account).first.members['Code']).to eq('America/Sao_Paulo')

      sessions = @application.session_manager
      token = sessions.login('zoned', 'Zoned#Pass2026').fetch(:token)
      expect(sessions.authenticate("Bearer #{token}", client_time_zone: 'Asia/Tokyo').attributes['time_zone'])
        .to eq('America/Sao_Paulo')
      admin = sessions.login('MxAdmin', 'Adm1n!Pass#2026').fetch(:token)
      expect(sessions.authenticate("Bearer #{admin}", client_time_zone: 'Asia/Tokyo').attributes['time_zone'])
        .to eq('America/Sao_Paulo')
      expect(sessions.anonymous(client_time_zone: 'Asia/Tokyo').attributes['time_zone']).to eq('Asia/Tokyo')
    end
  end
end
# rubocop:enable Metrics/BlockLength
