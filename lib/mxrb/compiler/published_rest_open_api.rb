# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    # The OpenAPI 2 and 3 documents MxBuild writes into a published REST service:
    # one path per operation under its resource, the operation's path and query
    # parameters, a plain-text response for a microflow that returns a string,
    # the unauthorized response and basic authentication when the service
    # authenticates, and one tag per resource. Version 2 is compact JSON and
    # version 3 indented with a space inside empty objects and arrays, as MxBuild
    # prints them. MxBuild confirmed string
    # parameters, string and empty responses and basic authentication; the
    # other parameter types follow the OpenAPI conventions.
    class PublishedRestOpenApi
      PARAMETER_TYPES = {
        'DataTypes$StringType' => 'string', 'DataTypes$IntegerType' => 'integer', 'DataTypes$LongType' => 'integer',
        'DataTypes$DecimalType' => 'number', 'DataTypes$BooleanType' => 'boolean', 'DataTypes$DateTimeType' => 'string'
      }.freeze
      SUCCESS = 'successful operation'
      UNAUTHORIZED = 'Authentication information is missing or invalid'

      # service: the compiled Rest$PublishedRestService; document: the service
      # as the MPR stores it; return_types: the Runtime return type of each
      # microflow by qualified name.
      def initialize(service, document, return_types:)
        @service = service
        @document = document
        @return_types = return_types
      end

      def swagger
        document = {
          'swagger' => '2.0', 'info' => info, 'host' => '{host}',
          'basePath' => "{applicationRootUrlPath}#{@service['Path']}", 'schemes' => ['{scheme}'],
          'paths' => paths(version: 2)
        }
        if authenticated?
          document['responses'] = { 'UnauthorizedError' => unauthorized(version: 2) }
          document.merge!(security(version: 2))
        end
        JSON.generate(document.merge('tags' => tags))
      end

      def openapi
        document = {
          'openapi' => '3.0.4', 'info' => info,
          'servers' => [{ 'url' => "{applicationRootUrl}#{@service['Path']}" }],
          'paths' => paths(version: 3), 'components' => components
        }
        document.merge!(security(version: 3)) if authenticated?
        JSON.pretty_generate(document.merge('tags' => tags)).gsub(': {}', ': { }').gsub(': []', ': [ ]')
      end

      private

      def info = { 'title' => @service['ServiceName'].to_s, 'version' => @service['Version'].to_s }
      def authenticated? = !Array(@service['AuthenticationTypesRuntime']).empty?
      def basic? = Array(@service['AuthenticationTypesRuntime']).include?('Basic')
      def resources = items(@document['Resources'])
      def items(value) = IO::BsonCodec.parse_array(value)[:items].grep(Hash)

      def tags
        resources.map { { 'name' => _1['Name'].to_s, 'description' => _1['Documentation'].to_s } }
      end

      def paths(version:)
        resources.each_with_object({}) do |resource, result|
          items(resource['Operations']).each do |operation|
            path = (result["/#{path_segments(resource, operation).join('/')}"] ||= {})
            path[operation['HttpMethod'].to_s.downcase] = operation_document(resource, operation, version:)
          end
        end
      end

      def path_segments(resource, operation)
        [resource['Name'], operation['Path']].map { _1.to_s.gsub(%r{\A/+|/+\z}, '') }.reject(&:empty?)
      end

      def operation_document(resource, operation, version:)
        document = { 'tags' => [resource['Name'].to_s] }
        parameters = items(operation['Parameters']).map { parameter(_1, version:) }
        document['parameters'] = parameters unless parameters.empty?
        document['responses'] = responses(operation, version:)
        document
      end

      def parameter(source, version:)
        document = { 'name' => source['Name'].to_s, 'in' => source['ParameterType'].to_s.downcase }
        document['required'] = true if source['ParameterType'] == 'Path'
        type = { 'type' => PARAMETER_TYPES.fetch(source.dig('Type', '$Type').to_s, 'string') }
        version == 2 ? document.merge(type) : document.merge('schema' => type)
      end

      def responses(operation, version:)
        success = { 'description' => SUCCESS }
        success.merge!(string_response(version:)) if @return_types[operation['Microflow'].to_s] == 'String'
        document = { '200' => success }
        reference = version == 2 ? '#/responses/UnauthorizedError' : '#/components/responses/UnauthorizedError'
        document['401'] = { '$ref' => reference } if authenticated?
        document
      end

      def string_response(version:)
        schema = { 'type' => 'string' }
        version == 2 ? { 'schema' => schema } : { 'content' => { 'text/plain' => { 'schema' => schema } } }
      end

      def unauthorized(version:)
        header = version == 2 ? { 'type' => 'string' } : { 'schema' => { 'type' => 'string' } }
        { 'description' => UNAUTHORIZED, 'headers' => { 'WWW-Authenticate' => header } }
      end

      def components
        return {} unless authenticated?

        document = { 'responses' => { 'UnauthorizedError' => unauthorized(version: 3) } }
        document['securitySchemes'] = { 'basicAuth' => { 'type' => 'http', 'scheme' => 'basic' } } if basic?
        document
      end

      def security(version:)
        return {} unless basic?

        document = version == 2 ? { 'securityDefinitions' => { 'basicAuth' => { 'type' => 'basic' } } } : {}
        document.merge('security' => [{ 'basicAuth' => [] }])
      end
    end
  end
end
