# frozen_string_literal: true

module Mxrb
  module Evaluation
    Check = Data.define(:name, :severity, :block)
    CheckResult = Data.define(:name, :severity, :passed, :message, :metadata) do
      def passed? = passed
      def failed? = !passed
    end

    Result = Data.define(:checks) do
      def failures = checks.select(&:failed?)
      def errors = failures.select { _1.severity == :error }
      def warnings = failures.select { _1.severity == :warning }
      def passed? = errors.empty?
      def score
        return 100.0 if checks.empty?

        (checks.count(&:passed?) * 100.0 / checks.size).round(2)
      end
    end

    # Defines executable expectations for a Mendix model using Ruby only.
    class Suite
      attr_reader :project, :checks

      def initialize(project)
        @project = project
        @checks = []
      end

      def check(name, severity: :error, &block)
        raise ArgumentError, "evaluation check requires a block" unless block
        unless %i[error warning].include?(severity.to_sym)
          raise ArgumentError, "evaluation severity must be :error or :warning"
        end

        @checks << Check.new(name.to_s, severity.to_sym, block)
        self
      end

      def artifact(name, kind: nil, severity: :error)
        check("artifact #{name} exists", severity:) do
          found = project.find_artifact(name, kind:)
          found ? true : "missing #{kind || 'artifact'} #{name}"
        end
      end

      def reference(from:, to:, relation: nil, severity: :error)
        check("#{from} references #{to}", severity:) do
          source = project.find_artifact(from)
          target = project.find_artifact(to)
          next "missing source #{from}" unless source
          next "missing target #{to}" unless target

          matches = project.references_from(source).select { _1.target.id == target.id }
          matches = matches.select { _1.relation == relation.to_sym } if relation
          matches.empty? ? "reference #{from} -> #{to} not found" : true
        end
      end

      def no_call_cycles(severity: :error)
        check("model has no call cycles", severity:) do
          cycles = project.analyze.call_cycles
          cycles.empty? ? true : "#{cycles.size} call cycle(s) found"
        end
      end

      def no_missing_internal_references(severity: :error)
        check("model has no missing internal references", severity:) do
          missing = project.analyze.errors.select { _1.rule == :unresolved_reference }
          missing.empty? ? true : "#{missing.size} internal reference(s) missing"
        end
      end

      def maximum_unreferenced(count, severity: :warning)
        check("model has at most #{count} unreferenced artifacts", severity:) do
          actual = project.analyze.unreferenced.size
          actual <= count ? true : "#{actual} unreferenced artifacts exceed maximum #{count}"
        end
      end

      def forbid_dependency(from:, to:, severity: :error)
        check("#{from} does not depend on #{to}", severity:) do
          dependency = project.analyze.module_dependencies.find do
            _1.from == from.to_s && _1.to == to.to_s
          end
          dependency ? "#{dependency.references.size} forbidden reference(s)" : true
        end
      end

      def require_dependency(from:, to:, severity: :error)
        check("#{from} depends on #{to}", severity:) do
          dependency = project.analyze.module_dependencies.find do
            _1.from == from.to_s && _1.to == to.to_s
          end
          dependency ? true : "required module dependency not found"
        end
      end

      def evaluate(path)
        instance_eval(File.read(path), path, 1)
        self
      end

      def run
        Result.new(@checks.map { execute(_1) }.freeze)
      end

      private

      def execute(check)
        value = check.block.call(project)
        passed = value == true
        message = passed ? "passed" : failure_message(value)
        CheckResult.new(check.name, check.severity, passed, message, {}.freeze)
      rescue StandardError => e
        CheckResult.new(
          check.name, check.severity, false,
          "#{e.class}: #{e.message}", { exception: e }.freeze
        )
      end

      def failure_message(value)
        return value if value.is_a?(String) && !value.empty?

        "check returned #{value.inspect}"
      end
    end
  end
end
