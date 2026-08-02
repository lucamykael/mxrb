# frozen_string_literal: true

require 'digest'
require 'json'

module Mxrb
  module Compiler
    # Lowers supported client-flow graphs to the instruction programs consumed by the Mendix client.
    class NanoflowProgramCompiler # rubocop:disable Metrics/ClassLength
      include ModelValues

      attr_reader :unsupported

      def initialize(source)
        @source = source
        @programs = {}
        @unsupported = []
      end

      def reference(qualified_name)
        if @programs.key?(qualified_name)
          identifier = @programs[qualified_name]&.fetch(:reference)
          return identifier && "() => #{identifier}"
        end

        unit = nanoflow_unit(qualified_name)
        return unless unit

        compile(unit, qualified_name)
      end

      def declarations
        @programs.values.filter_map { _1[:declaration] }.join("\n")
      end

      private

      def compile(unit, qualified_name)
        reference = "mxrbNanoflow_#{Digest::SHA256.hexdigest(qualified_name)[0, 12]}"
        @programs[qualified_name] = { reference:, declaration: nil }
        unsupported_count = @unsupported.length
        instructions = ordered_nodes(unit.document).filter_map { compile_node(_1) }
        return @programs.delete(qualified_name) && nil if @unsupported.length > unsupported_count

        program = { name: qualified_name, instructions: }
        @programs[qualified_name][:declaration] = "const #{reference} = #{js_literal(program)};"
        "() => #{reference}"
      end

      def ordered_nodes(document)
        objects = array(document.dig('ObjectCollection', 'Objects'))
        by_id = objects.to_h { [model_id(_1), _1] }
        traverse(objects, by_id, flow_destinations(document))
      end

      def flow_destinations(document)
        array(document['Flows']).to_h do |flow|
          [model_id(flow['OriginPointer']), model_id(flow['DestinationPointer'])]
        end
      end

      def traverse(objects, by_id, destinations)
        current = objects.find { _1['$Type'] == 'Microflows$StartEvent' }
        visited = {}
        [].tap do |result|
          while current && !visited[model_id(current)]
            visited[model_id(current)] = true
            result << current unless current['$Type'] == 'Microflows$StartEvent'
            current = by_id[destinations[model_id(current)]]
          end
        end
      end

      def compile_node(node)
        return compile_end(node) if node['$Type'] == 'Microflows$EndEvent'
        return unless node['$Type'] == 'Microflows$ActionActivity'

        action = node['Action'] || {}
        case action['$Type']
        when 'Microflows$CreateVariableAction' then compile_variable(action)
        when 'Microflows$CreateObjectAction' then compile_create_object(action)
        when 'Microflows$NanoflowCallAction' then compile_nanoflow_call(action)
        else unsupported!(node, action['$Type'])
        end
      end

      def compile_end(node)
        { type: 'return', label: model_id(node), result: expression(node['ReturnValue']),
          resultKind: expression_kind(node['ReturnValue']) }
      end

      def compile_variable(action)
        { type: 'createVariable', label: model_id(action), outputVar: action['VariableName'],
          value: expression(action['InitialValue']) }
      end

      def compile_create_object(action)
        { type: 'createObject', label: model_id(action), objectType: action['Entity'],
          outputVar: action['OutputVariableName'] || action['VariableName'] }
      end

      def compile_nanoflow_call(action)
        call = action['NanoflowCall'] || {}
        target = call['Nanoflow'].to_s
        reference = reference(target)
        return unsupported!(action, action['$Type']) unless reference

        result = { type: 'nanoflowCall', label: model_id(action), flow: raw(reference),
                   parameters: call_parameters(call) }
        output = action['OutputVariableName'].to_s
        result[:outputVar] = output unless output.empty?
        result
      end

      def call_parameters(call)
        array(call['ParameterMappings']).filter_map do |mapping|
          next unless mapping.is_a?(Hash)

          { name: mapping['Parameter'].to_s.split('.').last,
            value: expression(mapping['Argument']), kind: expression_kind(mapping['Argument']) }
        end
      end

      def expression(value)
        source = value.to_s.strip
        return { type: 'literal', value: nil } if source.empty? || source == 'empty'
        return { type: 'variable', variable: source.delete_prefix('$') } if source.start_with?('$')
        return { type: 'literal', value: source == 'true' } if %w[true false].include?(source)
        return { type: 'literal', value: source[1..-2] } if quoted?(source)
        return { type: 'literalNumeric', value: source } if source.match?(/\A-?\d+(?:\.\d+)?\z/)

        { type: 'literal', value: source }
      end

      def expression_kind(value)
        value.to_s.strip.start_with?('$') ? 'object' : 'primitive'
      end

      def quoted?(value)
        (value.start_with?("'") && value.end_with?("'")) ||
          (value.start_with?('"') && value.end_with?('"'))
      end

      def unsupported!(node, type)
        unit = @programs.keys.last
        label = type.to_s.empty? ? node['$Type'] : type
        @unsupported << "#{unit}:#{label}"
        nil
      end

      def nanoflow_unit(qualified_name)
        @source.units_of('Microflows$Nanoflow').find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == qualified_name
        end
      end

      def model_id(value)
        identifier = value.is_a?(Hash) && value.key?('$ID') ? value['$ID'] : value
        IO::BsonCodec.extract_id(identifier).to_s
      end

      def raw(value) = { '$raw' => value }

      def js_literal(value)
        return value['$raw'] if value.is_a?(Hash) && value.key?('$raw')
        return "[#{value.map { js_literal(_1) }.join(', ')}]" if value.is_a?(Array)
        if value.is_a?(Hash)
          return "{ #{value.map { |key, item| "#{JSON.generate(key)}: #{js_literal(item)}" }.join(', ')} }"
        end

        JSON.generate(value)
      end
    end # rubocop:enable Metrics/ClassLength
  end
end
