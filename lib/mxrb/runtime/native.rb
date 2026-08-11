# frozen_string_literal: true

require 'securerandom'
require 'strscan'
require 'json'
require 'monitor'
require 'net/http'
require 'uri'

module Mxrb
  module Runtime
    module Native
      # Graph interpretation intentionally keeps semantic dispatch together.
      # rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength, Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
      # rubocop:disable Metrics/ParameterLists
      ObjectValue = Data.define(:entity, :id, :members)

      # Transactional in-memory persistence used by the Ruby model Runtime.
      class Store
        LIFECYCLE_EVENTS = %i[
          before_create after_create before_update after_update
          before_commit after_commit before_delete after_delete
        ].freeze

        def initialize(defaults: {}, hooks: {}, transient_entities: [])
          @records = Hash.new { |records, entity| records[entity] = [] }
          @defaults = defaults
          @committed = {}
          @hooks = hooks
          @transient_entities = Array(transient_entities).map(&:to_s).to_h { [_1, true] }.freeze
        end

        def on(entity, event, &callback)
          raise ArgumentError, "unknown lifecycle event #{event}" unless LIFECYCLE_EVENTS.include?(event.to_sym)
          raise ArgumentError, 'lifecycle callback is required' unless callback

          @hooks[entity.to_s] ||= {}
          @hooks[entity.to_s][event.to_sym] ||= []
          @hooks[entity.to_s][event.to_sym] << callback
          self
        end

        def create(entity, events: true)
          raise ArgumentError, 'events must be boolean' unless [true, false].include?(events)

          members = @defaults.fetch(entity, {}).dup
          ObjectValue.new(entity:, id: SecureRandom.uuid, members:).tap do |object|
            @records[entity] << object
          end
        end

        def retrieve(entity) = @records[entity].dup

        def find(entity, id) = @records[entity].find { _1.id == id.to_s }

        def retrieve_association(association, start)
          member = association.to_s.split('.').last
          direct = Array(start&.members&.[](association) || start&.members&.[](member))
          inverse = @records.values.flatten.select do |object|
            Array(object.members[association] || object.members[member]).include?(start)
          end
          (direct + inverse).uniq
        end

        def delete(value, events: true)
          Array(value).each do |object|
            run_hooks(:before_delete, object) if events
            @records[object.entity].delete(object)
            @committed.delete(record_key(object))
            run_hooks(:after_delete, object) if events
          end
        end

        def count(entity, predicate = nil)
          values = retrieve(entity)
          predicate ? values.count { predicate.call(_1) } : values.size
        end

        def snapshot
          {
            records: copy_records(@records),
            committed: @committed.transform_values(&:dup)
          }
        end

        def restore(snapshot)
          @records.clear
          snapshot.fetch(:records).each { |entity, values| @records[entity] = values }
          @committed = snapshot.fetch(:committed).transform_values(&:dup)
        end

        def transaction
          state = snapshot
          result = yield
          discard_uncommitted
          result
        rescue StandardError
          restore(state)
          raise
        end

        def commit(value, events: true)
          Array(value).each do |object|
            creating = !@committed.key?(record_key(object))
            run_hooks(creating ? :before_create : :before_update, object) if events
            run_hooks(:before_commit, object) if events
            @committed[record_key(object)] = object.members.dup
            run_hooks(:after_commit, object) if events
            run_hooks(creating ? :after_create : :after_update, object) if events
          end
          value
        end

        def rollback(value)
          Array(value).each do |object|
            persisted = @committed[record_key(object)]
            if persisted
              object.members.replace(persisted.dup)
            else
              @records[object.entity].delete(object)
            end
          end
          value
        end

        def close; end

        private

        def copy_records(records)
          records.to_h do |entity, values|
            [entity, values.map { ObjectValue.new(entity: _1.entity, id: _1.id, members: _1.members.dup) }]
          end
        end

        # A root microflow is a unit of work. Persistent values only enter the
        # durable record set through commit; returned uncommitted values remain
        # valid Ruby objects, but are detached from subsequent retrieves.
        # Non-persistent entities deliberately remain session-local in memory.
        def discard_uncommitted
          transient = @records.filter_map do |entity, values|
            [entity, values.dup] if transient_entity?(entity)
          end.to_h
          @records.clear
          transient.each { |entity, values| @records[entity] = values }
          @committed.each do |(entity, id), members|
            next if transient_entity?(entity)

            @records[entity] << ObjectValue.new(entity:, id:, members: members.dup)
          end
        end

        def transient_entity?(entity) = @transient_entities.key?(entity.to_s)

        def record_key(object) = [object.entity, object.id]

        def run_hooks(event, object)
          raise ArgumentError, "unknown lifecycle event #{event}" unless LIFECYCLE_EVENTS.include?(event)

          Array(@hooks.dig(object.entity, event)).each { _1.call(object) }
        end
      end

      # Deliberately small Mendix-expression evaluator. Unsupported syntax is
      # rejected rather than guessed, preserving deterministic test semantics.
      class Expression
        def initialize
          @token_cache = {}
        end

        def evaluate(source, variables, node: nil)
          text = unwrap(source).strip
          return nil if text.empty?

          tokens = (@token_cache[text] ||= Lexer.new(text).tokens.freeze)
          Parser.new(tokens, self, variables, node).parse
        rescue ArgumentError, TypeError, KeyError
          raise NativeRuntimeError, "unsupported Mendix expression: #{source.inspect}"
        end

        def resolve_variable(text, variables)
          name, member = text.delete_prefix('$').split('/', 2)
          value = variables.fetch(name) do
            raise NativeRuntimeError, "unknown variable $#{name}"
          end
          return value unless member

          raise NativeRuntimeError, "$#{name} is not an object" unless value.is_a?(ObjectValue)

          value.members[member.split('.').last]
        end

        def resolve_identifier(text, node)
          return true if text.casecmp?('true')
          return false if text.casecmp?('false')
          return nil if text.casecmp?('empty')

          if node && bare_reference?(text)
            member = text.split('/').last.split('.').last
            return node.members[member] if node.members.key?(member)
          end
          return text if text.match?(/\A[A-Za-z_]\w*\.[A-Za-z_]\w*\.[A-Za-z_]\w*\z/)
          return node_member(text, node) if node && bare_reference?(text)

          raise ArgumentError, text
        end

        def invoke(name, arguments)
          case name.downcase
          when 'tostring' then mendix_string(arguments.fetch(0))
          when 'parseinteger' then Integer(arguments.fetch(0))
          when 'parsedecimal' then Float(arguments.fetch(0))
          when 'round' then arguments.fetch(0).round
          when 'random' then Random.rand
          when 'substring' then substring(*arguments)
          when 'find' then arguments.fetch(0).to_s.index(arguments.fetch(1).to_s) || -1
          when 'formatdatetime' then format_datetime(*arguments)
          when 'contains' then arguments.fetch(0).to_s.include?(arguments.fetch(1).to_s)
          when 'startswith' then arguments.fetch(0).to_s.start_with?(arguments.fetch(1).to_s)
          when 'endswith' then arguments.fetch(0).to_s.end_with?(arguments.fetch(1).to_s)
          else raise ArgumentError, name
          end
        end

        private

        def unwrap(source)
          source.is_a?(Hash) ? (source['Value'] || source['Expression'] || '') : source.to_s
        end

        def matching_parenthesis(text, opening)
          depth = 0
          quoted = false
          text.each_char.with_index do |character, index|
            next if index < opening

            quoted = !quoted if character == "'"
            next if quoted

            depth += 1 if character == '('
            depth -= 1 if character == ')'
            return index if depth.zero?
          end
          nil
        end

        # An attribute reference inside an XPath predicate, e.g. `Name` or
        # `Clinic.Animal/Name`, resolved against the current candidate object.
        def bare_reference?(text)
          text.match?(%r{\A[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*(?:/[A-Za-z_][\w.]*)?\z})
        end

        def node_member(text, node)
          node.members[text.split('/').last.split('.').last]
        end

        def mendix_string(value)
          return 'true' if value == true
          return 'false' if value == false

          value.to_s
        end

        def substring(value, start, length = nil)
          result = length.nil? ? value.to_s.slice(start..) : value.to_s.slice(start, length)
          result.to_s
        end

        def format_datetime(value, pattern)
          format = pattern.to_s.gsub('yyyy', '%Y').gsub('MMM', '%b').gsub('EEE', '%a')
                          .gsub('MM', '%m').gsub('dd', '%d').gsub('HH', '%H')
                          .gsub('mm', '%M').gsub('ss', '%S')
          value.strftime(format)
        end

        # Recursive-descent parser for the expression subset used by native
        # microflows. It deliberately accepts syntax, not arbitrary Ruby code.
        class Parser
          COMPARISONS = {
            '=' => ->(left, right) { left == right },
            '!=' => ->(left, right) { left != right },
            '>' => ->(left, right) { left > right },
            '<' => ->(left, right) { left < right },
            '>=' => ->(left, right) { left >= right },
            '<=' => ->(left, right) { left <= right }
          }.freeze

          def initialize(tokens, expression, variables, node)
            @tokens = tokens
            @index = 0
            @expression = expression
            @variables = variables
            @node = node
            advance
          end

          def parse
            value = parse_or
            raise ArgumentError unless @token == :eof

            value
          end

          private

          def parse_or
            left = parse_and
            while accept_word('or')
              right = parse_and
              left = truthy?(left) || truthy?(right)
            end
            left
          end

          def parse_and
            left = parse_comparison
            while accept_word('and')
              right = parse_comparison
              left = truthy?(left) && truthy?(right)
            end
            left
          end

          def parse_comparison
            left = parse_addition
            while @token == :operator && COMPARISONS.key?(@value)
              operator = consume(:operator)
              left = COMPARISONS.fetch(operator).call(left, parse_addition)
            end
            left
          end

          def parse_addition
            left = parse_multiplication
            while @token == :operator && %w[+ -].include?(@value)
              operator = consume(:operator)
              right = parse_multiplication
              left = operator == '+' ? left + right : left - right
            end
            left
          end

          def parse_multiplication
            left = parse_unary
            while @token == :operator && %w[* /].include?(@value)
              operator = consume(:operator)
              right = parse_unary
              left = operator == '*' ? left * right : left / right
            end
            left
          end

          def parse_unary
            return !parse_unary if accept_word('not')
            return -parse_unary if accept_operator('-')

            parse_primary
          end

          def parse_primary
            return consume(@token) if %i[number string].include?(@token)

            if @token == :datetime
              consume(:datetime)
              return Time.now
            end
            return @expression.resolve_variable(consume(:variable), @variables) if @token == :variable
            return grouped if accept(:left_parenthesis)
            return identifier if @token == :identifier

            raise ArgumentError, @value.to_s
          end

          def grouped
            value = parse_or
            consume(:right_parenthesis)
            value
          end

          def identifier
            name = consume(:identifier)
            return @expression.resolve_identifier(name, @node) unless accept(:left_parenthesis)

            arguments = []
            unless accept(:right_parenthesis)
              loop do
                arguments << parse_or
                break if accept(:right_parenthesis)

                consume(:comma)
              end
            end
            @expression.invoke(name, arguments)
          end

          def accept_word(word)
            return false unless @token == :identifier && @value.casecmp?(word)

            advance
            true
          end

          def accept_operator(operator)
            return false unless @token == :operator && @value == operator

            advance
            true
          end

          def accept(token)
            return false unless @token == token

            advance
            true
          end

          def consume(token)
            raise ArgumentError, "expected #{token}" unless @token == token

            value = @value
            advance
            value
          end

          def advance
            @token, @value = @tokens[@index] || [:eof, nil]
            @index += 1
          end

          def truthy?(value)
            value != false && !value.nil?
          end
        end

        # Tokenization is cached by Expression so tight microflow loops do not
        # repeatedly scan the same static Mendix source string.
        class Lexer
          def initialize(text)
            @scanner = StringScanner.new(text)
          end

          def tokens
            result = []
            loop do
              @scanner.skip(/\s+/)
              token = next_token
              result << token
              return result if token.first == :eof
            end
          end

          private

          def next_token
            return [:eof, nil] if @scanner.eos?
            return [:datetime, nil] if @scanner.scan(/\[%CurrentDateTime%\]/i)
            return [:string, scan_string] if @scanner.peek(1) == "'"
            return [:number, number(@scanner.scan(/\d+(?:\.\d+)?/))] if @scanner.check(/\d/)
            return [:variable, @scanner.scan(%r{\$[A-Za-z_]\w*(?:/[A-Za-z_][\w.]*)?})] if @scanner.check(/\$/)
            return [:identifier, @scanner.scan(/[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*/)] if @scanner.check(/[A-Za-z_]/)
            return [:operator, @scanner.scan(%r{!=|>=|<=|=|>|<|\+|-|\*|/})] if @scanner.check(%r{[!><=+*/-]})

            punctuation
          end

          def scan_string
            @scanner.getch
            value = +''
            until @scanner.eos?
              character = @scanner.getch
              unless character == "'"
                value << character
                next
              end

              return value unless @scanner.peek(1) == "'"

              @scanner.getch
              value << "'"
            end
            raise ArgumentError, 'unterminated string'
          end

          def number(value)
            value.include?('.') ? Float(value) : Integer(value)
          end

          def punctuation
            character = @scanner.getch
            token = { '(' => :left_parenthesis, ')' => :right_parenthesis, ',' => :comma }[character]
            raise ArgumentError, character unless token

            [token, character]
          end
        end
      end

      # Executes the graph and core data activities directly from the MPR.
      class Interpreter
        attr_reader :store, :log, :effects

        def initialize(project, store: nil, adapters: {}, java_custom_actions: {}, http: nil, policy: nil)
          @project = project
          @expression = Expression.new
          @log = []
          @effects = []
          @call_depth = 0
          @call_monitor = Monitor.new
          @collection_plans = {
            true => {}.compare_by_identity,
            false => {}.compare_by_identity
          }
          @identifier_cache = {}.compare_by_identity
          @flow_case_cache = {}.compare_by_identity
          @adapters = adapters.transform_keys(&:to_sym)
          @java_custom_actions = java_custom_actions.to_h.transform_keys(&:to_s).freeze
          @java_action_parameter_names = {}
          @http = http || method(:http_request)
          @policy = policy
          @security_context = nil
          @apply_entity_access = false
          @flows = project.modules.flat_map do |mod|
            mod.microflows.map { ["#{mod.name}.#{_1.name}", _1] }
          end.to_h
          entity_names = project.modules.flat_map do |mod|
            mod.entities.map { [_1.id.to_s, "#{mod.name}.#{_1.name}"] }
          end.to_h
          defaults = project.modules.flat_map do |mod|
            mod.entities.map do |entity|
              ["#{mod.name}.#{entity.name}", entity.attributes.to_h do |attribute|
                [attribute.name, attribute_default(attribute)]
              end]
            end
          end.to_h
          transient_entities = project.modules.flat_map do |mod|
            mod.entities.select { _1.persistable == false }.map { "#{mod.name}.#{_1.name}" }
          end
          @store = store || Store.new(defaults:, transient_entities:)
          register_model_lifecycle
          @associations = project.modules.flat_map do |mod|
            mod.associations.map do |association|
              ["#{mod.name}.#{association.name}", {
                type: association.association_type,
                from: entity_names[association.from_entity_id.to_s]
              }]
            end
          end.to_h
        end

        def call(name, arguments = nil, context: nil, **keyword_arguments)
          (@call_monitor ||= Monitor.new).synchronize do
            execute_call(name, arguments, context:, **keyword_arguments)
          end
        end

        def clear_effects! = @effects.clear

        # Counts stored objects of an entity, optionally narrowed by an XPath
        # constraint. Used by the functional Executor's count expectations.
        def count(entity, xpath = nil)
          filter_by_xpath(store.retrieve(entity.to_s), xpath.to_s, {}).size
        end

        private

        def execute_call(name, arguments = nil, context: nil, **keyword_arguments)
          arguments = keyword_arguments if arguments.nil?
          arguments = arguments.to_h.merge(keyword_arguments) unless keyword_arguments.empty?
          previous_context = @security_context
          previous_apply_entity_access = @apply_entity_access
          root_call = @call_depth.zero?
          @effects = [] if root_call
          @call_depth += 1
          flow = @flows[name]
          raise NativeRuntimeError, "microflow #{name} not found" unless flow

          @security_context = context unless context.nil?
          @apply_entity_access = flow.respond_to?(:apply_entity_access) && flow.apply_entity_access == true
          normalized = normalize_arguments(flow, arguments)
          if root_call && store.respond_to?(:transaction)
            store.transaction { execute(flow, normalized) }
          else
            snapshot = store.snapshot if root_call
            execute(flow, normalized)
          end
        rescue StandardError
          store.restore(snapshot) if snapshot
          raise
        ensure
          @security_context = previous_context
          @apply_entity_access = previous_apply_entity_access
          @call_depth -= 1
        end

        def attribute_default(attribute)
          value = attribute.default_value.to_s
          case attribute.type
          when :boolean then value.casecmp?('true')
          when :integer, :long, :autonumber then value.empty? ? nil : Integer(value)
          when :decimal then value.empty? ? nil : Float(value)
          when :string then value
          else value.empty? ? nil : value
          end
        end

        def register_model_lifecycle
          return unless store.respond_to?(:on)

          @project.modules.each do |mod|
            mod.entities.each do |entity|
              qualified = "#{mod.name}.#{entity.name}"
              Array(entity.respond_to?(:lifecycle) ? entity.lifecycle : nil).each do |callback|
                event = callback.fetch(:event).to_sym
                next unless Store::LIFECYCLE_EVENTS.include?(event)

                handler = qualify_flow(mod.name, callback.fetch(:handler))
                store.on(qualified, event) do |object|
                  result = call(handler, lifecycle_arguments(handler, object, callback))
                  if callback[:raise_error_on_false] && result == false
                    raise NativeRuntimeError, "entity lifecycle #{handler} rejected #{qualified}"
                  end
                end
              end
            end
          end
        end

        def qualify_flow(module_name, name)
          value = name.to_s
          value.include?('.') ? value : "#{module_name}.#{value}"
        end

        def lifecycle_arguments(handler, object, callback)
          return {} unless callback.fetch(:pass_event_object, true)

          flow = @flows[handler]
          parameter = flow&.parameters&.find { _1.is_a?(Hash) }
          name = parameter && parameter['Name'].to_s
          name.to_s.empty? ? {} : { name => object }
        end

        def execute(flow, variables)
          outgoing = flow.flows.group_by { identifier(_1['OriginPointer']) }
          result = execute_collection(flow.objects, outgoing, variables, label: "microflow #{flow.name}", root: true)
          result&.last
        end

        def execute_collection(collection, outgoing, variables, label:, root: false)
          plan = collection_plan(collection, outgoing, root:)
          objects = plan.fetch(:objects)
          current = plan.fetch(:entry)
          raise NativeRuntimeError, "#{label} has no start event" unless current

          10_000.times do
            type = current['$Type']
            return [:return, @expression.evaluate(current['ReturnValue'], variables)] if type == 'Microflows$EndEvent'
            return [:break, nil] if type == 'Microflows$BreakEvent'
            return [:continue, nil] if type == 'Microflows$ContinueEvent'

            if type == 'Microflows$ErrorEvent'
              raise NativeRuntimeError, @expression.evaluate(current['ErrorExpression'], variables).to_s
            end

            edges = outgoing[identifier(current)] || []
            error_edge = edges.find { _1['IsErrorHandler'] == true }
            action_snapshot = nil
            begin
              if type == 'Microflows$ActionActivity' && error_edge &&
                 current.dig('Action', 'ErrorHandlingType') == 'Rollback'
                action_snapshot = store.snapshot
              end
              execute_action(current['Action'], variables) if type == 'Microflows$ActionActivity'
              execute_loop(current, outgoing, variables, label:) if type == 'Microflows$LoopedActivity'
              edge = select_edge(current, edges.reject { _1['IsErrorHandler'] == true }, variables)
            rescue StandardError => e
              edge = error_edge
              raise unless edge

              if action_snapshot && current.dig('Action', 'ErrorHandlingType') == 'Rollback'
                store.restore(action_snapshot)
              end
              variables['latestError'] = e
            end
            return [:complete, nil] unless edge || root
            raise NativeRuntimeError, "#{label} stops at #{type}" unless edge

            destination = identifier(edge['DestinationPointer'])
            current = objects[destination]
            return [:complete, nil] unless current || root
            raise NativeRuntimeError, 'sequence flow points to a missing object' unless current
          end
          raise NativeRuntimeError, "#{label} exceeded 10000 steps"
        end

        def collection_plan(collection, outgoing, root:)
          plans = @collection_plans.fetch(root)
          plans[collection] ||= begin
            list = items(collection).select { _1.is_a?(Hash) }
            objects = list.to_h { [identifier(_1), _1] }
            { objects:, entry: collection_entry(list, objects, outgoing, root:) }.freeze
          end
        end

        def collection_entry(list, objects, outgoing, root:)
          start = list.find { _1['$Type'] == 'Microflows$StartEvent' }
          return start if start || root

          destinations = objects.keys.to_h { [_1, false] }
          objects.each_key do |origin|
            Array(outgoing[origin]).each do |edge|
              destination = identifier(edge['DestinationPointer'])
              destinations[destination] = true if destinations.key?(destination)
            end
          end
          list.find do |object|
            !destinations[identifier(object)] && executable_object?(object)
          end
        end

        def executable_object?(object)
          !%w[Microflows$Annotation Microflows$MicroflowParameter].include?(object['$Type'])
        end

        def execute_loop(activity, outgoing, variables, label:)
          source = activity['LoopSource'] || {}
          nested = activity.dig('ObjectCollection', 'Objects')
          case source['$Type']
          when 'Microflows$WhileLoopCondition'
            execute_while_loop(source, nested, outgoing, variables, label:)
          when 'Microflows$IterableList'
            execute_iterable_loop(source, nested, outgoing, variables, label:)
          else
            raise NativeRuntimeError, "unsupported loop source #{source['$Type']}"
          end
        end

        def execute_while_loop(source, nested, outgoing, variables, label:)
          10_000.times do
            return unless @expression.evaluate(source['WhileExpression'], variables)

            result = execute_collection(nested, outgoing, variables, label: "#{label} loop")
            return if result&.first == :break
          end
          raise NativeRuntimeError, "#{label} loop exceeded 10000 iterations"
        end

        def execute_iterable_loop(source, nested, outgoing, variables, label:)
          values = Array(variables.fetch(source['ListVariableName'].to_s))
          values.each do |value|
            variables[source['VariableName'].to_s] = value
            result = execute_collection(nested, outgoing, variables, label: "#{label} loop")
            break if result&.first == :break
          end
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
          @flow_case_cache[edge] ||= begin
            values = items(edge['CaseValues'])
            value = values.first || edge['NewCaseValue'] || {}
            value['$Type'] == 'Microflows$NoCase' ? '' : value['Value'].to_s
          end
        end

        def execute_action(action, variables)
          raise NativeRuntimeError, 'action activity has no action' unless action.is_a?(Hash)

          handler = action['$Type'].to_s.delete_prefix('Microflows$').delete_suffix('Action')
          method = "action_#{underscore(handler)}"
          raise NativeRuntimeError, "unsupported activity #{action['$Type']}" unless respond_to?(method, true)

          send(method, action, variables)
        end

        def action_create_change(action, variables)
          entity = action['Entity'].to_s
          authorize_entity!(entity, :create)
          object = store.create(entity, events: action_events(action))
          apply_changes(object, action['Items'], variables)
          variables[action['VariableName'].to_s] = object
          commit_for_action(action, object)
        end

        def action_change(action, variables)
          object = variables.fetch(action['ChangeVariableName'].to_s)
          authorize_entity!(object.entity, :write, record: object)
          apply_changes(object, action['Items'], variables)
          commit_for_action(action, object)
        end
        alias action_create_object action_create_change
        alias action_change_object action_change

        def action_create_variable(action, variables)
          variables[action['VariableName'].to_s] = @expression.evaluate(action['InitialValue'], variables)
        end

        def action_change_variable(action, variables)
          variables[action['ChangeVariableName'].to_s] = @expression.evaluate(action['Value'], variables)
        end

        def action_retrieve(action, variables)
          source = action['RetrieveSource'] || {}
          if source['$Type'] == 'Microflows$AssociationRetrieveSource'
            return action_association_retrieve(action, source, variables)
          end
          unless source['$Type'] == 'Microflows$DatabaseRetrieveSource'
            raise NativeRuntimeError, "unsupported retrieve source #{source['$Type']}"
          end

          entity = source['Entity'].to_s
          values = filter_by_xpath(store.retrieve(entity), source['XpathConstraint'].to_s, variables)
          values = @policy.filter_readable(entity, values, context: @security_context) if enforce_entity_access?
          values = sort_values(values, items(source.dig('NewSortings', 'Sortings')))
          range = source['Range'] || {}
          limit = @expression.evaluate(range['LimitExpression'], variables)
          values = values.first(limit) if limit.is_a?(Integer) && limit.positive?
          variables[action['ResultVariableName'].to_s] = range['SingleObject'] == true ? values.first : values
        end

        def action_association_retrieve(action, source, variables)
          variable = source['StartVariableName'].to_s
          association = source['AssociationId'].to_s.split('.').last
          if variable.empty? || association.empty?
            raise NativeRuntimeError, "unsupported retrieve source #{source['$Type']}"
          end

          start = variables.fetch(variable)
          values = store.retrieve_association(association, start)
          if enforce_entity_access?
            values = Array(values).select do |value|
              @policy.entity_allowed?(value.entity, action: :read, context: @security_context, record: value)
            end
          end
          definition = @associations[source['AssociationId'].to_s]
          values = values.first if definition&.fetch(:type) == :Reference && definition[:from] == start.entity
          variables[action['ResultVariableName'].to_s] = values
        end

        # Narrows a value set by a Mendix XPath constraint. Only attribute
        # predicates (comparisons, and/or, boolean shorthand) are understood;
        # anything else is rejected by the expression evaluator rather than
        # silently ignored.
        def filter_by_xpath(values, xpath, variables)
          predicate = xpath_predicate(xpath)
          return values if predicate.empty?

          values.select { @expression.evaluate(predicate, variables, node: _1) }
        end

        def xpath_predicate(xpath)
          text = xpath.strip
          return '' if text.empty?

          groups = text.scan(/\[([^\[\]]*)\]/).flatten.map(&:strip).reject(&:empty?)
          unless groups.any? && text.gsub(/\[[^\[\]]*\]/, '').strip.empty?
            raise NativeRuntimeError, "unsupported native XPath constraint: #{xpath.inspect}"
          end

          groups.map { "(#{_1})" }.join(' and ')
        end

        def sort_values(values, sortings)
          return values if sortings.empty?

          keys = sortings.map { [sort_attribute(_1), descending?(_1)] }
          values.sort { |left, right| compare_by_keys(left, right, keys) }
        end

        def compare_by_keys(left, right, keys)
          keys.each do |attribute, descending|
            comparison = compare_members(left.members[attribute], right.members[attribute])
            comparison = -comparison if descending
            return comparison unless comparison.zero?
          end
          0
        end

        def compare_members(left, right)
          return 0 if left.nil? && right.nil?
          return 1 if left.nil?
          return -1 if right.nil?

          (left <=> right) || raise(NativeRuntimeError, "cannot sort #{left.inspect} and #{right.inspect}")
        end

        def sort_attribute(sorting)
          path = (sorting['AttributePath'] || sorting.dig('AttributeRef', 'Attribute')).to_s
          raise NativeRuntimeError, 'native retrieve sorting requires an attribute' if path.empty?

          path.split(%r{[./]}).last
        end

        def descending?(sorting)
          sorting['SortOrder'].to_s.casecmp?('Descending')
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

        def action_commit(action, variables)
          variable = action['CommitVariableName'].to_s
          return if variable.empty?

          value = variables.fetch(variable)
          Array(value).each { authorize_entity!(_1.entity, :write, record: _1) } if enforce_entity_access?
          store.commit(value, events: action.fetch('WithEvents', true) != false) if store.respond_to?(:commit)
        end
        alias action_commit_objects action_commit

        def commit_for_action(action, value)
          setting = action['Commit'].is_a?(Hash) ? action['Commit']['Value'] : action['Commit']
          return if setting.to_s.empty? || setting.to_s.casecmp?('No')

          store.commit(value, events: !setting.to_s.match?(/WithoutEvents/i))
        end

        def action_events(action)
          setting = action['Commit'].is_a?(Hash) ? action['Commit']['Value'] : action['Commit']
          !setting.to_s.match?(/WithoutEvents/i)
        end

        def action_create_list(action, variables)
          variables[action['VariableName'].to_s] = []
        end

        def action_change_list(action, variables)
          list = variables.fetch(action['ChangeVariableName'].to_s)
          value = @expression.evaluate(action['Value'], variables)
          case action['Type'].to_s.downcase
          when 'add' then list << value unless list.include?(value)
          when 'remove' then list.delete(value)
          when 'clear' then list.clear
          else raise NativeRuntimeError, "unsupported list change #{action['Type']}"
          end
        end

        def action_delete(action, variables)
          value = variables.fetch(action['DeleteVariableName'].to_s)
          Array(value).each { authorize_entity!(_1.entity, :delete, record: _1) } if enforce_entity_access?
          store.delete(
            value,
            events: action.fetch('WithEvents', true) != false
          )
        end

        def action_log_message(action, variables)
          @log << render_template(action['MessageTemplate'], variables)
        end

        def action_cast(_action, _variables); end

        def action_rollback(action, variables)
          value = variables.fetch(action['RollbackVariableName'].to_s)
          store.rollback(value) if store.respond_to?(:rollback)
        end

        def action_show_message(action, variables)
          template = action['Template'] || {}
          @effects << {
            type: 'show_message', level: action['Type'].to_s.downcase,
            blocking: action['Blocking'] == true,
            message: render_text_template(template, variables)
          }
        end

        def action_validation_feedback(action, variables)
          object = variables.fetch(action['ValidationVariableName'].to_s)
          member = (action['Attribute'].to_s.empty? ? action['Association'] : action['Attribute']).to_s
          @effects << {
            type: 'validation_feedback', object_id: object.id,
            member: member.split(%r{[./]}).last,
            message: render_text_template(action['FeedbackTemplate'] || {}, variables)
          }
        end

        def action_list_operations(action, variables)
          operation = action['NewOperation'] || {}
          list = Array(variables.fetch(operation['ListName'].to_s))
          second = variables[operation['SecondListOrObjectName'].to_s]
          result = list_operation(operation['$Type'], list, second, operation['Expression'], variables)
          variables[action['ResultVariableName'].to_s] = result
        end

        def action_java_action_call(action, variables)
          name = action['JavaAction'].to_s
          adapter = @java_custom_actions[name]
          unless adapter
            raise NativeRuntimeError,
                  "Java Custom Action #{name.empty? ? '(missing name)' : name} is not registered; " \
                  'register an explicit Ruby adapter with ' \
                  'Mxrb::RubyApp::Registry.register_java_custom_action'
          end

          result = adapter.call(java_action_arguments(name, action, variables).freeze)
          result_name = (action['ResultVariableName'] || action['OutputVariableName']).to_s
          use_return = action.key?('UseReturnVariable') ? action['UseReturnVariable'] == true : !result_name.empty?
          variables[result_name] = result if use_return && !result_name.empty?
          result
        end
        alias action_java_action action_java_action_call
        alias action_basic_java action_java_action_call
        alias action_basic_code action_java_action_call
        alias action_entity_type_java action_java_action_call
        alias action_microflow_java action_java_action_call

        def java_action_arguments(name, action, variables)
          parameter_names = java_action_parameter_names(name)
          items(action['ParameterMappings']).to_h do |mapping|
            reference = identifier(mapping['Parameter'])
            parameter_name = parameter_names.fetch(reference, reference.to_s.split('.').last)
            if parameter_name.to_s.empty?
              raise NativeRuntimeError, "Java Custom Action #{name} has an unnamed parameter mapping"
            end

            [parameter_name, java_action_argument(name, parameter_name, mapping['Value'], variables)]
          end
        end

        def java_action_argument(action_name, parameter_name, value, variables)
          value ||= {}
          type = value['$Type'].to_s.delete_prefix('Microflows$')
          case type
          when 'BasicJavaActionParameterValue', 'BasicCodeActionParameterValue'
            @expression.evaluate(value['Argument'], variables)
          when 'EntityTypeJavaActionParameterValue'
            value['Entity'].to_s
          when 'MicroflowJavaActionParameterValue'
            value['Microflow'].to_s
          when 'ImportMappingJavaActionParameterValue'
            value['ImportMapping'].to_s
          when 'ExportMappingJavaActionParameterValue'
            value['ExportMapping'].to_s
          else
            raise NativeRuntimeError,
                  "Java Custom Action #{action_name} parameter #{parameter_name} " \
                  "uses unsupported mapping #{value['$Type'].inspect}"
          end
        end

        def java_action_parameter_names(name)
          @java_action_parameter_names[name] ||= begin
            artifact = @project.find_artifact(name, kind: :java_action)
            document = artifact && @project.parse_bson(@project.raw_unit(artifact.unit_id))
            items(document&.[]('Parameters')).to_h do |parameter|
              [identifier(parameter['$ID']), parameter['Name'].to_s]
            end
          end
        end

        def action_java_script_action_call(action, variables)
          client_action(:javascript, action['JavaScriptAction'], action, variables,
                        result_name: action['OutputVariableName'])
        end

        def action_nanoflow_call(action, variables)
          call = action['NanoflowCall'] || {}
          client_action(:nanoflow, call['Nanoflow'], call, variables,
                        result_name: action['OutputVariableName'])
        end

        def action_app_service_call(action, variables)
          invoke_adapter(:app_service, action['AppServiceAction'], action, variables,
                         result_name: action['ResultVariableName'])
        end

        def action_call_web_service(action, variables)
          invoke_adapter(
            :web_service, action['WebServiceCall'] || action['Operation'], action, variables,
            result_name: action['ResultVariableName']
          )
        end

        def action_import_xml(action, variables)
          invoke_adapter(
            :import_xml, action['ImportMapping'], action, variables,
            result_name: action['ResultVariableName']
          )
        end

        def action_generate_document(action, variables)
          invoke_adapter(
            :document, action['DocumentTemplate'], action, variables,
            result_name: action['ResultVariableName']
          )
        end

        def action_download_file(action, variables)
          @effects << {
            type: :download_file,
            value: variables[action['FileDocumentVariableName'].to_s],
            show_in_browser: action['ShowFileInBrowser'] == true
          }
        end

        def action_show_home_page(_action, _variables)
          @effects << { type: :show_home_page }
        end

        def action_empty(_action, _variables); end

        def action_import_mapping_java(action, variables)
          invoke_adapter(
            :import_mapping, action['ImportMapping'], action, variables,
            result_name: action['ResultVariableName']
          )
        end

        def action_export_mapping_java(action, variables)
          invoke_adapter(
            :export_mapping, action['ExportMapping'], action, variables,
            result_name: action['ResultVariableName']
          )
        end

        def action_rest_call(action, variables)
          configuration = action['HttpConfiguration'] || {}
          location = render_template(configuration['CustomLocationTemplate'], variables)
          headers = items(configuration['HttpHeaderEntries']).to_h do |entry|
            [entry['Key'].to_s, @expression.evaluate(entry['Value'], variables).to_s]
          rescue NativeRuntimeError
            [entry['Key'].to_s, entry['Value'].to_s]
          end
          request = action['RequestHandling'] || {}
          body_value = variables[request['MappingVariableName'].to_s]
          body = body_value.nil? ? nil : JSON.generate(runtime_json(body_value))
          timeout = @expression.evaluate(action['TimeOutExpression'], variables) if action['UseRequestTimeOut'] == true
          response = @http.call(configuration['HttpMethod'].to_s, location, headers, body, timeout)
          unless response.code.to_i.between?(200, 299)
            raise NativeRuntimeError, "REST call returned HTTP #{response.code}"
          end

          bind_rest_result(action['ResultHandling'] || {}, response.body.to_s, variables)
        rescue URI::InvalidURIError, JSON::ParserError => e
          raise NativeRuntimeError, "REST call failed: #{e.message}"
        end

        def action_show_form(action, variables)
          settings = action['FormSettings'] || {}
          arguments = items(settings['ParameterMappings']).to_h do |mapping|
            [mapping['Parameter'].to_s, @expression.evaluate(mapping['Argument'], variables)]
          end
          @effects << { type: 'open_page', page: settings['Form'].to_s, arguments: }
        end

        def action_close_form(_action, _variables)
          @effects << { type: 'close_page' }
        end

        def list_operation(type, list, second, expression, variables)
          operation = type.to_s.delete_prefix('Microflows$').downcase
          case operation
          when 'head' then list.first
          when 'tail' then list.drop(1)
          when 'find' then list.find { @expression.evaluate(expression, variables, node: _1) }
          when 'filter' then list.select { @expression.evaluate(expression, variables, node: _1) }
          when 'sort' then sort_values(list, items(second))
          when 'union' then (list + Array(second)).uniq
          when 'intersect' then list & Array(second)
          when 'subtract' then list - Array(second)
          when 'contains' then list.include?(second)
          else raise NativeRuntimeError, "unsupported list operation #{type}"
          end
        end

        def client_action(kind, name, document, variables, result_name:)
          return invoke_adapter(kind, name, document, variables, result_name:) if @adapters[kind]

          @effects << { type: kind.to_s, name: name.to_s }
          variables[result_name.to_s] = nil unless result_name.to_s.empty?
        end

        def invoke_adapter(kind, name, document, variables, result_name:)
          adapter = @adapters[kind] or raise NativeRuntimeError, "#{kind} adapter is not configured"
          result = adapter.call(name.to_s, document, variables)
          variables[result_name.to_s] = result unless result_name.to_s.empty?
          result
        end

        def bind_rest_result(handling, body, variables)
          return unless handling['Bind'] == true

          result = JSON.parse(body)
          entity = handling.dig('VariableType', 'Entity').to_s
          result = rest_object(entity, result) unless entity.empty?
          variables[handling['ResultVariableName'].to_s] = result
        end

        def rest_object(entity, value)
          authorize_entity!(entity, :create)
          object = store.create(entity)
          value.to_h.each do |key, child|
            authorize_entity!(entity, :write, member: key, record: object)
            object.members[key.to_s] = child
          end
          object
        end

        def runtime_json(value)
          case value
          when ObjectValue then value.members.transform_values { runtime_json(_1) }
          when Hash then value.transform_values { runtime_json(_1) }
          when Array then value.map { runtime_json(_1) }
          else value
          end
        end

        def http_request(method, location, headers, body, timeout)
          uri = URI.parse(location)
          request_class = Net::HTTP.const_get(method.to_s.downcase.capitalize)
          request = request_class.new(uri)
          headers.each { request[_1] = _2 }
          request.body = body if body
          Net::HTTP.start(
            uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                open_timeout: timeout || 10,
                                read_timeout: timeout || 30
          ) { _1.request(request) }
        end

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
            authorize_entity!(object.entity, :write, member: name, record: object)
            object.members[name] = @expression.evaluate(item['Value'], variables)
          end
        end

        def enforce_entity_access? = @apply_entity_access && @policy && @security_context

        def authorize_entity!(entity, action, member: nil, record: nil)
          return true unless enforce_entity_access?

          @policy.authorize!(
            entity, kind: :entity, action:, context: @security_context, member:, record:
          )
        end

        def render_template(template, variables)
          text = template&.dig('Text').to_s
          items(template&.dig('Parameters')).each_with_index do |parameter, index|
            text = text.gsub("{#{index + 1}}", @expression.evaluate(parameter['Expression'], variables).to_s)
          end
          text
        end

        def render_text_template(template, variables)
          text_doc = template&.dig('Text')
          text = if text_doc.is_a?(Hash)
                   translation = items(text_doc['Items']).find { _1['LanguageCode'] == 'en_US' } ||
                                 items(text_doc['Items']).first
                   translation&.fetch('Text', '').to_s
                 else
                   text_doc.to_s
                 end
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
          return value if value.is_a?(String)

          @identifier_cache[value] ||= IO::BsonCodec.extract_id(
            value.is_a?(Hash) ? value['$ID'] : value
          ).to_s
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
            actual_count = interpreter.count(expectation.entity, expectation.xpath)
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
      # rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength, Metrics/CyclomaticComplexity
      # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
      # rubocop:enable Metrics/ParameterLists
    end
  end
end
