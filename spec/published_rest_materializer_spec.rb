# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# The published REST services MxBuild 10.24 writes into model.mdp, as its
# deploy target recorded them for the same model.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::PublishedRestMaterializer do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'App.mpr')
      @deployment = File.join(root, 'deployment')
      Mxrb.define(@mpr) do
        mendix_version '10.24.0'
        self.module(:App) do
          module_role :User
          module_role :Viewer
          microflow :Echo do
            allowed_roles 'App.User'
            parameter :id, type: :String
            parameter :count, type: :Integer
            return_type :String
            return_value '$id'
          end
          microflow :List do
            allowed_roles 'App.User'
            return_type :String
            return_value "'all'"
          end
          published_rest_service :Api, path: 'rest/app/v1/', version: '1.0', requires_authentication: true,
                                       allowed_roles: ['App.User'], authentication_types: %i[basic session] do
            resource :items do
              get :echo, path: '/echo/{id}', microflow: 'App.Echo'
              get :list, path: '', microflow: 'App.List'
            end
          end
        end
        security do
          security_level :CheckFormsAndMicroflows
          user_role :Reader, module_roles: ['App.User']
          user_role :Other, module_roles: ['App.Viewer']
          admin_user_role 'Reader'
        end
      end
      FileUtils.mkdir_p(File.join(@deployment, 'model'))
      Mxrb::Compiler::ModelPackage.empty.write(File.join(@deployment, 'model', 'model.mdp'))
      example.run
    end
  end

  it 'writes each service with its request paths, parameter types, user roles and authentication' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    expect(result.services).to eq(['App.Api'])
    service = Mxrb::Compiler::ModelPackage.read(result.model_path).documents.find do
      _1['$Type'] == 'Rest$PublishedRestService'
    end
    expect(service).to include(
      'Name' => 'Api', 'QualifiedName' => 'App.Api', 'Path' => 'rest/app/v1', 'ServiceName' => 'Api',
      'Version' => '1.0', 'AuthenticationTypesRuntime' => %w[Basic Session], 'AuthenticationMicroflow' => '',
      'AllowedUserRoles' => ['Reader'], 'Parameters' => [], 'OpenApi2Schema' => '', 'OpenApi3Schema' => ''
    )
    resource = service.fetch('Resources').first
    expect(resource['PathRuntime']).to eq('rest/app/v1/items')
    echo, list = resource.fetch('Operations')
    expect(echo).to include('PathRuntime' => 'rest/app/v1/items/echo/{id}', 'HttpMethod' => 'Get',
                            'Microflow' => 'App.Echo', 'Commit' => 'No', 'ObjectHandlingBackup' => 'Create')
    expect(echo.fetch('Parameters').map { _1.values_at('Name', 'DataType', 'ParameterType') })
      .to eq([%w[id String Path], %w[count Integer Query]])
    expect(list['PathRuntime']).to eq('rest/app/v1/items')
  end

  it 'leaves the authentication types out when security is off and refuses what it cannot compile' do
    subject = described_class.new(@mpr, deployment: @deployment)
    document = { 'AuthenticationTypes' => [1, 'Basic'] }
    expect(subject.send(:authentication_types, document, { 'SecurityLevel' => 'CheckNothing' })).to eq([])
    expect { subject.send(:compile_parameter, { 'Name' => 'file', 'Type' => { '$Type' => 'DataTypes$ObjectType' } }) }
      .to raise_error(Mxrb::CompilationError, /file has unsupported type DataTypes\$ObjectType/)
    parameter = { 'Name' => 'tenant', 'ParameterType' => 'Path', 'Type' => { '$Type' => 'DataTypes$LongType' } }
    service = subject.send(:compile_service, Struct.new(:document, :module_name).new(
                                               { 'Name' => 'Scoped', 'Path' => 'rest/{tenant}',
                                                 'Parameters' => [3, parameter] }, 'App'
                                             ), {})
    expect(service.fetch('Parameters').map { _1.values_at('Name', 'DataType') }).to eq([%w[tenant Long]])
    outside = Struct.new(:document, :module_name).new({ 'Name' => 'Loose' }, nil)
    expect { subject.send(:compile_service, outside, {}) }.to raise_error(Mxrb::CompilationError, /Loose is outside/)
  end
end
# rubocop:enable Metrics/BlockLength
