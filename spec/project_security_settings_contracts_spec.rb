# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Project security settings contracts' do
  after { Mxrb::RubyApp::Registry.reset! }

  def identity(number)
    format('00000000-0000-4000-8000-%012d', number)
  end

  def declaration(**settings)
    { id: '', user_roles: [], demo_users: [], password_policy: nil, **settings }
  end

  def manifest(security = nil)
    Mxrb::RubyApp::Manifest.new('/tmp/project-security-settings',
                                'mode' => 'ruby', 'modules' => [], 'security' => security)
  end

  it 'validates Ruby-app project access declarations and supports clearing them' do
    security = Class.new(Mxrb::RubyApp::ProjectSecurity)
    security.project_security
    security.admin_user('MxAdmin')
    expect(security.native_definition).not_to have_key(:admin_password)
    security.admin_user('MxAdmin', password: 'private')
    security.file_document_access_rule('System.User', identity: 'rule_1') do
      member 'Name', rights: :read_only
    end
    security.image_access_rule('System.Administrator', members: [{
      name: 'PublicThumbnailPath', rights: :ReadOnly, kind: :association
    }])
    expect(security.native_definition).to include(admin_password: 'private')
    expect(security.native_definition.dig(:file_document_access, 0, :source_identity)).to eq('rule_1')

    expect { security.file_document_access_rule }
      .to raise_error(ArgumentError, /at least one module role/)
    expect do
      security.file_document_access_rule('System.User', members: [{
        name: 'Name', rights: :ReadOnly, kind: :unknown
      }])
    end.to raise_error(ArgumentError, /kind must be attribute or association/)
    expect { security.image_access_rule('System.User', default_rights: :unknown) }
      .to raise_error(ArgumentError, /access rights must be one of/)

    security.clear_file_document_access_rules!
    security.clear_image_access_rules!
    expect(security.native_definition).to include(file_document_access: [], image_access: [])

    plain = Class.new(Mxrb::RubyApp::ProjectSecurity)
    plain.project_security
    plain.resolve_security_identities!(Mxrb::RubyApp::SecurityIdentity.new(manifest))
    expect(plain.native_definition).not_to have_key(:file_document_access)
  end

  it 'resolves fresh nested identities and fails closed for missing or changed baselines' do
    fresh = declaration(file_document_access: [{
      roles: ['System.User'], xpath: '', members: [{
        name: 'Name', reference: '', rights: :ReadOnly, kind: :attribute
      }]
    }])
    expect(Mxrb::RubyApp::SecurityIdentity.new(manifest).project_security(fresh)
      .dig(:file_document_access, 0, :members, 0, :id)).to be_nil

    baseline = {
      'id' => identity(1), 'user_roles' => [], 'demo_users' => [],
      'file_document_access' => {
        'id' => identity(2), 'rules' => [{
          'id' => identity(3), 'roles' => ['System.User'], 'xpath' => '', 'members' => []
        }]
      }
    }
    missing = baseline.reject { |key, _value| key == 'file_document_access' }
    expect do
      Mxrb::RubyApp::SecurityIdentity.new(manifest(missing)).project_security(
        declaration(file_document_access: [])
      )
    end.to raise_error(Mxrb::ValidationError, /file_document_access identity baseline/)

    expect do
      Mxrb::RubyApp::SecurityIdentity.new(manifest(baseline)).project_security(
        declaration(file_document_access: [{
          roles: ['System.Administrator'], xpath: '', members: []
        }])
      )
    end.to raise_error(Mxrb::ValidationError, /clear the project access rules explicitly/)
  end

  it 'covers empty, legacy, and unsupported project-access container shapes' do
    writer = Mxrb::Writer.new('/tmp/project-security-settings.mpr', version: '11.12.1', modules: [])
    fresh = writer.send(
      :ruby_project_access_container_doc, [], nil,
      'Security$FileDocumentAccessRuleContainer', 'FileDocument'
    )
    expect(fresh.fetch('$Type')).to eq('Security$FileDocumentAccessRuleContainer')
    expect(writer.send(:project_access_container_doc, nil, nil,
                       'Security$ImageAccessRuleContainer', 'Image').fetch('AccessRules')).to eq([3])
    expect(writer.send(:project_access_container_doc, [], nil,
                       'Security$ImageAccessRuleContainer', 'Image').fetch('AccessRules')).to eq([3])

    exporter = Mxrb::Exporter.new('/tmp/source.mpr', '/tmp/exported')
    empty_role_rule = {
      '$Type' => 'DomainModels$AccessRule', 'AllowedModuleRoles' => [1], 'MemberAccesses' => [3]
    }
    document = {
      'FileDocumentAccess' => { 'AccessRules' => [3, empty_role_rule] }
    }
    expect(exporter.send(:project_access_source, document, 'FileDocumentAccess',
                         'file_document_access_rule', 'clear_file_document_access_rules!'))
      .to eq([])
    document['FileDocumentAccess']['AccessRules'] = [3]
    expect(exporter.send(:project_access_source, document, 'FileDocumentAccess',
                         'file_document_access_rule', 'clear_file_document_access_rules!'))
      .to eq(['  clear_file_document_access_rules!'])
    document['FileDocumentAccess']['AccessRules'] = [3, { '$Type' => 'Future$AccessRule' }]
    expect(exporter.send(:project_access_source, document, 'FileDocumentAccess',
                         'file_document_access_rule', 'clear_file_document_access_rules!')).to eq([])
    expect(exporter.send(:project_access_source, {}, 'FileDocumentAccess',
                         'file_document_access_rule', 'clear_file_document_access_rules!')).to eq([])

    ruby_exporter = Mxrb::RubyApp::Exporter.new(
      '/tmp/source.mpr', '/tmp/exported', mendix_sidecar: '/tmp/sidecar'
    )
    expect(ruby_exporter.send(:project_access_container_manifest, {
      'AccessRules' => [3, empty_role_rule]
    })).to be_nil

    comparator = Mxrb::Compare::Comparator.new('/tmp/left.mpr', '/tmp/right.mpr')
    expect(comparator.send(:project_access_summary, nil)).to eq([])
  end
end
# rubocop:enable Metrics/BlockLength
