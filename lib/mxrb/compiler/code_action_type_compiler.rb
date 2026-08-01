# frozen_string_literal: true

module Mxrb
  module Compiler
    # Converts CodeActions type trees into Runtime type identifiers.
    module CodeActionTypeCompiler
      SCALARS = {
        'CodeActions$VoidType' => 'Void', 'CodeActions$StringType' => 'String',
        'CodeActions$BooleanType' => 'Boolean', 'CodeActions$IntegerType' => 'Integer',
        'CodeActions$LongType' => 'Integer', 'CodeActions$DecimalType' => 'Decimal',
        'CodeActions$FloatType' => 'Decimal', 'CodeActions$DateTimeType' => 'DateTime'
      }.freeze

      private

      def code_action_type(source)
        return 'Void' unless source

        type = source['$Type'].to_s.sub(/\AJavaActions\$/, 'CodeActions$')
        return SCALARS.fetch(type) if SCALARS.key?(type)

        case type
        when 'CodeActions$ConcreteEntityType' then source['Entity'].to_s
        when 'CodeActions$EnumerationType' then "##{source['Enumeration']}"
        when 'CodeActions$ParameterizedEntityType' then 'Unknown'
        when 'CodeActions$ListType' then "[#{code_action_type(source['Parameter'])}]"
        else raise CompilationError, "unsupported code-action type #{source['$Type']}"
        end
      end
    end
  end
end
