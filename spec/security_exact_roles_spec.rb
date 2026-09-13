# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'project security role preservation' do # rubocop:disable Metrics/BlockLength
  it 'distinguishes conventional system roles from an exact native role list' do
    implicit = Mxrb::Dsl::SecurityBuilder.new.tap do |security|
      security.user_role(:Administrator, admin: true)
    end.to_h.fetch(:user_roles).first
    explicit = Mxrb::Dsl::SecurityBuilder.new.tap do |security|
      security.user_role(:Administrator, module_roles: [], exact_module_roles: true, admin: true)
    end.to_h.fetch(:user_roles).first

    expect(implicit.fetch(:module_roles)).to eq(['System.Administrator'])
    expect(explicit.fetch(:module_roles)).to be_empty
  end

  it 'round-trips an exported role without inventing a System role' do
    Dir.mktmpdir('mxrb-exact-security-') do |root|
      source = File.join(root, 'source.mpr')
      exported = File.join(root, 'ruby')
      rebuilt = File.join(root, 'rebuilt.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        security do
          user_role :Administrator, module_roles: [], exact_module_roles: true, admin: true
          admin_user_role :Administrator
        end
      end

      Mxrb::Exporter.new(source, exported).export!(parallel: false)
      security_source = File.read(File.join(exported, 'app', 'security', 'security.rb'))
      expect(security_source).to include('module_roles: []')
      with_output(rebuilt) { load File.join(exported, 'project.rb') }

      expect(Mxrb.compare(source, rebuilt)).to be_identical
    end
  end

  it 'preserves exact roles through the Ruby application declaration path' do
    security = Class.new(Mxrb::RubyApp::ProjectSecurity)
    security.user_role(
      :Administrator, module_roles: [], exact_module_roles: true, manage_all_roles: true
    )
    declaration = security.native_definition.fetch(:user_roles).first
    document = Mxrb::Writer.allocate.send(:ruby_project_user_roles, [declaration], nil).last

    expect(Mxrb::IO::BsonCodec.parse_array(document.fetch('ModuleRoles')).fetch(:items)).to be_empty
  end

  def with_output(path)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = path
    yield
  ensure
    ENV['MXRB_OUTPUT_PATH'] = previous
  end
end
