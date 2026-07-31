# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"

module Mxrb
  module Runtime
    Execution = Data.define(
      :result, :check_output, :build_output, :runtime_output, :elapsed
    ) do
      def passed? = result.passed?
    end

    # Runs the official validators against a disposable project copy and
    # converts the runtime protocol back into Ruby result objects.
    class Executor
      STARTUP_ALLOWANCE = 120

      def initialize(project_path, definition, plan: nil, java_home: ENV["JAVA_HOME"],
                     output: nil, clock: Process.method(:clock_gettime))
        @project_path = File.expand_path(project_path)
        @definition = definition
        @plan = plan || Toolchain.new(@project_path).plan
        @java_home = java_home && File.expand_path(java_home)
        @output = output
        @clock = clock
      end

      def run
        validate_environment!
        started = monotonic_time
        Dir.mktmpdir("mxrb-functional-") do |root|
          project = copy_project(root)
          Functional::Instrumenter.new(project, @definition).instrument!
          check_output = check(project, root)
          package = build(project, root)
          runtime_output = start_runtime(package, root)
          result = Functional::LogParser.new.parse(runtime_output)
          raise FunctionalTestError, "runtime stopped before the test suite completed" unless result.finished?

          Execution.new(
            result, check_output, build_output(package), runtime_output,
            monotonic_time - started
          )
        end
      end

      private

      def validate_environment!
        raise ToolchainError, "Mendix toolchain #{@plan.toolchain_path} is unavailable" unless @plan.available?
        unless @java_home && File.executable?(File.join(@java_home, "bin", "java"))
          raise ToolchainError, "JAVA_HOME must point to a Java #{@plan.java_version} installation"
        end
      end

      def copy_project(root)
        source_dir = File.dirname(@project_path)
        destination = File.join(root, "project")
        FileUtils.mkdir_p(destination)
        FileUtils.cp_r(
          Dir.glob(File.join(source_dir, "*"), File::FNM_DOTMATCH)
             .reject { [".", ".."].include?(File.basename(_1)) },
          destination
        )
        File.join(destination, File.basename(@project_path))
      end

      def check(project, _root)
        result = Mxrb.validate(project)
        unless result.valid?
          raise FunctionalTestError,
                "MXRB validation found #{result.errors.size} error(s): #{result.errors.first}"
        end

        (["MXRB native validation passed"] + result.warnings.map { "warning: #{_1}" }).join("\n")
      end

      def build(project, root)
        package = File.join(root, "runtime.zip")
        output, status = capture(
          @plan.mxbuild_path,
          "--java-home=#{@java_home}",
          "--java-exe-path=#{File.join(@java_home, 'bin', 'java')}",
          "--target=portable-app-package",
          "--output=#{package}",
          project
        )
        raise FunctionalTestError, "mxbuild failed:\n#{output}" unless status.success?

        @last_build_output = output
        package
      end

      def build_output(_package) = @last_build_output

      def start_runtime(package, root)
        runtime = File.join(root, "runtime")
        FileUtils.mkdir_p(runtime)
        output, status = capture("unzip", "-q", package, "-d", runtime)
        raise FunctionalTestError, "could not unpack runtime:\n#{output}" unless status.success?

        command = [File.join(runtime, "bin", "start"), "etc/Default"]
        environment = {
          "JAVA_HOME" => @java_home,
          "M2EE_ADMIN_PASS" => "mxrb-functional-test"
        }
        collect_runtime(environment, command, runtime)
      end

      def collect_runtime(environment, command, directory)
        transcript = +""
        deadline = monotonic_time + STARTUP_ALLOWANCE + @definition.tests.sum(&:timeout)
        Open3.popen2e(environment, *command, chdir: directory) do |stdin, stream, thread|
          stdin.close
          until transcript.include?("[MXRB_TEST] DONE")
            remaining = deadline - monotonic_time
            raise FunctionalTestError, "functional test runtime timed out" unless remaining.positive?

            ready = ::IO.select([stream], nil, nil, remaining)
            raise FunctionalTestError, "functional test runtime timed out" unless ready

            line = stream.gets
            break unless line

            transcript << line
            @output&.write(line)
          end
        ensure
          terminate(thread)
        end
        transcript
      end

      def terminate(thread)
        return unless thread&.alive?

        Process.kill("TERM", thread.pid)
        thread.join(10)
        Process.kill("KILL", thread.pid) if thread.alive?
      rescue Errno::ESRCH
        nil
      ensure
        thread&.join
      end

      def capture(*command)
        Open3.capture2e(*command)
      end

      def monotonic_time
        @clock.call(Process::CLOCK_MONOTONIC)
      rescue ArgumentError
        @clock.call
      end
    end
  end
end
