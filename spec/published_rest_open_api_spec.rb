# frozen_string_literal: true

require 'spec_helper'

# The OpenAPI documents MxBuild 10.24 and 11 write for a published REST service,
# as recorded for the probe service of the native_rest_http fixture.
# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::PublishedRestOpenApi do
  def parameter(name, type, kind)
    { '$Type' => 'Rest$RestOperationParameter', 'Name' => name, 'ParameterType' => kind,
      'Type' => { '$Type' => "DataTypes$#{type}Type" } }
  end

  def operation(path, microflow, method: 'Get', parameters: [])
    { '$Type' => 'Rest$PublishedRestServiceOperation', 'Path' => path, 'HttpMethod' => method,
      'Microflow' => microflow, 'Parameters' => [3, *parameters] }
  end

  let(:document) do
    {
      'Resources' => [3, {
        '$Type' => 'Rest$PublishedRestServiceResource', 'Name' => 'probe', 'Documentation' => '',
        'Operations' => [2, operation('echo/{id}', 'Probe.Echo', parameters: [parameter('id', 'String', 'Path'),
                                                                              parameter('q', 'Long', 'Query')]),
                         operation('/both', 'Probe.Both'), operation('body', 'Probe.Body', method: 'Post')]
      }]
    }
  end
  let(:returns) { { 'Probe.Echo' => 'Void', 'Probe.Both' => 'String', 'Probe.Body' => 'String' } }

  def service(authentication)
    { 'Path' => 'rest/probe/v1', 'ServiceName' => 'ProbeApi', 'Version' => '1.0',
      'AuthenticationTypesRuntime' => authentication }
  end

  it 'writes the compact version 2 document with the paths, parameters, responses and tags' do
    swagger = described_class.new(service([]), document, return_types: returns).swagger
    expect(swagger).to start_with('{"swagger":"2.0","info":{"title":"ProbeApi","version":"1.0"},"host":"{host}",' \
                                  '"basePath":"{applicationRootUrlPath}rest/probe/v1","schemes":["{scheme}"],"paths":{')
    paths = JSON.parse(swagger).fetch('paths')
    expect(paths.keys).to eq(['/probe/echo/{id}', '/probe/both', '/probe/body'])
    expect(paths['/probe/echo/{id}']['get']).to eq(
      'tags' => ['probe'],
      'parameters' => [{ 'name' => 'id', 'in' => 'path', 'required' => true, 'type' => 'string' },
                       { 'name' => 'q', 'in' => 'query', 'type' => 'integer' }],
      'responses' => { '200' => { 'description' => 'successful operation' } }
    )
    expect(paths['/probe/body']['post']).to eq(
      'tags' => ['probe'],
      'responses' => { '200' => { 'description' => 'successful operation', 'schema' => { 'type' => 'string' } } }
    )
    expect(JSON.parse(swagger).keys).to eq(%w[swagger info host basePath schemes paths tags])
    expect(swagger).to end_with('"tags":[{"name":"probe","description":""}]}')
  end

  it 'adds the unauthorized response and basic authentication to a service that authenticates' do
    generator = described_class.new(service(%w[Basic Session]), document, return_types: returns)
    swagger = JSON.parse(generator.swagger)
    expect(swagger.keys)
      .to eq(%w[swagger info host basePath schemes paths responses securityDefinitions security tags])
    expect(swagger.dig('paths', '/probe/both', 'get', 'responses', '401'))
      .to eq('$ref' => '#/responses/UnauthorizedError')
    expect(swagger['responses']).to eq('UnauthorizedError' => {
                                         'description' => 'Authentication information is missing or invalid',
                                         'headers' => { 'WWW-Authenticate' => { 'type' => 'string' } }
                                       })
    expect(swagger['securityDefinitions']).to eq('basicAuth' => { 'type' => 'basic' })
    expect(swagger['security']).to eq([{ 'basicAuth' => [] }])
    openapi = JSON.parse(generator.openapi)
    expect(openapi.keys).to eq(%w[openapi info servers paths components security tags])
    expect(generator.openapi).to include(%(  "security": [\n    {\n      "basicAuth": [ ]\n    }\n  ],\n))
    expect(openapi['components']).to eq(
      'responses' => { 'UnauthorizedError' => {
        'description' => 'Authentication information is missing or invalid',
        'headers' => { 'WWW-Authenticate' => { 'schema' => { 'type' => 'string' } } }
      } },
      'securitySchemes' => { 'basicAuth' => { 'type' => 'http', 'scheme' => 'basic' } }
    )
    session = described_class.new(service(['Session']), document, return_types: returns)
    expect(JSON.parse(session.swagger).keys).to eq(%w[swagger info host basePath schemes paths responses tags])
    expect(JSON.parse(session.openapi)['components'].keys).to eq(['responses'])
  end

  it 'writes the indented version 3 document with schemas, plain-text content and an empty components object' do
    openapi = described_class.new(service([]), document, return_types: returns).openapi
    head = ['{', '  "openapi": "3.0.4",', '  "info": {', '    "title": "ProbeApi",', '    "version": "1.0"', '  },',
            '  "servers": [', '    {', '      "url": "{applicationRootUrl}rest/probe/v1"', '    }', '  ],',
            '  "paths": {']
    expect(openapi).to start_with("#{head.join("\n")}\n")
    expect(openapi).to include(%(  "components": { },\n))
    expect(openapi).to end_with(%(  "tags": [\n    {\n      "name": "probe",\n      "description": ""\n    }\n  ]\n}))
    paths = JSON.parse(openapi).fetch('paths')
    expect(paths['/probe/echo/{id}']['get']['parameters']).to eq(
      [{ 'name' => 'id', 'in' => 'path', 'required' => true, 'schema' => { 'type' => 'string' } },
       { 'name' => 'q', 'in' => 'query', 'schema' => { 'type' => 'integer' } }]
    )
    expect(paths['/probe/both']['get']['responses']).to eq(
      '200' => { 'description' => 'successful operation',
                 'content' => { 'text/plain' => { 'schema' => { 'type' => 'string' } } } }
    )
  end
end
# rubocop:enable Metrics/BlockLength
