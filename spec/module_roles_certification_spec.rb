# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Module roles certification' do
  it 'round-trips every native field with stable unit and role identities' do
    Dir.mktmpdir('mxrb-module-roles-') do |dir|
      current = File.join(dir, 'ModuleRoles.mpr')
      build_source(current)
      baseline = roles_snapshot(current)

      ruby_app = File.join(dir, 'ruby-app')
      ruby_rebuilt = File.join(dir, 'ruby-rebuilt.mpr')
      Mxrb::Exporter.new(current, ruby_app, mode: :ruby).export!
      ruby_source = Dir[File.join(ruby_app, 'app/security/**/module_security.rb')].then do |paths|
        File.read(paths.fetch(0))
      end
      expect(ruby_source).to include('module_role "User"', 'description: "Uses the app"')
      expect(ruby_source).not_to match(/id:/)
      Mxrb::RubyApp.compile(ruby_app, ruby_rebuilt)
      expect(Mxrb.compare(current, ruby_rebuilt)).to be_identical
      expect(roles_snapshot(ruby_rebuilt)).to eq(baseline)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = File.read(File.join(exported, 'modules/App/security/security.rb'))
        expect(source).to include('module_role :User', 'description: "Uses the app"')
        expect(source).not_to include('native_document', 'deep_structure:', 'bson_binary(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(roles_snapshot(rebuilt)).to eq(baseline)
        current = rebuilt
      end
    end
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :App do
        module_role :User, description: 'Uses the app'
        module_role :Administrator, description: 'Administers the app'
        page(:Home) { title 'Module roles' }
      end
      security do
        security_level :CheckEverything
        user_role :User, module_roles: ['App.User']
        user_role :Administrator, module_roles: ['App.Administrator'], admin: true
        admin_user_role :Administrator
      end
      navigation do
        profile :Responsive, home_page: 'App.Home', app_title: 'Module roles'
      end
    end
  end

  def roles_snapshot(path)
    Mxrb.open(path) do |project|
      mod = project.modules.find { _1.name == 'App' }
      roles = mod.module_roles.map do |role|
        role.slice(:id, :name, :description).transform_values(&:to_s)
      end
      { unit_id: mod.module_security_id.to_s,
        roles: roles.sort_by { _1.fetch(:name) } }
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
