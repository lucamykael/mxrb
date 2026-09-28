# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Project security records certification' do
  it 'round-trips user roles, demo users, and password policy with stable identities' do
    Dir.mktmpdir('mxrb-project-security-records-') do |dir|
      current = File.join(dir, 'ProjectSecurityRecords.mpr')
      build_source(current)
      baseline = security_snapshot(current)

      ruby_app = File.join(dir, 'ruby-app')
      ruby_rebuilt = File.join(dir, 'ruby-rebuilt.mpr')
      Mxrb::Exporter.new(current, ruby_app, mode: :ruby).export!
      ruby_source = File.read(File.join(ruby_app, 'app/security/project_security.rb'))
      expect(ruby_source).to include(
        'user_role "Administrator"', 'manageable_roles: ["User"]',
        'demo_user "manager"', 'password: nil', 'password_policy do'
      )
      expect(ruby_source).not_to include('MxrbDemo123!')
      Mxrb::RubyApp.compile(ruby_app, ruby_rebuilt)
      expect(Mxrb.compare(current, ruby_rebuilt)).to be_identical
      expect(security_snapshot(ruby_rebuilt)).to eq(baseline)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = File.read(File.join(exported, 'app/security/security.rb'))
        expect(source).to include(
          'user_role :Administrator', 'manageable_roles: ["User"]',
          'demo_user "manager"', 'password_policy('
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(security_snapshot(rebuilt)).to eq(baseline)
        current = rebuilt
      end
    end
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        module_role :User
        module_role :Administrator
        page(:Home) { title 'Project security records' }
      end
      security do
        security_level :CheckEverything
        user_role :User, description: 'Regular user', module_roles: ['App.User'],
                         exact_module_roles: false
        user_role :Administrator, description: 'Administrator', check_security: false,
                                  module_roles: ['App.Administrator', 'System.Administrator'],
                                  exact_module_roles: true, manageable_roles: ['User'],
                                  manage_users_without_roles: true, admin: true
        admin_user_role :Administrator
        demo_user 'manager', entity: 'System.User', roles: ['Administrator'],
                             password: 'MxrbDemo123!'
        password_policy minimum_length: 12, require_digit: true,
                        require_mixed_case: false, require_symbol: true
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', app_title: 'Project security records'
      end
    end
  end

  def security_snapshot(path)
    Mxrb.open(path) do |project|
      raw = project.all_units.find do |unit|
        project.parse_bson(unit)['$Type'] == 'Security$ProjectSecurity'
      end
      document = project.parse_bson(raw)
      roles = Mxrb::IO::BsonCodec.parse_array(document.fetch('UserRoles'))[:items]
      users = Mxrb::IO::BsonCodec.parse_array(document.fetch('DemoUsers'))[:items]
      policy = document.fetch('PasswordPolicySettings')
      {
        unit_id: raw.fetch('UnitID'), document_id: document.fetch('$ID'),
        roles: roles.map { security_role_snapshot(_1) }.sort_by { _1.fetch(:name) },
        demo_users: users.map { demo_user_snapshot(_1) }.sort_by { _1.fetch(:name) },
        password_policy: policy.reject { |key, _value| key == '$Type' }
      }
    end
  end

  def security_role_snapshot(role)
    {
      id: role.fetch('$ID'), guid: Mxrb::IO::BsonCodec.extract_id(role.fetch('GUID')),
      name: role.fetch('Name'), description: role.fetch('Description'),
      check_security: role.fetch('CheckSecurity'), manage_all_roles: role.fetch('ManageAllRoles'),
      manage_users_without_roles: role.fetch('ManageUsersWithoutRoles'),
      manageable_roles: Mxrb::IO::BsonCodec.parse_array(role.fetch('ManageableRoles'))[:items],
      module_roles: Mxrb::IO::BsonCodec.parse_array(role.fetch('ModuleRoles'))[:items]
    }
  end

  def demo_user_snapshot(user)
    {
      id: user.fetch('$ID'), name: user.fetch('UserName'), password: user.fetch('Password'),
      entity: user.fetch('Entity'),
      roles: Mxrb::IO::BsonCodec.parse_array(user.fetch('UserRoles'))[:items]
    }
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
