# frozen_string_literal: true

module Mxrb
  module Compiler
    PublishedRestMaterialization = Data.define(:model_path, :services)

    # Compiles the published REST services of an MPR into the form the Runtime
    # reads from model.mdp, as MxBuild writes it: full request paths on each
    # resource and operation, parameter data types by name, the user roles that
    # hold an allowed module role and, unless security is off, the
    # authentication types.
    class PublishedRestMaterializer
      include RuntimeDataTypes

      DATA_TYPES = {
        'DataTypes$StringType' => 'String', 'DataTypes$IntegerType' => 'Integer',
        'DataTypes$LongType' => 'Long', 'DataTypes$DecimalType' => 'Decimal',
        'DataTypes$BooleanType' => 'Boolean', 'DataTypes$DateTimeType' => 'DateTime'
      }.freeze
      OPERATION_FIELDS = %w[HttpMethod Microflow ExportMapping ImportMapping ObjectHandlingBackup Commit].freeze

      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        source = SourceModel.read(@mpr_path)
        security = source.units_of('Security$ProjectSecurity').map(&:document).first || {}
        returns = microflow_return_types(source)
        services = source.units_of('Rest$PublishedRestService').map { compile_service(_1, security, returns) }
        model_path = File.join(@deployment, 'model', 'model.mdp')
        write_model(model_path, services)
        PublishedRestMaterialization.new(model_path:, services: services.map { _1.fetch('QualifiedName') }.freeze)
      end

      private

      def write_model(path, services)
        services.reduce(ModelPackage.read(path)) { |package, service| package.upsert(service) }.write(path)
      end

      def compile_service(unit, security, returns = {}) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        document = unit.document
        raise CompilationError, "published REST service #{document['Name']} is outside a module" unless unit.module_name

        path = document['Path'].to_s.delete_suffix('/')
        {
          '$ID' => document['$ID'], '$Type' => document['$Type'], 'CorsConfiguration' => document['CorsConfiguration'],
          'Resources' => items(document['Resources']).map { compile_resource(_1, path) },
          'Parameters' => items(document['Parameters']).map { compile_parameter(_1) },
          'Name' => document['Name'], 'QualifiedName' => "#{unit.module_name}.#{document['Name']}", 'Path' => path,
          'ServiceName' => document['ServiceName'], 'Version' => document['Version'],
          'AuthenticationTypesRuntime' => authentication_types(document, security),
          'AuthenticationMicroflow' => document['AuthenticationMicroflow'].to_s,
          'AllowedUserRoles' => allowed_user_roles(document, security),
          'OpenApi2Schema' => '', 'OpenApi3Schema' => ''
        }.then { open_api(_1, document, returns) }
      end

      def open_api(service, document, returns)
        documents = PublishedRestOpenApi.new(service, document, return_types: returns)
        service.merge('OpenApi2Schema' => documents.swagger, 'OpenApi3Schema' => documents.openapi)
      end

      def microflow_return_types(source)
        source.units_of('Microflows$Microflow').to_h do |unit|
          ["#{unit.module_name}.#{unit.document['Name']}", data_type(unit.document['MicroflowReturnType'])]
        end
      end

      def compile_resource(resource, service_path)
        path = join(service_path, resource['Name'])
        {
          '$ID' => resource['$ID'], '$Type' => resource['$Type'],
          'Operations' => items(resource['Operations']).map { compile_operation(_1, path) }, 'PathRuntime' => path
        }
      end

      def compile_operation(operation, resource_path)
        {
          '$ID' => operation['$ID'], '$Type' => operation['$Type'],
          'Parameters' => items(operation['Parameters']).map { compile_parameter(_1) },
          'PathRuntime' => join(resource_path, operation['Path'])
        }.merge(operation.slice(*OPERATION_FIELDS))
      end

      def compile_parameter(parameter)
        type = parameter.dig('Type', '$Type').to_s
        data_type = DATA_TYPES.fetch(type) do
          raise CompilationError, "published REST parameter #{parameter['Name']} has unsupported type #{type}"
        end
        {
          '$ID' => parameter['$ID'], '$Type' => parameter['$Type'], 'Name' => parameter['Name'],
          'MicroflowParameter' => parameter['MicroflowParameter'].to_s, 'DataType' => data_type,
          'ParameterType' => parameter['ParameterType']
        }
      end

      # MxBuild leaves them out when security is off.
      def authentication_types(document, security)
        return [] if security['SecurityLevel'].to_s == 'CheckNothing'

        items(document['AuthenticationTypes']).map(&:to_s)
      end

      def allowed_user_roles(document, security)
        allowed = items(document['AllowedRoles']).map(&:to_s)
        items(security['UserRoles']).select { (items(_1['ModuleRoles']).map(&:to_s) & allowed).any? }
                                    .map { _1['Name'].to_s }
      end

      def join(base, segment) = [base, segment.to_s.delete_prefix('/')].reject(&:empty?).join('/')
      def items(value) = IO::BsonCodec.parse_array(value)[:items].select { _1.is_a?(Hash) || _1.is_a?(String) }
    end
  end
end
