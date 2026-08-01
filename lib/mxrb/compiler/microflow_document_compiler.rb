# frozen_string_literal: true

require 'digest'

module Mxrb
  module Compiler
    # Compiles microflow-family roots and delegates ordered graph nodes.
    class MicroflowDocumentCompiler
      include ModelValues
      include RuntimeDataTypes

      ROOT_TYPES = %w[Microflows$Microflow Microflows$Nanoflow Microflows$Rule].freeze

      def initialize(source, schema)
        @schema = schema
        @nodes = MicroflowNodeCompiler.new(schema, source:)
        @role_map = project_role_map(source)
      end

      def compile(unit)
        source = unit.document
        raise CompilationError, "unsupported flow root #{source['$Type']}" unless ROOT_TYPES.include?(source['$Type'])

        @nodes.prepare(source)
        @schema.fields_for(source).to_h do |field|
          [field, root_value(source, field, unit.module_name)]
        end
      end

      private

      def root_value(source, field, module_name) # rubocop:disable Metrics/CyclomaticComplexity
        case field
        when '$ID', '$Type', 'Name' then source[field]
        when 'ObjectCollection' then @nodes.compile(source['ObjectCollection'])
        when 'SequenceFlows' then @nodes.compile(source['Flows'])
        when 'QualifiedName' then "#{module_name}.#{source['Name']}"
        when 'ReturnType' then data_type(source['MicroflowReturnType'])
        when 'ModelerAllowedUserRoles' then allowed_user_roles(source)
        when 'UrlSegments' then []
        else generic_field(source, field)
        end
      end

      def generic_field(source, field)
        return @nodes.compile(source[field]) if source.key?(field)

        existing = @schema.counterpart(source)
        return existing[field] if existing&.key?(field)

        root_default(source, field)
      end

      def root_default(source, field)
        case field
        when 'ConcurrenyErrorMessage'
          { '$ID' => derived_id(source, field), '$Type' => 'Texts$Text' }
        when 'ApplyEntityAccess', 'AllowConcurrentExecution' then false
        when 'ConcurrencyErrorMicroflow', 'Url' then ''
        when 'UrlSearchParameters' then []
        else raise CompilationError, "cannot derive Runtime root field #{source['$Type']}.#{field}"
        end
      end

      def allowed_user_roles(flow)
        array(flow['AllowedModuleRoles']).flat_map { @role_map.fetch(_1.to_s, []) }.uniq
      end

      def project_role_map(source)
        security = source.documents('Security$ProjectSecurity').first
        return {} unless security

        array(security['UserRoles']).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |role, map|
          array(role['ModuleRoles']).each { |module_role| map[module_role.to_s] << role['Name'].to_s }
        end
      end

      def derived_id(source, label)
        seed = "#{IO::BsonCodec.extract_id(source['$ID'])}:#{label}"
        hex = Digest::SHA256.hexdigest(seed)[0, 32]
        "#{hex[0, 8]}-#{hex[8, 4]}-4#{hex[13, 3]}-8#{hex[17, 3]}-#{hex[20, 12]}"
      end
    end
  end
end
