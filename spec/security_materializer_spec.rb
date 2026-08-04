# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::SecurityMaterializer do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'App.mpr')
      @deployment = File.join(root, 'deployment')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        security do
          security_level :CheckEverything
          user_role :User, module_roles: ['App.User']
          user_role :Administrator,
                    module_roles: ['App.Administrator', 'System.Administrator'], admin: true
        end
        self.module(:App) do
          module_role :User
          module_role :Administrator
        end
      end
      mpr = Mxrb::IO::MprFile.open(@mpr, readonly: true)
      @source = mpr.all_units.map { mpr.parse_contents(_1) }
                   .find { _1['$Type'] == 'Security$ProjectSecurity' }
      mpr.close
      FileUtils.mkdir_p(File.join(@deployment, 'model'))
      other = { '$ID' => '11111111-1111-4111-8111-111111111111', '$Type' => 'Projects$Project' }
      old = @source.merge('SecurityLevel' => 'CheckNothing', 'UserRoles' => [])
      File.binwrite(File.join(@deployment, 'model', 'model.mdp'),
                    Mxrb::IO::BsonCodec.serialize(other) + Mxrb::IO::BsonCodec.serialize(old))
      File.write(File.join(@deployment, 'model', 'metadata.json'), JSON.generate('RuntimeVersion' => '11.12.1'))
      example.run
    end
  end

  it 'materializes flattened security BSON and matching Runtime role metadata' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    package = Mxrb::Compiler::ModelPackage.read(result.model_path)
    security = package.find(Mxrb::IO::BsonCodec.extract_id(@source['$ID'])).document
    expect(security).to include('SecurityLevel' => 'CheckEverything', 'AdminUserRole' => 'Administrator')
    expect(security['UserRoles'].map { _1['Name'] }).to eq(%w[User Administrator])
    expect(security['UserRoles'].last).to include(
      'IsSystemAdministrator' => true, 'ManageableRoles' => %w[User Administrator]
    )
    metadata = JSON.parse(File.read(result.metadata_path))
    expect(metadata['Roles']).to eq(result.roles)
    expect(metadata.dig('Roles', metadata['AdminRole'], 'Name')).to eq('Administrator')
  end

  it 'normalizes BSON marker arrays on demo-user role assignments' do
    compiler = described_class.allocate
    user = { 'Name' => 'Demo', 'UserRoles' => [2, 'User', 'Administrator'] }
    expect(compiler.send(:compile_demo_user, user))
      .to include('UserRoles' => %w[User Administrator])

    source = @source.merge('DemoUsers' => [2, user])
    expect(compiler.send(:compiled_document, source, []).fetch('DemoUsers').first)
      .to include('Name' => 'Demo', 'UserRoles' => %w[User Administrator])
  end

  it 'rejects missing project security, model documents, and invalid admin roles' do
    allow(Mxrb::IO::MprFile).to receive(:open).and_call_original
    allow(Mxrb::IO::MprFile).to receive(:open).with('/missing/App.mpr', readonly: true)
                                              .and_raise(Errno::ENOENT)
    expect { described_class.new('/missing/App.mpr', deployment: @deployment).materialize }
      .to raise_error(Errno::ENOENT)

    no_security = File.join(File.dirname(@mpr), 'NoSecurity.mpr')
    Mxrb.define(no_security) do
      mendix_version '11.12.1'
      self.module(:App)
    end
    mpr = Mxrb::IO::MprFile.open(no_security)
    security_unit = mpr.all_units.find do |unit|
      mpr.parse_contents(unit)['$Type'] == 'Security$ProjectSecurity'
    end
    mpr.delete_unit(security_unit['UnitID'])
    mpr.close
    expect { described_class.new(no_security, deployment: @deployment).materialize }
      .to raise_error(Mxrb::CompilationError, /no project security/)

    package = Mxrb::Compiler::ModelPackage.read(File.join(@deployment, 'model', 'model.mdp'))
    package.replace(Mxrb::IO::BsonCodec.extract_id(@source['$ID']),
                    @source.merge('$ID' => '33333333-3333-4333-8333-333333333333'))
           .write(File.join(@deployment, 'model', 'model.mdp'))
    result = described_class.new(@mpr, deployment: @deployment).materialize
    expect(Mxrb::Compiler::ModelPackage.read(result.model_path).find(
             Mxrb::IO::BsonCodec.extract_id(@source['$ID'])
           )).not_to be_nil

    File.binwrite(File.join(@deployment, 'model', 'model.mdp'),
                  Mxrb::IO::BsonCodec.serialize(@source))
    @source['AdminUserRole'] = 'Missing'
    allow_any_instance_of(described_class).to receive(:source_security).and_return(@source)
    expect { described_class.new(@mpr, deployment: @deployment).materialize }
      .to raise_error(Mxrb::CompilationError, /admin role.*not defined/)
  end
end
# rubocop:enable Metrics/BlockLength
