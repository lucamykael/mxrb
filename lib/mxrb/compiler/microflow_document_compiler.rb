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
        @roles = UserRoleResolver.new(source)
      end

      def compile(unit)
        source = unit.document
        raise CompilationError, "unsupported flow root #{source['$Type']}" unless ROOT_TYPES.include?(source['$Type'])

        @nodes.prepare(source)
        @schema.fields_for(source).to_h do |field|
          [field, root_value(source, field, unit.module_name)]
        end
      end

      # The user roles that hold one of the module roles.
      def user_roles_for(module_roles) = @roles.resolve(module_roles)

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

      def allowed_user_roles(flow) = user_roles_for(array(flow['AllowedModuleRoles']))
    end
  end
end
