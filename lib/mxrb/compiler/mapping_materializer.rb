# frozen_string_literal: true

module Mxrb
  module Compiler
    MappingMaterialization = Data.define(:model_path, :documents)

    # Compiles the import mappings, export mappings, JSON structures and message
    # definitions an import with mapping, an export with mapping or a REST call
    # reads at run time into model.mdp, in the version's Runtime form, deriving
    # the fields MxBuild derives.
    class MappingMaterializer
      TYPES = %w[
        ImportMappings$ImportMapping ExportMappings$ExportMapping JsonStructures$JsonStructure
        MessageDefinitions$MessageDefinitionCollection
      ].freeze

      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        source = SourceModel.read(@mpr_path)
        path = File.join(@deployment, 'model', 'model.mdp')
        package = ModelPackage.read(path)
        compiler = MappingDocumentCompiler.new(RuntimeModelSchema.new(package, version: source.version))
        documents = mapping_units(source).map { compiler.compile(_1) }
        documents.reduce(package) { |result, document| result.upsert(document) }.write(path)
        MappingMaterialization.new(model_path: path, documents: documents.length)
      end

      private

      def mapping_units(source) = source.units.select { TYPES.include?(_1.document['$Type']) }
    end

    # A mapping document and its elements with the fields the Runtime schema
    # lists, taken from the MPR or derived as MxBuild does.
    class MappingDocumentCompiler
      include ModelValues

      def initialize(schema)
        @schema = schema
      end

      def compile(unit) = node(unit.document, unit.module_name)

      private

      def node(source, module_name)
        @schema.fields_for(source).to_h do |field|
          [field, source.key?(field) ? value(source[field], module_name) : derived(source, field, module_name)]
        end
      end

      def value(value, module_name)
        case value
        when Hash then value['$Type'] ? node(value, module_name) : value.transform_values { value(_1, module_name) }
        when Array then array(value).map { value(_1, module_name) }
        else value
        end
      end

      def derived(source, field, module_name) # rubocop:disable Metrics/CyclomaticComplexity
        case field
        when 'QualifiedName' then "#{module_name}.#{source['Name']}"
        when 'SupportedContentTypesRuntime' then content_types(source)
        when 'ParameterDataTypeRuntime' then parameter_type(source)
        when 'OccursMoreThanOnce' then source['MaxOccurs'].to_i == -1 || source['MaxOccurs'].to_i > 1
        when 'ObjectHandlingBackupOverride' then false
        when 'XmlType' then source['XmlPrimitiveType'].to_s
        else raise CompilationError, "cannot derive Runtime field #{source['$Type']}.#{field}"
        end
      end

      # A mapping on a JSON structure reads and writes JSON; one on a message
      # definition JSON and XML; one on an XML schema XML.
      def content_types(source)
        return %w[Json Xml] unless source['MessageDefinition'].to_s.empty?
        return ['Json'] unless source['JsonStructure'].to_s.empty?
        return ['Xml'] unless source['XmlSchema'].to_s.empty?

        raise CompilationError, "mapping #{source['Name']} has no JSON structure, message definition or XML schema"
      end

      def parameter_type(source)
        type = source.dig('ParameterType', '$Type').to_s
        return 'Unknown' if type.empty? || type.end_with?('UnknownType')

        raise CompilationError, "import mapping #{source['Name']} takes a parameter, whose Runtime type is not audited"
      end
    end
  end
end
