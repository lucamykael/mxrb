# frozen_string_literal: true

require 'base64'
require 'spec_helper'

# These examples exercise the public Ruby representation at its optional
# boundaries. They intentionally use real builders so coverage proves that the
# exported source can be evaluated, rather than merely checking serializer
# helpers in isolation.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'complete Ruby projection contracts' do
  let(:uuid) { '11111111-1111-4111-8111-111111111111' }

  def id(number)
    format('00000000-0000-4000-8000-%012d', number)
  end

  def bson_array(items, marker = 3)
    Mxrb::IO::BsonCodec.build_array(items, marker:)
  end

  it 'evaluates every recursive document and code-action representation' do
    builder = Mxrb::Dsl::ModuleBuilder.new('App')
    binary = BSON::Binary.new('native')
    node = {
      node_type: 'Forms$DivContainer', id: uuid,
      fields: {
        'Children' => { collection: [{ map: { 'Caption' => 'Child' } }], marker: 3 },
        'Payload' => { binary: Base64.strict_encode64('payload'), subtype: :generic }
      }
    }
    appearance = [{ map: { 'Class' => 'shell' } }]

    builder.layout_document(
      :Shell, appearance:, canvas_height: 600, canvas_width: 800, content: node
    )
    builder.page_template_document(
      :Starter, appearance:, canvas_height: 600, canvas_width: 800,
                display_name: 'Starter', documentation: '', documentation_url: '', excluded: false,
                export_level: 'Hidden', image: binary, layout_call: node,
                template_category: 'General', template_category_weight: 1, template_type: node
    )
    builder.building_block_document(
      :Card, canvas_height: 200, canvas_width: 300, display_name: 'Card',
             documentation: '', documentation_url: '', excluded: false, export_level: 'Hidden',
             image: binary, platform: 'Web', template_category: 'General',
             template_category_weight: 1, widgets: { collection: [node] }
    )
    builder.snippet_document(
      :Summary, canvas_height: 200, canvas_width: 300, documentation: '', excluded: false,
                export_level: 'Hidden', parameters: { collection: [] }, snippet_type: 'Web',
                variables: { collection: [] }, widgets: { collection: [node] }
    )

    info = {
      caption: 'Run', category: 'Tests', icon: binary,
      icon_dark: { data: Base64.strict_encode64('dark') },
      image: { data: Base64.strict_encode64('image') }, image_dark: binary
    }
    parameters = [
      { name: 'basic', type: { kind: :basic, type: { kind: :string } } },
      { name: 'template', type: { kind: :string_template, grammar: 'Text' } },
      { name: 'entity', type: { kind: :entity_type_parameter, pointer: uuid } },
      { name: 'flow', type: { kind: :microflow } }
    ]
    builder.java_action(
      :Run, parameters:, return_type: { kind: :concrete_entity, entity: 'App.Item' },
            type_parameters: [{ id: uuid, name: 'Entity' }], microflow_info: info
    )
    builder.javascript_action(
      :Notify, parameters: [], return_type: {
        kind: :list, parameter: { kind: :enumeration, enumeration: 'App.Status' }
      }, platform: 'Web'
    )
    builder.published_rest_service(
      :Api, path: '/api', version: '1', resources: [],
            authentication_types: %i[basic custom], enable_cors: false,
            requires_authentication: true
    )
    builder.custom_icon_collection(
      :Icons, collection_class: 'icons', prefix: 'i', font: binary,
              icons: [{ name: 'ok', character_code: 1 }]
    )

    expect(builder.native_documents.map { _1.fetch(:type) }).to include(
      'Forms$Layout', 'Forms$PageTemplate', 'Forms$BuildingBlock', 'Forms$Snippet',
      'JavaActions$JavaAction', 'JavaScriptActions$JavaScriptAction',
      'Rest$PublishedRestService', 'CustomIcons$CustomIconCollection'
    )
    expect do
      builder.java_action(
        :Bad, parameters: [{ name: 'x', type: { kind: :unsupported } }],
              return_type: { kind: :void }
      )
    end.to raise_error(ArgumentError, /unsupported code action parameter type/)
    expect do
      builder.java_action(:Bad, parameters: [], return_type: { kind: :unsupported })
    end.to raise_error(ArgumentError, /unsupported code action data type/)
    expect(builder.send(:database_query_type, 7)).to eq(7)
  end

  it 'evaluates menus, pages, widgets, flow types, and native flow activities' do
    binary = Base64.strict_encode64('payload')
    menu = Mxrb::Dsl::MenuBuilder.new('Main')
    menu.deep_structure('Name' => 'Main')
    menu.form_structure(map: { 'Items' => [] })
    expect(menu.bson_binary(binary).data).to eq('payload')
    expect { menu.deep_structure([]) }.to raise_error(ArgumentError)
    expect { menu.form_structure([]) }.to raise_error(ArgumentError)

    page = Mxrb::Dsl::PageBuilder.new('Home')
    page.radio_button_group(:Choice, horizontal: true)
    page.page_title(:Title)
    page.static_image(:Logo, image: 'App.Images.logo')
    page.deep_structure('Name' => 'Home')
    page.form_structure(map: { 'Widgets' => [] })
    expect(page.bson_binary(binary).data).to eq('payload')
    expect { page.deep_structure([]) }.to raise_error(ArgumentError)
    expect { page.form_structure([]) }.to raise_error(ArgumentError)

    flow = Mxrb::Dsl::FlowBuilder.new('Run', runtime: :server, kind: :use_case, public: false)
    flow.execute_database_query('SELECT 1', as: :rows, dynamic_query: '$query',
                                            parameters: { id: '$id' }, connection_parameters: { host: '$host' })
    flow.import_xml('$document', mapping: 'App.Import', as: :items, result_entity: 'App.Item')
    flow.download_file('$file', show_in_browser: true)
    expect(flow.flow_type(kind: :object, entity: 'App.Item', id: uuid)).to include(
      '$Type' => 'DataTypes$ObjectType', 'Entity' => 'App.Item', '$ID' => uuid
    )
    expect(flow.bson_binary(binary).data).to eq('payload')
    expect { flow.flow_type(kind: :unsupported) }.to raise_error(ArgumentError)
    expect(flow.to_h.fetch(:body)).to include(
      include(type: :execute_database_query), include(type: :import_xml),
      include(type: :download_file)
    )
  end

  it 'expresses native entity behavior and project security in Ruby application classes' do
    record = Class.new(Mxrb::RubyApp::Record)
    record.mendix_name('App.Item')
    record.attribute(:name, type: :string, mendix_name: 'Name')
    record.attribute(:code, type: :string, mendix_name: 'Code')
    record.generalizes('App.Base', id: uuid)
    record.oql_view(source: 'App.ItemSource', query: 'SELECT Name',
                    document_id: uuid, source_id: uuid)
    record.index(:name, :code, ascending: [true, false])
    record.before_commit microflow: 'App.Validate', id: uuid
    record.after_commit microflow: 'App.Notify', raise_error_on_false: true
    record.validation_rule(:name, kind: :required)

    expect(record.generalization).to eq(target: 'App.Base', id: uuid)
    expect(record.oql_view_definition).to include(source: 'App.ItemSource', query: 'SELECT Name')
    expect(record.indexes.first.fetch(:members).map { _1.fetch(:ascending) }).to eq([true, false])
    expect(record.native_lifecycle_definitions.map { _1.fetch(:event) })
      .to eq(%i[before_commit after_commit])
    expect { record.generalizes('') }.to raise_error(ArgumentError)
    expect { record.oql_view }.to raise_error(ArgumentError)
    expect { record.index(:name, :code, ascending: [true, false, true]) }
      .to raise_error(ArgumentError)
    expect { record.before_commit(:callback, microflow: 'App.Validate') }
      .to raise_error(ArgumentError)

    security = Class.new(Mxrb::RubyApp::ProjectSecurity)
    security.mendix_id(uuid)
    security.demo_user('manager', entity: 'Administration.Account', roles: ['Administrator'],
                                  password: 'secret')
    expect(security.demo_user_definitions.first).to include(name: 'manager', password: 'secret')
  end

  it 'serializes security and scheduled-event documents with stable native identities' do
    writer = Mxrb::Writer.new('/tmp/projection.mpr', version: '11.12.1', modules: [])
    opaque = { '$ID' => id(90), '$Type' => 'Vendor$Role', 'Value' => true }
    previous_module = {
      '$ID' => id(1), '$Type' => 'Security$ModuleSecurity', 'Extension' => 'kept',
      'ModuleRoles' => bson_array([
                                    { '$ID' => id(2), '$Type' => 'Security$ModuleRole', 'Name' => 'User' }, opaque
                                  ])
    }
    module_security = writer.send(
      :ruby_module_security_doc,
      { id: id(1), roles: [{ id: id(2), name: 'User', description: 'Can use' }] },
      previous_module, 'App'
    )
    expect(Mxrb::IO::BsonCodec.parse_array(module_security['ModuleRoles'])[:items])
      .to include(include('Name' => 'User', 'Description' => 'Can use'), opaque)

    declaration = {
      id: id(3), security_level: 'Production', admin_user_role: 'Administrator',
      demo_users_enabled: true, guest_access_enabled: false, guest_user_role: '',
      sign_in_microflow: 'App.SignIn',
      user_roles: [
        { id: id(4), guid: id(5), name: 'Administrator', manage_all_roles: true,
          module_roles: [], manageable_roles: ['User'] },
        { id: id(6), name: 'User', module_roles: ['System.User', 'App.User'] }
      ],
      demo_users: [
        { id: id(7), name: 'manager', password: 'secret', entity: 'System.User',
          roles: ['Administrator'] }
      ],
      password_policy: { id: id(8), properties: { 'MinimumLength' => 12 } }
    }
    security = writer.send(:ruby_project_security_doc, declaration, {})
    roles = Mxrb::IO::BsonCodec.parse_array(security['UserRoles'])[:items]
    expect(roles.find { _1['Name'] == 'Administrator' }.fetch('ModuleRoles'))
      .to include('System.Administrator')
    expect(roles.find { _1['Name'] == 'User' }.fetch('ModuleRoles'))
      .to include('System.User')
    expect(security.dig('PasswordPolicySettings', 'MinimumLength')).to eq(12)

    preserved = writer.send(
      :ruby_project_security_doc,
      declaration.merge(
        demo_users: [{ id: id(7), name: 'manager', password: nil, entity: 'System.User',
                       roles: ['Administrator'] }],
        password_policy: false
      ),
      security
    )
    expect(Mxrb::IO::BsonCodec.parse_array(preserved['DemoUsers'])[:items].first['Password'])
      .to eq('secret')
    expect(preserved).not_to have_key('PasswordPolicySettings')
    expect(writer.send(:ruby_default_system_role, name: 'Operator')).to eq('System.User')

    event = {
      id: id(10), name: 'Cleanup', microflow: 'App.Cleanup', documentation: 'daily',
      export_level: 'Hidden', start_at: '2026-08-28T12:00:00Z', time_zone: 'UTC',
      schedule: {
        id: id(11), type: 'ScheduledEvents$DailySchedule',
        properties: { 'HourOfDay' => 12 }
      },
      on_overlap: 'SkipNext', enabled: true, interval_type: 'Days', interval: 1
    }
    writer.send(:validate_ruby_scheduled_events!, 'App', [event])
    document = writer.send(:ruby_scheduled_event_doc, event, nil, 'App')
    expect(document).to include('Name' => 'Cleanup', 'StartDateTime' => Time.utc(2026, 8, 28, 12))
    expect(document['Schedule']).to include('HourOfDay' => 12)
    expect(writer.send(:ruby_scheduled_event_doc, event.merge(start_at: Time.utc(2026)), document, 'App'))
      .to include('StartDateTime' => Time.utc(2026))
  end

  it 'rejects inconsistent security and scheduled-event declarations' do
    writer = Mxrb::Writer.new('/tmp/projection.mpr', version: '11.12.1', modules: [])
    expect do
      writer.send(:validate_ruby_security_declarations!, [{ name: 'Same' }, { name: 'Same' }], 'roles')
    end.to raise_error(Mxrb::ValidationError, /duplicate roles/)
    expect do
      writer.send(:validate_ruby_security_declarations!, [{ name: '' }], 'roles')
    end.to raise_error(Mxrb::ValidationError, /empty name/)
    expect do
      writer.send(:ruby_project_security_doc, { admin_user_role: 'Missing', user_roles: [] }, {})
    end.to raise_error(Mxrb::ValidationError, /admin user role Missing/)
    expect do
      writer.send(
        :ruby_project_demo_users,
        [{ name: 'new', password: nil, entity: 'System.User', roles: [] }], nil
      )
    end.to raise_error(Mxrb::ValidationError, /requires an explicit password/)
    expect do
      writer.send(:ruby_project_role_guid, { name: 'User', guid: id(2) }, { 'GUID' => id(1) }, id(3))
    end.to raise_error(Mxrb::ValidationError, /identity mismatch/)
    expect do
      writer.send(:ruby_existing_or_stable_id, id(2), id(1), 'role', 'role')
    end.to raise_error(Mxrb::ValidationError, /identity mismatch/)

    base = { name: 'Event', microflow: 'App.Run', schedule: { type: 'ScheduledEvents$DailySchedule' } }
    expect do
      writer.send(:validate_ruby_scheduled_events!, 'App', [base.merge(microflow: '')])
    end.to raise_error(Mxrb::ValidationError, /has no microflow/)
    expect do
      writer.send(:validate_ruby_scheduled_events!, 'App', [base.merge(schedule: nil)])
    end.to raise_error(Mxrb::ValidationError, /has no schedule/)
    expect do
      writer.send(:validate_ruby_scheduled_events!, 'App', [base.merge(schedule: { type: 'Bad' })])
    end.to raise_error(Mxrb::ValidationError, /unsupported scheduled event schedule/)
    expect do
      writer.send(:validate_ruby_scheduled_events!, 'App', [base.merge(interval: 'bad')])
    end.to raise_error(Mxrb::ValidationError, /invalid interval/)
    expect do
      writer.send(:ruby_scheduled_event_doc, base.merge(start_at: 'invalid'), nil, 'App')
    end.to raise_error(Mxrb::ValidationError, /invalid start time/)
  end

  it 'serializes indexes, generalizations, OQL views, lifecycle, validation, and access' do
    writer = Mxrb::Writer.new('/tmp/projection.mpr', version: '11.12.1', modules: [])
    attributes = { 'Name' => id(20), 'Code' => id(21) }
    previous_member = {
      '$ID' => id(23), '$Type' => 'DomainModels$IndexedAttribute',
      'AttributePointer' => BSON::Binary.new(Mxrb::IO::BsonCodec.uuid_to_blob(id(20)))
    }
    previous_index = {
      '$ID' => id(22), '$Type' => 'DomainModels$EntityIndex',
      'GUID' => BSON::Binary.new(Mxrb::IO::BsonCodec.uuid_to_blob(id(24))),
      'Attributes' => bson_array([previous_member])
    }
    indexes = writer.send(
      :ruby_index_docs,
      [{ id: id(22), guid: id(24), include_offline: true,
         members: [{ id: id(23), name: 'Name', ascending: false }] }],
      bson_array([previous_index, { '$Type' => 'Vendor$Index' }]), attributes, 'App', 'Item'
    )
    expect(Mxrb::IO::BsonCodec.parse_array(indexes)[:items]).to include(
      include('$ID' => id(22), 'IncludeInOffline' => true), include('$Type' => 'Vendor$Index')
    )

    entity = {
      'MaybeGeneralization' => { '$ID' => id(30), '$Type' => 'DomainModels$NoGeneralization' },
      'Attributes' => bson_array([
                                   { '$ID' => id(20), 'Name' => 'Name', 'Value' => { 'DefaultValue' => 'old' } },
                                   { '$ID' => id(21), 'Name' => '' }
                                 ])
    }
    writer.send(:synchronize_ruby_system_members!, entity, owner: true, changed_by: true)
    writer.send(:synchronize_ruby_generalization!, entity, target: 'System.User', id: id(30))
    expect(entity['MaybeGeneralization']).to include(
      '$Type' => 'DomainModels$Generalization', 'Generalization' => 'System.User',
      'Persistable' => true
    )
    writer.send(
      :synchronize_ruby_oql_view!, entity,
      { source: 'App.ItemSource', query: 'SELECT Name', source_id: id(31) }, 'App', 'Item'
    )
    writer.send(:synchronize_ruby_oql_member_values!, entity)
    member = Mxrb::IO::BsonCodec.parse_array(entity['Attributes'])[:items].first
    expect(member.fetch('Value')).to include('$Type' => 'DomainModels$OqlViewValue', 'Reference' => 'Name')
    expect(member.fetch('Value')).not_to have_key('DefaultValue')

    lifecycle = writer.send(
      :ruby_lifecycle_docs,
      [{ event: :before_commit, handler: 'App.Validate', translations: [] }],
      bson_array([{ '$Type' => 'Vendor$Handler' }]), 'App', 'Item'
    )
    expect(Mxrb::IO::BsonCodec.parse_array(lifecycle)[:items]).to include(
      include('$Type' => 'DomainModels$EventHandler', 'Moment' => 'Before', 'Event' => 'Commit'),
      include('$Type' => 'Vendor$Handler')
    )

    rules = writer.send(
      :ruby_validation_rule_docs,
      [{ attribute: 'Name', kind: :required,
         translations: [{ language_code: 'en_US', text: 'Required' }],
         rule_info: { 'Custom' => true } }],
      bson_array([{ '$Type' => 'Vendor$Validation' }]), 'App', 'Item', %w[Name Code]
    )
    expect(Mxrb::IO::BsonCodec.parse_array(rules)[:items]).to include(
      include('$Type' => 'DomainModels$ValidationRule'), include('$Type' => 'Vendor$Validation')
    )

    access = writer.send(
      :ruby_access_rule_docs,
      [{ roles: ['App.User'], create: true, delete: false, default_rights: :ReadOnly,
         xpath: '[Active]', xpath_caption: 'Active', members: [
           { name: 'Name', rights: :ReadWrite, kind: :attribute },
           { name: 'Item_Owner', rights: :ReadOnly, kind: :association }
         ] }],
      bson_array([{ '$Type' => 'Vendor$Access' }]), 'App', 'Item'
    )
    access_items = Mxrb::IO::BsonCodec.parse_array(access)[:items]
    members = Mxrb::IO::BsonCodec.parse_array(access_items.first['MemberAccesses'])[:items]
    expect(members).to include(
      include('Attribute' => 'App.Item.Name'), include('Association' => 'App.Item_Owner')
    )
    expect(access_items).to include(include('$Type' => 'Vendor$Access'))
  end

  it 'rejects inconsistent entity structure and behavior declarations' do
    writer = Mxrb::Writer.new('/tmp/projection.mpr', version: '11.12.1', modules: [])
    attributes = { 'Name' => id(20) }
    duplicate = { id: id(22), members: [{ name: 'Name' }] }
    expect do
      writer.send(:validate_ruby_indexes!, [duplicate, duplicate], attributes, 'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /duplicate indexes/)
    expect do
      writer.send(:validate_ruby_indexes!, [{ members: [] }], attributes, 'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /empty index/)
    expect do
      writer.send(
        :validate_ruby_indexes!,
        [{ members: [{ id: id(1), name: 'Name' }, { id: id(1), name: 'Name' }] }],
        attributes, 'App', 'Item'
      )
    end.to raise_error(Mxrb::ValidationError, /duplicate index members/)
    expect do
      writer.send(:validate_ruby_indexes!, [{ members: [{ name: 'Missing' }] }], attributes, 'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /unknown indexed attribute/)
    expect do
      writer.send(:synchronize_ruby_system_members!, { 'MaybeGeneralization' => {} }, {})
    end.to raise_error(Mxrb::ValidationError, /without generalization/)
    expect do
      writer.send(:synchronize_ruby_generalization!, {}, '')
    end.to raise_error(Mxrb::ValidationError, /cannot be empty/)
    expect do
      writer.send(:synchronize_ruby_oql_view!, {}, {}, 'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /requires source or query/)

    expect do
      writer.send(
        :ruby_lifecycle_docs,
        [{ event: :before_commit, handler: 'App.Run' }, { event: :before_commit, handler: 'App.Run' }],
        nil, 'App', 'Item'
      )
    end.to raise_error(Mxrb::ValidationError, /duplicate lifecycle/)
    expect do
      writer.send(:ruby_lifecycle_docs, [{ event: :after_create, handler: 'App.Run' }], nil, 'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /unsupported native lifecycle/)
    expect do
      writer.send(:ruby_lifecycle_docs, [{ event: :before_commit, handler: '' }], nil, 'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /is empty/)

    expect do
      writer.send(
        :ruby_validation_rule_docs,
        [{ attribute: 'Name', kind: :required }, { attribute: 'Name', kind: :required }],
        nil, 'App', 'Item', ['Name']
      )
    end.to raise_error(Mxrb::ValidationError, /duplicate validation rules/)
    expect do
      writer.send(:ruby_validation_rule_docs, [{ attribute: 'Missing', kind: :required }],
                  nil, 'App', 'Item', ['Name'])
    end.to raise_error(Mxrb::ValidationError, /unknown validation attribute/)
    expect { writer.send(:validation_rule_type, :unsupported) }
      .to raise_error(Mxrb::ValidationError, /unsupported validation rule/)

    expect do
      writer.send(:validate_ruby_access_rules!, [{ roles: [] }], 'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /has no roles/)
    expect do
      writer.send(:validate_ruby_access_rules!, [{ id: id(1), roles: ['App.User'] },
                                                 { id: id(1), roles: ['App.Admin'] }], 'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /duplicate access rule ids/)
    expect do
      writer.send(:validate_ruby_access_rules!, [{ roles: ['App.User'], default_rights: :Bad }],
                  'App', 'Item')
    end.to raise_error(Mxrb::ValidationError, /unsupported default access/)
    expect do
      writer.send(
        :validate_ruby_access_rules!,
        [{ roles: ['App.User'], members: [{ name: 'Name', rights: :ReadOnly },
                                          { name: 'Name', rights: :ReadOnly }] }],
        'App', 'Item'
      )
    end.to raise_error(Mxrb::ValidationError, /duplicate access members/)
    expect do
      writer.send(
        :validate_ruby_access_rules!,
        [{ roles: ['App.User'], members: [{ name: 'Name', rights: :ReadOnly, kind: :bad }] }],
        'App', 'Item'
      )
    end.to raise_error(Mxrb::ValidationError, /unsupported access member kind/)
  end

  it 'exports complete Ruby application manifests for security and entity semantics' do
    exporter = Mxrb::RubyApp::Exporter.new(
      '/tmp/source.mpr', '/tmp/ruby-app', mendix_sidecar: '/tmp/mendix-sidecar'
    )
    allow(exporter).to receive(:write)
    allow(exporter).to receive(:add_coverage)
    allow(exporter).to receive(:embedded_security_path).and_return(nil)
    security = {
      '$ID' => id(1), '$Type' => 'Security$ProjectSecurity',
      'SecurityLevel' => 'Production', 'AdminUserRole' => 'Administrator',
      'EnableDemoUsers' => true, 'EnableGuestAccess' => false,
      'GuestUserRole' => '', 'SignInMicroflow' => 'App.SignIn',
      'UserRoles' => bson_array([{
        '$ID' => id(2), '$Type' => 'Security$UserRole', 'Name' => 'Administrator',
        'GUID' => BSON::Binary.new(Mxrb::IO::BsonCodec.uuid_to_blob(id(3))),
        'ManageableRoles' => bson_array(['User']), 'ManageAllRoles' => true,
        'ManageUsersWithoutRoles' => false, 'ModuleRoles' => bson_array(['System.Administrator'])
      }]),
      'DemoUsers' => bson_array([{
        '$ID' => id(4), '$Type' => 'Security$DemoUserImpl', 'UserName' => 'manager',
        'Entity' => 'System.User', 'UserRoles' => bson_array(['Administrator'])
      }]),
      'PasswordPolicySettings' => {
        '$ID' => id(5), '$Type' => 'Security$PasswordPolicySettings', 'MinimumLength' => 12
      }
    }
    unit = { 'UnitID' => id(1) }
    project = double(all_units: [unit])
    allow(project).to receive(:parse_bson).with(unit).and_return(security)
    manifest = exporter.send(:export_project_security, project)
    expect(manifest.fetch('demo_users')).to include(
      include('name' => 'manager', 'password_redacted' => true)
    )
    expect(manifest.fetch('password_policy')).to include('properties' => { 'MinimumLength' => 12 })
    empty_project = double(all_units: [], parse_bson: nil)
    expect(exporter.send(:export_project_security, empty_project)).to be_nil

    document = { name: 'ItemSource', id: id(10), doc: { 'Oql' => 'SELECT Name' } }
    mod = double(name: 'App', oql_view_documents: [document])
    entity = double(
      oql_view?: true, oql_source_document: 'App.ItemSource',
      source: { '$ID' => id(11) }, generalization_target: 'App.Base',
      generalization: { '$ID' => id(12) }
    )
    expect(exporter.send(:oql_view_manifest, entity, mod)).to include(
      'source' => 'App.ItemSource', 'source_id' => id(11),
      'document_id' => id(10), 'query' => 'SELECT Name'
    )
    expect(exporter.send(:generalization_manifest, entity)).to eq(
      'target' => 'App.Base', 'id' => id(12)
    )
    query_entity = double(oql_view?: true, oql_query: 'SELECT Code')
    allow(query_entity).to receive(:respond_to?).and_return(false)
    allow(query_entity).to receive(:respond_to?).with(:oql_view?).and_return(true)
    allow(query_entity).to receive(:respond_to?).with(:oql_query).and_return(true)
    expect(exporter.send(:oql_view_manifest, query_entity, double(name: 'App')))
      .to eq('query' => 'SELECT Code')

    callback = exporter.send(
      :lifecycle_manifest,
      event: :before_commit, handler: 'App.Validate', pass_event_object: false,
      raise_error_on_false: true
    )
    expect(exporter.send(:lifecycle_source, callback)).to include('before_commit microflow:')
    source = exporter.send(
      :entity_source, 'App', 'Item', 'App.Item', id(20), [], [],
      dto: false, persistable: true, system_members: { 'owner' => true },
      generalization: { 'target' => 'App.Base', 'id' => id(12) },
      oql_view: { 'source' => 'App.ItemSource', 'query' => nil },
      lifecycle: [callback], validation_rules: []
    )
    expect(source).to include('generalizes "App.Base"', 'oql_view source:', 'before_commit microflow:')
    expect(exporter.send(:scheduled_event_start, 'raw')).to eq('raw')
    security_source = exporter.send(:project_security_source, manifest)
    expect(security_source).to include('demo_user "manager"', 'password_policy id:')
  end

  it 'exports semantic code-action types and modern native flow actions' do
    exporter = Mxrb::Exporter.new('/tmp/source.mpr', '/tmp/exported')
    identity = { '$ID' => id(1) }
    expect(exporter.send(
             :code_action_parameter_type_spec,
             identity.merge('$Type' => 'CodeActions$BasicParameterType',
                            'Type' => identity.merge('$Type' => 'CodeActions$StringType'))
           )).to include(kind: :basic, type: include(kind: :string))
    expect(exporter.send(
             :code_action_parameter_type_spec,
             identity.merge('$Type' => 'JavaActions$MicroflowJavaActionParameterType')
           )).to include(kind: :microflow)
    expect do
      exporter.send(:code_action_parameter_type_spec, identity.merge('$Type' => 'Bad'))
    end.to raise_error(KeyError)
    expect(exporter.send(
             :code_action_type_spec,
             identity.merge('$Type' => 'CodeActions$ConcreteEntityType', 'Entity' => 'App.Item')
           )).to include(kind: :concrete_entity, entity: 'App.Item')
    expect(exporter.send(
             :code_action_type_spec,
             identity.merge('$Type' => 'CodeActions$EnumerationType', 'Enumeration' => 'App.Status')
           )).to include(kind: :enumeration, enumeration: 'App.Status')
    expect { exporter.send(:code_action_type_spec, identity.merge('$Type' => 'Bad')) }
      .to raise_error(KeyError)
    expect(exporter.send(:bson_marker, Object.new, 7)).to eq(7)
    rest = {
      '$Type' => 'Microflows$RestCallAction',
      'HttpConfiguration' => {
        'HttpMethod' => 'Post',
        'CustomLocationTemplate' => {
          'Text' => '/items/{1}', 'Parameters' => bson_array([{ 'Expression' => '$id' }])
        },
        'HttpHeaderEntries' => bson_array([{ 'Key' => 'Accept', 'Value' => 'application/json' }])
      },
      'RequestHandling' => {
        '$Type' => 'Microflows$CustomRequestHandling',
        'Template' => { 'Text' => '{1}', 'Parameters' => bson_array([{ 'Expression' => '$body' }]) }
      },
      'ResultHandlingType' => 'HttpResponse',
      'ResultHandling' => {
        'Bind' => true, 'ImportMappingCall' => nil, 'ResultVariableName' => 'response',
        'VariableType' => { 'Entity' => 'System.HttpResponse' }
      },
      'UseRequestTimeOut' => true, 'TimeOutExpression' => '30',
      'ErrorResultHandlingType' => 'Store', 'ErrorHandlingType' => 'Continue'
    }
    expect(exporter.send(:editable_action?, rest)).to be(true)
    expect(exporter.send(:rest_call_line, '  ', rest)).to include(
      'request_body:', 'request_parameters:', 'result_handling: :http_response', 'timeout:'
    )

    query = {
      '$Type' => 'DatabaseConnector$ExecuteDatabaseQueryAction', 'Query' => 'SELECT 1',
      'DynamicQuery' => '$query', 'OutputVariableName' => 'rows',
      'ParameterMappings' => bson_array([{ 'ParameterName' => 'id', 'Value' => '$id' }]),
      'ConnectionParameterMappings' => bson_array([{ 'ParameterName' => 'host', 'Value' => '$host' }]),
      'ErrorHandlingType' => 'Continue'
    }
    expect(exporter.send(:editable_action?, query)).to be(true)
    expect(exporter.send(:database_query_line, '  ', query)).to include(
      'dynamic_query:', 'parameters:', 'connection_parameters:', 'error: :continue'
    )

    import = {
      '$Type' => 'Microflows$ImportXmlAction', 'XmlDocumentVariableName' => 'document',
      'IsValidationRequired' => true, 'ErrorHandlingType' => 'Continue',
      'ResultHandling' => {
        'Bind' => true, 'ResultVariableName' => 'items',
        'VariableType' => { 'Entity' => 'App.Item' },
        'ImportMappingCall' => {
          'ReturnValueMapping' => 'App.Import', 'ContentType' => 'Json', 'Commit' => 'Yes',
          'ForceSingleOccurrence' => true, 'ObjectHandlingBackup' => 'Find',
          'ParameterVariableName' => 'parameter',
          'Range' => { '$Type' => 'Microflows$ConstantRange', 'SingleObject' => true }
        }
      }
    }
    expect(exporter.send(:editable_action?, import)).to be(true)
    expect(exporter.send(:import_xml_line, '  ', import)).to include(
      'validate: true', 'content_type: :json', 'force_single: true', 'single: true'
    )
    expect(exporter.send(
             :editable_action?,
             '$Type' => 'Microflows$DownloadFileAction', 'FileDocumentVariableName' => 'file'
           )).to be(true)
    expect(exporter.send(:code_action_parameter_value,
                         '$Type' => 'X$ImportMappingValue', 'ImportMapping' => 'App.Import'))
      .to eq(kind: :import_mapping, value: 'App.Import')
    expect(exporter.send(:code_action_parameter_value,
                         '$Type' => 'X$ExportMappingValue', 'ExportMapping' => 'App.Export'))
      .to eq(kind: :export_mapping, value: 'App.Export')
  end

  it 'materializes database, XML, download, and REST activities as Mendix documents' do
    writer = Mxrb::Writer.new('/tmp/projection.mpr', version: '11.12.1', modules: [])
    query = writer.send(
      :database_query_action_doc,
      query: 'SELECT 1', dynamic_query: '$query', variable: 'rows', error: :continue,
      parameters: [{ name: 'id', value: '$id' }],
      connection_parameters: [{ name: 'host', value: '$host' }]
    )
    expect(query).to include('$Type' => 'DatabaseConnector$ExecuteDatabaseQueryAction')
    expect(Mxrb::IO::BsonCodec.parse_array(query['ParameterMappings'])[:items].first)
      .to include('ParameterName' => 'id')
    expect do
      writer.send(:database_query_action_doc, query: '', dynamic_query: '')
    end.to raise_error(Mxrb::ValidationError, /requires query or dynamic_query/)

    import = writer.send(
      :import_xml_action_doc,
      variable: 'document', mapping: 'App.Import', output: 'items', result_entity: 'App.Item',
      validate: true, content_type: :json, commit: :yes, force_single: true, single: true,
      object_handling: :find, parameter_variable: 'parameter', error: :continue
    )
    expect(import).to include('$Type' => 'Microflows$ImportXmlAction', 'IsValidationRequired' => true)
    expect do
      writer.send(:import_xml_action_doc, variable: '', mapping: '', output: '', result_entity: '')
    end.to raise_error(Mxrb::ValidationError, /requires document, mapping, as, and result_entity/)
    expect(writer.send(:download_file_action_doc,
                       variable: 'file', show_in_browser: true, error: :continue))
      .to include('FileDocumentVariableName' => 'file', 'ShowFileInBrowser' => true)
    expect { writer.send(:download_file_action_doc, variable: '') }
      .to raise_error(Mxrb::ValidationError, /requires a variable/)

    custom = writer.send(
      :rest_call_action_doc,
      method: :post, location: '/items/{1}', location_parameters: ['$id'],
      headers: { 'Accept' => 'application/json' }, request_body: '{1}',
      request_parameters: ['$body'], result_handling: :http_response,
      variable: 'response', result_entity: 'System.HttpResponse', timeout: '30',
      error_result: :store, error: :continue
    )
    expect(custom['RequestHandling']).to include('$Type' => 'Microflows$CustomRequestHandling')
    expect(custom['ResultHandling']).to include('ImportMappingCall' => nil)
    mapped = writer.send(
      :rest_call_action_doc,
      method: :get, location: '/items', location_parameters: [], headers: {},
      request_body: nil, request_mapping: 'App.Export', request_variable: 'item',
      result_handling: :mapping, result_mapping: 'App.Import', variable: 'item',
      result_entity: 'App.Item', commit: :yes, result_content_type: :xml,
      force_single: true, single: true, object_handling: :find,
      parameter_variable: 'parameter', timeout: '', error_result: :store, error: :rollback
    )
    expect(mapped['RequestHandling']).to include('$Type' => 'Microflows$MappingRequestHandling')
    expect do
      writer.send(:rest_result_handling_doc, result_handling: :http_response,
                                             variable: '', result_entity: '')
    end.to raise_error(Mxrb::ValidationError, /requires as and result_entity/)
  end

  it 'dispatches exported and materialized modern actions through their public type cases' do
    exporter = Mxrb::Exporter.new('/tmp/source.mpr', '/tmp/exported')
    writer = Mxrb::Writer.new('/tmp/projection.mpr', version: '11.12.1', modules: [])
    query = {
      '$Type' => 'DatabaseConnector$ExecuteDatabaseQueryAction', 'Query' => 'SELECT 1',
      'ParameterMappings' => bson_array([]), 'ConnectionParameterMappings' => bson_array([]),
      'ErrorHandlingType' => 'Rollback'
    }
    import = {
      '$Type' => 'Microflows$ImportXmlAction', 'XmlDocumentVariableName' => 'document',
      'ErrorHandlingType' => 'Rollback', 'ResultHandling' => {
        'ResultVariableName' => 'items', 'VariableType' => { 'Entity' => 'App.Item' },
        'ImportMappingCall' => {
          'ReturnValueMapping' => 'App.Import', 'ContentType' => 'Xml',
          'Commit' => 'YesWithoutEvents', 'ObjectHandlingBackup' => 'Create',
          'Range' => { '$Type' => 'Microflows$ConstantRange' }
        }
      }
    }
    download = {
      '$Type' => 'Microflows$DownloadFileAction', 'FileDocumentVariableName' => 'file',
      'ShowFileInBrowser' => true, 'ErrorHandlingType' => 'Continue'
    }
    expect(exporter.send(:action_dsl_line, { 'Action' => query }, 2))
      .to include('execute_database_query')
    expect(exporter.send(:action_dsl_line, { 'Action' => import }, 2)).to include('import_xml')
    expect(exporter.send(:action_dsl_line, { 'Action' => download }, 2))
      .to include('download_file', 'show_in_browser: true', 'error: :continue')
    expect(writer.send(:activity_action_doc,
                       type: :execute_database_query, query: 'SELECT 1', dynamic_query: '',
                       parameters: [], connection_parameters: [], error: :rollback))
      .to include('$Type' => 'DatabaseConnector$ExecuteDatabaseQueryAction')
    expect(writer.send(:activity_action_doc,
                       type: :import_xml, variable: 'document', mapping: 'App.Import',
                       output: 'items', result_entity: 'App.Item', error: :rollback))
      .to include('$Type' => 'Microflows$ImportXmlAction')
    expect(writer.send(:activity_action_doc,
                       type: :download_file, variable: 'file', error: :rollback))
      .to include('$Type' => 'Microflows$DownloadFileAction')

    unsupported_request = {
      '$Type' => 'Microflows$RestCallAction',
      'HttpConfiguration' => { 'HttpMethod' => 'Get' },
      'RequestHandling' => { '$Type' => 'Vendor$Request' },
      'ResultHandlingType' => 'None'
    }
    expect(exporter.send(:editable_action?, unsupported_request)).to be(false)
    unsupported_result = unsupported_request.merge(
      'RequestHandling' => { '$Type' => 'Microflows$MappingRequestHandling', 'MappingId' => 'App.Export' },
      'ResultHandlingType' => 'Vendor'
    )
    expect(exporter.send(:editable_action?, unsupported_result)).to be(false)

    rest_with_object_handling = {
      'HttpConfiguration' => { 'HttpMethod' => 'Get', 'CustomLocationTemplate' => { 'Text' => '/x' } },
      'RequestHandling' => { '$Type' => 'Microflows$MappingRequestHandling' },
      'ResultHandling' => {
        'ImportMappingCall' => { 'ObjectHandlingBackup' => 'Find' }
      },
      'ErrorResultHandlingType' => 'Store', 'ErrorHandlingType' => 'Rollback'
    }
    expect(exporter.send(:rest_call_line, '', rest_with_object_handling))
      .to include('object_handling: :find')
  end

  it 'exports REST authentication enums and a generalized Ruby application entity' do
    exporter = Mxrb::Exporter.new('/tmp/source.mpr', '/tmp/exported')
    declaration = exporter.send(
      :published_rest_declaration,
      name: 'Api', id: id(1), container_id: id(2), doc: {
        'Path' => '/api', 'Version' => '1', 'AuthenticationTypes' => bson_array(%w[Basic Custom]),
        'Resources' => bson_array([]), 'AllowedRoles' => bson_array([])
      }
    )
    expect(declaration).to include('authentication_types:', '"basic"', '"custom"')

    ruby_exporter = Mxrb::RubyApp::Exporter.new(
      '/tmp/source.mpr', '/tmp/ruby-app', mendix_sidecar: '/tmp/mendix-sidecar'
    )
    allow(ruby_exporter).to receive(:write)
    allow(ruby_exporter).to receive(:add_coverage)
    ruby_exporter.instance_variable_set(:@project, double(modules: []))
    entity = double(
      name: 'Child', id: id(3), persistable: true, oql_view?: false, attributes: [],
      access_rules: [], indexes: [], lifecycle: [], validation_rules: [],
      generalization_target: 'App.Base', generalization: { '$ID' => id(4) }
    )
    mod = double(name: 'App', associations: [], oql_view_documents: [])
    manifest = ruby_exporter.send(:export_entity, entity, mod, 'App', 'app')
    expect(manifest).to include(
      'generalization' => { 'target' => 'App.Base', 'id' => id(4) },
      'system_members' => nil
    )
  end

  it 'synchronizes semantic structures into a real MPR without native payloads' do
    Dir.mktmpdir('mxrb-ruby-projection-sync-') do |dir|
      path = File.join(dir, 'App.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:App) do
          entity(:Item) { string :Name }
          microflow(:Cleanup)
        end
      end
      mpr = Mxrb::IO::MprFile.open(path)
      writer = Mxrb::Writer.new(path, version: '11.12.1', modules: [])
      project_security = mpr.all_units.find do |unit|
        mpr.parse_contents(unit)['$Type'] == 'Security$ProjectSecurity'
      end
      mpr.transaction { mpr.delete_unit(project_security.fetch('UnitID')) } if project_security
      writer.synchronize_ruby_entity_structures!(
        mpr, module_name: 'App', entities: [{
          name: 'Item', indexes: nil, system_members: nil, generalization: nil,
          oql_view: {
            source: 'App.ItemSource', query: 'SELECT Name FROM App.Item',
            source_id: id(10), document_id: id(11)
          }
        }]
      )
      writer.synchronize_ruby_entity_behaviors!(
        mpr, module_name: 'App', entities: [{
          name: 'Item', lifecycle: [{ event: :before_commit, handler: 'App.Cleanup' }],
          validation_rules: [{ attribute: 'Name', kind: :required, translations: [] }]
        }]
      )
      writer.synchronize_ruby_module_security!(
        mpr, module_name: 'App', security: { id: id(12), roles: [{ name: 'User' }] }
      )
      writer.synchronize_ruby_project_security!(
        mpr, security: {
          id: id(13), admin_user_role: 'Administrator',
          user_roles: [{ name: 'Administrator', manage_all_roles: true }], demo_users: []
        }
      )
      event = {
        id: id(14), name: 'Cleanup', microflow: 'App.Cleanup', interval: 1,
        schedule: { id: id(15), type: 'ScheduledEvents$DailySchedule' }
      }
      writer.synchronize_ruby_scheduled_events!(mpr, module_name: 'App', events: [event])
      writer.synchronize_ruby_scheduled_events!(mpr, module_name: 'App', events: [event])
      expect(mpr.all_units.map { mpr.parse_contents(_1)['$Type'] }).to include(
        'Security$ModuleSecurity', 'Security$ProjectSecurity',
        'ScheduledEvents$ScheduledEvent', 'DomainModels$ViewEntitySourceDocument'
      )
    ensure
      mpr&.close
    end
  end

  it 'covers remaining writer identity, OQL, association, and graph guards' do
    writer = Mxrb::Writer.new('/tmp/projection.mpr', version: '11.12.1', modules: [])
    generalization = {
      'MaybeGeneralization' => {
        '$ID' => id(1), '$Type' => 'DomainModels$Generalization',
        'Generalization' => 'App.Base'
      }
    }
    writer.send(:synchronize_ruby_generalization!, generalization, 'App.OtherBase')
    expect(generalization.dig('MaybeGeneralization', 'Generalization')).to eq('App.OtherBase')
    source_entity = { 'Source' => { '$ID' => id(2), '$Type' => 'DomainModels$OqlViewEntitySource' } }
    expect do
      writer.send(:synchronize_ruby_oql_view!, source_entity,
                  { source: 'App.Source', source_id: id(3) }, 'App', 'View')
    end.to raise_error(Mxrb::ValidationError, /OQL source id does not match/)
    query_entity = {}
    writer.send(:synchronize_ruby_oql_view!, query_entity, { query: 'SELECT 1' }, 'App', 'View')
    expect(query_entity['OqlQuery']).to eq('SELECT 1')

    mpr = double
    allow(mpr).to receive(:children_of).and_return([])
    allow(mpr).to receive(:parse_contents)
    allow(mpr).to receive(:insert_unit)
    view = { source: 'App.Source' }
    def view.[](key)
      return 'SELECT 1' if key == :query

      super
    end
    expect do
      writer.send(:synchronize_ruby_oql_documents!, mpr, id(4), 'App', [{ name: 'View', oql_view: view }])
    end.to raise_error(Mxrb::ValidationError, /invalid declaration/)

    expect do
      writer.send(:ruby_nested_document_id, id(2), id(1), 'nested')
    end.to raise_error(Mxrb::ValidationError, /identity mismatch/)
    expect do
      writer.send(:validate_ruby_nested_identity!, id(2), {}, { '$ID' => id(1) }, 'nested')
    end.to raise_error(Mxrb::ValidationError, /identity mismatch/)
    expect(writer.send(:access_rule_signature,
                       'ModuleRoles' => bson_array(['App.User']), 'XPathConstraint' => '[]'))
      .to eq([['App.User'], '[]'])
    expect(writer.send(:access_member_signature,
                       'Association' => 'App.Item_Owner', 'Attribute' => ''))
      .to eq([:association, 'App.Item_Owner'])

    expect do
      writer.send(
        :validate_flow_endpoints!, [{ '$ID' => id(1) }],
        [{ '$ID' => id(2), 'OriginPointer' => id(1), 'DestinationPointer' => id(3) }]
      )
    end.to raise_error(Mxrb::ValidationError, /references a missing object/)
    index = writer.send(
      :index_doc, { attributes: ['Name'], ascending: [false] }, attribute_ids: { 'Name' => id(5) }
    )
    expect(index['Attributes']).not_to be_nil
    association = {
      name: 'Item_Owner', type: :Reference, owner: :Default,
      parent_delete: :NoAction, child_delete: :NoAction
    }
    oql = writer.send(
      :association_doc, association, from_id: id(6), to_id: id(7), previous: nil, oql_view: true
    )
    expect(oql['Source']).to include('$Type' => 'DomainModels$OqlViewAssociationSource')
    regular = writer.send(
      :association_doc, association, from_id: id(6), to_id: id(7), previous: oql, oql_view: false
    )
    expect(regular).not_to have_key('Source')
  end
end
# rubocop:enable Metrics/BlockLength
