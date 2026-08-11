# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'spec_helper'
require 'tmpdir'

# Generic contract for projecting arbitrary Mendix published REST services
# into the Ruby runtime. No application-specific model is assumed here.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby mode published REST services' do
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def define_source(path)
    Mxrb.define(path) do
      mendix_version '10.24.4'
      self.module(:Catalog) do
        enumeration(:PublicationState) do
          value :Published
          value :Draft
        end
        entity(:Product) do
          string :TenantID
          string :Code
          string :Name
          enum :State, enumeration: 'Catalog.PublicationState'
        end
      end
      self.module(:PublicAPI) do
        entity(:RequestEnvelope) do
          non_persistent!
          integer :TotalCount
        end
        entity(:Parameter) do
          non_persistent!
          string :Name
          string :Value
        end
        entity(:Credential) do
          non_persistent!
          string :Code
        end
        microflow :ListProducts do
          parameter :TenantID, type: :String
          return_type '$Type' => 'DataTypes$ListType', 'Entity' => 'Catalog.Product'
          retrieve_objects(
            'Catalog.Product', as: :products,
                               xpath: '[TenantID = $TenantID][State = Catalog.PublicationState.Published]'
          )
          return_value '$products'
        end
        microflow :EchoRequest do
          parameter :Payload, type: :RequestEnvelope
          return_type :RequestEnvelope
          return_value '$Payload'
        end
      end
    end
    add_published_rest_service(path)
  end

  def add_published_rest_service(path)
    mpr = Mxrb::IO::MprFile.open(path, readonly: false)
    module_id = mpr.units_by_containment('Modules').find do |unit|
      mpr.parse_contents(unit)['Name'] == 'PublicAPI'
    end.fetch('UnitID')
    operation = {
      '$ID' => SecureRandom.uuid, '$Type' => 'Rest$PublishedRestServiceOperation',
      'HttpMethod' => 'Get', 'Path' => 'products/{TenantID}',
      'Microflow' => 'PublicAPI.ListProducts', 'SuccessStatusCode' => '200 OK'
    }
    post_operation = {
      '$ID' => SecureRandom.uuid, '$Type' => 'Rest$PublishedRestServiceOperation',
      'HttpMethod' => 'Post', 'Path' => 'echo',
      'Microflow' => 'PublicAPI.EchoRequest', 'SuccessStatusCode' => 'Created'
    }
    resource = {
      '$ID' => SecureRandom.uuid, '$Type' => 'Rest$PublishedRestServiceResource',
      'Name' => 'Products',
      'Operations' => Mxrb::IO::BsonCodec.build_array([operation, post_operation], marker: 2)
    }
    mpr.insert_unit(
      container_uuid: module_id, containment_name: 'Documents',
      contents_doc: {
        '$Type' => 'Rest$PublishedRestService', 'Name' => 'CatalogAPI',
        'Version' => '1.0.0', 'Path' => 'rest/catalog/v1', 'EnableCors' => true,
        'RequiresAuthentication' => false,
        'Resources' => Mxrb::IO::BsonCodec.build_array([resource], marker: 3)
      }
    )
  ensure
    mpr&.close
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  it 'discovers routes and executes their microflows without project-specific configuration' do
    Dir.mktmpdir('mxrb-published-rest-') do |dir|
      source = File.join(dir, 'Catalog.mpr')
      root = File.join(dir, 'catalog_app')
      rebuilt = File.join(dir, 'Catalog_rebuilt.mpr')
      define_source(source)

      Mxrb::Exporter.new(source, root, mode: :ruby).export!
      manifest = JSON.parse(File.read(File.join(root, '.mxrb', 'ruby-app.json')))
      api_module = manifest.fetch('modules').find { _1.fetch('name') == 'PublicAPI' }
      operations = api_module.dig('endpoints', 0, 'operations')
      route = operations.find { _1.fetch('method') == 'GET' }

      expect(route).to include(
        'method' => 'GET', 'path' => '/rest/catalog/v1/products/{TenantID}',
        'microflow' => 'PublicAPI.ListProducts', 'success_status' => 200
      )
      expect(operations.find { _1.fetch('method') == 'POST' }).to include(
        'path' => '/rest/catalog/v1/echo', 'microflow' => 'PublicAPI.EchoRequest',
        'success_status' => 201
      )
      %w[request_envelope_dto.rb parameter_dto.rb credential_dto.rb].each do |filename|
        expect(File).to exist(File.join(root, 'app', 'dtos', 'public_api', filename))
      end
      expect(Dir.glob(File.join(root, 'app', 'dtos', '**', '*_2.rb'))).to be_empty

      application = Mxrb::RubyApp::Application.new(root)
      seed_products(application)
      result = application.invoke_rest(
        application.rest_routes.fetch(0), path_parameters: { 'TenantID' => 'tenant-a' }
      )
      expect(result.map { _1.dig(:attributes, 'Code') }).to contain_exactly('P-1', 'P-2')
      application.close

      verify_http_route(root)
      verify_json_body_route(root)
      expect(Mxrb::RubyApp.compile(root, rebuilt)).to eq(rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid
      Mxrb.open(rebuilt) do |project|
        public_api = project.modules.find { _1.name == 'PublicAPI' }
        expect(public_api.infrastructure_documents.map { _1[:type] }).to include('Rest$PublishedRestService')
        expect(public_api.entities.reject(&:persistable).map(&:name))
          .to contain_exactly('Credential', 'Parameter', 'RequestEnvelope')
      end
    end
  end

  def seed_products(application)
    [
      %w[tenant-a P-1 Published], %w[tenant-a P-2 Published],
      %w[tenant-a P-3 Draft], %w[tenant-b P-4 Published]
    ].each do |tenant, code, state|
      application.create_record(
        'Catalog.Product', 'TenantID' => tenant, 'Code' => code, 'Name' => code,
                           'State' => "Catalog.PublicationState.#{state}"
      )
    end
  end

  def verify_http_route(root) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    server = Mxrb::RubyApp::Server.new(root, port: 0)
    request_class = Struct.new(:path, :request_method, :body, :query, :headers) do
      def [](name) = headers[name]
    end
    request = request_class.new('/rest/catalog/v1/products/tenant-a', 'GET', '', {}, {})
    response = Mxrb::Http::Response.new
    server.send(:dispatch, request, response)
    expect(response.status).to eq(200)
    expect(response['Access-Control-Allow-Origin']).to eq('*')
    expect(JSON.parse(response.body).map { _1.dig('attributes', 'Code') })
      .to contain_exactly('P-1', 'P-2')
  ensure
    server&.application&.close
  end

  def verify_json_body_route(root) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    server = Mxrb::RubyApp::Server.new(root, port: 0)
    request_class = Struct.new(:path, :request_method, :body, :query, :headers) do
      def [](name) = headers[name]
    end
    request = request_class.new(
      '/rest/catalog/v1/echo', 'POST', JSON.generate('TotalCount' => 2), {}, {}
    )
    response = Mxrb::Http::Response.new
    server.send(:dispatch, request, response)
    expect(response.status).to eq(201)
    expect(JSON.parse(response.body)).to include(
      'type' => 'PublicAPI.RequestEnvelope', 'attributes' => { 'TotalCount' => 2 }
    )
  ensure
    server&.application&.close
  end
end
# rubocop:enable Metrics/BlockLength
