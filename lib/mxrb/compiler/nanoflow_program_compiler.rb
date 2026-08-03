# frozen_string_literal: true

require 'digest'
require 'json'

module Mxrb
  module Compiler
    # Lowers supported client-flow graphs to the instruction programs consumed by the Mendix client.
    # rubocop:disable Metrics
    class NanoflowProgramCompiler
      include ModelValues

      attr_reader :unsupported

      def initialize(source)
        @source = source
        @nanoflows = source.units_of('Microflows$Nanoflow').to_h do |unit|
          ["#{unit.module_name}.#{unit.document['Name']}", unit]
        end
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
        (@variable_kind_stack ||= []) << variable_kinds(unit.document)
        (@flow_stack ||= []) << qualified_name
        unsupported_count = @unsupported.length
        instructions = compile_graph(unit.document)
        return @programs.delete(qualified_name) && nil if @unsupported.length > unsupported_count

        program = { name: qualified_name, useListParameterByReference: true, instructions: }
        @programs[qualified_name][:declaration] = "const #{reference} = #{js_literal(program)};"
        "() => #{reference}"
      ensure
        @flow_stack&.pop
        @variable_kind_stack&.pop
      end

      def variable_kinds(document)
        array(document.dig('ObjectCollection', 'Objects')).each_with_object({}) do |object, result|
          case object['$Type']
          when 'Microflows$MicroflowParameter'
            result[object['Name']] = variable_kind(object['VariableType'])
          when 'Microflows$ActionActivity'
            action = object['Action'] || {}
            result[action['VariableName']] = variable_kind(action['VariableType']) if action['VariableName']
            if %w[Microflows$CreateObjectAction
                  Microflows$CreateChangeAction].include?(action['$Type']) && action['VariableName']
              result[action['VariableName']] = 'object'
            end
            result[action['OutputVariableName']] = 'object' if action['OutputVariableName']
            result[action['ResultVariableName']] = 'primitive' if action['ResultVariableName']
          end
        end
      end

      def graph(document)
        objects = array(document.dig('ObjectCollection', 'Objects'))
        by_id = objects.to_h { [model_id(_1), _1] }
        flows = array(document['Flows']).group_by { model_id(_1['OriginPointer']) }
        [objects, by_id, flows]
      end

      def compile_graph(document)
        objects, by_id, flows = graph(document)
        start = objects.find { _1['$Type'] == 'Microflows$StartEvent' }
        ordered = reachable_nodes(start, by_id, flows)
        ordered.flat_map { compile_graph_node(_1, flows.fetch(model_id(_1), [])) }.compact
      end

      def reachable_nodes(start, by_id, flows)
        queue = (start ? [start] : []).flat_map { flows.fetch(model_id(_1), []) }
                                      .map { by_id[model_id(_1['DestinationPointer'])] }
        visited = {}
        [].tap do |result|
          until queue.empty?
            current = queue.shift
            next unless current
            next if visited[model_id(current)]

            visited[model_id(current)] = true
            result << current
            queue.concat(flows.fetch(model_id(current), []).map do |flow|
              by_id[model_id(flow['DestinationPointer'])]
            end)
          end
        end
      end

      def compile_graph_node(node, flows)
        error_flows = flows.select { _1['IsErrorHandler'] == true }
        normal_flows = flows.reject { _1['IsErrorHandler'] == true }
        instruction = if error_flows.empty?
                        compile_node(node, normal_flows)
                      else
                        compile_try_catch(node, normal_flows, error_flows)
                      end
        instructions = instruction.is_a?(Array) ? instruction : [instruction].compact
        return instructions if terminal_node?(node) || instruction.nil?
        return instructions unless normal_flows.one?

        instructions << { type: 'jump', label: "#{model_id(node)}$next",
                          target: model_id(normal_flows.first['DestinationPointer']) }
      end

      def compile_try_catch(node, normal_flows, error_flows)
        return unsupported!(node, 'Microflows$ErrorHandler') unless normal_flows.one? && error_flows.one?

        compiled = compile_node(node, normal_flows)
        body = (compiled.is_a?(Array) ? compiled : [compiled]).compact.map { _1.except(:label) }
        return if body.empty?

        body << { type: 'return', result: { type: 'literal', value: true }, resultKind: 'primitive' }
        {
          type: 'tryCatch', label: model_id(node),
          catchTarget: model_id(error_flows.first['DestinationPointer']), body:
        }
      end

      def terminal_node?(node)
        %w[Microflows$EndEvent Microflows$ExclusiveSplit Microflows$ExclusiveMerge]
          .include?(node['$Type'])
      end

      def compile_node(node, flows = [])
        return compile_end(node) if node['$Type'] == 'Microflows$EndEvent'
        return compile_split(node, flows) if node['$Type'] == 'Microflows$ExclusiveSplit'
        return compile_merge(node, flows) if node['$Type'] == 'Microflows$ExclusiveMerge'
        return unsupported!(node, node['$Type']) unless node['$Type'] == 'Microflows$ActionActivity'

        action = node['Action'] || {}
        case action['$Type']
        when 'Microflows$CreateVariableAction' then compile_variable(action, node)
        when 'Microflows$ChangeVariableAction' then compile_change_variable(action, node)
        when 'Microflows$CreateObjectAction' then compile_create_object(action, node)
        when 'Microflows$CreateChangeAction' then compile_create_object(action, node)
        when 'Microflows$ChangeAction' then compile_change_object(action, node)
        when 'Microflows$NanoflowCallAction' then compile_nanoflow_call(action, node)
        when 'Microflows$MicroflowCallAction' then compile_microflow_call(action, node)
        when 'Microflows$JavaScriptActionCallAction' then compile_javascript_call(action, node)
        when 'Microflows$ShowFormAction' then compile_show_form(action, node)
        when 'Microflows$CloseFormAction' then compile_close_form(action, node)
        when 'Microflows$ShowMessageAction' then compile_show_message(action, node)
        when 'Microflows$ValidationFeedbackAction' then compile_validation(action, node)
        when 'Microflows$LogMessageAction' then compile_log(action, node)
        when 'Microflows$CommitAction' then compile_commit(action, node)
        else unsupported!(node, action['$Type'])
        end
      end

      def compile_end(node)
        { type: 'return', label: model_id(node), result: expression(node['ReturnValue']),
          resultKind: expression_kind(node['ReturnValue']) }
      end

      def compile_variable(action, node)
        { type: 'setVariable', label: model_id(node), outputVar: action['VariableName'],
          outputKind: variable_kind(action['VariableType']), value: expression(action['InitialValue']) }
      end

      def compile_change_variable(action, node)
        { type: 'setVariable', label: model_id(node), outputVar: action['ChangeVariableName'],
          outputKind: 'primitive', value: expression(action['Value']) }
      end

      def compile_create_object(action, node)
        variable = action['OutputVariableName'] || action['VariableName']
        create = { type: 'createObject', label: model_id(node), objectType: action['Entity'],
                   outputVar: variable }
        instructions = [create] + change_instructions(action, variable, "#{model_id(node)}$change")
        instructions << compile_commit(action, node, label: false) if action['Commit'] == 'Yes'
        instructions.compact
      end

      def compile_change_object(action, node)
        variable = action['ChangeVariableName']
        changes = change_instructions(action, variable, model_id(node))
        changes << compile_commit(action, node, label: false) if action['Commit'] == 'Yes'
        changes.compact
      end

      def change_instructions(action, variable, label)
        array(action['Items']).map.with_index do |item, index|
          member = item['Attribute'].to_s.split('.').last
          next unsupported!(item, item['$Type']) if member.empty? || item['Type'] != 'Set'

          { type: 'changeObject', label: index.zero? ? label : "#{label}$#{index}",
            inputVar: variable, member:, value: expression(item['Value']) }
        end.compact
      end

      def compile_nanoflow_call(action, node = action)
        call = action['NanoflowCall'] || {}
        target = call['Nanoflow'].to_s
        reference = reference(target)
        return unsupported!(action, action['$Type']) unless reference

        result = { type: 'nanoflowCall', label: model_id(node), flow: raw(reference),
                   parameters: call_parameters(call) }
        output = action['OutputVariableName'].to_s
        result[:outputVar] = output unless output.empty?
        result
      end

      def compile_microflow_call(action, node)
        call = action['MicroflowCall'] || {}
        name = call['Microflow'].to_s
        return unsupported!(action, action['$Type']) if name.empty?

        result = {
          type: 'microflowCall', label: model_id(node),
          operationId: WebOperationCompiler.operation_id(current_flow, model_id(node)),
          parameters: call_parameters(call)
        }
        output = action['ResultVariableName'].to_s
        result[:outputVar] = output if action['UseReturnVariable'] == true && !output.empty?
        result
      end

      def compile_javascript_call(action, node)
        qualified = action['JavaScriptAction'].to_s
        unit = @source.units_of('JavaScriptActions$JavaScriptAction').find do |candidate|
          "#{candidate.module_name}.#{candidate.document['Name']}" == qualified
        end
        return unsupported!(action, action['$Type']) unless unit

        result = {
          type: 'javaScriptActionCall', label: model_id(node), action: raw(javascript_reference(unit)),
          parameters: javascript_parameters(action, unit)
        }
        output = action['OutputVariableName'].to_s
        result[:outputVar] = output if action['UseReturnVariable'] == true && !output.empty?
        result
      end

      def javascript_reference(unit)
        module_path = unit.module_name.downcase
        name = unit.document['Name']
        path = File.join(File.dirname(@source.path), 'javascriptsource', module_path, 'actions', name)
        "() => require(#{JSON.generate(path)}).#{name}"
      end

      def javascript_parameters(action, unit)
        parameter_types = array(unit.document['Parameters']).to_h do |parameter|
          [parameter['Name'], javascript_parameter_kind(parameter)]
        end
        array(action['ParameterMappings']).map do |mapping|
          name = mapping['Parameter'].to_s.split('.').last
          value = mapping['ParameterValue'] || {}
          argument = value['Argument'] || quoted_entity(value['Entity'])
          { kind: parameter_types.fetch(name, 'primitive'), value: expression(argument) }
        end
      end

      def quoted_entity(entity)
        entity.to_s.empty? ? nil : JSON.generate(entity.to_s)
      end

      def javascript_parameter_kind(parameter)
        type = parameter.dig('ParameterType', 'Type', '$Type').to_s
        return 'object' if type.include?('EntityType')
        return 'list' if type.include?('ListType')

        'primitive'
      end

      def compile_split(node, flows)
        targets = flows.to_h do |flow|
          case_value = array(flow['CaseValues']).first
          key = case_value&.fetch('Value', nil).to_s
          key = '' if case_value&.fetch('$Type', nil) == 'Microflows$NoCase'
          [key, model_id(flow['DestinationPointer'])]
        end
        condition = node.dig('SplitCondition', 'Expression')
        return unsupported!(node, node['$Type']) if targets.empty? || condition.to_s.empty?

        { type: 'switch', label: model_id(node), condition: expression(condition), targets: }
      end

      def compile_merge(node, flows)
        target = flows.one? && model_id(flows.first['DestinationPointer'])
        return unsupported!(node, node['$Type']) unless target

        { type: 'jump', label: model_id(node), target: }
      end

      def compile_show_form(action, node)
        settings = action['FormSettings'] || {}
        form = settings['Form'].to_s
        return unsupported!(action, action['$Type']) if form.empty?

        path = "#{form.tr('.', '/')}.page.xml"
        params = { name: path, location: 'modal', resizable: false }
        mappings = array(settings['ParameterMappings']).to_h do |mapping|
          ["$#{mapping['Parameter'].to_s.split('.').last}", expression(mapping['Argument'])]
        end
        { type: 'openForm', label: model_id(node), path:, params: }.tap do |instruction|
          instruction[:inputArgs] = mappings unless mappings.empty?
        end
      end

      def compile_close_form(action, node)
        value = action['NumberOfPagesToClose'].to_s
        { type: 'closeForm', label: model_id(node) }.tap do |instruction|
          instruction[:numberOfPagesToClose] = expression(value) unless value.empty?
        end
      end

      def compile_show_message(action, node)
        { type: 'showMessage', label: model_id(node),
          message: text_template_expression(action['Template']),
          messageType: action['Type'].to_s.downcase, blocking: action['Blocking'] == true }
      end

      def compile_validation(action, node)
        member = action['Attribute'].to_s.split('.').last
        return unsupported!(action, action['$Type']) if member.empty?

        { type: 'showValidation', label: model_id(node), inputVar: action['ValidationVariableName'],
          member:, text: text_template_expression(action['FeedbackTemplate']) }
      end

      def compile_log(action, node)
        { type: 'writeLog', label: model_id(node), level: action['Level'].to_s.downcase,
          message: text_template_expression(action['MessageTemplate']) }
      end

      def compile_commit(action, node, label: true)
        input = (action['CommitVariableName'] || action['ChangeVariableName'] ||
                 action['OutputVariableName'] || action['VariableName']).to_s
        return unsupported!(action, action['$Type']) if input.empty?

        { type: 'commitObjects', inputVar: input,
          operationId: WebOperationCompiler.operation_id(current_flow, model_id(node)) }.tap do |result|
          result[:label] = model_id(node) if label
        end
      end

      def text_template_expression(template)
        text = template&.fetch('Text', nil)
        value = if text.is_a?(Hash)
                  items = array(text['Items'])
                  items.find { _1['LanguageCode'] == 'en_US' }&.fetch('Text', nil) ||
                    items.first&.fetch('Text', nil).to_s
                else
                  text.to_s
                end
        parameters = array(template&.fetch('Parameters', nil))
        return expression(value) if parameters.empty?

        arguments = parameters.map { expression(_1['Expression'] || _1['Argument']) }
        { type: 'function', name: 'formatString', parameters: [{ type: 'literal', value: }] + arguments }
      end

      def variable_kind(type)
        type&.fetch('$Type', nil).to_s.include?('Object') ? 'object' : 'primitive'
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

        conditional = conditional_expression(source)
        return conditional if conditional

        function = function_expression(source)
        return function if function

        binary = binary_expression(source)
        return binary if binary
        return variable_expression(source) if source.match?(%r{\A\$[A-Za-z_]\w*(?:/[A-Za-z_]\w*)*\z})
        return { type: 'constant', name: source.delete_prefix('@') } if source.start_with?('@')
        return { type: 'literal', value: source == 'true' } if %w[true false].include?(source)
        return { type: 'literal', value: source[1..-2] } if quoted?(source)
        return { type: 'literalNumeric', value: source } if source.match?(/\A-?\d+(?:\.\d+)?\z/)

        { type: 'literal', value: source }
      end

      def expression_kind(value)
        name = value.to_s.strip[/\A\$([A-Za-z_]\w*)/, 1]
        name ? current_variable_kinds.fetch(name, 'primitive') : 'primitive'
      end

      def current_variable_kinds = @variable_kind_stack&.last || {}

      def variable_expression(source)
        variable, *path = source.delete_prefix('$').split('/')
        { type: 'variable', variable: }.tap do |result|
          result[:path] = path.join('/') unless path.empty?
        end
      end

      def conditional_expression(source)
        match = source.match(/\Aif\s+(.+?)\s+then\s+(.+?)\s+else\s+(.+)\z/im)
        return unless match

        { type: 'conditional', condition: expression(match[1]),
          then: expression(match[2]), else: expression(match[3]) }
      end

      def function_expression(source)
        match = source.match(/\A(not|isNew|isSynced)\((.*)\)\z/im)
        return unless match

        { type: 'function', name: match[1], parameters: [expression(match[2])] }
      end

      def binary_expression(source)
        match = source.match(/\A(.+?)\s+(and|or|!=|=|>=|<=|>|<)\s+(.+)\z/im)
        return unless match

        { type: 'function', name: match[2].downcase,
          parameters: [expression(match[1]), expression(match[3])] }
      end

      def quoted?(value)
        (value.start_with?("'") && value.end_with?("'")) ||
          (value.start_with?('"') && value.end_with?('"'))
      end

      def unsupported!(node, type)
        unit = current_flow
        label = type.to_s.empty? ? node['$Type'] : type
        @unsupported << "#{unit}:#{label}"
        nil
      end

      def current_flow = @flow_stack&.last || @programs.keys.last

      def nanoflow_unit(qualified_name)
        @nanoflows[qualified_name]
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
    end
    # rubocop:enable Metrics
  end
end
