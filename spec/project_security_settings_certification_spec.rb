# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Project security settings certification' do
  it 'round-trips every global setting while keeping the admin password private' do
    Dir.mktmpdir('mxrb-project-security-settings-') do |dir|
      current = File.join(dir, 'ProjectSecuritySettings.mpr')
      build_source(current)
      baseline = security_snapshot(current)

      ruby_app = File.join(dir, 'ruby-app')
      ruby_rebuilt = File.join(dir, 'ruby-rebuilt.mpr')
      Mxrb::Exporter.new(current, ruby_app, mode: :ruby).export!
      ruby_source = File.read(File.join(ruby_app, 'app/security/project_security.rb'))
      expect(ruby_source).to include(
        'security_level "CheckEverything"', 'check_security false',
        'strict_page_url_check false', 'admin_user "MxAdmin"', 'strict_mode true'
      )
      expect(ruby_source).not_to include(admin_secret, 'admin_password')
      Mxrb::RubyApp.compile(ruby_app, ruby_rebuilt)
      expect(Mxrb.compare(current, ruby_rebuilt)).to be_identical
      expect(security_snapshot(ruby_rebuilt)).to eq(baseline)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = File.read(File.join(exported, 'app/security/security.rb'))
        expect(source).to include(
          'security_level "CheckEverything"', 'check_security false',
          'strict_page_url_check false', 'admin_user "MxAdmin"', 'strict_mode true'
        )
        expect(source).not_to include(admin_secret, 'admin_password', 'native_document')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(security_snapshot(rebuilt)).to eq(baseline)
        current = rebuilt
      end
    end
  end

  def build_source(path)
    secret = admin_secret
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        module_role :Administrator
        page(:Home) { title 'Project security settings' }
      end
      security do
        security_level :CheckEverything
        check_security false
        strict_page_url_check false
        strict_mode true
        admin_user 'MxAdmin', password: secret
        user_role :Administrator, admin: true,
                                  module_roles: ['App.Administrator', 'System.Administrator'],
                                  exact_module_roles: true
        admin_user_role :Administrator
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', app_title: 'Project security settings'
      end
    end
  end

  def admin_secret = 'MxrbAdmin-Private-2026!'

  def security_snapshot(path)
    Mxrb.open(path) do |project|
      raw = project.all_units.find do |unit|
        project.parse_bson(unit)['$Type'] == 'Security$ProjectSecurity'
      end
      document = project.parse_bson(raw)
      {
        unit_id: raw.fetch('UnitID'), document_id: document.fetch('$ID'),
        security_level: document.fetch('SecurityLevel'),
        check_security: document.fetch('CheckSecurity'),
        strict_page_url_check: document.fetch('StrictPageUrlCheck'),
        admin_user_name: document.fetch('AdminUserName'),
        admin_password: document.fetch('AdminPassword'),
        admin_user_role: document.fetch('AdminUserRole'),
        strict_mode: document.fetch('StrictMode'),
        file_document_access: access_container_snapshot(document.fetch('FileDocumentAccess')),
        image_access: access_container_snapshot(document.fetch('ImageAccess'))
      }
    end
  end

  def access_container_snapshot(container)
    {
      id: container.fetch('$ID'), type: container.fetch('$Type'),
      rules: Mxrb::IO::BsonCodec.parse_array(container.fetch('AccessRules'))[:items]
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
