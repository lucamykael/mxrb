# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'

module Mxrb
  module Compiler
    ConstantsMaterialization = Data.define(:model_path, :metadata_path, :constants)

    # Compiles MPR constants into Runtime model and metadata representations.
    class ConstantsMaterializer
      DATA_TYPES = {
        'DataTypes$StringType' => 'String', 'DataTypes$IntegerType' => 'Integer',
        'DataTypes$BooleanType' => 'Boolean', 'DataTypes$DecimalType' => 'Decimal',
        'DataTypes$DateTimeType' => 'DateTime'
      }.freeze

      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        source = SourceModel.read(@mpr_path)
        constants = compile(source)
        model_path = File.join(@deployment, 'model', 'model.mdp')
        metadata_path = File.join(@deployment, 'model', 'metadata.json')
        write_model(model_path, constants)
        metadata_constants = write_metadata(metadata_path, constants)
        ConstantsMaterialization.new(
          model_path:, metadata_path:, constants: metadata_constants.freeze
        )
      end

      private

      def compile(source)
        source.units_of('Constants$Constant').map do |unit|
          raise CompilationError, "constant #{unit.document['Name']} is outside a module" unless unit.module_name

          compile_constant(source, unit)
        end
      end

      def compile_constant(source, unit)
        document = unit.document
        qualified_name = "#{unit.module_name}.#{document['Name']}"
        data_type = constant_type(document, qualified_name)
        {
          module_name: unit.module_name, runtime: runtime_document(document, qualified_name, data_type, source),
          metadata: metadata_document(document, qualified_name, data_type)
        }
      end

      def constant_type(document, qualified_name)
        native = document.dig('Type', '$Type')
        legacy = document['DataType'].to_s
        return legacy if DATA_TYPES.value?(legacy)

        DATA_TYPES.fetch(native) do
          raise CompilationError, "unsupported constant type #{native.inspect} for #{qualified_name}"
        end
      end

      def runtime_document(source, qualified_name, data_type, model)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'], 'Name' => source['Name'],
          'QualifiedName' => qualified_name, 'DataType' => data_type,
          'ExposedToClient' => model.client_reference?(qualified_name)
        }
      end

      def metadata_document(source, qualified_name, data_type)
        {
          'Name' => qualified_name, 'Type' => data_type,
          'Description' => source['Documentation'].to_s,
          'DefaultValue' => source['DefaultValue'].to_s
        }
      end

      def write_metadata(path, constants)
        metadata = JSON.parse(File.read(path))
        metadata['Constants'] = ordered_metadata(constants)
        atomic_json_write(path, metadata)
        metadata.fetch('Constants')
      end

      def ordered_metadata(constants)
        constants.group_by { _1.fetch(:module_name) }
                 .flat_map { |_module, entries| entries.sort_by { _1.dig(:metadata, 'Name') } }
                 .map { _1.fetch(:metadata) }
      end

      def write_model(path, constants)
        package = constants.reduce(ModelPackage.read(path)) do |result, constant|
          result.upsert(constant.fetch(:runtime))
        end
        package.write(path)
      end

      def atomic_json_write(path, document)
        Dir.mktmpdir('mxrb-metadata-', File.dirname(path)) do |directory|
          temporary = File.join(directory, 'metadata.json')
          File.write(temporary, JSON.pretty_generate(document))
          FileUtils.mv(temporary, path, force: true)
        end
      end
    end
  end
end
