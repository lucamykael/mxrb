# frozen_string_literal: true

require 'securerandom'
require 'strscan'
require 'base64'
require 'json'
require 'monitor'
require 'net/http'
require 'openssl'
require 'uri'
require_relative 'string_functions'
require_relative 'calendar_functions'
require_relative 'calendar_ranges'
require_relative 'date_parsing'
require_relative 'decimal_values'
require_relative 'sort_order'
require_relative 'date_formatting'
require_relative 'expression_functions'

require_relative 'system_domain'
require_relative 'languages'
require_relative 'time_zones'
require_relative 'lifecycle'
require_relative 'constants'
require_relative 'enumerations'
require_relative 'import_mapping'
require_relative 'sort_path'
require_relative 'decimal_parsing'
require_relative 'java_action_context'
require_relative 'java_sidecar'
require_relative 'java_http_exchange'

module Mxrb
  module Runtime
    # The pure-Ruby Runtime that interprets microflows straight from the model.
    module Native
      # Graph interpretation intentionally keeps semantic dispatch together.
      # rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength, Metrics/CyclomaticComplexity
      # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
      # rubocop:disable Metrics/ParameterLists
      ObjectValue = Data.define(:entity, :id, :members)

      # Explicit opt-in for adapters that need the current application's store.
      StoreJavaAction = Data.define(:handler) do
        def bind(store) = ->(arguments) { handler.call(arguments, store:) }
      end

      # The value each attribute of each entity starts with, as the model declares it.
      def self.attribute_defaults(project)
        project.modules.flat_map do |mod|
          mod.entities.map do |entity|
            ["#{mod.name}.#{entity.name}", entity.attributes.to_h { [_1.name, attribute_default(_1)] }]
          end
        end.to_h
      end

      def self.attribute_default(attribute)
        value = attribute.default_value.to_s
        case attribute.type
        when :boolean then value.casecmp?('true')
        when :integer, :long, :autonumber then value.empty? ? nil : Integer(value)
        when :decimal then value.empty? ? nil : DecimalValues.parse(value)
        else value.empty? ? nil : value
        end
      end

      # What the Mendix 11.12.1 Runtime reports of its System module: entities,
      # their attributes and supers, associations and microflows.
      # Explicit opt-in for adapters that act on the calling microflow's runtime:
      # its store, log, transaction and other flows, through a JavaActionContext.
      ContextJavaAction = Data.define(:handler)

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

        def retrieve_reverse_association(association, start)
          member = association.to_s.split('.').last
          retrieve(start.entity).select do |object|
            Array(object.members[association] || object.members[member]).any? do |target|
              target.is_a?(ObjectValue) && target.entity == start.entity && target.id == start.id
            end
          end
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
          (@transaction_states ||= []).push(snapshot)
          result = yield
          discard_uncommitted
          result
        rescue StandardError
          state = @transaction_states.last
          state == :autocommit ? discard_uncommitted : restore(state)
          raise
        ensure
          @transaction_states.pop
        end

        # A savepoint for custom error handling; a rollback of the whole transaction
        # invalidates the savepoints taken before it.
        def savepoint = { state: snapshot, generation: @savepoint_generation.to_i }
        def release_savepoint(_token) = nil

        def rollback_savepoint(token)
          restore(token.fetch(:state)) if token.fetch(:generation) == @savepoint_generation.to_i
        end

        # Custom error handling: the running transaction rolls back and the error flow
        # continues in a new one.
        def restart_transaction
          state = @transaction_states.to_a.last
          return if state.nil? || state == :autocommit

          restore(state)
          @savepoint_generation = @savepoint_generation.to_i + 1
        end

        # IContext.endTransaction: the work committed so far stays, and so does what
        # is committed afterwards, as in the Runtime's autocommit after the end.
        def end_transaction
          return false if @transaction_states.to_a.empty? || @transaction_states.last == :autocommit

          @transaction_states[-1] = :autocommit
          true
        end

        def commit(value, events: true)
          Array(value).each do |object|
            creating = !@committed.key?(record_key(object))
            run_hooks(creating ? :before_create : :before_update, object) if events
            run_hooks(:before_commit, object) if events
            @committed[record_key(object)] = object.members.dup
            @touched&.delete(record_key(object))
            run_hooks(:after_commit, object) if events
            run_hooks(creating ? :after_create : :after_update, object) if events
          end
          value
        end

        # Marks members set by a change, which IMendixObject.isChanged reports
        # until the next commit even when the value is set back.
        def touch(object) = (@touched ||= {})[record_key(object)] = true

        # IMendixObject.isChanged: set since the last commit, or members that differ
        # from the last commit (the defaults for an object never committed).
        def changed?(object)
          return true if @touched&.key?(record_key(object))

          baseline = @committed.fetch(record_key(object)) { @defaults.fetch(object.entity, {}) }
          object.members.compact != baseline.compact
        end

        # The members an object had at its last commit, or nil for one never committed.
        def original(object) = @committed[record_key(object)]&.dup

        def rollback(value)
          Array(value).each do |object|
            @touched&.delete(record_key(object))
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
        include StringFunctions

        # The value of a member that is not calculated, which calculated: answers then.
        STORED = Object.new.freeze

        # associations: ->(object, association) { related objects } reaches the
        # side of a reference that the object does not own; constants: ->(name) { value };
        # calculated: ->(object, member) { value or STORED } computes calculated attributes;
        # enumerations, a Runtime::Enumerations, gives enumeration literals their key.
        def initialize(time_zone: 'UTC', decimal: DecimalContext.new, associations: nil, constants: nil,
                       calculated: nil, enumerations: nil)
          @token_cache = {}
          @enumerations = enumerations
          @associations = associations
          @calculated = calculated
          @constants = constants
          @decimal = decimal
          @calendar = CalendarFunctions.new(time_zone:)
          @ranges = CalendarRanges.new(@calendar)
        end

        def evaluate(source, variables, node: nil)
          text = unwrap(source).strip
          return nil if text.empty?

          tokens = (@token_cache[text] ||= Lexer.new(text).tokens.freeze)
          Parser.new(tokens, self, variables, node).parse
        rescue ArgumentError, TypeError, KeyError, EncodingError
          raise NativeRuntimeError, "unsupported Mendix expression: #{source.inspect}"
        end

        def constant(name)
          raise NativeRuntimeError, "constant @#{name} is not available here" unless @constants

          @constants.call(name)
        end

        # $Variable/Attribute or a path of references, $Order/M.Order_Customer/M.Customer/Name,
        # which is empty once a reference on the way is empty.
        def resolve_variable(text, variables)
          name, path = text.delete_prefix('$').split('/', 2)
          value = variables.fetch(name) do
            raise NativeRuntimeError, "unknown variable $#{name}"
          end
          return value unless path

          return nil if value.nil?
          raise NativeRuntimeError, "$#{name} is not an object" unless value.is_a?(ObjectValue)

          follow_path(value, path.split('/'))
        end

        def follow_path(object, segments)
          member, entity, *rest = segments
          return member_value(object, member) unless entity

          target = reference(object, member)
          rest.empty? || target.nil? ? target : follow_path(target, rest)
        end

        def member_value(object, member)
          name = member.split('.').last
          if @calculated
            value = @calculated.call(object, name)
            return value unless value.equal?(STORED)
          end
          if object.members.key?(name) || !member.include?('.')
            value = object.members[name]
            return @enumerations ? @enumerations.attribute_value(object.entity, name, value) : value
          end

          related(object, member)
        end

        def reference(object, association)
          name = association.split('.').last
          value = object.members.key?(name) ? object.members[name] : related(object, association)
          raise NativeRuntimeError, "an expression cannot follow the reference set #{association}" if value.is_a?(Array)

          value
        end

        # The other side of a reference: one object, or the list when there are several.
        def related(object, association)
          values = Array(@associations&.call(object, association))
          values.length > 1 ? values : values.first
        end

        def resolve_identifier(text, node)
          return true if text.casecmp?('true')
          return false if text.casecmp?('false')
          return nil if text.casecmp?('empty')

          if node && bare_reference?(text)
            member = text.split('/').last.split('.').last
            return node.members[member] if node.members.key?(member)
          end
          return @enumerations&.literal(text) || text if text.match?(/\A[A-Za-z_]\w*\.[A-Za-z_]\w*\.[A-Za-z_]\w*\z/)
          return node_member(text, node) if node && bare_reference?(text)

          raise ArgumentError, text
        end

        # Mendix measures text in UTF-16 code units; a list's length is its size.
        def text_or_list_length(value)
          value.is_a?(Array) ? value.length : value.to_s.encode('UTF-16LE').bytesize / 2
        end

        def invoke(name, arguments)
          return @calendar.invoke(name.downcase, arguments) if @calendar.supported?(name.downcase)
          return @ranges.invoke(name.downcase, arguments) if @ranges.supported?(name.downcase)

          case name.downcase
          when 'parsedatetimeutc' then DateParsing.invoke(arguments)
          when 'parsedatetime' then DateParsing.invoke(arguments, zone: @calendar.zone(false).identifier)
          when 'length' then text_or_list_length(arguments.fetch(0))
          when 'trim' then arguments.fetch(0).to_s.gsub(/\A[\x00-\x20]+|[\x00-\x20]+\z/, '')
          when 'tolowercase' then arguments.fetch(0).to_s.downcase
          when 'touppercase' then arguments.fetch(0).to_s.upcase
          when 'urlencode' then URI::RFC2396_PARSER.escape(arguments.fetch(0).to_s, /[^A-Za-z0-9\-._~]/)
          when 'urldecode' then URI.decode_www_form_component(arguments.fetch(0).to_s)
          when 'tostring' then mendix_string(arguments.fetch(0))
          when 'parsedecimal' then parse_decimal(arguments)
          when 'round' then @decimal.round(*arguments)
          when 'floor' then DecimalValues.parse(arguments.fetch(0)).floor
          when 'ceil' then DecimalValues.parse(arguments.fetch(0)).ceil
          when 'abs' then arguments.fetch(0).abs
          when 'random' then BigDecimal(Random.rand.to_s)
          when 'substring' then substring(*arguments)
          when 'find' then string_find(*arguments)
          when 'findlast' then string_find_last(*arguments)
          when *DATE_FORMATS then format_date(name.downcase, arguments)
          when *ExpressionFunctions::NAMES then ExpressionFunctions.invoke(name.downcase, arguments, @decimal)
          when 'getcaption', 'getkey' then enumeration_text(name.downcase, arguments)
          when 'contains' then arguments.fetch(0).to_s.include?(arguments.fetch(1).to_s)
          when 'startswith' then arguments.fetch(0).to_s.start_with?(arguments.fetch(1).to_s)
          when 'endswith' then arguments.fetch(0).to_s.end_with?(arguments.fetch(1).to_s)
          else raise ArgumentError, name
          end
        end

        def enumeration_text(function, arguments)
          raise ArgumentError, "#{function} takes one enumeration value" unless arguments.length == 1
          raise ArgumentError, function unless @enumerations

          @enumerations.text(function, arguments.first)
        end

        # [%BeginOfCurrentDay%] and the other boundary tokens, in the session time zone.
        def date_token(source)
          XPathDates.new(SecurityContext.new(attributes: { 'time_zone' => @calendar.zone(false).identifier }))
                    .resolve(source)
        end

        DATE_FORMATS = %w[formatdatetime formatdatetimeutc formatdate formatdateutc formattime formattimeutc].freeze

        def divide(left, right) = @decimal.divide(left, right)

        def format_date(name, arguments)
          raise ArgumentError, "#{name} requires a date" if arguments.empty?

          zone = @calendar.zone(name.end_with?('utc'))
          time = zone.to_local(@calendar.instant(arguments[0]))
          DateFormatting.invoke(name, time, arguments.drop(1), zone.identifier)
        end

        private

        # parseDecimal(text), parseDecimal(text, default), parseDecimal(text, pattern)
        # and parseDecimal(text, pattern, default).
        def parse_decimal(arguments)
          raise ArgumentError, 'parseDecimal requires one to three arguments' unless (1..3).cover?(arguments.size)

          text, *rest = arguments
          pattern = rest.first.is_a?(String) ? rest.shift : nil
          if rest.size > 1 || (rest.any? && !rest[0].nil? && !rest[0].is_a?(Numeric))
            raise ArgumentError, 'unsupported decimal format'
          end

          parsed = pattern ? DecimalParsing.parse(text, pattern) : plain_decimal(text, fallback: !rest.empty?)
          return parsed if parsed
          raise ArgumentError, "cannot parse #{text.inspect} with #{pattern.inspect}" if rest.empty?

          rest[0].nil? ? nil : DecimalValues.parse(rest[0])
        end

        def plain_decimal(text, fallback:)
          DecimalValues.parse(text)
        rescue ArgumentError
          raise unless fallback
        end

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

          return format_date('formatdatetime', [value]) if value.is_a?(Time) || value.is_a?(DateTime)

          value.is_a?(BigDecimal) ? DecimalValues.text(value) : value.to_s
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

            evaluate(value)
          end

          private

          def parse_or
            left = parse_and
            while accept_word('or')
              right = parse_and
              left = [:binary, 'or', left, right]
            end
            left
          end

          def parse_and
            left = parse_comparison
            while accept_word('and')
              right = parse_comparison
              left = [:binary, 'and', left, right]
            end
            left
          end

          def parse_comparison
            left = parse_addition
            while @token == :operator && COMPARISONS.key?(@value)
              operator = consume(:operator)
              left = [:binary, operator, left, parse_addition]
            end
            left
          end

          def parse_addition
            left = parse_multiplication
            while @token == :operator && %w[+ -].include?(@value)
              operator = consume(:operator)
              right = parse_multiplication
              left = [:binary, operator, left, right]
            end
            left
          end

          def parse_multiplication
            left = parse_unary
            while (@token == :operator && %w[* :].include?(@value)) ||
                  (@token == :identifier && %w[div mod].include?(@value.downcase))
              operator = consume(@token).downcase
              right = parse_unary
              left = [:binary, operator, left, right]
            end
            left
          end

          def parse_unary
            return [:unary, 'not', parse_unary] if accept_word('not')
            return [:unary, '-', parse_unary] if accept_operator('-')

            parse_primary
          end

          def parse_primary
            return [:literal, consume(@token)] if %i[number string].include?(@token)

            if @token == :datetime
              consume(:datetime)
              return [:datetime]
            end
            return [:date_token, consume(:date_token)] if @token == :date_token
            return [:variable, consume(:variable)] if @token == :variable
            return [:constant, consume(:constant)] if @token == :constant
            return conditional if accept_word('if')
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
            return [:identifier, name] unless accept(:left_parenthesis)

            arguments = []
            unless accept(:right_parenthesis)
              loop do
                arguments << parse_or
                break if accept(:right_parenthesis)

                consume(:comma)
              end
            end
            [:call, name, arguments]
          end

          def conditional
            condition = parse_or
            raise ArgumentError, 'expected then' unless accept_word('then')

            consequent = parse_or
            raise ArgumentError, 'expected else' unless accept_word('else')

            [:conditional, condition, consequent, parse_or]
          end

          def evaluate(tree)
            kind, value, left, right = tree
            case kind
            when :literal then value
            when :datetime then Time.now
            when :date_token then @expression.date_token(value)
            when :variable then @expression.resolve_variable(value, @variables)
            when :constant then @expression.constant(value.delete_prefix('@'))
            when :identifier then @expression.resolve_identifier(value, @node)
            when :call then @expression.invoke(value, left.map { evaluate(_1) })
            when :unary then value == 'not' ? !truthy?(evaluate(left)) : -evaluate(left)
            when :conditional then truthy?(evaluate(value)) ? evaluate(left) : evaluate(right)
            else binary(value, left, right)
            end
          end

          def binary(operator, left, right)
            return truthy?(evaluate(left)) && truthy?(evaluate(right)) if operator == 'and'
            return truthy?(evaluate(left)) || truthy?(evaluate(right)) if operator == 'or'

            first = evaluate(left)
            second = evaluate(right)
            # A list without objects is empty, as the Runtime compares it.
            first, second = [first, second].map { _1 == [] ? nil : _1 } if %w[= !=].include?(operator)
            return COMPARISONS.fetch(operator).call(first, second) if COMPARISONS.key?(operator)
            return concatenate(first, second) if operator == '+' && (first.is_a?(String) || second.is_a?(String))
            return first + second if operator == '+'
            return first - second if operator == '-'
            return first * second if operator == '*'

            raise ArgumentError, 'numeric operands required' unless first.is_a?(Numeric) && second.is_a?(Numeric)
            raise ArgumentError, 'division by zero' if second.zero?

            operator == 'mod' ? first.remainder(second) : @expression.divide(first, second)
          end

          # Mendix joins text with numbers as toString shows them and an empty value as
          # no text (MxBuild already rejects the literal empty); nothing else joins.
          def concatenate(first, second)
            unless [first, second].all? { _1.nil? || _1.is_a?(String) || _1.is_a?(Numeric) }
              raise ArgumentError, 'text can only be joined with text or numbers'
            end

            [first, second].map { _1.is_a?(String) || _1.nil? ? _1.to_s : @expression.invoke('toString', [_1]) }.join
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
            raise ArgumentError, 'boolean operand required' unless [true, false].include?(value)

            value
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
            return [:date_token, @scanner.matched] if @scanner.scan(/\[%(?:Begin|End)Of[A-Za-z]+%\]/)
            return [:string, scan_string] if @scanner.peek(1) == "'"
            return [:number, number(@scanner.scan(/\d+(?:\.\d+)?/))] if @scanner.check(/\d/)
            return [:variable, @scanner.scan(%r{\$[A-Za-z_]\w*(?:/[A-Za-z_][\w.]*)*})] if @scanner.check(/\$/)
            return [:constant, @scanner.scan(/@[A-Za-z_]\w*\.[A-Za-z_]\w*/)] if @scanner.check(/@[A-Za-z_]/)
            return [:identifier, @scanner.scan(/[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*/)] if @scanner.check(/[A-Za-z_]/)
            return [:operator, @scanner.scan(%r{!=|>=|<=|=|>|<|\+|-|\*|:|/})] if @scanner.check(%r{[!><=+*:/-]})

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
            value.include?('.') ? DecimalValues.parse(value) : Integer(value)
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
        attr_reader :store, :log, :effects, :java_sidecar

        def initialize(project, store: nil, adapters: {}, java_custom_actions: {}, http: nil, policy: nil,
                       service_dispatch: nil, constants: nil, java_sidecar: nil)
          @project = project
          @java_sidecar = java_sidecar
          @decimal = DecimalContext.new(**DecimalContext.settings(project).transform_keys(&:to_sym))
          @constants = constants ||= Constants.new(project)
          enumerations = Enumerations.new(project)
          @expression = Expression.new(decimal: @decimal, associations: lambda { |object, association|
            @store.retrieve_association(association, object)
          }, constants: ->(name) { constants.value(name) }, time_zone: lambda {
            attributes = @security_context.respond_to?(:attributes) ? @security_context.attributes : {}
            attributes.fetch('time_zone', 'UTC')
          }, calculated: ->(object, member) { calculated_value(object, member) }, enumerations:)
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
          @service_dispatch = service_dispatch
          @security_context = nil
          @apply_entity_access = false
          @flows = project.modules.flat_map do |mod|
            (mod.microflows + mod.nanoflows + (mod.respond_to?(:rules) ? mod.rules : [])).map do
              ["#{mod.name}.#{_1.name}", _1]
            end
          end.to_h
          entity_names = project.modules.flat_map do |mod|
            mod.entities.map { [_1.id.to_s, "#{mod.name}.#{_1.name}"] }
          end.to_h
          defaults = Native.attribute_defaults(project)
          transient_entities = project.modules.flat_map do |mod|
            mod.entities.select { _1.persistable == false }.map { "#{mod.name}.#{_1.name}" }
          end
          @store = store || Store.new(defaults:, transient_entities:)
          @java_custom_actions = @java_custom_actions.transform_values do |adapter|
            adapter.is_a?(StoreJavaAction) ? adapter.bind(@store) : adapter
          end.freeze
          register_model_lifecycle
          @associations = project.modules.flat_map do |mod|
            mod.associations.map do |association|
              ["#{mod.name}.#{association.name}", {
                type: association.association_type,
                from: entity_names[association.from_entity_id.to_s],
                owner: association.owner.to_s
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

        # The URL the application is reached at, as Core.getConfiguration reports it.
        def application_root_url = java_action_context.application_root_url

        # Counts stored objects of an entity, optionally narrowed by an XPath
        # constraint. Used by the functional Executor's count expectations.
        def count(entity, xpath = nil)
          filter_by_xpath(store.retrieve(entity.to_s), xpath.to_s, {}).size
        end

        # A retrieve a Java action makes through Core: an XPath constraint with
        # variables, sortings as [path, descending], an offset and an amount (0 or less: all).
        def retrieve_xpath(entity, xpath, variables = {}, offset: 0, amount: -1, sort: [])
          values = readable(entity.to_s, filter_by_xpath(store.retrieve(entity.to_s), xpath.to_s, variables))
          keys = sort.map { |path, descending| [SortPath.parse(path), descending] }
          read = SortPath.reader { @store }
          values = SortOrder.sort(values, keys) { |value, path| read.call(value, path) }.drop(offset)
          amount.positive? ? values.first(amount) : values
        end

        # An HTTP request to a path a Java action registered with Core.addRequestHandler,
        # handled by the sidecar in a transaction of its own, as the given session.
        def java_request(handler, request, context: nil)
          raise NativeRuntimeError, 'request handlers need the Java actions sidecar' unless @java_sidecar

          (@call_monitor ||= Monitor.new).synchronize do
            java_root(context) do |java|
              session = java.session
              session = nil unless session['id']
              request = request.merge('root_url' => request['root_url'] || java.application_root_url)
              @java_sidecar.request(handler, request, session:, context: java)
            end
          end
        end

        # Runs a published REST operation for an HTTP request, which its Java actions
        # see through IContext.getRuntimeRequest (a JavaSidecar::HttpExchange).
        def with_http_exchange(exchange)
          previous = @http_exchange
          @http_exchange = exchange
          yield
        ensure
          @http_exchange = previous
        end

        # A callback of work a Java action left running, in a transaction of its own
        # with a system context.
        def java_attach(ticket)
          raise NativeRuntimeError, 'background work needs the Java actions sidecar' unless @java_sidecar

          (@call_monitor ||= Monitor.new).synchronize do
            java_root(nil) { |java| @java_sidecar.attach(ticket, context: java) }
          end
        end

        # The calculated attributes of an object as the client gets them, computed
        # for the user the object is sent to; the effects of the request so far are kept.
        def calculated_members(object, context: nil)
          names = calculated_attributes.fetch(object.entity, {}).keys
          return {} if names.empty?

          previous = @effects
          names.to_h { [_1, calculated_value(object, _1, context:)] }
        ensure
          @effects = previous + @effects if previous && !previous.equal?(@effects)
        end

        # A calculated attribute, computed by its microflow each time an expression
        # reads it, as Mendix 11.12.1 does: not when the object is created, changed,
        # committed or retrieved. The microflow gets the object unless pass_entity is false.
        def calculated_value(object, member, context: nil)
          microflow, pass_entity = calculated_attributes.dig(object.entity, member)
          return Expression::STORED unless microflow

          flow = @flows.fetch(microflow) do
            raise NativeRuntimeError, "calculated attribute #{object.entity}.#{member} needs microflow #{microflow}"
          end
          call(microflow, pass_entity ? { flow.parameters.first.fetch('Name') => object } : {}, context:)
        end

        # IContext.endTransaction, as measured on Mendix 11.12.1: it commits the
        # innermost transaction unless a savepoint of a sub-microflow called with
        # custom error handling is open above it; afterwards commits are immediate.
        def end_transaction
          return false unless @scopes&.last == :transaction && store.respond_to?(:end_transaction)
          return false unless store.end_transaction == true

          @scopes[-1] = :ended
          true
        end

        private

        # Each entity's calculated attributes, its generalizations' included, as
        # name => [microflow, pass_entity].
        def calculated_attributes
          @calculated_attributes ||= begin
            entities = @project.modules.flat_map { |mod| mod.entities.map { ["#{mod.name}.#{_1.name}", _1] } }.to_h
            entities.to_h do |name, entity|
              chain = []
              while entity && !chain.include?(entity)
                chain << entity
                entity = entities[entity.generalization_target.to_s]
              end
              [name, chain.flat_map(&:attributes).filter_map { calculated_attribute(_1) }.to_h]
            end
          end
        end

        def calculated_attribute(attribute)
          microflow = attribute.calculated
          [attribute.name, [microflow, attribute.pass_entity]] if microflow
        end

        def java_root(context)
          previous = @security_context
          @security_context = context
          @effects = []
          @scopes = [:transaction]
          @call_depth += 1
          java = java_action_context
          store.transaction { yield java }
        ensure
          @call_depth -= 1
          @security_context = previous
        end

        def execute_call(name, arguments = nil, context: nil, **keyword_arguments)
          arguments = keyword_arguments if arguments.nil?
          arguments = arguments.to_h.merge(keyword_arguments) unless keyword_arguments.empty?
          previous_context = @security_context
          previous_apply_entity_access = @apply_entity_access
          root_call = @call_depth.zero?
          @effects = [] if root_call
          @scopes = [:transaction] if root_call
          @call_depth += 1
          flow = @flows[name]
          raise NativeRuntimeError, "flow #{name} not found" unless flow

          @security_context = context unless context.nil?
          @apply_entity_access = flow.respond_to?(:apply_entity_access) && flow.apply_entity_access == true
          normalized = with_current_user(normalize_arguments(flow, arguments))
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

        # Custom error handling as measured on Mendix 11.12.1: a sub-microflow call runs
        # under a savepoint, or in a transaction of its own once the running one ended.
        # On an error CustomWithoutRollBack undoes that call, Custom the whole running
        # transaction, and the error flow continues (in a new transaction after Custom).
        def with_error_scope(action, error_edge)
          handling = action['ErrorHandlingType']
          return yield unless error_edge && CUSTOM_ERROR_HANDLING.include?(handling) && store.respond_to?(:savepoint)

          scope = open_scope if action['$Type'] == 'Microflows$MicroflowCallAction'
          result = yield
          close_scope(scope, :release_savepoint)
          result
        rescue StandardError
          close_scope(scope, :rollback_savepoint)
          store.restart_transaction if handling == 'Custom'
          raise
        end

        def open_scope
          @scopes ||= []
          kind = @scopes.include?(:transaction) ? :savepoint : :transaction
          @scopes.push(kind)
          store.savepoint
        end

        def close_scope(token, outcome)
          return unless token

          @scopes.pop
          store.public_send(outcome, token)
        end

        # $currentUser is the signed-in System.User (or a specialization such as an Account);
        # $latestError is empty until an error handler catches one.
        def with_current_user(arguments)
          id = @security_context.respond_to?(:user) && @security_context.user
          user = store.find(SystemDomain::USER, id) if id.is_a?(String) && store.respond_to?(:schema)
          { 'latestError' => nil }.merge(arguments, 'currentUser' => user)
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
              if type == 'Microflows$ActionActivity'
                with_error_scope(current['Action'], error_edge) { execute_action(current['Action'], variables) }
              end
              execute_loop(current, outgoing, variables, label:) if type == 'Microflows$LoopedActivity'
              edge = select_edge(current, edges.reject { _1['IsErrorHandler'] == true }, variables)
            rescue StandardError => e
              edge = error_edge
              raise unless edge

              if action_snapshot && current.dig('Action', 'ErrorHandlingType') == 'Rollback'
                store.restore(action_snapshot)
              end
              variables['latestError'] = error_object(e)
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
          elsif object.dig('SplitCondition', '$Type') == 'Microflows$RuleSplitCondition'
            invoke_flow_call(object.dig('SplitCondition', 'RuleCall'), variables)
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
          values = readable(entity, filter_by_xpath(store.retrieve(entity), source['XpathConstraint'].to_s, variables))
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
          # A reference gives one object from its owner, and from both sides when both own it.
          owner = definition && (definition[:from] == start.entity || definition[:owner] == 'Both')
          values = values.first if owner && definition.fetch(:type) == :Reference
          variables[action['ResultVariableName'].to_s] = values
        end

        def readable(entity, values)
          enforce_entity_access? ? @policy.filter_readable(entity, values, context: @security_context) : values
        end

        def filter_by_xpath(values, xpath, variables)
          require_relative 'xpath'
          policy = enforce_entity_access? ? @policy : nil
          XPath.new(xpath, store:, policy:, context: @security_context).filter(values, variables)
        rescue ArgumentError, TypeError
          raise NativeRuntimeError, "unsupported native XPath constraint: #{xpath.inspect}"
        end

        def sort_values(values, sortings, memory: false)
          return values if sortings.empty?

          keys = sortings.map { [sort_attribute(_1), descending?(_1)] }
          read = SortPath.reader { @store }
          SortOrder.sort(values, keys, memory:) { |value, path| read.call(value, path) }
        end

        def sort_attribute(sorting)
          return SortPath.parse(sorting['AttributePath']) unless sorting['AttributePath'].to_s.empty?
          if sorting.dig('AttributeRef', 'Attribute').to_s.empty?
            raise NativeRuntimeError, 'native retrieve sorting requires an attribute'
          end

          SortPath.from_reference(sorting['AttributeRef'])
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
          result = invoke_flow_call(action['MicroflowCall'] || {}, variables)
          variables[action['ResultVariableName'].to_s] = result if action['UseReturnVariable'] == true
        end

        def invoke_flow_call(call_doc, variables)
          arguments = items(call_doc['ParameterMappings']).to_h do |mapping|
            [mapping['Parameter'].to_s.split('.').last, @expression.evaluate(mapping['Argument'], variables)]
          end
          if @service_dispatch
            @service_dispatch.call(call_doc['Microflow'].to_s, arguments, @security_context)
          else
            call(call_doc['Microflow'].to_s, arguments)
          end
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
          second = if operation['$Type'] == 'Microflows$Sort'
                     operation.dig('Sortings', 'Sortings')
                   else
                     variables[operation['SecondListOrObjectName'].to_s]
                   end
          result = if %w[Attribute Association].any? { !operation[_1].to_s.empty? }
                     member_list_operation(operation, list, variables)
                   else
                     list_operation(operation['$Type'], list, second, operation['Expression'], variables)
                   end
          variables[action['ResultVariableName'].to_s] = result
        end

        # Find and Filter by attribute or association: the objects whose member equals
        # the value of the expression.
        def member_list_operation(operation, list, variables)
          expected = @expression.evaluate(operation['Expression'], variables)
          attribute = operation['Attribute'].to_s
          matches = if attribute.empty?
                      association = operation['Association'].to_s
                      ->(object) { object_id_of(@expression.reference(object, association)) == object_id_of(expected) }
                    else
                      ->(object) { @expression.member_value(object, attribute) == expected }
                    end
          operation['$Type'] == 'Microflows$Find' ? list.find(&matches) : list.select(&matches)
        end

        def object_id_of(value) = value.is_a?(ObjectValue) ? value.id.to_s : value&.to_s

        CUSTOM_ERROR_HANDLING = %w[Custom CustomWithoutRollBack].freeze

        # Java actions the Runtime itself provides; an explicitly registered adapter still wins.
        PLATFORM_JAVA_ACTIONS = {
          'System.VerifyPassword' => lambda { |store, arguments|
            SystemDomain.verify_password(store, arguments['userName'], arguments['password'])
          }
        }.freeze

        def action_java_action_call(action, variables)
          name = action['JavaAction'].to_s
          adapter = @java_custom_actions[name]
          platform = PLATFORM_JAVA_ACTIONS[name]
          adapter ||= platform && ->(arguments) { platform.call(@store, arguments) }
          adapter ||= @java_sidecar && sidecar_action(name)
          unless adapter
            raise NativeRuntimeError,
                  "Java Custom Action #{name.empty? ? '(missing name)' : name} is not registered; " \
                  'register an explicit Ruby adapter with ' \
                  'Mxrb::RubyApp::Registry.register_java_custom_action'
          end

          arguments = java_action_arguments(name, action, variables).freeze
          result = if adapter.is_a?(ContextJavaAction)
                     adapter.handler.call(arguments, context: java_action_context)
                   else
                     adapter.call(arguments)
                   end
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

        # A project's own Java action, run by the opt-in sidecar with its
        # parameters in the order the action declares them.
        def sidecar_action(name)
          order = java_action_parameter_names(name).values
          ContextJavaAction.new(lambda { |arguments, context:|
            parameters = (order | arguments.keys).map { [_1, arguments[_1]] }
            @java_sidecar.invoke(name, parameters, context:, http: @http_exchange)
          })
        end

        def java_action_context
          JavaActionContext.new(interpreter: self, store: @store, log: @log, project: @project, flows: @flows.keys,
                                security_context: @security_context, policy: @policy, constants: @constants)
        end

        # $latestError: a System.Error object whose members describe the caught error.
        def error_object(error)
          type = error.respond_to?(:java_class) ? error.java_class : error.class.name
          ObjectValue.new(entity: 'System.Error', id: SecureRandom.uuid,
                          members: { 'ErrorType' => type, 'Message' => error.message,
                                     'Stacktrace' => Array(error.backtrace).join("\n") })
        end

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
          when 'EntityTypeCodeActionParameterValue'
            entity = value['Entity'].to_s
            if entity.empty?
              raise NativeRuntimeError,
                    "Java Custom Action #{action_name} parameter #{parameter_name} " \
                    'has an empty entity type'
            end
            entity
          when 'MicroflowJavaActionParameterValue', 'MicroflowParameterValue'
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
          return @project.java_action_parameter_names(name) if @project.respond_to?(:java_action_parameter_names)

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

        # Import with mapping: a registered adapter, else the JSON import mapping
        # applied to the text of the variable.
        def action_import_xml(action, variables)
          handling = action['ResultHandling'] || {}
          if @adapters[:import_xml]
            return invoke_adapter(:import_xml, action['ImportMapping'], action, variables,
                                  result_name: action['ResultVariableName'] || handling['ResultVariableName'])
          end

          source = variables.fetch(action['XmlDocumentVariableName'].to_s)
          import_with_mapping(handling, source.to_s, variables)
        end

        # Applies the ImportMappingCall of a result handling to JSON text and binds
        # the root object, or the list of roots, to its variable.
        def import_with_mapping(handling, content, variables)
          call = handling['ImportMappingCall'] || {}
          name = call['ReturnValueMapping'].to_s
          unless call['ContentType'].to_s.casecmp?('Json')
            raise NativeRuntimeError, "import mapping #{name} reads #{call['ContentType']}; only JSON runs natively"
          end

          mapping = ImportMapping.new(import_mapping_definition(name), store:, associations: @associations,
                                                                       converter: method(:convert_with_microflow))
          roots = mapping.import(content)
          commit_for_action(call, mapping.objects) unless mapping.objects.empty?
          return roots unless handling['Bind'] == true

          list = handling.dig('VariableType', '$Type') == 'DataTypes$ListType'
          variables[handling['ResultVariableName'].to_s] = list ? roots : roots.first
        rescue JSON::ParserError => e
          raise NativeRuntimeError, "import mapping #{name} could not read the JSON: #{e.message}"
        end

        def import_mapping_definition(name)
          (@import_mappings ||= {})[name] ||=
            if @project.respond_to?(:import_mapping)
              @project.import_mapping(name)
            else
              module_name, document = name.split('.', 2)
              mod = @project.modules.find { _1.name == module_name }
              found = mod&.infrastructure_documents&.find do
                _1[:type] == 'ImportMappings$ImportMapping' && _1[:name].to_s == document
              end
              found && ImportMapping.definition(found.fetch(:doc))
            end || raise(NativeRuntimeError, "import mapping #{name} not found")
        end

        # The value a converter microflow of an import mapping makes of a JSON value.
        def convert_with_microflow(name, value)
          flow = @flows.fetch(name) { raise NativeRuntimeError, "converter microflow #{name} not found" }
          call(name, { Array(flow.parameters).first.to_h['Name'].to_s => value })
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

        def action_export_xml(action, variables)
          output = action['OutputMethod'] || {}
          handling = action['ResultHandling'] || {}
          unless output['$Type'] == 'ExportXmlAction$StringExport' &&
                 handling['$Type'] == 'Microflows$MappingRequestHandling' &&
                 %w[Xml Json].include?(handling['ContentType']) &&
                 [true, false].include?(action['IsValidationRequired'])
            raise NativeRuntimeError, 'unsupported export XML configuration'
          end

          output_name = output['OutputVariableName'].to_s
          mapping = handling['MappingId'].to_s
          source = handling['MappingVariableName'].to_s
          if output_name.empty? || mapping.empty? || source.empty?
            raise NativeRuntimeError, 'export XML requires output, mapping, and source variables'
          end

          variables.fetch(source)
          result = invoke_adapter(
            :export_mapping, mapping, action, variables, result_name: output_name
          )
          raise NativeRuntimeError, 'string export mapping returned a non-string value' unless result.is_a?(String)

          result
        end

        def action_rest_call(action, variables)
          configuration = action['HttpConfiguration'] || {}
          location = render_template(configuration['CustomLocationTemplate'], variables)
          headers = items(configuration['HttpHeaderEntries']).to_h do |entry|
            [entry['Key'].to_s, @expression.evaluate(entry['Value'], variables).to_s]
          rescue NativeRuntimeError
            [entry['Key'].to_s, entry['Value'].to_s]
          end
          if configuration['UseHttpAuthentication'] == true
            username = @expression.evaluate(
              configuration['HttpAuthenticationUserName'].to_s, variables
            )
            password = @expression.evaluate(
              configuration['HttpAuthenticationPassword'].to_s, variables
            )
            headers['Authorization'] = "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
          end
          request = action['RequestHandling'] || {}
          body_value = variables[request['MappingVariableName'].to_s]
          body = body_value.nil? ? nil : JSON.generate(runtime_json(body_value))
          timeout = @expression.evaluate(action['TimeOutExpression'], variables) if action['UseRequestTimeOut'] == true
          transport = rest_transport_options(action, configuration, variables)
          arguments = [configuration['HttpMethod'].to_s, location, headers, body, timeout]
          response = if transport.empty?
                       @http.call(*arguments)
                     else
                       @http.call(*arguments, transport)
                     end
          unless response.code.to_i.between?(200, 299)
            raise NativeRuntimeError, "REST call returned HTTP #{response.code}"
          end

          bind_rest_result(
            action['ResultHandling'] || {}, response.body.to_s, variables,
            result_handling_type: action.fetch('ResultHandlingType', 'Mapping')
          )
        rescue URI::InvalidURIError, JSON::ParserError => e
          raise NativeRuntimeError, "REST call failed: #{e.message}"
        end

        def action_show_form(action, variables)
          settings = action['FormSettings'] || {}
          arguments = items(settings['ParameterMappings']).to_h do |mapping|
            [mapping['Parameter'].to_s, @expression.evaluate(mapping['Argument'], variables)]
          end
          count = page_close_count(action, variables, default: '0')
          @effects << { type: 'close_page', count: } if count.positive?
          effect = { type: 'open_page', page: settings['Form'].to_s, arguments: }
          title = settings['TitleOverride'] || settings['FormTitle']
          effect[:title] = render_text_template(title.key?('Items') ? { 'Text' => title } : title, variables) if title
          location = { 'Content' => 'content', 'Popup' => 'popup', 'ModalPopup' => 'modal' }[settings['Location']]
          effect[:location] = location if location
          variable = action['FormObjectVariable'].to_s
          effect[:context] = variables[variable] unless variable.empty?
          @effects << effect
        end

        def action_close_form(action, variables)
          @effects << { type: 'close_page', count: page_close_count(action, variables, default: '1') }
        end

        def page_close_count(action, variables, default:)
          expression = action['NumberOfPagesToClose'].to_s
          value = @expression.evaluate(expression.empty? ? default : expression, variables)
          unless value.is_a?(Numeric) && value >= 0 && value == value.to_i
            raise NativeRuntimeError, 'Number of pages to close must be a non-negative integer'
          end

          value.to_i
        end

        def list_operation(type, list, second, expression, variables)
          operation = type.to_s.delete_prefix('Microflows$').downcase
          case operation
          when 'head' then list.first
          when 'tail' then list.drop(1)
          when 'find' then list.find { @expression.evaluate(expression, variables, node: _1) }
          when 'filter' then list.select { @expression.evaluate(expression, variables, node: _1) }
          when 'findbyexpression' then list.find { current_object?(expression, variables, _1) }
          when 'filterbyexpression' then list.select { current_object?(expression, variables, _1) }
          when 'sort' then sort_values(list, items(second), memory: true)
          when 'union' then (list + Array(second)).uniq
          when 'intersect' then list & Array(second)
          when 'subtract' then list - Array(second)
          when 'contains' then list.include?(second)
          else raise NativeRuntimeError, "unsupported list operation #{type}"
          end
        end

        # Whether an expression over $currentObject holds for one object of a list.
        def current_object?(expression, variables, object)
          @expression.evaluate(expression, variables.merge('currentObject' => object)) == true
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

        # An import mapping makes its objects even when the result is not stored.
        def bind_rest_result(handling, body, variables, result_handling_type: 'Mapping')
          mapped = result_handling_type.to_s == 'Mapping' &&
                   !handling.dig('ImportMappingCall', 'ReturnValueMapping').to_s.empty?
          return import_with_mapping(handling, body, variables) if mapped
          return unless handling['Bind'] == true

          result = case result_handling_type.to_s
                   when 'String'
                     unless handling.dig('VariableType', '$Type') == 'DataTypes$StringType' &&
                            handling['ImportMappingCall'].nil?
                       raise NativeRuntimeError, 'invalid string REST result handling'
                     end

                     body
                   when '', 'Mapping', 'HttpResponse'
                     JSON.parse(body)
                   else
                     raise NativeRuntimeError,
                           "unsupported REST result handling #{result_handling_type.inspect}"
                   end
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

        def rest_transport_options(action, configuration, variables)
          options = {}
          certificate = configuration['ClientCertificate'].to_s
          unless certificate.empty?
            options[:client_certificate] = evaluate_rest_transport_expression(certificate, variables)
          end
          case action.fetch('RequestProxyType', 'DefaultProxy')
          when 'DefaultProxy'
            nil
          when 'NoProxy'
            options[:proxy] = :none
          when 'Override'
            proxy = action['ProxyConfiguration'] || {}
            enabled = evaluate_rest_transport_expression(
              proxy.fetch('UseConfigurationExpression', 'true'), variables
            )
            if enabled == false
              nil
            else
              options[:proxy] = {
                host: evaluate_rest_transport_expression(proxy['HostExpression'], variables).to_s,
                port: Integer(evaluate_rest_transport_expression(proxy['PortExpression'], variables)),
                username: evaluate_rest_transport_expression(proxy['UsernameExpression'], variables).to_s,
                password: evaluate_rest_transport_expression(proxy['PasswordExpression'], variables).to_s
              }
            end
          else
            raise NativeRuntimeError,
                  "unsupported REST proxy type #{action['RequestProxyType'].inspect}"
          end
          options
        rescue ArgumentError, TypeError => e
          raise NativeRuntimeError, "invalid REST proxy configuration: #{e.message}"
        end

        def evaluate_rest_transport_expression(expression, variables)
          text = expression.to_s
          return '' if text.empty?

          @expression.evaluate(text, variables)
        rescue NativeRuntimeError, ArgumentError
          text
        end

        def http_request(method, location, headers, body, timeout, transport = {})
          uri = URI.parse(location)
          request_class = Net::HTTP.const_get(method.to_s.downcase.capitalize)
          request = request_class.new(uri)
          headers.each { request[_1] = _2 }
          request.body = body if body
          if transport.empty?
            return Net::HTTP.start(
              uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                  open_timeout: timeout || 10,
                                  read_timeout: timeout || 30
            ) { _1.request(request) }
          end

          http = rest_http_client(uri, transport[:proxy])
          http.use_ssl = uri.scheme == 'https'
          http.open_timeout = timeout || 10
          http.read_timeout = timeout || 30
          configure_client_certificate(http, transport[:client_certificate])
          http.start { _1.request(request) }
        rescue Errno::ENOENT, OpenSSL::OpenSSLError => e
          raise NativeRuntimeError, "REST client certificate failed: #{e.message}"
        end

        def rest_http_client(uri, proxy)
          return Net::HTTP.new(uri.host, uri.port, nil) if proxy == :none
          return Net::HTTP.new(uri.host, uri.port) unless proxy.is_a?(Hash)

          Net::HTTP::Proxy(
            proxy.fetch(:host), proxy.fetch(:port), proxy[:username], proxy[:password]
          ).new(uri.host, uri.port)
        end

        def configure_client_certificate(http, certificate)
          return if certificate.nil? || certificate.to_s.empty?

          source = certificate.is_a?(Hash) ? certificate : { path: certificate.to_s }
          bundle = OpenSSL::PKCS12.new(
            File.binread(source.fetch(:path)), source.fetch(:password, '').to_s
          )
          http.cert = bundle.certificate
          http.key = bundle.key
        end

        def aggregate(function, values)
          case function.to_s.downcase
          when 'count' then values.size
          when 'sum' then values.compact.sum
          when 'minimum', 'min' then values.compact.min
          when 'maximum', 'max' then values.compact.max
          when 'average', 'avg'
            values.compact.empty? ? nil : @decimal.divide(values.compact.sum, values.compact.size)
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
          store.touch(object) if !items(values).empty? && store.respond_to?(:touch)
        end

        def enforce_entity_access?
          @apply_entity_access && @policy && @security_context &&
            !(@security_context.respond_to?(:attributes) && @security_context.attributes['sudo'] == true)
        end

        def authorize_entity!(entity, action, member: nil, record: nil)
          return true unless enforce_entity_access?

          @policy.authorize!(
            entity, kind: :entity, action:, context: @security_context, member:, record:
          )
        end

        def render_template(template, variables)
          text = template&.dig('Text').to_s
          items(template&.dig('Parameters')).each_with_index do |parameter, index|
            value = @expression.evaluate(parameter['Expression'], variables)
            text = text.gsub("{#{index + 1}}") { value.nil? ? 'null' : value.to_s }
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
            value = @expression.evaluate(parameter['Expression'], variables).to_s
            text = text.gsub("{#{index + 1}}") { value }
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
