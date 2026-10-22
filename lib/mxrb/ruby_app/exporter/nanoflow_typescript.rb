# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Translates nanoflows into the generated TypeScript runtime.
      module NanoflowTypescript
        private

        def export_nanoflow(flow, mod, namespace, root = nil, duplicate_name: false)
          root ||= namespace
          namespace = ruby_constant(mod.name) if root == namespace
          qualified = "#{mod.name}.#{flow.name}"
          relative = File.join(
            'frontend', 'src', 'generated', 'nanoflows', root,
            "#{flow_file_stem(flow, duplicate_name:)}.ts"
          )
          write(relative, nanoflow_typescript(flow, qualified))
          native_source = native_flow_source(flow, :nanoflow)
          embedded_ruby_path = embedded_identity_path(:service, flow.id)
          ruby_path = embedded_ruby_path || File.join(
            'app', 'services', root, "#{flow_file_stem(flow, duplicate_name:)}_nanoflow.rb"
          )
          if native_source
            write(
              ruby_path,
              service_source(
                namespace, flow_ruby_constant(flow, duplicate_name:), qualified, flow.id,
                native_source:, native_kind: :nanoflow
              )
            )
          end
          entry = {
            'name' => qualified, 'id' => flow.id, 'path' => relative,
            'kind' => 'nanoflow', 'runtime' => 'frontend'
          }
          if native_source || embedded_ruby_path
            entry['ruby_path'] = ruby_path
            entry['ruby_class'] = embedded_identity_class(
              :service, flow.id, "#{namespace}::#{flow_ruby_constant(flow, duplicate_name:)}"
            )
          end
          @nanoflow_entries << entry.merge('import_name' => "Nanoflow#{@nanoflow_entries.size}")
          add_coverage(
            flow.id, qualified, 'nanoflow', native_source || embedded_ruby_path ? ruby_path : relative,
            native_source || embedded_ruby_path ? 'native_projection_source_preserved' : 'frontend_executable'
          )
          entry
        end

        def native_flow_source(flow, kind)
          return unless flow.is_a?(Model::Microflow)

          converter = Mxrb::Exporter.allocate
          converter.instance_variable_set(:@mpr_path, @mpr_path)
          method = kind.to_sym == :nanoflow ? :nanoflow_source : :microflow_source
          source = converter.send(method, flow, nil, internal_metadata: true)
          return unless source.include?('body_fingerprint')

          declaration = source.lines.index { _1.match?(/^\s*(?:microflow|nanoflow)\s/) }
          return unless declaration

          body = source.lines[(declaration + 1)...-1]
                       .reject { _1.match?(/^\s*body_fingerprint\b/) }
                       .map { _1.delete_prefix('  ') }.join.rstrip
          settings = {
            allowed_roles: flow.allowed_module_roles,
            apply_entity_access: flow.apply_entity_access,
            allow_concurrent_execution: flow.allow_concurrent_execution
          }.filter_map do |name, value|
            next if body.match?(/^\s*#{name}\b/)

            arguments = name == :allowed_roles ? Array(value).map(&:inspect).join(', ') : value.inspect
            "#{name}#{arguments.empty? ? '' : " #{arguments}"}"
          end
          [*settings, body].join("\n")
        rescue StandardError, SyntaxError
          nil
        end

        def nanoflow_typescript(flow, qualified)
          plan = begin
            nanoflow_plan(flow, qualified)
          rescue SerializationError
            raise unless flow.excluded

            # Studio Pro does not check excluded documents, which may refer to
            # removed model elements; the application never calls them.
            { 'objects' => [], 'flows' => [], 'parameters' => [] }
          end
          parameters = nanoflow_parameter_type(flow.parameters)
          result_type = nanoflow_result_type(flow.respond_to?(:return_type) ? flow.return_type : nil)
          start = plan.fetch('objects').find { _1['type'] == 'StartEvent' }
          cases = plan.fetch('objects').filter_map do |object|
            nanoflow_typescript_case(object, plan.fetch('flows'), result_type)
          end
          <<~TS
            import { defineNanoflow } from '../../bridge/nanoflow';
            import type { DecimalValue, EntityRecord, EntityTypeMap, NanoflowParameters, RuntimeValue } from '../../types';

            type Parameters = NanoflowParameters & #{parameters};

            export default defineNanoflow<Parameters, #{result_type}>({
              name: #{JSON.generate(qualified)},
              id: #{JSON.generate(flow.id.to_s)},
              parameters: #{JSON.generate(plan.fetch('parameters'))}
            }, async runtime => {
              let current = #{JSON.generate(start && start['id'])};
              for (let step = 0; step < 10_000; step += 1) {
                switch (current) {
            #{cases.join("\n")}
                  default:
                    throw runtime.missing(current);
                }
              }
              throw runtime.exceeded();
            });
          TS
        end

        def nanoflow_parameter_type(parameters)
          fields = parameters.filter_map do |parameter|
            next unless parameter.is_a?(Hash)

            "  #{JSON.generate(parameter['Name'].to_s)}: #{typescript_flow_type(parameter['VariableType'])};"
          end
          "{\n#{fields.join("\n")}\n}"
        end

        def nanoflow_result_type(type)
          typescript_flow_type('$Type' => type.to_s).delete_suffix(' | null')
        end

        def typescript_flow_type(type)
          type = {} unless type.is_a?(Hash)
          kind = (type['$Type'] || type['Type']).to_s
          entity = type['Entity'].to_s
          return "#{typescript_entity_reference(entity)} | null" if
            kind.end_with?('ObjectType') && !entity.empty?
          return "Array<#{typescript_entity_reference(entity)}>" if
            kind.end_with?('ListType') && !entity.empty?
          return 'boolean' if kind.match?(/Boolean/)
          return 'DecimalValue' if kind.match?(/Decimal/)
          return 'number' if kind.match?(/Integer|Long|Float/)
          return 'string' if kind.match?(/String|DateTime|Enumeration/)
          return 'undefined' if kind.empty? || kind.match?(/Void|MicroflowReturnType/)

          'RuntimeValue | undefined'
        end

        def nanoflow_typescript_case(object, flows, result_type)
          return if object['type'] == 'MicroflowParameter'

          outgoing = flows.select { _1['origin'] == object['id'] }
          body = case object['type']
                 when 'EndEvent' then nanoflow_end_source(object, result_type)
                 when 'ExclusiveSplit' then nanoflow_split_source(object, outgoing)
                 when 'ActionActivity' then nanoflow_action_case_source(object['action'], outgoing)
                 when 'LoopedActivity' then nanoflow_loop_source(object['loop'], flows, outgoing, result_type)
                 when 'BreakEvent' then "return 'break';"
                 when 'ContinueEvent' then "return 'continue';"
                 else nanoflow_next_source(outgoing)
                 end
          <<~TS.chomp
                  case #{JSON.generate(object['id'])}: {
            #{indent(body, 10)}
                  }
          TS
        end

        # A loop body runs as its own state machine and reports 'break' or 'continue'.
        def nanoflow_loop_source(loop, flows, outgoing, result_type)
          after = nanoflow_next_source(outgoing)
          @nanoflow_loop_depth = @nanoflow_loop_depth.to_i + 1
          cases = loop.fetch('objects').filter_map { nanoflow_typescript_case(_1, flows, result_type) }
          <<~TS.chomp
            for (const item of runtime.loop(#{JSON.generate(loop.slice('kind', 'list', 'condition'))})) {
              #{loop['kind'] == 'iterable' ? "runtime.set(#{JSON.generate(loop['variable'])}, item);" : 'void item;'}
              const signal = await (async (): Promise<'break' | 'continue'> => {
                let current = #{JSON.generate(nanoflow_loop_entry(loop.fetch('objects'), flows))};
                for (let step = 0; step < 10_000; step += 1) {
                  switch (current) {
            #{indent(cases.join("\n"), 6)}
                    default:
                      throw runtime.missing(current);
                  }
                }
                throw runtime.exceeded();
              })();
              if (signal === 'break') break;
            }
            #{after}
          TS
        ensure
          @nanoflow_loop_depth -= 1
        end

        def nanoflow_loop_entry(objects, flows)
          ids = objects.reject { %w[MicroflowParameter Annotation].include?(_1['type']) }.map { _1['id'] }
          targets = flows.map { _1['destination'] }
          ids.find { !targets.include?(_1) }
        end

        def nanoflow_end_source(object, result_type)
          expression = JSON.generate(object['return'].to_s)
          value = case result_type
                  when 'boolean' then "runtime.boolean(#{expression})"
                  when 'number' then "runtime.number(#{expression})"
                  when 'string' then "runtime.string(#{expression})"
                  when 'undefined' then 'undefined'
                  else "runtime.value(#{expression}) as #{result_type}"
                  end
          "return runtime.complete(#{value});"
        end

        def nanoflow_split_source(object, flows)
          flows = flows.reject { _1['error'] }
          cases = flows.reject { _1['case'].to_s.empty? }.map do |edge|
            "case #{JSON.generate(edge['case'].to_s)}: current = #{JSON.generate(edge['destination'])}; break;"
          end
          fallback = flows.find { _1['case'].to_s.empty? }
          default = if fallback
                      "current = #{JSON.generate(fallback['destination'])}; break;"
                    else
                      "throw runtime.stopped(#{JSON.generate(object['type'])});"
                    end
          <<~TS.chomp
            switch (String(runtime.condition(#{JSON.generate(object['condition'].to_s)}))) {
            #{indent(cases.join("\n"), 2)}
              default: #{default}
            }
            break;
          TS
        end

        def nanoflow_action_source(action)
          action ||= {}
          case action['type']
          when 'LogMessage'
            parameters = JSON.generate(action.fetch('parameters', []))
            "runtime.log(#{JSON.generate(action['message'].to_s)}, #{parameters});\n"
          when 'Retrieve'
            spec = JSON.generate(action.except('type', 'variable'))
            "await runtime.retrieve(#{JSON.generate(action['variable'])}, #{spec});\n"
          when 'Commit' then "await runtime.commit(#{JSON.generate(action['variable'])});\n"
          when 'Delete' then "await runtime.delete(#{JSON.generate(action['variable'])});\n"
          when 'Rollback' then "await runtime.rollback(#{JSON.generate(action['variable'])});\n"
          when 'Synchronize'
            "await runtime.synchronize(#{JSON.generate(action['mode'].to_s)}, " \
              "#{JSON.generate(action.fetch('variables', []))});\n"
          when 'ListOperations' then "runtime.listOperation(#{JSON.generate(action.except('type'))});\n"
          when 'Aggregate' then "runtime.aggregate(#{JSON.generate(action.except('type'))});\n"
          when 'CreateVariable', 'ChangeVariable'
            "runtime.set(#{JSON.generate(action['variable'].to_s)}, " \
              "runtime.value(#{JSON.generate(action['value'].to_s)}));\n"
          when 'Change'
            changes = action.fetch('changes', []).to_h do |change|
              [change['member'].to_s, change['value'].to_s]
            end
            "runtime.change(#{JSON.generate(action['variable'].to_s)}, #{JSON.generate(changes)});\n"
          when 'CreateChange'
            changes = action.fetch('changes', []).to_h { [_1['member'].to_s, _1['value'].to_s] }
            "runtime.create(#{JSON.generate(action['variable'].to_s)}, " \
              "#{JSON.generate(action['entity'].to_s)}, #{JSON.generate(changes)});\n"
          when 'CreateList'
            "runtime.set(#{JSON.generate(action['variable'].to_s)}, []);\n"
          when 'ChangeList'
            "runtime.changeList(#{JSON.generate(action['variable'].to_s)}, " \
              "#{JSON.generate(action['operation'].to_s)}, #{JSON.generate(action['value'].to_s)});\n"
          when 'MicroflowCall'
            variable = action['result_variable'].to_s
            invocation = "runtime.callMicroflow(#{JSON.generate(action['microflow'].to_s)}, " \
                         "#{JSON.generate(action.fetch('arguments', {}))})"
            if variable.empty?
              "await #{invocation};\n"
            else
              "const response = await #{invocation};\n" \
                "runtime.set(#{JSON.generate(variable)}, response);\n"
            end
          when 'ShowMessage'
            "runtime.showMessage(#{JSON.generate(action['message'].to_s)}.replace(" \
              '/\\{(\\d+)\\}/g, (_placeholder, rawIndex) => ' \
              "runtime.string(#{JSON.generate(action.fetch('parameters', []))}[Number(rawIndex) - 1])), " \
              "#{JSON.generate(action['level'].to_s.downcase)}, " \
              "#{action['blocking'] == true});\n"
          when 'NanoflowCall'
            invocation = "runtime.callNanoflow(#{JSON.generate(action['nanoflow'].to_s)}, " \
                         "#{JSON.generate(action.fetch('arguments', {}))})"
            nanoflow_await_source(invocation, action['result_variable'])
          when 'JavaScriptActionCall'
            (@called_javascript_actions ||= Set.new) << action['javascript_action'].to_s
            invocation = "runtime.callJavaScript(#{JSON.generate(action['javascript_action'].to_s)}, " \
                         "#{JSON.generate(action.fetch('arguments', {}))})"
            nanoflow_await_source(invocation, action['result_variable'])
          when 'ShowForm'
            "runtime.showPage(#{JSON.generate(action['page'].to_s)}, " \
              "#{JSON.generate(action.fetch('arguments', {}))}, " \
              "#{JSON.generate(action.fetch('settings', {}))});\n"
          when 'CloseForm'
            "runtime.closePage(#{JSON.generate(action.fetch('count', '1').to_s)});\n"
          when 'ValidationFeedback'
            "runtime.validationFeedback(#{JSON.generate(action['variable'].to_s)}, " \
              "#{JSON.generate(action['member'].to_s)}, #{JSON.generate(action['message'].to_s)});\n"
          else
            "throw runtime.unsupported(#{JSON.generate(action['type'].to_s)});\n"
          end
        end

        def nanoflow_await_source(invocation, result_variable)
          variable = result_variable.to_s
          return "await #{invocation};\n" if variable.empty?

          "runtime.set(#{JSON.generate(variable)}, await #{invocation});\n"
        end

        def nanoflow_action_case_source(action, flows)
          normal = flows.reject { _1['error'] }
          errors = flows.select { _1['error'] }
          raise SerializationError, 'nanoflow action has multiple error-handler paths' if errors.size > 1

          source = nanoflow_action_source(action) + nanoflow_next_source(normal)
          return source if errors.empty?

          <<~TS.chomp
            try {
            #{indent(source, 2)}
            } catch (error) {
              runtime.set('latestError', error instanceof Error ? error.message : String(error));
              current = #{JSON.generate(errors.first['destination'])};
              break;
            }
          TS
        end

        def nanoflow_next_source(flows)
          edge = flows.find { !_1['error'] }
          return "return 'continue';" if !edge && @nanoflow_loop_depth.to_i.positive?
          return "throw runtime.stopped('node');" unless edge

          "current = #{JSON.generate(edge['destination'])};\nbreak;"
        end

        def indent(source, spaces)
          prefix = ' ' * spaces
          source.to_s.lines.map { "#{prefix}#{_1}" }.join.chomp
        end

        def nanoflow_plan(flow, qualified)
          {
            'name' => qualified, 'id' => flow.id,
            'parameters' => flow.parameters.filter_map { _1['Name'] if _1.is_a?(Hash) },
            'objects' => flow.objects.filter_map { nanoflow_object(_1) },
            'flows' => flow.flows.map do |edge|
              {
                'origin' => native_identifier(edge['OriginPointer']),
                'destination' => native_identifier(edge['DestinationPointer']),
                'case' => nanoflow_case(edge), 'error' => edge['IsErrorHandler'] == true
              }
            end
          }
        end

        def nanoflow_object(object)
          return unless object.is_a?(Hash)

          type = object['$Type'].to_s.delete_prefix('Microflows$')
          result = { 'id' => native_identifier(object), 'type' => type }
          result['return'] = object['ReturnValue'].to_s if type == 'EndEvent'
          result['condition'] = object.dig('SplitCondition', 'Expression').to_s if type == 'ExclusiveSplit'
          result['action'] = nanoflow_action(object['Action']) if type == 'ActionActivity'
          result['loop'] = nanoflow_loop(object) if type == 'LoopedActivity'
          result
        end

        def nanoflow_loop(object)
          source = object['LoopSource'] || {}
          {
            'kind' => source['$Type'].to_s.end_with?('WhileLoopCondition') ? 'while' : 'iterable',
            'list' => source['ListVariableName'].to_s, 'variable' => source['VariableName'].to_s,
            'condition' => source['WhileExpression'].to_s,
            'objects' => native_items(object.dig('ObjectCollection', 'Objects')).filter_map { nanoflow_object(_1) }
          }
        end

        def nanoflow_action(action)
          return {} unless action.is_a?(Hash)

          type = action['$Type'].to_s.delete_prefix('Microflows$').delete_suffix('Action')
          result = { 'type' => type }
          case type
          when 'CreateVariable'
            result.merge!('variable' => action['VariableName'].to_s, 'value' => action['InitialValue'].to_s)
          when 'ChangeVariable'
            result.merge!('variable' => action['ChangeVariableName'].to_s, 'value' => action['Value'].to_s)
          when 'Change'
            changes = nanoflow_changes(action)
            result.merge!('variable' => action['ChangeVariableName'].to_s, 'changes' => changes)
          when 'CreateChange'
            result.merge!('variable' => action['VariableName'].to_s,
                          'entity' => action['Entity'].to_s, 'changes' => nanoflow_changes(action))
          when 'CreateList'
            result['variable'] = action['VariableName'].to_s
          when 'ChangeList'
            result.merge!('variable' => action['ChangeVariableName'].to_s,
                          'operation' => action['Type'].to_s, 'value' => action['Value'].to_s)
          when 'LogMessage'
            result['message'] = translated_text_template(action['MessageTemplate'])
            result['parameters'] =
              native_items(action.dig('MessageTemplate', 'Parameters')).map { _1['Expression'].to_s }
          when 'Retrieve' then result.merge!(nanoflow_retrieve(action))
          when 'Commit' then result['variable'] = action['CommitVariableName'].to_s
          when 'Delete' then result['variable'] = action['DeleteVariableName'].to_s
          when 'Rollback' then result['variable'] = action['RollbackVariableName'].to_s
          when 'Synchronize'
            result.merge!('mode' => action['Type'].to_s,
                          'variables' => native_items(action['VariableNames']).map(&:to_s))
          when 'ListOperations' then result.merge!(nanoflow_list_operation(action))
          when 'Aggregate'
            result.merge!('list' => action['AggregateVariableName'].to_s,
                          'function' => action['AggregateFunction'].to_s,
                          'attribute' => action['Attribute'].to_s.split('.').last.to_s,
                          'result_variable' => action['VariableName'].to_s)
          when 'MicroflowCall'
            call = action['MicroflowCall'] || {}
            arguments = native_items(call['ParameterMappings']).to_h do |mapping|
              [mapping['Parameter'].to_s.split('.').last, mapping['Argument'].to_s]
            end
            result.merge!(
              'microflow' => call['Microflow'].to_s,
              'arguments' => arguments,
              'result_variable' => action['UseReturnVariable'] == true ? action['ResultVariableName'].to_s : ''
            )
          when 'ShowMessage'
            template = action['Template'] || {}
            result.merge!(
              'message' => translated_text_template(template),
              'parameters' => native_items(template['Parameters']).map { _1['Expression'].to_s },
              'level' => action['Type'].to_s,
              'blocking' => action['Blocking'] == true
            )
          when 'NanoflowCall'
            call = action['NanoflowCall'] || {}
            result_variable = action['UseReturnVariable'] == true ? action['OutputVariableName'].to_s : ''
            result.merge!('nanoflow' => call['Nanoflow'].to_s,
                          'arguments' => nanoflow_call_arguments(call['ParameterMappings']),
                          'result_variable' => result_variable)
          when 'JavaScriptActionCall'
            result_variable = action['UseReturnVariable'] == true ? action['OutputVariableName'].to_s : ''
            result.merge!('javascript_action' => action['JavaScriptAction'].to_s,
                          'arguments' => javascript_action_arguments(action['ParameterMappings']),
                          'result_variable' => result_variable)
          when 'ShowForm'
            settings = action['FormSettings'] || {}
            result.merge!('page' => settings['Form'].to_s,
                          'arguments' => nanoflow_call_arguments(settings['ParameterMappings']),
                          'settings' => nanoflow_page_settings(action, settings))
          when 'CloseForm'
            result['count'] = action.fetch('NumberOfPagesToClose', '1').to_s
          when 'ValidationFeedback'
            member = (action['Attribute'].to_s.empty? ? action['Association'] : action['Attribute']).to_s
            result.merge!('variable' => action['ValidationVariableName'].to_s,
                          'member' => member.split(%r{[./]}).last.to_s,
                          'message' => translated_text_template(action['FeedbackTemplate']))
          end
          result
        end

        def nanoflow_retrieve(action)
          source = action['RetrieveSource'] || {}
          result = { 'variable' => action['ResultVariableName'].to_s }
          if source['$Type'].to_s.end_with?('AssociationRetrieveSource')
            return result.merge(nanoflow_association_retrieve(source))
          end

          range = source['Range'] || {}
          result.merge(
            'source' => 'database', 'entity' => source['Entity'].to_s, 'xpath' => source['XpathConstraint'].to_s,
            'sort' => nanoflow_sortings(source.dig('NewSortings', 'Sortings')),
            'single' => range['SingleObject'] == true, 'limit' => range['LimitExpression'].to_s,
            'offset' => range['OffsetExpression'].to_s
          )
        end

        def nanoflow_association_retrieve(source)
          name = source['AssociationId'].to_s
          link = @project.modules.flat_map { |mod| mod.associations.map { association_manifest(mod, _1) } }
                         .find { _1['name'] == name }
          raise SerializationError, "unknown nanoflow association #{name}" unless link

          { 'source' => 'association', 'start' => source['StartVariableName'].to_s, 'association' => name,
            'from' => link['from_entity'], 'to' => link['to_entity'], 'kind' => link['type'] }
        end

        def nanoflow_sortings(sortings)
          native_items(sortings).map do |sorting|
            attribute = sorting['AttributePath'] || sorting.dig('AttributeRef', 'Attribute')
            { 'attribute' => attribute.to_s.split('.').last.to_s, 'direction' => sorting['SortOrder'].to_s }
          end
        end

        def nanoflow_list_operation(action)
          operation = action['NewOperation'] || {}
          {
            'operation' => operation['$Type'].to_s.delete_prefix('Microflows$'), 'list' => operation['ListName'].to_s,
            'second' => operation['SecondListOrObjectName'].to_s, 'expression' => operation['Expression'].to_s,
            'attribute' => operation['Attribute'].to_s.split('.').last.to_s,
            'sort' => nanoflow_sortings(operation.dig('Sortings', 'Sortings')),
            'result_variable' => action['ResultVariableName'].to_s
          }
        end

        def nanoflow_page_settings(action, settings)
          title = settings['TitleOverride'] || settings['FormTitle']
          title = { 'Text' => title } if title&.key?('Items')
          {
            'close' => action['NumberOfPagesToClose'].to_s,
            'context' => action['FormObjectVariable'].to_s,
            'location' => { 'Content' => 'content', 'Popup' => 'popup', 'ModalPopup' => 'modal' }[settings['Location']],
            'title' => title ? translated_text_template(title) : nil,
            'title_parameters' => native_items(title&.dig('Parameters')).map { _1['Expression'].to_s }
          }.compact
        end

        def nanoflow_changes(action)
          native_items(action['Items']).map do |item|
            member = (item['Attribute'].to_s.empty? ? item['Association'] : item['Attribute']).to_s
            { 'member' => member.split(%r{[./]}).last.to_s, 'value' => item['Value'].to_s }
          end
        end

        def nanoflow_call_arguments(mappings)
          native_items(mappings).to_h do |mapping|
            [mapping['Parameter'].to_s.split('.').last, mapping['Argument'].to_s]
          end
        end

        def javascript_action_arguments(mappings)
          native_items(mappings).to_h do |mapping|
            value = mapping.fetch('ParameterValue', {})
            argument = if value['$Type'].to_s.end_with?('EntityTypeCodeActionParameterValue')
                         "'#{value['Entity'].to_s.gsub("'", "''")}'"
                       else
                         value['Argument'].to_s
                       end
            [mapping['Parameter'].to_s.split('.').last, argument]
          end
        end

        def translated_text_template(template)
          text = template.is_a?(Hash) ? template['Text'] : nil
          return text.to_s unless text.is_a?(Hash)

          translations = native_items(text['Items'])
          selected = translations.find { _1['LanguageCode'].to_s == 'en_US' } || translations.first
          selected.is_a?(Hash) ? selected['Text'].to_s : ''
        end

        def typescript_entity_reference(entity)
          known = @known_entity_names
          available = known ? known.include?(entity.to_s) : !entity.to_s.start_with?('System.')
          return "EntityTypeMap[#{JSON.generate(entity)}]" if available

          'EntityRecord'
        end

        def nanoflow_case(edge)
          value = native_items(edge['CaseValues']).first || edge['NewCaseValue'] || {}
          value['$Type'] == 'Microflows$NoCase' ? '' : value['Value'].to_s
        end

        def native_items(value)
          IO::BsonCodec.parse_array(value)[:items]
        rescue StandardError
          Array(value).drop(value.is_a?(Array) && value.first.is_a?(Integer) ? 1 : 0)
        end

        def native_identifier(value)
          IO::BsonCodec.extract_id(value.is_a?(Hash) ? value['$ID'] : value).to_s
        end
      end
      # rubocop:enable Metrics
    end
  end
end
