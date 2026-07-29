# frozen_string_literal: true

require "cgi"
require "json"

module Mxrb
  module Functional
    Hook = Data.define(:target, :arguments)
    CountExpectation = Data.define(:entity, :xpath, :equals)
    TestCase = Data.define(
      :name, :target, :arguments, :timeout,
      :expected_return, :counts, :setup, :cleanup
    ) do
      class << self
        alias data_new new

        def new(name, target, arguments, timeout, expected_return = nil,
                counts = [].freeze, setup = nil, cleanup = nil)
          data_new(
            name, target, arguments, timeout,
            expected_return, counts, setup, cleanup
          )
        end
      end
    end
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

      def microflow(name, call:, pass: {}, timeout: 60, expect: {},
                    before: nil, after: nil)
        label = name.to_s.strip
        target = call.to_s.strip
        raise ArgumentError, "functional test name cannot be empty" if label.empty?
        unless target.match?(/\A[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\z/)
          raise ArgumentError, "microflow call must be a qualified Mendix name"
        end
        raise ArgumentError, "functional test timeout must be positive" unless timeout.to_f.positive?

        arguments = pass.to_h.transform_keys(&:to_s).transform_values(&:to_s).freeze
        expectations = expect.to_h
        expected_return = expectations[:return] || expectations["return"]
        counts = normalize_counts(expectations[:count] || expectations["count"])
        @tests << TestCase.new(
          label, target, arguments, timeout.to_f, expected_return&.to_s,
          counts, normalize_hook(before), normalize_hook(after)
        )
        self
      end

      def evaluate(path)
        instance_eval(File.read(path), path, 1)
        self
      end

      def definition
        Definition.new(@tests.dup.freeze)
      end

      private

      def normalize_hook(value)
        return unless value

        options = value.is_a?(Hash) ? value : { call: value }
        target = (options[:call] || options["call"]).to_s
        unless target.match?(/\A[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\z/)
          raise ArgumentError, "functional hook must call a qualified microflow"
        end
        arguments = (options[:pass] || options["pass"] || {}).to_h
          .transform_keys(&:to_s).transform_values(&:to_s).freeze
        Hook.new(target, arguments)
      end

      def normalize_counts(value)
        values = value.is_a?(Array) ? value : [value]
        values.compact.map do |item|
          options = item.to_h
          entity = (options[:entity] || options["entity"]).to_s
          equals = options.key?(:equals) ? options[:equals] : options["equals"]
          unless entity.match?(/\A[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\z/)
            raise ArgumentError, "count expectation requires a qualified entity"
          end
          raise ArgumentError, "count expectation requires a non-negative integer" unless
            equals.is_a?(Integer) && equals >= 0

          CountExpectation.new(
            entity, (options[:xpath] || options["xpath"])&.to_s, equals
          )
        end.freeze
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
            validate_call!(project, test.target, test.arguments)
            validate_call!(project, test.setup.target, test.setup.arguments) if test.setup
            validate_call!(project, test.cleanup.target, test.cleanup.arguments) if test.cleanup
            test.counts.each do |expectation|
              unless project.find_artifact(expectation.entity, kind: :entity)
                raise FunctionalTestError, "entity #{expectation.entity} not found"
              end
            end
          end
          project.mendix_version
        end
      end

      def validate_call!(project, target, arguments)
        artifact = project.find_artifact(target, kind: :microflow)
        raise FunctionalTestError, "microflow #{target} not found" unless artifact

        doc = project.parse_bson(project.raw_unit(artifact.unit_id))
        collection = doc["MicroflowParameterCollection"] || doc["Parameters"] || {}
        parameter_docs = collection.is_a?(Hash) ?
          IO::BsonCodec.parse_array(collection["Parameters"])[:items] : []
        parameter_docs += IO::BsonCodec.parse_array(
          doc.dig("ObjectCollection", "Objects")
        )[:items].select { _1["$Type"] == "Microflows$MicroflowParameter" }
        parameters = parameter_docs.filter_map do |parameter|
          parameter["Name"] || parameter["name"] if parameter.is_a?(Hash)
        end
        unknown = arguments.keys - parameters
        missing = parameters - arguments.keys
        return if unknown.empty? && missing.empty?

        raise FunctionalTestError,
              "microflow #{target} arguments mismatch " \
              "(missing: #{missing.join(', ')}, unknown: #{unknown.join(', ')})"
      end

      def build_module
        mod = Dsl::ModuleBuilder.new(MODULE_NAME)
        tests = @definition.tests
        wrapper_names = tests.each_index.map { wrapper_name(_1) }
        emit_hook = lambda do |flow, hook|
          flow.call_microflow(hook.target, pass: hook.arguments) if hook
        end
        tests.each_with_index do |test, index|
          mod.microflow(wrapper_name(index), kind: :test) do
            return_type :Boolean
            emit_hook.call(self, test.setup)
            call_microflow(
              test.target, pass: test.arguments,
              as: (test.expected_return ? :mxrb_actual : nil)
            )
            conditions = []
            conditions << "$mxrb_actual = #{test.expected_return}" if test.expected_return
            test.counts.each_with_index do |expectation, count_index|
              list = :"mxrb_items_#{count_index + 1}"
              count = :"mxrb_count_#{count_index + 1}"
              retrieve_objects expectation.entity, as: list, xpath: expectation.xpath
              aggregate list, function: :count, as: count
              conditions << "$#{count} = #{expectation.equals}"
            end
            if conditions.empty?
              emit_hook.call(self, test.cleanup)
              return_value "true"
            else
              emit_hook.call(self, test.cleanup)
              return_value "(#{conditions.join(' and ')})"
            end
            rescue_all do
              emit_hook.call(self, test.cleanup)
              return_value "false"
            end
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

    class Reporter
      def write_json(execution, path)
        payload = {
          passed: execution.passed?,
          finished: execution.result.finished?,
          elapsed: execution.elapsed,
          tests: execution.result.tests.map do |test|
            { name: test.name, passed: test.passed?, message: test.message }
          end
        }
        File.write(path, JSON.pretty_generate(payload) << "\n")
        path
      end

      def write_junit(execution, path)
        tests = execution.result.tests
        failures = tests.count(&:failed?)
        cases = tests.map do |test|
          name = CGI.escapeHTML(test.name)
          if test.passed?
            %(  <testcase name="#{name}"/>)
          else
            message = CGI.escapeHTML(test.message)
            %(  <testcase name="#{name}"><failure message="#{message}"/></testcase>)
          end
        end.join("\n")
        xml = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <testsuite name="mxrb" tests="#{tests.size}" failures="#{failures}" time="#{execution.elapsed}">
          #{cases}
          </testsuite>
        XML
        File.write(path, xml)
        path
      end
    end
  end
end
