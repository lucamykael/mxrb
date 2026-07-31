# frozen_string_literal: true

require 'securerandom'

module Mxrb
  module Runtime
    module Native
      # Graph interpretation intentionally keeps semantic dispatch together.
      # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
      ObjectValue = Data.define(:entity, :id, :members)

      # Transactional in-memory persistence used by the Ruby model Runtime.
      class Store
        def initialize
          @records = Hash.new { |records, entity| records[entity] = [] }
        end

        def create(entity)
          ObjectValue.new(entity:, id: SecureRandom.uuid, members: {}).tap do |object|
            @records[entity] << object
          end
        end

        def retrieve(entity) = @records[entity].dup

        def delete(value)
          Array(value).each { @records[_1.entity].delete(_1) }
        end

        def count(entity, predicate = nil)
          values = retrieve(entity)
          predicate ? values.count { predicate.call(_1) } : values.size
        end

        def snapshot
          @records.to_h do |entity, values|
            [entity, values.map { ObjectValue.new(entity: _1.entity, id: _1.id, members: _1.members.dup) }]
          end
        end

        def restore(snapshot)
          @records.clear
          snapshot.each { |entity, values| @records[entity] = values }
        end
      end

      # Deliberately small Mendix-expression evaluator. Unsupported syntax is
      # rejected rather than guessed, preserving deterministic test semantics.
      class Expression
        def evaluate(source, variables)
          text = unwrap(source).strip
          return nil if text.empty? || text == 'empty'
          return true if text.casecmp?('true')
          return false if text.casecmp?('false')
          return text[1...-1].gsub("''", "'") if quoted?(text)
          return Integer(text) if text.match?(/\A-?\d+\z/)
          return Float(text) if text.match?(/\A-?\d+\.\d+\z/)
          return variable(text, variables) if text.match?(%r{\A\$[A-Za-z_]\w*(?:/[A-Za-z_][\w.]*)?\z})

          logical(text, variables) { |part| evaluate(part, variables) }
        rescue ArgumentError
          raise NativeRuntimeError, "unsupported Mendix expression: #{source.inspect}"
        end

        private

        def unwrap(source)
          source.is_a?(Hash) ? (source['Value'] || source['Expression'] || '') : source.to_s
        end

        def quoted?(text)
          text.length >= 2 && text.start_with?("'") && text.end_with?("'")
        end

        def variable(text, variables)
          name, member = text.delete_prefix('$').split('/', 2)
          value = variables.fetch(name) do
            raise NativeRuntimeError, "unknown variable $#{name}"
          end
          return value unless member

          raise NativeRuntimeError, "$#{name} is not an object" unless value.is_a?(ObjectValue)

          value.members[member.split('.').last]
        end

        def logical(text, variables, &block)
          split = split_operator(text, /\s+or\s+/i)
          return split.any? { yield(_1) } if split.size > 1

          split = split_operator(text, /\s+and\s+/i)
          return split.all? { yield(_1) } if split.size > 1

          comparison(text, variables, &block)
        end

        def comparison(text, _variables)
          match = text.match(/\A\(?(.+?)\)?\s*(=|!=|>=|<=|>|<)\s*\(?(.+?)\)?\z/)
          raise ArgumentError unless match

          left = yield(match[1])
          right = yield(match[3])
          { '=' => left == right, '!=' => left != right, '>' => left > right,
            '<' => left < right, '>=' => left >= right, '<=' => left <= right }.fetch(match[2])
        end

        def split_operator(text, operator)
          text.sub(/\A\((.*)\)\z/, '\\1').split(operator)
        end
      end

      # Executes the graph and core data activities directly from the MPR.
      class Interpreter
        attr_reader :store, :log

        def initialize(project, store: Store.new)
          @project = project
          @store = store
          @expression = Expression.new
          @log = []
          @flows = project.modules.flat_map do |mod|
            mod.microflows.map { ["#{mod.name}.#{_1.name}", _1] }
          end.to_h
        end

        def call(name, arguments = {})
          flow = @flows[name]
          raise NativeRuntimeError, "microflow #{name} not found" unless flow

          snapshot = store.snapshot
          execute(flow, normalize_arguments(flow, arguments))
        rescue StandardError
          store.restore(snapshot) if snapshot
          raise
        end

        private

        def execute(flow, variables)
          objects = flow.objects.to_h { [identifier(_1), _1] }
          outgoing = flow.flows.reject { _1['IsErrorHandler'] == true }
                               .group_by { identifier(_1['OriginPointer']) }
          current = flow.objects.find { _1['$Type'] == 'Microflows$StartEvent' }
          raise NativeRuntimeError, "microflow #{flow.name} has no start event" unless current

          10_000.times do
            type = current['$Type']
            return @expression.evaluate(current['ReturnValue'], variables) if type == 'Microflows$EndEvent'

            execute_action(current['Action'], variables) if type == 'Microflows$ActionActivity'
            edge = select_edge(current, outgoing[identifier(current)] || [], variables)
            raise NativeRuntimeError, "microflow #{flow.name} stops at #{type}" unless edge

            current = objects[identifier(edge['DestinationPointer'])]
            raise NativeRuntimeError, 'sequence flow points to a missing object' unless current
          end
          raise NativeRuntimeError, "microflow #{flow.name} exceeded 10000 steps"
        end

        def select_edge(object, edges, variables)
          return edges.first unless %w[Microflows$ExclusiveSplit Microflows$InheritanceSplit].include?(object['$Type'])

          value = split_value(object, variables)
          edges.find { flow_case(_1) == value.to_s } || edges.find { flow_case(_1).empty? }
        end

        def split_value(object, variables)
          if object['$Type'] == 'Microflows$InheritanceSplit'
            value = variables.fetch(object['SplitVariableName'].to_s)
            value.respond_to?(:entity) ? value.entity : value.class.name
          else
            @expression.evaluate(object.dig('SplitCondition', 'Expression'), variables)
          end
        end

        def flow_case(edge)
          values = items(edge['CaseValues'])
          value = values.first || edge['NewCaseValue'] || {}
          value['$Type'] == 'Microflows$NoCase' ? '' : value['Value'].to_s
        end

        def execute_action(action, variables)
          raise NativeRuntimeError, 'action activity has no action' unless action.is_a?(Hash)

          handler = action['$Type'].to_s.delete_prefix('Microflows$').delete_suffix('Action')
          method = "action_#{underscore(handler)}"
          raise NativeRuntimeError, "unsupported activity #{action['$Type']}" unless respond_to?(method, true)

          send(method, action, variables)
        end

        def action_create_change(action, variables)
          object = store.create(action['Entity'].to_s)
          apply_changes(object, action['Items'], variables)
          variables[action['VariableName'].to_s] = object
        end

        def action_change(action, variables)
          object = variables.fetch(action['ChangeVariableName'].to_s)
          apply_changes(object, action['Items'], variables)
        end

        def action_create_variable(action, variables)
          variables[action['VariableName'].to_s] = @expression.evaluate(action['InitialValue'], variables)
        end

        def action_change_variable(action, variables)
          variables[action['ChangeVariableName'].to_s] = @expression.evaluate(action['Value'], variables)
        end

        def action_retrieve(action, variables)
          source = action['RetrieveSource'] || {}
          unless source['$Type'] == 'Microflows$DatabaseRetrieveSource'
            raise NativeRuntimeError, "unsupported retrieve source #{source['$Type']}"
          end

          values = store.retrieve(source['Entity'].to_s)
          range = source['Range'] || {}
          limit = @expression.evaluate(range['LimitExpression'], variables)
          values = values.first(limit) if limit.is_a?(Integer) && limit.positive?
          variables[action['ResultVariableName'].to_s] = values
        end

        def action_aggregate(action, variables)
          values = Array(variables.fetch(action['AggregateVariableName'].to_s))
          attribute = action['Attribute'].to_s.split('.').last.to_s
          members = attribute.empty? ? values : values.map { _1.members[attribute] }
          result = aggregate(action['AggregateFunction'], members)
          variables[action['VariableName'].to_s] = result
        end

        def action_microflow_call(action, variables)
          call_doc = action['MicroflowCall'] || {}
          arguments = items(call_doc['ParameterMappings']).to_h do |mapping|
            [mapping['Parameter'].to_s.split('.').last, @expression.evaluate(mapping['Argument'], variables)]
          end
          result = call(call_doc['Microflow'].to_s, arguments)
          variables[action['ResultVariableName'].to_s] = result if action['UseReturnVariable'] == true
        end

        def action_commit(_action, _variables); end

        def action_delete(action, variables)
          store.delete(variables.fetch(action['DeleteVariableName'].to_s))
        end

        def action_log_message(action, variables)
          @log << render_template(action['MessageTemplate'], variables)
        end

        def action_cast(_action, _variables); end

        def aggregate(function, values)
          case function.to_s.downcase
          when 'count' then values.size
          when 'sum' then values.compact.sum
          when 'minimum', 'min' then values.compact.min
          when 'maximum', 'max' then values.compact.max
          when 'average', 'avg' then values.empty? ? nil : values.compact.sum.to_f / values.compact.size
          else raise NativeRuntimeError, "unsupported aggregate #{function}"
          end
        end

        def apply_changes(object, values, variables)
          items(values).each do |item|
            member = (item['Attribute'].to_s.empty? ? item['Association'] : item['Attribute']).to_s
            name = member.split(%r{[./]}).last
            object.members[name] = @expression.evaluate(item['Value'], variables)
          end
        end

        def render_template(template, variables)
          text = template&.dig('Text').to_s
          items(template&.dig('Parameters')).each_with_index do |parameter, index|
            text = text.gsub("{#{index + 1}}", @expression.evaluate(parameter['Expression'], variables).to_s)
          end
          text
        end

        def normalize_arguments(flow, arguments)
          names = flow.parameters.filter_map { _1['Name'] if _1.is_a?(Hash) }
          names.to_h do |name|
            [name, arguments.fetch(name) { raise NativeRuntimeError, "missing argument #{name}" }]
          end
        end

        def items(value)
          IO::BsonCodec.parse_array(value)[:items]
        rescue StandardError
          Array(value).drop(value.is_a?(Array) && value.first.is_a?(Integer) ? 1 : 0)
        end

        def identifier(value)
          IO::BsonCodec.extract_id(value.is_a?(Hash) ? value['$ID'] : value).to_s
        end

        def underscore(value)
          value.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase
        end
      end

      # Runs existing functional definitions against the Ruby interpreter.
      class Executor
        def initialize(project_path, definition, output: nil, clock: Process.method(:clock_gettime), **)
          @project_path = File.expand_path(project_path)
          @definition = definition
          @output = output
          @clock = clock
        end

        def run
          started = monotonic_time
          project = Model::Project.open(@project_path)
          interpreter = Interpreter.new(project)
          tests = @definition.tests.map { run_test(interpreter, _1) }
          transcript = tests.map { "[MXRB_TEST] #{_1.passed? ? 'PASS' : 'FAIL'} #{_1.name}" }.join("\n")
          transcript = "#{transcript}\n[MXRB_TEST] DONE\n"
          @output&.write(transcript)
          Execution.new(
            Functional::Result.new(tests.freeze, true), 'MXRB native validation passed',
            'Ruby microflow interpreter', transcript, monotonic_time - started
          )
        ensure
          project&.close
        end

        private

        def run_test(interpreter, test)
          interpreter.call(test.setup.target, evaluated_arguments(test.setup.arguments)) if test.setup
          actual = interpreter.call(test.target, evaluated_arguments(test.arguments))
          failures = expectations(interpreter, test, actual)
          interpreter.call(test.cleanup.target, evaluated_arguments(test.cleanup.arguments)) if test.cleanup
          Functional::TestResult.new(test.name, failures.empty?, failures.empty? ? 'passed' : failures.join('; '))
        rescue StandardError => e
          Functional::TestResult.new(test.name, false, e.message)
        end

        def expectations(interpreter, test, actual)
          failures = []
          if test.expected_return
            expected = Expression.new.evaluate(test.expected_return, {})
            failures << "return #{actual.inspect}, expected #{expected.inspect}" unless actual == expected
          end
          test.counts.each do |expectation|
            actual_count = interpreter.store.count(expectation.entity)
            unless actual_count == expectation.equals
              failures << "#{expectation.entity} count #{actual_count}, expected #{expectation.equals}"
            end
          end
          failures
        end

        def evaluated_arguments(arguments)
          arguments.to_h.transform_values { Expression.new.evaluate(_1, {}) }
        end

        def monotonic_time
          @clock.call(Process::CLOCK_MONOTONIC)
        rescue ArgumentError
          @clock.call
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
    end
  end
end
