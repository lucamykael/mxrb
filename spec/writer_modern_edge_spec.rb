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

  it 'removes dangling template demo users while bootstrapping project roles' do
    raw = { 'UnitID' => 'security', 'ContainmentName' => 'ProjectDocuments' }
    existing = {
      '$ID' => 'security', '$Type' => 'Security$ProjectSecurity',
      'UserRoles' => [2], 'EnableDemoUsers' => true,
      'DemoUsers' => [2, {
        '$Type' => 'Security$DemoUserImpl', 'UserName' => 'demo_user',
        'Entity' => 'Administration.Account', 'UserRoles' => [1, 'User']
      }]
    }
    mpr = double(children_of: [raw])
    allow(mpr).to receive(:parse_contents).with(raw).and_return(existing)
    expect(mpr).to receive(:update_unit).with(
      'security', hash_including(
                    'EnableDemoUsers' => false, 'DemoUsers' => [2], 'SecurityLevel' => 'CheckNothing'
                  )
    )

    writer.send(:write_project_security, mpr, 'root', {})
  end

  it 'removes donor lifecycle callbacks from standalone project templates' do
    document = {
      'Settings' => [2,
                     { '$Type' => 'Forms$WebUIProjectSettingsPart',
                       'ThemeModuleName' => 'Donor_UI' },
                     { '$Type' => 'Settings$ModelSettings',
                       'AfterStartupMicroflow' => 'Donor.Start',
                       'BeforeShutdownMicroflow' => 'Donor.Stop',
                       'HealthCheckMicroflow' => 'Donor.Health' }]
    }

    writer.send(:sanitize_project_settings!, document)

    expect(document['Settings'][1]).to include(
      'EnableNewStringBehavior' => true, 'ThemeModuleName' => ''
    )
    expect(document['Settings'][2]).to include(
      'AfterStartupMicroflow' => '', 'BeforeShutdownMicroflow' => '',
      'HealthCheckMicroflow' => ''
    )
  end

  it 'does not require translations for non-default donor-template languages' do
    document = {
      'Settings' => [2, {
        '$Type' => 'Settings$LanguageSettings', 'DefaultLanguageCode' => 'en_US',
        'Languages' => [3,
                        { '$Type' => 'Texts$Language', 'Code' => 'en_US',
                          'CheckCompleteness' => true },
                        { '$Type' => 'Texts$Language', 'Code' => 'nl_NL',
                          'CheckCompleteness' => true }]
      }]
    }

    writer.send(:sanitize_project_settings!, document)

    languages = Mxrb::IO::BsonCodec.parse_array(document['Settings'][1]['Languages'])[:items]
    expect(languages).to contain_exactly(
      hash_including('Code' => 'en_US', 'CheckCompleteness' => true),
      hash_including('Code' => 'nl_NL', 'CheckCompleteness' => false)
    )
  end

  it 'leaves absent lifecycle fields absent and uses the prior legacy application title' do
    document = { 'Settings' => [2, { '$Type' => 'Settings$ModelSettings' }] }
    writer.send(:sanitize_project_settings!, document)
    expect(document['Settings'][1]).not_to have_key('AfterStartupMicroflow')

    profile = writer.send(
      :legacy_navigation_profile_doc,
      { role_homes: {}, role_home_details: [], app_title: {}, items: [] },
      previous: { 'ApplicationTitle' => 'Existing title' }
    )
    expect(profile['ApplicationTitle']).to eq('Existing title')
  end

  it 'writes empty navigation role-home alternatives as empty references' do
    page_home = writer.send(
      :navigation_role_home_doc, role: 'Trainee', page: 'App.TraineeOverview'
    )
    microflow_home = writer.send(
      :navigation_role_home_doc, role: 'Administrator', microflow: 'App.ACT_Home'
    )

    expect(page_home).to include(
      'Page' => 'App.TraineeOverview', 'Microflow' => ''
    )
    expect(microflow_home).to include(
      'Page' => '', 'Microflow' => 'App.ACT_Home'
    )
  end

  it 'validates incremental navigation targets and updates existing menu items' do
    missing_module = double(root_unit: { 'UnitID' => 'root' }, units_by_containment: [])
    expect do
      writer.synchronize_ruby_documents!(missing_module, module_name: 'Missing')
    end.to raise_error(Mxrb::ValidationError, /module Missing does not exist/)

    expect do
      writer.send(:synchronize_ruby_navigation_item!, double(children_of: []), 'root',
                  profile: 'Responsive', page: 'App.Home', caption: 'Home')
    end.to raise_error(Mxrb::ValidationError, /navigation document does not exist/)

    raw = { 'UnitID' => 'navigation' }
    missing_profile = { '$Type' => 'Navigation$NavigationDocument', 'Profiles' => [2] }
    mpr = double(children_of: [raw])
    allow(mpr).to receive(:parse_contents).with(raw).and_return(missing_profile)
    expect do
      writer.send(:synchronize_ruby_navigation_item!, mpr, 'root',
                  profile: 'Missing', page: 'App.Home', caption: 'Home')
    end.to raise_error(Mxrb::ValidationError, /profile Missing does not exist/)

    profile = { 'Name' => 'Responsive' }
    document = { '$Type' => 'Navigation$NavigationDocument', 'Profiles' => [2, profile] }
    allow(mpr).to receive(:parse_contents).with(raw).and_return(document)
    expect do
      writer.send(:synchronize_ruby_navigation_item!, mpr, 'root',
                  profile: 'Responsive', page: 'App.Home', caption: 'Home')
    end.to raise_error(Mxrb::ValidationError, /has no menu/)

    existing = writer.send(
      :navigation_menu_item_doc, caption: { en_US: 'Old' }, page: 'App.Home', items: []
    )
    existing['$ID'] = 'existing-id'
    profile['Menu'] = { 'Items' => Mxrb::IO::BsonCodec.build_array([existing], marker: 2) }
    expect(mpr).to receive(:update_unit).with('navigation', document)
    writer.send(:synchronize_ruby_navigation_item!, mpr, 'root',
                profile: 'Responsive', page: 'App.Home', caption: { en_US: 'New' }, home: true)
    updated = Mxrb::IO::BsonCodec.parse_array(profile.dig('Menu', 'Items'))[:items].first
    expect(updated['$ID']).to eq('existing-id')
    expect(profile.dig('HomePage', 'Page')).to eq('App.Home')

    updated.delete('$ID')
    expect(mpr).to receive(:update_unit).with('navigation', document)
    writer.send(:synchronize_ruby_navigation_item!, mpr, 'root',
                profile: 'Responsive', page: 'App.Home', caption: 'Again')
    expect(Mxrb::IO::BsonCodec.parse_array(profile.dig('Menu', 'Items'))[:items].first.fetch('$ID'))
      .not_to eq('existing-id')

    legacy = { 'DesktopProfile' => { 'Menu' => {} } }
    expect(writer.send(:ruby_navigation_profile, legacy, 'Desktop')).to eq(legacy['DesktopProfile'])
    expect(writer.send(:ruby_navigation_profile, legacy, 'Phone')).to be_nil
  end

  it 'normalizes explicitly supplied native layouts before writing Mendix 6 documents' do
    legacy = described_class.new('v6.mpr', version: '6.10.8', modules: [])
    mpr = double
    expect(legacy).to receive(:upsert_native_unit).with(
      mpr, 'module-id', hash_including(
                          'containment' => 'Documents',
                          'doc' => hash_including('$Type' => 'Forms$Layout', 'Widget' => hash_including(
                            '$Type' => 'Forms$Placeholder'
                          ))
                        )
    )
    legacy.send(
      :write_native_documents, mpr, 'module-id',
      native_documents: [{ containment: 'Documents', doc: {
        '$Type' => 'Forms$Layout', 'Name' => 'Shell'
      } }]
    )
  end

  it 'removes donor image references from standalone navigation templates' do
    document = {
      'Profiles' => [2, {
        '$Type' => 'Navigation$NavigationProfile', 'Name' => 'Responsive',
        'AppIcon' => 'Donor_UI.Images.Icon'
      }]
    }

    writer.send(:sanitize_project_navigation!, document)

    expect(document.dig('Profiles', 1, 'AppIcon')).to eq('')
  end

  it 'materializes the audited singular and plural legacy layout contracts' do
    source = { 'Name' => 'Shell', 'Appearance' => { 'Class' => 'shell', 'Style' => 'gap: 1px' } }
    oldest = described_class.new('v6.mpr', version: '6.10.8', modules: [])
                            .send(:legacy_layout_doc, source)
    modern_legacy = described_class.new('v717.mpr', version: '7.17.0', modules: [])
                                   .send(:legacy_layout_doc, source.merge('$ID' => 'layout-id'))

    expect(oldest).to include('MainPlaceholderName' => 'Main', 'Widget' => hash_including(
      '$Type' => 'Forms$Placeholder'
    ))
    expect(oldest).not_to have_key('Widgets')
    expect(modern_legacy).to include('$ID' => 'layout-id', 'Widgets' => [2, hash_including(
      '$Type' => 'Forms$Placeholder'
    )])
  end

  it 'normalizes nested legacy widgets and singular cardinalities' do
    legacy = described_class.new('v6.mpr', version: '6.10.8', modules: [])
    tree = {
      '$Type' => 'Forms$DataView', 'Other' => 'kept', 'Metadata' => { 'Flag' => true },
      'Widgets' => [2, { '$Type' => 'Forms$DivContainer', 'Widgets' => [2] },
                    { '$Type' => 'Forms$TabPage', 'Widgets' => [2, { 'Name' => 'Only' }] }],
      'FooterWidgets' => [2, { 'Name' => 'First' }, { 'Name' => 'Second' }]
    }

    normalized = legacy.send(:legacy_widget_tree, tree)
    expect(normalized['Widget']['$Type']).to eq('Forms$VerticalFlow')
    expect(normalized['Widget']['Widgets'][1]['Widget']).to be_nil
    expect(normalized['Widget']['Widgets'][2]['Widget']).to eq('Name' => 'Only')
    expect(normalized['FooterWidget']['$Type']).to eq('Forms$VerticalFlow')
    expect(normalized['Other']).to eq('kept')
    expect(normalized['Metadata']).to eq('Flag' => true)
    expect(legacy.send(:legacy_widget_tree, '$Type' => 'Forms$DivContainer'))
      .not_to have_key('Widget')
  end

  it 'covers legacy navigation and singular page decisions without donor references' do
    legacy = described_class.new('v6.mpr', version: '6.10.8', modules: [])
    navigation = legacy.send(:legacy_navigation_doc, {}, profiles: [{
      name: 'Responsive', home_page: nil, home_microflow: nil,
      role_homes: { 'User' => 'App.Home' }, role_home_details: [],
      app_title: 'Plain title', items: [], kind: nil
    }])
    page = legacy.send(:page_doc, {
      name: 'Home', layout: 'App.Shell', title: 'Home', widgets: [], events: [],
      allowed_roles: nil, popup: false, data_source: nil
    })

    expect(navigation).to have_key('DesktopProfile')
    expect(navigation.dig('DesktopProfile', 'ApplicationTitle')).to eq('Plain title')
    expect(navigation.dig('DesktopProfile', 'HomeItems', 1, 'Page')).to eq('App.Home')
    expect(navigation.fetch('DesktopProfile')).not_to have_key('Kind')
    expect(page.dig('FormCall', 'Arguments', 1)).to have_key('Widget')
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

  it 'preserves localized native validation rules until explicitly disabled' do
    native_rule = {
      '$ID' => 'rule', '$Type' => 'DomainModels$ValidationRule',
      'Attribute' => 'Catalog.Item.Name',
      'Message' => {
        '$ID' => 'message', '$Type' => 'Texts$Text',
        'Items' => Mxrb::IO::BsonCodec.build_array([
                                                     { 'LanguageCode' => 'en_US',
                                                       'Text' => 'Name is required' },
                                                     { 'LanguageCode' => 'nl_NL',
                                                       'Text' => 'Naam is verplicht' }
                                                   ])
      },
      'RuleInfo' => { '$ID' => 'info', '$Type' => 'DomainModels$RequiredRuleInfo' }
    }
    previous = Mxrb::IO::BsonCodec.build_array([native_rule])

    preserved = writer.send(
      :validation_rules_doc,
      { name: 'Item', attributes: [{ name: 'Name', required: true }] }, 'Catalog', previous
    )
    expect(Mxrb::IO::BsonCodec.parse_array(preserved)[:items]).to eq([native_rule])

    removed = writer.send(
      :validation_rules_doc,
      { name: 'Item', attributes: [{ name: 'Name', required: false }] }, 'Catalog', previous
    )
    expect(Mxrb::IO::BsonCodec.parse_array(removed)[:items]).to be_empty

    generated = writer.send(
      :validation_rules_doc,
      { name: 'Item', attributes: [{ name: 'Name', unique: true }] }, 'Catalog', previous
    )
    expect(Mxrb::IO::BsonCodec.parse_array(generated)[:items]).to contain_exactly(
      native_rule, hash_including(
                     'Attribute' => 'Catalog.Item.Name',
                     'RuleInfo' => hash_including('$Type' => 'DomainModels$UniqueRuleInfo')
                   )
    )
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
