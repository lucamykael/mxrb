# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'native mobile navigation profiles' do
  def define_native_profile_project(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:App) do
        module_role :User
        page(:Home) { allowed_roles :User }
        page(:Tasks) { allowed_roles :User }
      end
      security do
        security_level :CheckEverything
        user_role :User, module_roles: ['App.User']
      end
      navigation do
        profile :Responsive, home_page: 'App.Home'
        profile :NativePhone, kind: 'Native', home_page: 'App.Home',
                              settings: { ota_enabled: true, network_timeout_ms: 30_000 } do
          home_for :User, page: 'App.Tasks'
          bottom_bar_item 'Home', page: 'App.Home', icon: { collection: 'Atlas_Core.Atlas_Filled.home' }
          bottom_bar_item 'Tasks', page: 'App.Tasks', translations: { nl_NL: 'Taken' }
        end
      end
    end
  end

  def native_profile_document(path)
    mpr = Mxrb::IO::MprFile.open(path, readonly: true)
    document = mpr.all_units.map { mpr.parse_contents(_1) }
                  .find { _1['$Type'] == 'Navigation$NavigationDocument' }
    Mxrb::IO::BsonCodec.parse_array(document['Profiles']).fetch(:items)
                       .find { _1['$Type'] == Mxrb::Model::NativeNavigationProfile::TYPE }
  ensure
    mpr&.close
  end

  it 'writes a native profile with its home pages, bottom bar and settings' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app.mpr')
      define_native_profile_project(path)

      document = native_profile_document(path)
      expect(document.keys).not_to include('HomePage', 'HomeItems', 'Menu', 'Kind')
      expect(document).to include('Name' => 'NativePhone', 'OtaEnabled' => true, 'NetworkTimeoutMs' => 30_000,
                                  'LoggingEnabled' => false, 'ScreenNavigationTransition' => 'SystemDefault')
      expect(document.dig('NativeHomePage', '$Type')).to eq('Navigation$NativeHomePage')

      profile = Mxrb.open(path) { |project| project.navigation.profiles.fetch(1).to_h }
      expect(profile).to include(
        name: 'NativePhone', kind: 'Native', home_page: 'App.Home', home_nanoflow: nil,
        role_homes: [{ role: 'User', page: 'App.Tasks' }], throw_partial_sync_error: true
      )
      expect(profile.fetch(:bottom_bar)).to eq([
                                                 { caption: { 'en_US' => 'Home' }, page: 'App.Home',
                                                   icon: { collection: 'Atlas_Core.Atlas_Filled.home' } },
                                                 { caption: { 'en_US' => 'Tasks', 'nl_NL' => 'Taken' },
                                                   page: 'App.Tasks' }
                                               ])
      expect(profile.dig(:settings, :ota_enabled)).to be(true)
    end
  end

  it 'exports a native profile and rebuilds it identically' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app.mpr')
      exported = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt', 'app.mpr')
      define_native_profile_project(path)

      Mxrb::Exporter.new(path, exported).export!
      expect(File.read(File.join(exported, 'app', 'navigation', 'navigation.rb'))).to include(
        'profile :NativePhone, kind: "Native", home_page: "App.Home"', 'home_for "User", page: "App.Tasks"',
        'bottom_bar_item "Tasks", page: "App.Tasks", translations: {nl_NL: "Taken"}'
      )
      begin
        ENV['MXRB_OUTPUT_PATH'] = rebuilt
        load File.join(exported, 'project.rb')
      ensure
        ENV.delete('MXRB_OUTPUT_PATH')
      end
      expect(Mxrb.compare(path, rebuilt)).to be_identical
      expect(Mxrb.validate(rebuilt)).to be_valid
    end
  end

  it 'adds and promotes Ruby page declarations in a native bottom bar' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'app.mpr')
      define_native_profile_project(path)
      mpr = Mxrb::IO::MprFile.open(path, readonly: false)
      writer = Mxrb::Writer.new(path, version: '11.12.1', modules: [])
      writer.send(:synchronize_ruby_navigation!, mpr, mpr.root_unit.fetch('UnitID'), [
                    { page: 'App.Tasks', caption: 'All tasks', profile: 'NativePhone',
                      icon: nil, home: true },
                    { page: 'App.Settings', caption: { 'en_US' => 'Settings' },
                      profile: 'NativePhone', icon: nil, home: false }
                  ])
      mpr.close

      profile = Mxrb.open(path) { |project| project.navigation.profiles.fetch(1).to_h }
      expect(profile.fetch(:home_page)).to eq('App.Tasks')
      expect(profile.fetch(:bottom_bar).map { [_1.dig(:caption, 'en_US'), _1.fetch(:page)] })
        .to eq([['Home', 'App.Home'], ['All tasks', 'App.Tasks'], ['Settings', 'App.Settings']])
      expect(native_profile_document(path).dig('BottomBarItems', 0)).to eq(2)
    end
  end

  it 'covers the optional native profile surface' do
    profile = Mxrb::Model::NativeNavigationProfile.new(
      'Name' => 'Bare', 'BottomBarItems' => [
        2, { 'Caption' => nil, 'Icon' => { '$Type' => 'Forms$GlyphIcon', 'Code' => 7 }, 'Page' => 'App.Home' },
        { 'Caption' => nil, 'Icon' => nil, 'Page' => '' }
      ]
    )
    expect(profile.bottom_bar_items).to eq([{ caption: {}, page: 'App.Home', icon: 7 }, { caption: {} }])
    expect(profile.to_h).to include(home_page: nil, role_homes: [], settings: {})

    writer = Mxrb::Writer.new('unused.mpr', version: '11.12.1', modules: [])
    existing = writer.send(:modern_navigation_doc, {}, profiles: [{ name: 'NativePhone', kind: 'Native' }])
    previous = Mxrb::IO::BsonCodec.parse_array(existing['Profiles']).fetch(:items).first
    updated = writer.send(:modern_navigation_doc, existing, profiles: [
                            { name: 'NativePhone', home_nanoflow: 'App.Start', throw_partial_sync_error: false,
                              role_homes: { User: 'App.Home' } }
                          ])
    native = Mxrb::IO::BsonCodec.parse_array(updated['Profiles']).fetch(:items).first
    expect(native).to include('$ID' => previous['$ID'], '$Type' => Mxrb::Model::NativeNavigationProfile::TYPE,
                              'ThrowPartialSyncError' => false)
    expect(native.dig('NativeHomePage', 'HomePageNanoflow')).to eq('App.Start')
    expect(native.dig('RoleBasedNativeHomePages', 1)).to include('UserRole' => 'User', 'HomePagePage' => 'App.Home')

    exporter = Mxrb::Exporter.new('unused.mpr', Dir.mktmpdir)
    source = exporter.send(:navigation_source, profiles: [
                             { name: 'Bare', kind: 'Native' },
                             { name: 'Full', kind: 'Native', home_nanoflow: 'App.Start',
                               throw_partial_sync_error: false, role_homes: { 'User' => 'App.Home' },
                               role_home_details: [{ role: 'Guest', nanoflow: 'App.Start' }],
                               bottom_bar: [{ caption: { 'nl_NL' => 'Thuis' }, page: 'App.Home', icon: 7 },
                                            { caption: {}, page: 'App.Other' }] }
                           ])
    expect(source).to include(
      "profile :Bare, kind: \"Native\"\n", 'home_nanoflow: "App.Start"', 'throw_partial_sync_error: false',
      'home_for "User", page: "App.Home"', 'home_for "Guest", nanoflow: "App.Start"',
      'bottom_bar_item "Thuis", page: "App.Home", icon: 7, translations: {"nl_NL" => "Thuis"}',
      'bottom_bar_item "", page: "App.Other"'
    )
  end

  it 'rejects unknown native navigation settings and accepts nanoflow role homes' do
    builder = Mxrb::Dsl::NavigationProfileBuilder.new(:NativePhone)
    builder.home_for(:User, nanoflow: :App_Start)
    expect(builder.to_h.fetch(:role_home_details)).to eq([{ role: 'User', nanoflow: 'App_Start' }])
    expect { Mxrb::Dsl::NavigationProfileBuilder.new(:NativePhone, settings: { offline_sync: true }) }
      .to raise_error(ArgumentError, /unknown native navigation settings: offline_sync/)
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
