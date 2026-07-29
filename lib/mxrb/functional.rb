# frozen_string_literal: true

module Mxrb
  module Functional
    TestCase = Data.define(:name, :target, :arguments, :timeout)
    Definition = Data.define(:tests) do
      def empty? = tests.empty?
    end
    TestResult = Data.define(:name, :passed, :message) do
      def passed? = passed
      def failed? = !passed
    end
    Result = Data.define(:tests, :finished) do
      def passed? = finished && tests.all?(&:passed?)
      def finished? = finished
      def failures = tests.select(&:failed?)
    end

    # Ruby-only definition of runtime microflow tests.
    class Suite
      attr_reader :tests

      def initialize
        @tests = []
      end

      def microflow(name, call:, pass: {}, timeout: 60)
        label = name.to_s.strip
        target = call.to_s.strip
        raise ArgumentError, "functional test name cannot be empty" if label.empty?
        unless target.match?(/\A[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\z/)
          raise ArgumentError, "microflow call must be a qualified Mendix name"
        end
        raise ArgumentError, "functional test timeout must be positive" unless timeout.to_f.positive?

        arguments = pass.to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze
        @tests << TestCase.new(label, target, arguments, timeout.to_f)
        self
      end

      def evaluate(path)
        instance_eval(File.read(path), path, 1)
        self
      end

      def definition
        Definition.new(@tests.dup.freeze)
      end
    end

    # Adds an isolated after-startup runner to a writable disposable MPR copy.
    class Instrumenter
      MODULE_NAME = "MxrbTests"
      RUNNER_NAME = "RunAll"
      LOG_NODE = "'MXRB_TEST'".freeze

      def initialize(path, definition)
        @path = File.expand_path(path)
        @definition = definition
      end

      def instrument!
        raise FunctionalTestError, "functional test suite is empty" if @definition.empty?

        version = validate_targets!
        mod = build_module
        Writer.new(
          @path,
          version: version, modules: [mod.to_h],
          security: nil, native_units_path: nil
        ).write!
        select_after_startup!
        self
      end

      def runner = "#{MODULE_NAME}.#{RUNNER_NAME}"

      private

      def validate_targets!
        Mxrb.open(@path) do |project|
          @definition.tests.each do |test|
            artifact = project.find_artifact(test.target, kind: :microflow)
            raise FunctionalTestError, "microflow #{test.target} not found" unless artifact

            raw = project.raw_unit(artifact.unit_id)
            doc = project.parse_bson(raw)
            collection = doc["MicroflowParameterCollection"] || doc["Parameters"] || {}
            parameter_docs = collection.is_a?(Hash) ?
              IO::BsonCodec.parse_array(collection["Parameters"])[:items] : []
            parameter_docs += IO::BsonCodec.parse_array(
              doc.dig("ObjectCollection", "Objects")
            )[:items].select { _1["$Type"] == "Microflows$MicroflowParameter" }
            parameters = parameter_docs.filter_map do |parameter|
              parameter["Name"] || parameter["name"] if parameter.is_a?(Hash)
            end
            supplied = test.arguments.keys
            unknown = supplied - parameters
            missing = parameters - supplied
            unless unknown.empty? && missing.empty?
              raise FunctionalTestError,
                    "microflow #{test.target} arguments mismatch " \
                    "(missing: #{missing.join(', ')}, unknown: #{unknown.join(', ')})"
            end
          end
          project.mendix_version
        end
      end

      def build_module
        mod = Dsl::ModuleBuilder.new(MODULE_NAME)
        tests = @definition.tests
        wrapper_names = tests.each_index.map { wrapper_name(_1) }
        tests.each_with_index do |test, index|
          mod.microflow(wrapper_name(index), kind: :test) do
            return_type :Boolean
            call_microflow test.target, pass: test.arguments
            return_value "true"
            rescue_all { return_value "false" }
          end
        end
        mod.microflow(RUNNER_NAME, kind: :test) do
          return_type :Boolean
          tests.each_with_index do |test, index|
            variable = :"passed_#{index + 1}"
            call_microflow "#{MODULE_NAME}.#{wrapper_names.fetch(index)}", as: variable
            decision "$#{variable}" do
              on(true) do
                log_message "[MXRB_TEST] PASS #{test.name}", node: LOG_NODE
              end
              on(false) do
                log_message "[MXRB_TEST] FAIL #{test.name}", level: :error, node: LOG_NODE
              end
            end
          end
          log_message "[MXRB_TEST] DONE", node: LOG_NODE
          return_value "true"
        end
        mod
      end

      def wrapper_name(index) = format("Test_%03d", index + 1)

      def select_after_startup!
        mpr = IO::MprFile.open(@path)
        raw = mpr.all_units.find { mpr.parse_contents(_1)["$Type"] == "Settings$ProjectSettings" }
        raise FunctionalTestError, "project settings unit not found" unless raw

        doc = mpr.parse_contents(raw)
        settings = IO::BsonCodec.parse_array(doc["Settings"])[:items]
        model_settings = settings.find { _1["$Type"] == "Settings$ModelSettings" }
        raise FunctionalTestError, "model settings part not found" unless model_settings

        model_settings["AfterStartupMicroflow"] = runner
        mpr.update_unit(raw.fetch("UnitID"), doc)
      ensure
        mpr&.close
      end
    end

    class LogParser
      PATTERN = /\[MXRB_TEST\] (PASS|FAIL) (.+)$/

      def parse(text)
        tests = text.each_line.filter_map do |line|
          match = line.strip.match(PATTERN)
          next unless match

          passed = match[1] == "PASS"
          TestResult.new(match[2], passed, passed ? "passed" : "microflow failed")
        end
        Result.new(tests.freeze, text.include?("[MXRB_TEST] DONE"))
      end
    end
  end
end
