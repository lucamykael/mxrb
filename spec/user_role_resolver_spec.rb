# frozen_string_literal: true

require 'spec_helper'

# The user roles MxBuild writes for allowed module roles: the project's roles
# that hold one of them, in the order the project security lists them.
RSpec.describe Mxrb::Compiler::UserRoleResolver do
  def source(roles)
    security = roles && { 'UserRoles' => [3, *roles.map do |name, held|
      { 'Name' => name, 'ModuleRoles' => [1, *held] }
    end] }
    Struct.new(:security) do
      def documents(type) = type == 'Security$ProjectSecurity' && security ? [security] : []
    end.new(security)
  end

  it 'lists the holders of the module roles in project order, once each' do
    resolver = described_class.new(source([['Administrator', %w[System.Administrator App.Admin]],
                                           ['Guest', %w[System.User]], ['User', %w[System.User App.User App.Admin]]]))
    expect(resolver.resolve(%w[App.User App.Admin])).to eq(%w[Administrator User])
    expect(resolver.resolve(['System.User'])).to eq(%w[Guest User])
    expect(resolver.resolve([])).to eq([])
    expect(resolver.resolve_seed(%w[Administrator User])).to eq(%w[Administrator Guest User])
    expect(resolver.resolve_seed(['Administrator'])).to eq(['Administrator'])
  end

  it 'resolves nothing without project security' do
    expect(described_class.new(source(nil)).resolve(['App.User'])).to eq([])
    expect(described_class.new(Object.new).resolve(['App.User'])).to eq([])
  end
end
