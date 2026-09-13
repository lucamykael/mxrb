# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::SecurityIdentity do
  after { Mxrb::RubyApp::Registry.reset! }

  def identity(number)
    format('00000000-0000-4000-8000-%012d', number)
  end

  def manifest(modules: [], security: nil)
    Mxrb::RubyApp::Manifest.new('/tmp/security-identities',
                                'mode' => 'ruby', 'modules' => modules, 'security' => security)
  end

  def project_baseline
    {
      'id' => identity(1),
      'user_roles' => [{ 'name' => 'Manager', 'id' => identity(2), 'guid' => identity(3),
                         'description' => 'Private baseline description' }],
      'demo_users' => [{ 'name' => 'manager', 'id' => identity(4), 'password_redacted' => true }],
      'password_policy' => { 'id' => identity(5), 'properties' => { 'MinimumLength' => 99 } }
    }
  end

  def project_declaration
    {
      id: '', user_roles: [{ name: 'Manager', id: '', guid: '', description: 'Edited' }],
      demo_users: [{ name: 'manager', id: '', password: nil, roles: [] }],
      password_policy: { id: '', properties: { 'RequireDigit' => false } }
    }
  end

  it 'restores only private identities and leaves declarations and policy properties authoritative' do
    baseline = project_baseline
    declaration = project_declaration
    original = Marshal.load(Marshal.dump(declaration))
    result = described_class.new(manifest(security: baseline)).project_security(declaration)

    expect(result).to include(id: identity(1))
    expect(result[:user_roles]).to eq([original[:user_roles].first.merge(id: identity(2), guid: identity(3))])
    expect(result[:demo_users]).to eq([original[:demo_users].first.merge(id: identity(4))])
    expect(result[:password_policy]).to eq(id: identity(5), properties: { 'RequireDigit' => false })
    expect(declaration).to eq(original)
    expect(baseline).to eq(project_baseline)
  end

  it 'preserves explicit legacy IDs and GUIDs, and rejects conflicting singleton identities' do
    resolver = described_class.new(manifest(security: project_baseline))
    explicit = resolver.project_security(project_declaration)
    expect(resolver.project_security(explicit)).to eq(explicit)
    expect { resolver.project_security(explicit.merge(id: identity(90))) }
      .to raise_error(Mxrb::ValidationError, /project security/)
    expect { resolver.project_security(explicit.merge(password_policy: { id: identity(91), properties: {} })) }
      .to raise_error(Mxrb::ValidationError, /password policy/)
    explicit[:user_roles].first[:guid] = identity(92)
    expect { resolver.project_security(explicit) }.to raise_error(Mxrb::ValidationError, /GUID/)
  end

  it 'requires explicit project role and demo-user renames instead of positional guesses' do
    resolver = described_class.new(manifest(security: project_baseline))
    declaration = project_declaration
    declaration[:user_roles].first[:name] = 'Supervisor'
    expect { resolver.project_security(declaration) }
      .to raise_error(Mxrb::ValidationError, /renamed_from: or remove_user_role/)
    declaration[:user_roles].first[:renamed_from] = 'Manager'
    declaration[:demo_users].first[:name] = 'supervisor'
    expect { resolver.project_security(declaration) }
      .to raise_error(Mxrb::ValidationError, /renamed_from: or remove_demo_user/)
    declaration[:demo_users].first[:renamed_from] = 'manager'

    result = resolver.project_security(declaration)
    expect(result[:user_roles].first).to include(name: 'Supervisor', id: identity(2), guid: identity(3))
    expect(result[:demo_users].first).to include(name: 'supervisor', id: identity(4), password: nil)
  end

  it 'distinguishes explicit removal and insertion without transferring removed identities' do
    resolver = described_class.new(manifest(security: project_baseline))
    declaration = project_declaration
    declaration[:user_roles] = [{ name: 'NewRole', id: '' }]
    declaration[:demo_users] = [{ name: 'new-user', id: '', password: 'new password' }]
    result = resolver.project_security(declaration, removed_user_roles: ['Manager'], removed_demo_users: ['manager'])
    expect(result[:user_roles]).to eq(declaration[:user_roles])
    expect(result[:demo_users]).to eq(declaration[:demo_users])
    expect { resolver.project_security(project_declaration, removed_user_roles: ['Manager']) }
      .to raise_error(Mxrb::ValidationError, /removed and retained/)
  end

  it 'resolves module roles by names and explicit renames, not their order' do
    baseline = { 'name' => 'App', 'module_security' => { 'id' => identity(10), 'roles' => [
      { 'name' => 'Reader', 'id' => identity(11) }, { 'name' => 'Writer', 'id' => identity(12) }
    ] } }
    resolver = described_class.new(manifest(modules: [baseline]))
    declaration = { module_name: 'App', id: identity(10), roles: [
      { name: 'Writer', description: 'Changed' }, { name: 'Viewer', renamed_from: 'Reader' }
    ] }
    result = resolver.module_security(declaration)
    expect(result[:roles].map { _1[:id] }).to eq([identity(12), identity(11)])
    declaration[:roles].last.delete(:renamed_from)
    expect { resolver.module_security(declaration) }
      .to raise_error(Mxrb::ValidationError, /remove_module_role/)
    result = resolver.module_security(declaration, removed_roles: ['Reader'])
    expect(result[:roles].last).not_to have_key(:id)
  end

  it 'fails closed for missing existing collection baselines but allows newly authored security' do
    %w[user_roles demo_users].each do |collection|
      baseline = project_baseline.reject { |key, _| key == collection }
      expect { described_class.new(manifest(security: baseline)).project_security(project_declaration) }
        .to raise_error(Mxrb::ValidationError, /#{collection} identity baseline/)
    end
    resolver = described_class.new(manifest(modules: [{ 'name' => 'App',
                                                        'module_security' => { 'id' => identity(10) } }]))
    expect { resolver.module_security({ module_name: 'App', roles: [] }) }
      .to raise_error(Mxrb::ValidationError, /roles identity baseline/)
    expect(described_class.new(manifest).project_security(project_declaration)).to eq(project_declaration)
  end

  it 'preserves absent and explicitly removed policies and rejects missing declared policy baselines' do
    resolver = described_class.new(manifest(security: project_baseline))
    expect(resolver.project_security(project_declaration.merge(password_policy: nil))[:password_policy]).to be_nil
    expect(resolver.project_security(project_declaration.reject { |key, _| key == :password_policy }))
      .not_to have_key(:password_policy)
    baseline = project_baseline.reject { |key, _| key == 'password_policy' }
    expect { described_class.new(manifest(security: baseline)).project_security(project_declaration) }
      .to raise_error(Mxrb::ValidationError, /password policy identity baseline/)
  end

  it 'does not partially assign class declarations when a later collection fails reconciliation' do
    security = Class.new(Mxrb::RubyApp::ProjectSecurity)
    security.project_security
    security.user_role('Manager')
    security.demo_user('renamed-without-hint', entity: 'App.Account', roles: [])
    original = Marshal.load(Marshal.dump(security.native_definition))
    expect { security.resolve_security_identities!(described_class.new(manifest(security: project_baseline))) }
      .to raise_error(Mxrb::ValidationError, /remove_demo_user/)
    expect(security.native_definition).to eq(original)
  end

  def native_security(path)
    mpr = Mxrb::IO::MprFile.open(path)
    mpr.all_units.filter_map do |unit|
      document = mpr.parse_contents(unit)
      document if %w[Security$ModuleSecurity Security$ProjectSecurity].include?(document['$Type'])
    end.sort_by { Mxrb::IO::BsonCodec.extract_id(_1['$ID']) }
  ensure
    mpr&.close
  end

  it 'writes fresh security reference lists with marker 1 and preserves explicitly stored markers' do
    writer = Mxrb::Writer.new('/tmp/security-markers.mpr', version: '11.12.1', modules: [])
    role = { name: 'Manager', manageable_roles: ['Reader'], module_roles: ['App.User'] }
    user = { name: 'manager', entity: 'App.Account', roles: ['Manager'], password: 'secret' }
    role_doc = writer.send(:ruby_project_user_roles, [role], nil).last
    user_doc = writer.send(:ruby_project_demo_users, [user], nil).last
    expect(role_doc.fetch('ManageableRoles')).to eq([1, 'Reader'])
    expect(role_doc.fetch('ModuleRoles')).to eq([1, 'App.User', 'System.User'])
    expect(user_doc.fetch('UserRoles')).to eq([1, 'Manager'])

    role_doc.fetch('ManageableRoles')[0] = 2
    role_doc.fetch('ModuleRoles')[0] = 3
    user_doc.fetch('UserRoles')[0] = 2
    preserved_role = writer.send(:ruby_project_user_roles, [role], [2, role_doc]).last
    preserved_user = writer.send(:ruby_project_demo_users, [user], [2, user_doc]).last
    expect(preserved_role.fetch('ManageableRoles')).to eq([2, 'Reader'])
    expect(preserved_role.fetch('ModuleRoles')).to eq([3, 'App.User', 'System.User'])
    expect(preserved_user.fetch('UserRoles')).to eq([2, 'Manager'])
  end

  it 'exports, loads, compiles and reexports security without public IDs while retaining native GUIDs and edits' do
    Dir.mktmpdir('mxrb-security-identities-') do |directory|
      source = File.join(directory, 'Source.mpr')
      exported = File.join(directory, 'ruby')
      rebuilt = File.join(directory, 'Rebuilt.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:App) { entity(:Account) { string :Name } }
      end
      writer = Mxrb::Writer.new(source, version: '11.12.1', modules: [])
      mpr = Mxrb::IO::MprFile.open(source)
      begin
        writer.synchronize_ruby_module_security!(mpr, module_name: 'App', security: { roles: [{ name: 'User' }] })
        writer.synchronize_ruby_project_security!(mpr, security: {
          admin_user_role: 'Manager', user_roles: [{ name: 'Manager', module_roles: ['App.User'] }],
          demo_users: [{ name: 'manager', entity: 'App.Account', roles: ['Manager'], password: 'private-secret' }],
          password_policy: { properties: { 'MinimumLength' => 10, 'RequireDigit' => false } }
        })
      ensure
        mpr.close
      end
      original = native_security(source)
      Mxrb::Exporter.new(source, exported, mode: :ruby).export!
      files = Dir.glob(File.join(exported, 'app', 'security', '**', '*.rb'))
      expect(files.size).to be >= 2
      files.each do |path|
        expect(File.read(path)).not_to match(/\bid:|\bguid:|\bmendix_id\b|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)
        expect(File.read(path)).not_to include('private-secret')
      end
      Mxrb::RubyApp::Application.new(exported)
      loaded = Mxrb::RubyApp::Registry.fetch(:project_security, 'project').native_definition
      private_security = Mxrb::RubyApp::Manifest.load(exported).data.fetch('security')
      expect(loaded[:id]).to eq(private_security.fetch('id'))
      expect(loaded[:user_roles].first[:guid]).to eq(private_security.fetch('user_roles').first.fetch('guid'))
      Mxrb::RubyApp.compile(exported, rebuilt)
      expect(native_security(rebuilt)).to eq(original)

      project_path = File.join(exported, 'app', 'security', 'project_security.rb')
      ruby = File.read(project_path)
      File.write(project_path, ruby.sub('minimum_length 10', 'minimum_length 14'))
      Mxrb::RubyApp.compile(exported, rebuilt)
      expected = Marshal.load(Marshal.dump(original))
      expected.find { _1['$Type'] == 'Security$ProjectSecurity' }['PasswordPolicySettings']['MinimumLength'] = 14
      expect(native_security(rebuilt)).to eq(expected)

      restored = File.join(directory, 'restored')
      Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
      Mxrb::RubyApp.compile(restored, File.join(directory, 'Restored.mpr'))
      expect(native_security(File.join(directory, 'Restored.mpr'))).to eq(expected)
    end
  end
end
# rubocop:enable Metrics/BlockLength
