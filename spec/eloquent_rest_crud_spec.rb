# frozen_string_literal: true

require 'json'
require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'eloquent Ruby REST CRUD' do
  def request_class
    @request_class ||= Struct.new(:path, :request_method, :body, :query, :headers) do
      def [](name) = headers[name]
    end
  end

  def define_source(path) # rubocop:disable Metrics/AbcSize
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:EloquentApi) do
        entity(:Item) do
          autonumber :ItemId
          string :Name
        end

        microflow(:ListItems) do
          return_type list_of('EloquentApi.Item')
          create_list 'EloquentApi.Item', as: :Items
          return_value '$Items'
        end
        microflow(:ShowItem) do
          parameter :id, type: :Integer
          return_type object_of('EloquentApi.Item')
          retrieve_objects 'EloquentApi.Item', as: :Item, xpath: '[ItemId = $id]', single: true
          return_value '$Item'
        end
        microflow(:CreateItem) do
          parameter :name, type: :String
          return_type object_of('EloquentApi.Item')
          create_object 'EloquentApi.Item', as: :Item, commit: true do
            set 'EloquentApi.Item.Name', to: '$name'
          end
          return_value '$Item'
        end
        microflow(:UpdateItem) do
          parameter :id, type: :Integer
          parameter :name, type: :String
          return_type object_of('EloquentApi.Item')
          retrieve_objects 'EloquentApi.Item', as: :Item, xpath: '[ItemId = $id]', single: true
          change_object :Item, commit: true do
            set 'EloquentApi.Item.Name', to: '$name'
          end
          return_value '$Item'
        end
        microflow(:DeleteItem) do
          parameter :id, type: :Integer
          return_type :Boolean
          retrieve_objects 'EloquentApi.Item', as: :Item, xpath: '[ItemId = $id]', single: true
          delete :Item
          return_value 'true'
        end

        published_rest_service :ItemsApi, path: 'api/eloquent', version: '1.0' do
          resource :items do
            get :index, path: '', microflow: 'EloquentApi.ListItems'
            get :show, path: '{id}', microflow: 'EloquentApi.ShowItem'
            post :create, path: '', microflow: 'EloquentApi.CreateItem',
                          success_status: :created
            put :update, path: '{id}', microflow: 'EloquentApi.UpdateItem'
            delete :destroy, path: '{id}', microflow: 'EloquentApi.DeleteItem',
                             success_status: :no_content
          end
        end
      end
    end
  end # rubocop:enable Metrics/AbcSize

  def install_controller(root)
    directory = File.join(root, 'app', 'controllers', 'eloquent_api')
    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, 'items_controller.rb'), <<~RUBY)
      # frozen_string_literal: true

      module EloquentApi
        class ItemsController < Mxrb::RubyApp::Controller
          controller_name 'EloquentApi.Items'

          def item = model('EloquentApi.Item')
          def index = all(item)
          def show(id:) = find_by!(item, item_id: id)
          def create_item(name:) = create(item, name:)
          def update_item(id:, name:) = update_by(item, attribute: :item_id, value: id, name:)
          def destroy_item(id:) = destroy_by(item, attribute: :item_id, value: id)
        end
      end
    RUBY

    actions = {
      'list_items.rb' => :index,
      'show_item.rb' => :show,
      'create_item.rb' => :create_item,
      'update_item.rb' => :update_item,
      'delete_item.rb' => :destroy_item
    }
    actions.each do |filename, action|
      path = File.join(root, 'app', 'services', 'eloquent_api', filename)
      source = File.read(path)
      declaration = "    controller 'EloquentApi.Items', action: :#{action}\n"
      File.write(path, source.sub(/(    mendix_name .*\n)/, "\\1#{declaration}"))
    end
  end

  def request(server, method, path, body = nil)
    payload = body && JSON.generate(body)
    response = Mxrb::Http::Response.new
    server.send(:dispatch, request_class.new(path, method, payload.to_s, {}, {}), response)
    parsed = response.body.to_s.empty? ? nil : JSON.parse(response.body)
    [response.status, parsed]
  end

  it 'routes five HTTP operations through application-owned controllers and typed CRUD helpers' do
    Dir.mktmpdir('mxrb-eloquent-rest-') do |dir|
      source = File.join(dir, 'source.mpr')
      root = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      define_source(source)

      Mxrb::Exporter.new(source, root, mode: :ruby).export!
      install_controller(root)
      endpoint = File.read(File.join(root, '.mxrb', 'mendix', 'modules', 'EloquentApi',
                                     'infrastructure', 'endpoints', 'items_api.rb'))
      expect(endpoint).to include(
        'published_rest_service :ItemsApi', 'resource :items', 'get :list_items',
        'post :create_item', 'put :update_item', 'delete :delete_item',
        'response 201', 'response 204'
      )
      expect(endpoint).not_to include('resources:', 'operations:', 'deep_structure:', 'bson_binary(')
      rest_metadata = JSON.parse(
        File.read(File.join(root, '.mxrb', 'mendix', '.mxrb', 'rest_metadata.json'))
      )
      expect(rest_metadata.fetch('operations').flat_map { _1.fetch('responses') }
                          .map { _1.fetch('status') }).to contain_exactly(201, 204)

      server = Mxrb::RubyApp::Server.new(root, port: 0)
      status, created = request(server, 'POST', '/api/eloquent/items', Name: 'First')
      expect(status).to eq(201)
      internal_id = created.fetch('id')
      id = created.dig('attributes', 'ItemId')

      expect(request(server, 'GET', '/api/eloquent/items').last)
        .to contain_exactly(include('id' => internal_id, 'attributes' => include('Name' => 'First')))
      expect(request(server, 'GET', "/api/eloquent/items/#{id}").last)
        .to include('id' => internal_id, 'attributes' => include('Name' => 'First'))
      expect(request(server, 'PUT', "/api/eloquent/items/#{id}", Name: 'Updated').last)
        .to include('id' => internal_id, 'attributes' => include('Name' => 'Updated'))
      expect(request(server, 'DELETE', "/api/eloquent/items/#{id}")).to eq([204, nil])
      expect(request(server, 'GET', "/api/eloquent/items/#{id}").first).to eq(404)

      expect(Mxrb::RubyApp.compile(root, rebuilt)).to eq(rebuilt)
      expect(Mxrb.validate(rebuilt)).to be_valid

      mpr = Mxrb::IO::MprFile.open(rebuilt)
      documents = mpr.all_units.map { mpr.parse_contents(_1) }
      service = documents.find do |document|
        document['$Type'] == 'Rest$PublishedRestService' && document['Name'] == 'ItemsApi'
      end
      operations = Mxrb::IO::BsonCodec.parse_array(service.fetch('Resources'))[:items].flat_map do |resource|
        Mxrb::IO::BsonCodec.parse_array(resource.fetch('Operations'))[:items]
      end
      expect(operations.map { _1.fetch('Path') }).to eq(['', '{id}', '', '{id}', '{id}'])
      expect(operations.filter { _1.fetch('Microflow').end_with?('ShowItem') }
                       .flat_map { Mxrb::IO::BsonCodec.parse_array(_1.fetch('Parameters'))[:items] }
                       .map { [_1.fetch('Name'), _1.fetch('ParameterType')] })
        .to eq([%w[id Path]])
      expect(operations.filter { _1.fetch('Microflow').end_with?('CreateItem') }
                       .flat_map { Mxrb::IO::BsonCodec.parse_array(_1.fetch('Parameters'))[:items] }
                       .map { [_1.fetch('Name'), _1.fetch('ParameterType')] })
        .to eq([%w[name Query]])
      expect(operations.first(4).map { _1.fetch('ExportMapping') }).to all(match(/\.EM_/))
      expect(operations.map { _1.fetch('Documentation') }).not_to include(match(/Responses:/))
      expect(documents.count { _1['$Type'] == 'JsonStructures$JsonStructure' }).to eq(2)
      expect(documents.count { _1['$Type'] == 'ExportMappings$ExportMapping' }).to eq(2)
    ensure
      mpr&.close
      server&.application&.close
    end
  end

  it 'uses conventional Mendix folders for new flows, mappings, and JSON structures' do
    Dir.mktmpdir('mxrb-eloquent-folders-') do |dir|
      source = File.join(dir, 'source.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:EloquentApi) {}
      end

      mpr = Mxrb::IO::MprFile.open(source, readonly: false)
      module_id = mpr.units_by_containment('Modules').find do |raw|
        mpr.parse_contents(raw)['Name'] == 'EloquentApi'
      end.fetch('UnitID')
      folder_ids = %w[Flows Export_Mappings Json_Structures].to_h do |name|
        id = mpr.insert_unit(
          container_uuid: module_id, containment_name: 'Folders',
          contents_doc: { '$Type' => 'Projects$Folder', 'Name' => name }
        )
        [name, id]
      end
      mpr.close
      mpr = nil

      define_source(source)

      mpr = Mxrb::IO::MprFile.open(source)
      grouped = mpr.all_units.group_by do |raw|
        [mpr.parse_contents(raw)['$Type'], raw['ContainerID']]
      end
      expect(grouped.fetch(['Microflows$Microflow', folder_ids.fetch('Flows')]).size).to eq(5)
      expect(grouped.fetch(
        ['ExportMappings$ExportMapping', folder_ids.fetch('Export_Mappings')]
      ).size).to eq(2)
      expect(grouped.fetch(
        ['JsonStructures$JsonStructure', folder_ids.fetch('Json_Structures')]
      ).size).to eq(2)
    ensure
      mpr&.close
    end
  end

  it 'keeps resources hashes compatible and rejects ambiguous block declarations' do
    builder = Mxrb::Dsl::ModuleBuilder.new('Compatibility')
    expect do
      builder.published_rest_service(
        :Legacy, path: 'api', version: '1',
                 resources: [{ name: 'items', operations: [] }]
      )
    end.not_to raise_error
    expect do
      builder.published_rest_service(
        :Ambiguous, path: 'api', version: '1', resources: []
      ) { resource :items }
    end.to raise_error(ArgumentError, /resources: or a block/)
  end

  it 'keeps route responses in typed metadata instead of human documentation' do
    builder = Mxrb::Dsl::ModuleBuilder.new('DocumentedApi')
    builder.published_rest_service(:API_Service, path: 'api', version: '1') do
      resource :items do
        post :create, path: '', microflow: 'DocumentedApi.MF_Items_Create',
                      summary: 'Create an item', documentation: 'Validates the request.' do
          response 201, description: 'Item created.'
          response 422, description: 'Validation failed.'
        end
      end
    end

    service = builder.native_documents.first.fetch(:doc)
    resource = Mxrb::IO::BsonCodec.parse_array(service.fetch('Resources'))[:items].first
    operation = Mxrb::IO::BsonCodec.parse_array(resource.fetch('Operations'))[:items].first
    expect(operation).to include('Summary' => 'Create an item')
    expect(operation).not_to have_key('SuccessStatusCode')
    expect(operation.fetch('Documentation')).to eq('Validates the request.')
    expect(builder.rest_response_metadata.first.fetch(:responses)).to eq(
      [
        { status: 201, description: 'Item created.' },
        { status: 422, description: 'Validation failed.' }
      ]
    )
  end

  it 'implements HTTP success codes through a System.HttpResponse parameter' do
    builder = Mxrb::Dsl::ModuleBuilder.new('NativeStatusApi')
    %i[List Create Accept Delete].each do |name|
      builder.microflow(name) { return_type :Boolean }
    end
    builder.published_rest_service(:API, path: 'api', version: '1') do
      resource :items do
        get :index, path: '', microflow: 'NativeStatusApi.List', success_status: '200 OK'
        post :create, path: '', microflow: 'NativeStatusApi.Create', success_status: 201
        put :accept, path: '{id}', microflow: 'NativeStatusApi.Accept' do
          response 202, description: 'Accepted.'
        end
        delete :destroy, path: '{id}', microflow: 'NativeStatusApi.Delete',
                         success_status: :no_content
      end
    end

    service = builder.native_documents.first.fetch(:doc)
    resource = Mxrb::IO::BsonCodec.parse_array(service.fetch('Resources'))[:items].first
    operations = Mxrb::IO::BsonCodec.parse_array(resource.fetch('Operations'))[:items]
    expect(operations).to all(satisfy { !_1.key?('SuccessStatusCode') })
    expect(operations.map { _1.fetch('Documentation') }).to eq(['', '', '', ''])
    expect(builder.rest_response_metadata.flat_map { _1.fetch(:responses) })
      .to eq([
               { status: 200, description: '' }, { status: 201, description: '' },
               { status: 202, description: 'Accepted.' }, { status: 204, description: '' }
             ])

    statuses = builder.microflows.to_h do |flow|
      parameter = flow.fetch(:parameters).find do |candidate|
        candidate.dig(:type, 'Entity') == 'System.HttpResponse'
      end
      assignment = Array(flow[:body]).first
      [flow.fetch(:name), [parameter&.fetch(:name, nil), assignment&.dig(:members, 0, :value)]]
    end
    expect(statuses).to include(
      'List' => [nil, nil], 'Create' => ['HttpResponse', 201],
      'Accept' => ['HttpResponse', 202], 'Delete' => ['HttpResponse', 204]
    )
  end

  it 'preserves explicit resources parameters when a local microflow has a different signature' do
    builder = Mxrb::Dsl::ModuleBuilder.new('Compatibility')
    builder.microflow(:LegacyLookup) do
      parameter :current_id, type: :Integer
    end
    explicit_parameters = [{
      id: SecureRandom.uuid,
      name: 'legacyId',
      description: 'Hand-authored legacy parameter',
      microflow_parameter: 'Compatibility.LegacyLookup.legacy_identifier',
      parameter_type: :header,
      type: :string
    }]

    builder.published_rest_service(
      :Legacy, path: 'api', version: '1',
               resources: [{
                 name: 'items',
                 operations: [{
                   method: :get, path: '{current_id}', microflow: 'Compatibility.LegacyLookup',
                   parameters: explicit_parameters
                 }]
               }]
    )

    service = builder.native_documents.find { _1.fetch(:name) == 'Legacy' }.fetch(:doc)
    resource = Mxrb::IO::BsonCodec.parse_array(service.fetch('Resources'))[:items].first
    operation = Mxrb::IO::BsonCodec.parse_array(resource.fetch('Operations'))[:items].first
    parameter = Mxrb::IO::BsonCodec.parse_array(operation.fetch('Parameters'))[:items].first

    expect(parameter).to include(
      '$ID' => explicit_parameters.first.fetch(:id),
      'Name' => 'legacyId',
      'Description' => 'Hand-authored legacy parameter',
      'MicroflowParameter' => 'Compatibility.LegacyLookup.legacy_identifier',
      'ParameterType' => 'Header',
      'Type' => include('$Type' => 'DataTypes$StringType')
    )
  end

  it 'exports hand-authored operation parameters semantically and preserves them' do
    Dir.mktmpdir('mxrb-manual-rest-') do |dir|
      source = File.join(dir, 'source.mpr')
      root = File.join(dir, 'ruby')
      rebuilt = File.join(dir, 'rebuilt.mpr')
      define_source(source)

      mpr = Mxrb::IO::MprFile.open(source)
      service_unit = mpr.all_units.find do |unit|
        mpr.parse_contents(unit)['$Type'] == 'Rest$PublishedRestService'
      end
      service = mpr.parse_contents(service_unit)
      resources = Mxrb::IO::BsonCodec.parse_array(service.fetch('Resources'))[:items]
      operations = resources.flat_map do |resource|
        Mxrb::IO::BsonCodec.parse_array(resource.fetch('Operations'))[:items]
      end
      parameter = Mxrb::IO::BsonCodec.parse_array(
        operations.find { _1.fetch('Microflow').end_with?('ShowItem') }.fetch('Parameters')
      )[:items].first
      parameter.merge!(
        'Name' => 'legacyId', 'Description' => 'Hand-authored legacy parameter',
        'MicroflowParameter' => 'LegacyApi.ManualLookup.identifier',
        'ParameterType' => 'Header'
      )
      mpr.update_unit(service_unit.fetch('UnitID'), service)
      mpr.close
      mpr = nil

      Mxrb::Exporter.new(source, root, mode: :ruby).export!
      endpoint = File.read(File.join(root, '.mxrb', 'mendix', 'modules', 'EloquentApi',
                                     'infrastructure', 'endpoints', 'items_api.rb'))
      expect(endpoint).to include(
        'published_rest_service :ItemsApi',
        'parameter :legacyId, type: :integer, in: :header'
      )
      expect(endpoint).not_to include('native_document :ItemsApi', 'deep_structure:')

      Mxrb::RubyApp.compile(root, rebuilt)
      rebuilt_mpr = Mxrb::IO::MprFile.open(rebuilt)
      rebuilt_service = rebuilt_mpr.all_units.map { rebuilt_mpr.parse_contents(_1) }.find do |document|
        document['$Type'] == 'Rest$PublishedRestService'
      end
      rebuilt_resources = Mxrb::IO::BsonCodec.parse_array(rebuilt_service.fetch('Resources'))[:items]
      rebuilt_operations = rebuilt_resources.flat_map do |resource|
        Mxrb::IO::BsonCodec.parse_array(resource.fetch('Operations'))[:items]
      end
      rebuilt_parameters = rebuilt_operations.filter_map do |operation|
        Mxrb::IO::BsonCodec.parse_array(operation.fetch('Parameters'))[:items].first
      end
      rebuilt_parameter = rebuilt_parameters.find { _1['Name'] == 'legacyId' }

      expect(rebuilt_parameter).to include(
        'Name' => 'legacyId',
        'Description' => 'Hand-authored legacy parameter',
        'MicroflowParameter' => 'LegacyApi.ManualLookup.identifier',
        'ParameterType' => 'Header',
        'Type' => include('$Type' => 'DataTypes$IntegerType')
      )
    ensure
      mpr&.close
      rebuilt_mpr&.close
    end
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
