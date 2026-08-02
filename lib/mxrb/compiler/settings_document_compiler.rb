# frozen_string_literal: true

module Mxrb
  module Compiler
    # Compiles project settings using the ordered, version-matched Runtime schema.
    class SettingsDocumentCompiler
      include ModelValues

      def initialize(schema)
        @schema = schema
      end

      def compile(unit)
        source = unit.document
        unless source['$Type'] == 'Settings$ProjectSettings'
          raise CompilationError,
                "unsupported settings root #{source['$Type']}"
        end

        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Settings' => array(source['Settings']).map { compile_node(_1) }
        }
      end

      private

      def compile_value(value)
        case value
        when Hash then value['$Type'] ? compile_node(value) : value.transform_values { compile_value(_1) }
        when Array then array(value).map { compile_value(_1) }
        else value
        end
      end

      def compile_node(source)
        existing = @schema.counterpart(source)
        @schema.fields_for(source).to_h do |field|
          value = source.key?(field) ? compile_value(source[field]) : existing&.fetch(field, nil)
          [field, value]
        end
      end
    end
  end
end
