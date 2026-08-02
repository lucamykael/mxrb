# frozen_string_literal: true

module Mxrb
  module Compiler
    # Compiles Java and JavaScript action signatures consumed by the Runtime model.
    class CodeActionDocumentCompiler
      include ModelValues
      include CodeActionTypeCompiler

      TYPES = %w[JavaActions$JavaAction JavaScriptActions$JavaScriptAction].freeze

      def compile(unit)
        source = unit.document
        case source['$Type']
        when 'JavaActions$JavaAction' then java_action(source, unit.module_name)
        when 'JavaScriptActions$JavaScriptAction' then javascript_action(source, unit.module_name)
        else raise CompilationError, "unsupported code action #{source['$Type']}"
        end
      end

      private

      def java_action(source, module_name)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Parameters' => array(source['Parameters']).map { java_parameter(_1) },
          'Name' => source['Name'], 'QualifiedName' => qualified_name(module_name, source['Name']),
          'ReturnType' => code_action_type(source['JavaReturnType'])
        }
      end

      def java_parameter(source)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'], 'Name' => source['Name'],
          'Type' => java_parameter_type(source['ParameterType'])
        }
      end

      def java_parameter_type(source)
        return 'String' if source['$Type'] == 'JavaActions$MicroflowJavaActionParameterType'

        code_action_type(source['Type'])
      end

      def javascript_action(source, module_name)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Parameters' => array(source['Parameters']).map { javascript_parameter(_1) },
          'Name' => source['Name'], 'QualifiedName' => qualified_name(module_name, source['Name'])
        }
      end

      def javascript_parameter(source)
        { '$ID' => source['$ID'], '$Type' => source['$Type'], 'Name' => source['Name'] }
      end

      def qualified_name(module_name, name)
        raise CompilationError, "code action #{name} is outside a module" unless module_name

        "#{module_name}.#{name}"
      end
    end
  end
end
