# frozen_string_literal: true

require_relative 'native'
require_relative 'xpath_functions'
require_relative 'xpath_dates'

module Mxrb
  module Runtime
    # A parsed constraint, shared by database retrieves and HTTP selectors.
    # Paths produce sets; comparisons are existential, including !=. A nested
    # predicate is evaluated on the related object, not on the outer candidate.
    # AST dispatch and grammar productions keep their alternatives together.
    # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
    class XPath
      ARITHMETIC = {
        '+' => ->(left, right) { left + right }, '-' => ->(left, right) { left - right },
        '*' => ->(left, right) { left * right }, '/' => ->(left, right) { left / right },
        'div' => ->(left, right) { left / right }, 'mod' => ->(left, right) { left % right }
      }.freeze
      def initialize(source, store:, policy: nil, context: nil)
        @store = store
        @policy = policy
        @context = context
        @expression = Native::Expression.new
        @functions = XPathFunctions.new(context)
        @tree = Parser.new(source.to_s).parse
      end

      def filter(records, variables = {})
        records.select { match?(_1, variables) }
      end

      def match?(record, variables = {})
        readable?(record) && truthy?(evaluate(@tree, record, variables))
      rescue IndexError, TypeError, ZeroDivisionError
        raise ArgumentError, 'invalid XPath operand or function arguments'
      end

      private

      def readable?(record)
        !@policy || @policy.entity_allowed?(record.entity, action: :read, context: @context, record:)
      end

      def authorize_member(record, member)
        return unless @policy

        @policy.authorize!(record.entity, kind: :entity, action: :read, context: @context, member:, record:)
      end

      def evaluate(tree, record, variables)
        kind, *parts = tree
        case kind
        when :literal then parts.first
        when :variable then variable(parts.first, variables)
        when :path then path(record, parts.first, variables)
        when :call then invoke(parts.first, parts.last.map { evaluate(_1, record, variables) })
        when :system then system_variable(parts.first, variables)
        when :not then !truthy?(evaluate(parts.first, record, variables))
        when :negative then -scalar(evaluate(parts.first, record, variables))
        when :and, :or
          left = truthy?(evaluate(parts.first, record, variables))
          right = truthy?(evaluate(parts.last, record, variables))
          kind == :and ? left & right : left | right
        else compare(kind, evaluate(parts.first, record, variables), evaluate(parts.last, record, variables))
        end
      end

      def invoke(name, arguments)
        normalized = name.downcase
        return @functions.invoke(normalized, arguments) if @functions.supported?(normalized)

        @expression.invoke(name, arguments.map { scalar(_1) })
      end

      def system_variable(source, variables)
        return identity(@context&.user) if source == '[%CurrentUser%]'
        return identity(variable('currentObject', variables)) if source == '[%CurrentObject%]'
        return user_role(source.delete_prefix('[%UserRole_').delete_suffix('%]')) if source.start_with?('[%UserRole_')

        XPathDates.new(@context).resolve(source)
      end

      def identity(value)
        return value.id if value.is_a?(Native::ObjectValue)
        return value['id'] || value[:id] if value.is_a?(Hash)

        value
      end

      def user_role(name)
        found = @store.retrieve('System.UserRole').find do |role|
          next false unless readable?(role)

          authorize_member(role, 'Name')
          role.members['Name'] == name
        end
        raise ArgumentError, "unknown or unreadable XPath user role #{name}" unless found

        found.id
      end

      def variable(name, variables)
        key, member = name.delete_prefix('$').split('/', 2)
        value = variables.fetch(key) { raise ArgumentError, "unknown XPath variable $#{key}" }
        return value unless member

        raise ArgumentError, "XPath variable $#{key} is not an object" unless value.is_a?(Native::ObjectValue)
        raise AuthorizationError, 'XPath context is not readable' unless readable?(value)

        authorize_member(value, member.split('.').last)
        value.members[member.split('.').last]
      end

      def path(record, steps, variables)
        values = [record]
        steps.each do |name, predicates|
          values = values.flat_map { step(_1, name) }
          predicates.each do |predicate|
            values = values.select { truthy?(evaluate(predicate, _1, variables)) }
          end
        end
        values
      end

      def step(record, name)
        raise ArgumentError, 'XPath path must traverse objects' unless record.is_a?(Native::ObjectValue)
        return [record] if entity_type?(record, name)
        return [name] if name.split('.').length == 3 && !entity_type?(record, name.rpartition('.').first)

        member = name.split('.').last
        authorize_member(record, member)
        return [record.id] if name == 'id'

        if record.members.key?(member)
          value = record.members[member]
          return [] if value.nil?
          return Array(value).select { readable?(_1) } if value.is_a?(Native::ObjectValue) || value.is_a?(Array)

          return [value]
        end
        @store.retrieve_association(name, record).select { readable?(_1) }
      end

      def entity_type?(record, name)
        name == record.entity || (@store.respond_to?(:schema) && @store.schema.assignable?(record.entity, name))
      end

      def compare(operator, left, right)
        arithmetic = ARITHMETIC[operator.to_s]
        return arithmetic.call(scalar(left), scalar(right)) if arithmetic

        left = [left] unless left.is_a?(Array)
        right = [right] unless right.is_a?(Array)
        left = [nil] if left.empty?
        right = [nil] if right.empty?
        left.any? do |one|
          right.any? do |other|
            one = one.id if one.is_a?(Native::ObjectValue)
            other = other.id if other.is_a?(Native::ObjectValue)
            next false if (one.nil? || other.nil?) && !%i[= !=].include?(operator)

            Native::Expression::Parser::COMPARISONS.fetch(operator.to_s).call(one, other)
          end
        end
      end

      def scalar(value)
        return value unless value.is_a?(Array)
        raise ArgumentError, 'XPath function requires a single value' unless value.one?

        value.first
      end

      def truthy?(value)
        value.is_a?(Array) ? value.any? { truthy?(_1) } : value != false && !value.nil?
      end

      # AST construction validates the entire constraint even for empty tables.
      class Parser
        def initialize(source)
          raise ArgumentError, 'XPath constraint is too large' if source.bytesize > 8192

          @tokens = Lexer.new(source).tokens
          @index = 0
          @depth = 0
        end

        def parse
          groups = predicates
          consume(:eof)
          groups.reduce([:literal, true]) { |left, right| [:and, left, right] }
        end

        private

        def predicates
          groups = []
          while accept(:left_bracket)
            groups << nested { expression }
            consume(:right_bracket)
          end
          groups
        end

        def nested
          @depth += 1
          raise ArgumentError, 'XPath nesting limit exceeded' if @depth > 32

          yield
        ensure
          @depth -= 1
        end

        def expression
          left = conjunction
          left = [:or, left, conjunction] while accept(:identifier, 'or')
          left
        end

        def conjunction
          left = comparison
          left = [:and, left, comparison] while accept(:identifier, 'and')
          left
        end

        def comparison
          left = addition
          return left unless peek.first == :operator && Native::Expression::Parser::COMPARISONS.key?(peek.last)

          operator = consume(:operator)
          [operator.to_sym, left, addition]
        end

        def addition
          left = multiplication
          while peek.first == :operator && %w[+ -].include?(peek.last)
            left = [consume(:operator).to_sym, left, multiplication]
          end
          left
        end

        def multiplication
          left = primary
          left = [consume(peek.first).to_sym, left, primary] while %w[* / div mod].include?(peek.last)
          left
        end

        def primary
          return [:not, nested { primary }] if accept(:identifier, 'not')
          return [:negative, nested { primary }] if accept(:operator, '-')

          if accept(:left_parenthesis)
            value = nested { expression }
            consume(:right_parenthesis)
            return value
          end
          kind, = peek
          return [:system, consume(kind)] if kind == :system
          return [:system, consume(kind)] if kind == :string && peek.last.start_with?('[%')
          return [:literal, consume(kind)] if %i[number string].include?(kind)
          return [:variable, consume(kind)] if kind == :variable

          identifier
        end

        def identifier
          name = consume(:identifier)
          if %w[true false empty NULL].include?(name)
            consume(:right_parenthesis) if accept(:left_parenthesis)
            return [:literal, { 'true' => true, 'false' => false, 'empty' => nil, 'NULL' => nil }.fetch(name)]
          end

          if accept(:left_parenthesis)
            arguments = []
            unless accept(:right_parenthesis)
              arguments << nested { expression }
              arguments << nested { expression } while accept(:comma)
              consume(:right_parenthesis)
            end
            return [:call, name, arguments]
          end
          steps = [[name, predicates]]
          while peek == [:operator, '/'] && @tokens.fetch(@index + 1).first == :identifier
            consume(:operator)
            steps << [consume(:identifier), predicates]
          end
          [:path, steps]
        end

        def peek = @tokens.fetch(@index)

        def accept(kind, value = nil)
          return false unless peek.first == kind && (value.nil? || peek.last == value)

          @index += 1
          true
        end

        def consume(kind)
          value = peek.last
          raise ArgumentError, "invalid XPath: expected #{kind}" unless accept(kind)

          value
        end
      end

      # Keep malformed tokens from stalling the shared expression scanner.
      class Lexer < Native::Expression::Lexer
        private

        def next_token
          @scanner.skip(/\s+/)
          system = @scanner.scan(/\[%[A-Za-z_]\w*%\]/)
          return [:system, system] if system

          function = @scanner.scan(/[A-Za-z_]\w*(?:-[A-Za-z_]\w*)+(?=\s*\()/)
          return [:identifier, function] if function

          position = @scanner.pos
          token = super
          raise ArgumentError, 'invalid XPath token' if @scanner.pos == position && token.first != :eof

          token
        end

        def punctuation
          case @scanner.peek(1)
          when '[' then [:left_bracket, @scanner.getch]
          when ']' then [:right_bracket, @scanner.getch]
          else super
          end
        end
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
