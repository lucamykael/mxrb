# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Mxrb::Functional do
  def build_functional_mpr(path, java: "21")
    Mxrb.define(path) do
      mendix_version "11.12.1"
      self.module :Demo do
        entity :Record do
          string :Name
        end
        microflow :Noop do
          log_message "noop"
        end
        microflow :Setup do
          log_message "setup"
        end
        microflow :Cleanup do
          log_message "cleanup"
        end
        microflow :ReturnsBool do
          return_type :Boolean
          return_value "true"
        end
        microflow :WithInput do
          parameter :Value, type: :String
          log_message "input"
        end
      end
    end
    mpr = Mxrb::IO::MprFile.open(path)
    root = mpr.root_unit.fetch("UnitID")
    mpr.insert_unit(
      container_uuid: root,
      containment_name: "ProjectDocuments",
      contents_doc: {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Settings$ProjectSettings",
        "Settings" => [2, {
          "$ID" => SecureRandom.uuid,
          "$Type" => "Settings$ModelSettings",
          "AfterStartupMicroflow" => "",
          "JavaMajorVersion" => java
        }]
      }
    )
  ensure
    mpr&.close
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "Demo.mpr")
      build_functional_mpr(@path)
      @definition_path = File.join(dir, "functional_test.rb")
      File.write(
        @definition_path,
        <<~RUBY
          microflow "No-op completes", call: "Demo.Noop"
          microflow "No-op with input", call: "Demo.WithInput",
                    pass: { Value: "'test'" }, timeout: 5
        RUBY
      )
      example.run
    end
  end

  it "loads immutable Ruby functional test definitions" do
    definition = Mxrb.functional_definition(@definition_path)

    expect(definition.tests.map(&:name)).to eq(["No-op completes", "No-op with input"])
    expect(definition.tests.last.arguments).to eq("Value" => "'test'")
    expect(definition.tests.last.timeout).to eq(5.0)
    expect(definition).not_to be_empty
  end

  it "rejects invalid functional test declarations" do
    suite = described_class::Suite.new
    expect { suite.microflow("", call: "Demo.Noop") }
      .to raise_error(ArgumentError, /name/)
    expect { suite.microflow("bad", call: "Noop") }
      .to raise_error(ArgumentError, /qualified/)
    expect { suite.microflow("bad", call: "Demo.Noop", timeout: 0) }
      .to raise_error(ArgumentError, /positive/)
    expect do
      suite.microflow("bad hook", call: "Demo.Noop", before: "Setup")
    end.to raise_error(ArgumentError, /hook/)
    expect do
      suite.microflow(
        "bad count", call: "Demo.Noop",
        expect: { count: { entity: "Record", equals: -1 } }
      )
    end.to raise_error(ArgumentError, /qualified entity/)
    expect do
      suite.microflow(
        "bad count", call: "Demo.Noop",
        expect: { count: { entity: "Demo.Record", equals: -1 } }
      )
    end.to raise_error(ArgumentError, /non-negative/)
    expect(suite.definition).to be_empty
  end

  it "loads return, persisted-count, setup and cleanup expectations" do
    suite = described_class::Suite.new
    suite.microflow(
      "assertions", call: "Demo.ReturnsBool",
      before: { call: "Demo.Setup" }, after: "Demo.Cleanup",
      expect: {
        return: "true",
        count: { entity: "Demo.Record", xpath: "[Name = 'x']", equals: 0 }
      }
    )
    test = suite.definition.tests.first

    expect(test.expected_return).to eq("true")
    expect(test.setup.target).to eq("Demo.Setup")
    expect(test.cleanup.target).to eq("Demo.Cleanup")
    expect(test.counts.first.to_h).to eq(
      entity: "Demo.Record", xpath: "[Name = 'x']", equals: 0
    )
  end

  it "instruments a disposable MPR with wrappers and an after-startup runner" do
    definition = Mxrb.functional_definition(@definition_path)
    instrumenter = described_class::Instrumenter.new(@path, definition).instrument!

    expect(instrumenter.runner).to eq("MxrbTests.RunAll")
    Mxrb.open(@path) do |project|
      expect(project.find_artifact("MxrbTests.Test_001", kind: :microflow)).not_to be_nil
      expect(project.find_artifact("MxrbTests.RunAll", kind: :microflow)).not_to be_nil
      settings = project.all_units.filter_map do |raw|
        doc = project.parse_bson(raw)
        doc if doc["$Type"] == "Settings$ProjectSettings"
      end.first
      model = Mxrb::IO::BsonCodec.parse_array(settings["Settings"])[:items].first
      expect(model["AfterStartupMicroflow"]).to eq("MxrbTests.RunAll")
    end
    expect(Mxrb.validate(@path)).to be_valid
  end

  it "rejects empty suites, missing targets, and incomplete project settings" do
    expect do
      described_class::Instrumenter.new(
        @path, described_class::Definition.new([].freeze)
      ).instrument!
    end.to raise_error(Mxrb::FunctionalTestError, /empty/)

    missing = described_class::Definition.new([
      described_class::TestCase.new("missing", "Demo.Missing", {}.freeze, 1.0)
    ].freeze)
    expect { described_class::Instrumenter.new(@path, missing).instrument! }
      .to raise_error(Mxrb::FunctionalTestError, /not found/)

    mismatch = described_class::Definition.new([
      described_class::TestCase.new("mismatch", "Demo.WithInput", {}.freeze, 1.0)
    ].freeze)
    expect { described_class::Instrumenter.new(@path, mismatch).instrument! }
      .to raise_error(Mxrb::FunctionalTestError, /arguments mismatch/)

    missing_entity = described_class::Suite.new.tap do |suite|
      suite.microflow(
        "count", call: "Demo.Noop",
        expect: { count: { entity: "Demo.Missing", equals: 0 } }
      )
    end.definition
    expect { described_class::Instrumenter.new(@path, missing_entity).instrument! }
      .to raise_error(Mxrb::FunctionalTestError, /entity Demo.Missing/)

    no_settings = File.join(File.dirname(@path), "NoSettings.mpr")
    Mxrb.define(no_settings) do
      mendix_version "11.12.1"
      self.module(:Demo) { microflow(:Noop) }
    end
    valid = described_class::Definition.new([
      described_class::TestCase.new("noop", "Demo.Noop", {}.freeze, 1.0)
    ].freeze)
    expect { described_class::Instrumenter.new(no_settings, valid).instrument! }
      .to raise_error(Mxrb::FunctionalTestError, /project settings/)

    mpr = Mxrb::IO::MprFile.open(no_settings)
    mpr.insert_unit(
      container_uuid: mpr.root_unit.fetch("UnitID"),
      containment_name: "ProjectDocuments",
      contents_doc: {
        "$ID" => SecureRandom.uuid, "$Type" => "Settings$ProjectSettings",
        "Settings" => [2]
      }
    )
    mpr.close
    expect { described_class::Instrumenter.new(no_settings, valid).instrument! }
      .to raise_error(Mxrb::FunctionalTestError, /model settings/)
  end

  it "parses structured runtime logs into Ruby results" do
    result = described_class::LogParser.new.parse(<<~LOG)
      INFO [MXRB_TEST] PASS first
      ERROR [MXRB_TEST] FAIL second
      INFO [MXRB_TEST] DONE
    LOG

    expect(result).not_to be_passed
    expect(result).to be_finished
    expect(result.tests.first).to be_passed
    expect(result.failures.map(&:name)).to eq(["second"])
    expect(result.failures.first.message).to eq("microflow failed")
    expect(described_class::LogParser.new.parse("nothing")).not_to be_passed
  end

  it "instruments return and persisted-count assertions with hooks" do
    definition = described_class::Suite.new.tap do |suite|
      suite.microflow(
        "asserted", call: "Demo.ReturnsBool",
        before: "Demo.Setup", after: "Demo.Cleanup",
        expect: {
          return: "true",
          count: { entity: "Demo.Record", equals: 0 }
        }
      )
    end.definition

    described_class::Instrumenter.new(@path, definition).instrument!
    Mxrb.open(@path) do |project|
      flow = project.microflows.find { _1.name == "Test_001" }
      types = flow.objects.filter_map { _1.dig("Action", "$Type") }
      expect(types).to include(
        "Microflows$MicroflowCallAction",
        "Microflows$RetrieveAction",
        "Microflows$AggregateAction"
      )
      expect(flow.objects.any? { _1["$Type"] == "Microflows$ExclusiveSplit" })
        .to be(false)
      return_value = flow.objects.find { _1["$Type"] == "Microflows$EndEvent" }
                          .fetch("ReturnValue")
      expect(return_value).to include("$mxrb_actual", "$mxrb_count_1")
    end
    expect(Mxrb.validate(@path)).to be_valid
  end

  it "writes JSON and JUnit reports with escaped failures" do
    result = described_class::Result.new([
      described_class::TestResult.new("works", true, "passed"),
      described_class::TestResult.new("bad <case>", false, "failed & stopped")
    ].freeze, true)
    execution = Mxrb::Runtime::Execution.new(result, "", "", "", 1.25)
    json = File.join(File.dirname(@path), "result.json")
    junit = File.join(File.dirname(@path), "result.xml")
    reporter = described_class::Reporter.new

    expect(reporter.write_json(execution, json)).to eq(json)
    expect(reporter.write_junit(execution, junit)).to eq(junit)
    expect(JSON.parse(File.read(json))).to include("passed" => false, "elapsed" => 1.25)
    expect(File.read(junit)).to include(
      'tests="2"', 'failures="1"', "bad &lt;case&gt;", "failed &amp; stopped"
    )
  end
end

RSpec.describe Mxrb::Runtime do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "Plan.mpr")
      Mxrb.define(@path) do
        mendix_version "11.12.1"
        self.module(:Demo) { microflow(:Noop) }
      end
      @toolchains = File.join(dir, "toolchains")
      FileUtils.mkdir_p(File.join(@toolchains, "11.12.1", "modeler"))
      example.run
    end
  end

  it "selects lightweight Java packages and the configured Mendix toolchain" do
    toolchain = described_class::Toolchain.new(@path, mendix_home: @toolchains)
    allow(toolchain).to receive(:configured_java).and_return("21")
    plan = toolchain.plan

    expect(plan.java_version).to eq("21")
    expect(plan.jdk_package).to eq("zulu21-ca-jdk-headless")
    expect(plan.jre_package).to eq("zulu21-ca-jre-headless")
    expect(plan.builder_image).to eq("mxrb/mendix-builder:java21")
    expect(plan.runtime_image).to eq("eclipse-temurin:21-jre")
    expect(plan).not_to be_available
  end

  it "reads the Java family from project settings through the public API" do
    mpr = Mxrb::IO::MprFile.open(@path)
    mpr.insert_unit(
      container_uuid: mpr.root_unit.fetch("UnitID"),
      containment_name: "ProjectDocuments",
      contents_doc: {
        "$ID" => SecureRandom.uuid, "$Type" => "Settings$ProjectSettings",
        "Settings" => [2, {
          "$ID" => SecureRandom.uuid, "$Type" => "Settings$ModelSettings",
          "JavaMajorVersion" => "21"
        }]
      }
    )
    mpr.close

    plan = Mxrb.runtime_plan(@path, mendix_home: @toolchains)
    expect(plan.java_version).to eq("21")
    expect(plan.toolchain_path).to end_with("11.12.1")
  end

  it "maps legacy Mendix versions to their minimum Java families" do
    toolchain = described_class::Toolchain.allocate
    expectations = {
      "5.21.4" => "7", "7.5.0" => "8", "8.18.0" => "11",
      "9.17.0" => "11", "9.18.16" => "17", "10.6.6" => "11",
      "10.6.7" => "17", "10.21.0" => "21", "11.12.1" => "21"
    }
    expectations.each do |version, java|
      expect(toolchain.send(:fallback_java, version)).to eq(java)
    end

    expect(described_class::Toolchain.new(@path, mendix_home: @toolchains).plan.java_version)
      .to eq("21")
  end

  it "builds Docker commands with read-only source and disposable workspaces" do
    plan = described_class::Plan.new(
      "11.12.1", "21", File.join(@toolchains, "11.12.1"),
      "/tools/mx", "/tools/mxbuild", "jdk", "jre", "builder:image", "runtime:image"
    )
    workspace = described_class::DockerWorkspace.new(@path, plan, workspace_size: "4g")
    build = workspace.builder_command("/tmp/tests.rb")
    runtime = workspace.runtime_command(
      package_volume: "mxrb-package", http_port: 18_080, admin_port: 18_090
    )

    expect(build.join(" ")).to include(
      "readonly", "/workspace:exec,size=4g", "mxrb-mendix-11-12-1-cache",
      "source=mxrb-functional-package,target=/output"
    )
    expect(build).to include("builder:image")
    expect(runtime.join(" ")).to include(
      "source=mxrb-package", "18080:8080", "18090:8090", "runtime:image"
    )
    expect(workspace.send(:bind_mount, "/source", "/target", readonly: false))
      .to eq("type=bind,source=/source,target=/target")
  end

  it "ignores missing and invalid Java settings before using the fallback" do
    toolchain = described_class::Toolchain.allocate
    project = double
    allow(project).to receive(:all_units).and_return(
      [{ "id" => "without-model" }, { "id" => "invalid-java" }]
    )
    allow(project).to receive(:parse_bson) do |raw|
      if raw["id"] == "without-model"
        { "$Type" => "Settings$ProjectSettings", "Settings" => [2] }
      else
        {
          "$Type" => "Settings$ProjectSettings",
          "Settings" => [2, {
            "$Type" => "Settings$ModelSettings", "JavaMajorVersion" => "invalid"
          }]
        }
      end
    end

    expect(toolchain.send(:configured_java, project)).to be_nil
  end
end

RSpec.describe Mxrb::Runtime::Executor do
  Status = Struct.new(:success?)

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      @project = File.join(dir, "Demo.mpr")
      File.write(@project, "mpr")
      @java = File.join(dir, "java")
      FileUtils.mkdir_p(File.join(@java, "bin"))
      File.write(File.join(@java, "bin", "java"), "#!/bin/sh\n")
      FileUtils.chmod(0o755, File.join(@java, "bin", "java"))
      @mx = File.join(dir, "mx")
      @mxbuild = File.join(dir, "mxbuild")
      [@mx, @mxbuild].each do |path|
        File.write(path, "#!/bin/sh\n")
        FileUtils.chmod(0o755, path)
      end
      @plan = Mxrb::Runtime::Plan.new(
        "11.12.1", "21", dir, @mx, @mxbuild,
        "jdk", "jre", "builder", "runtime"
      )
      @definition = Mxrb::Functional::Definition.new([
        Mxrb::Functional::TestCase.new("works", "Demo.Noop", {}.freeze, 1.0)
      ].freeze)
      @executor = described_class.new(
        @project, @definition, plan: @plan, java_home: @java
      )
      example.run
    end
  end

  it "runs the disposable pipeline and returns a Ruby execution result" do
    instrumenter = instance_double(Mxrb::Functional::Instrumenter, instrument!: true)
    allow(Mxrb::Functional::Instrumenter).to receive(:new).and_return(instrumenter)
    allow(@executor).to receive(:copy_project).and_return(@project)
    allow(@executor).to receive(:check).and_return("checked")
    allow(@executor).to receive(:build).and_return("runtime.zip")
    allow(@executor).to receive(:build_output).and_return("built")
    allow(@executor).to receive(:start_runtime)
      .and_return("[MXRB_TEST] PASS works\n[MXRB_TEST] DONE\n")

    execution = @executor.run
    expect(execution).to be_passed
    expect(execution.check_output).to eq("checked")
    expect(execution.build_output).to eq("built")

    allow(@executor).to receive(:start_runtime).and_return("runtime ended")
    expect { @executor.run }.to raise_error(Mxrb::FunctionalTestError, /before/)
  end

  it "validates the official toolchain and Java home" do
    expect { @executor.send(:validate_environment!) }.not_to raise_error

    missing_plan = @plan.with(mx_path: File.join(@dir, "missing"))
    executor = described_class.new(
      @project, @definition, plan: missing_plan, java_home: @java
    )
    expect { executor.send(:validate_environment!) }
      .to raise_error(Mxrb::ToolchainError, /toolchain/)

    executor = described_class.new(
      @project, @definition, plan: @plan, java_home: nil
    )
    expect { executor.send(:validate_environment!) }
      .to raise_error(Mxrb::ToolchainError, /JAVA_HOME/)
  end

  it "copies the complete project directory into the disposable workspace" do
    File.write(File.join(@dir, ".hidden"), "kept")
    root = Dir.mktmpdir(dir: @dir)
    copied = @executor.send(:copy_project, root)

    expect(File.read(copied)).to eq("mpr")
    expect(File.read(File.join(root, "project", ".hidden"))).to eq("kept")
  end

  it "accepts warning-only checks and reports malformed or error diagnostics" do
    report_root = Dir.mktmpdir(dir: @dir)
    report = File.join(report_root, "mx-check.json")
    allow(@executor).to receive(:capture).and_return(["ok", Status.new(true)])
    expect(@executor.send(:check, @project, report_root)).to eq("ok")

    allow(@executor).to receive(:capture).and_return(["warnings", Status.new(false)])
    File.write(report, JSON.generate([{ "severity" => "warning" }]))
    expect(@executor.send(:check, @project, report_root)).to eq("warnings")

    File.write(
      report,
      JSON.generate([{ "children" => [
        { "severity" => "error", "Message" => "broken" },
        { "severity" => "error", "detail" => "fallback" }
      ] }])
    )
    expect { @executor.send(:check, @project, report_root) }
      .to raise_error(Mxrb::FunctionalTestError, /2 error.*broken/)

    File.write(report, "{")
    expect(@executor.send(:check_errors, report).first).to match(/invalid/)
    FileUtils.rm_f(report)
    expect(@executor.send(:check_errors, report)).to eq(
      ["mx check failed without a diagnostic report"]
    )
    expect(@executor.send(:diagnostic_errors, "text")).to eq([])
  end

  it "builds and unpacks portable applications with actionable failures" do
    allow(@executor).to receive(:capture).and_return(["built", Status.new(true)])
    package = @executor.send(:build, @project, @dir)
    expect(package).to end_with("runtime.zip")
    expect(@executor.send(:build_output, package)).to eq("built")

    allow(@executor).to receive(:capture).and_return(["bad build", Status.new(false)])
    expect { @executor.send(:build, @project, @dir) }
      .to raise_error(Mxrb::FunctionalTestError, /bad build/)

    allow(@executor).to receive(:capture).and_return(["unzipped", Status.new(true)])
    allow(@executor).to receive(:collect_runtime).and_return("runtime output")
    expect(@executor.send(:start_runtime, "runtime.zip", @dir)).to eq("runtime output")

    allow(@executor).to receive(:capture).and_return(["bad zip", Status.new(false)])
    expect { @executor.send(:start_runtime, "runtime.zip", @dir) }
      .to raise_error(Mxrb::FunctionalTestError, /bad zip/)
  end

  it "collects the runtime protocol, streams it, and enforces its deadline" do
    script = File.join(@dir, "runtime")
    File.write(script, "#!/bin/sh\nprintf '[MXRB_TEST] DONE\\n'\nsleep 30\n")
    FileUtils.chmod(0o755, script)
    output = StringIO.new
    executor = described_class.new(
      @project, @definition, plan: @plan, java_home: @java, output: output
    )
    transcript = executor.send(:collect_runtime, {}, [script], @dir)
    expect(transcript).to include("DONE")
    expect(output.string).to eq(transcript)

    ticks = [0, 1_000_000]
    clock = ->(*) { ticks.shift || 1_000_000 }
    executor = described_class.new(
      @project, @definition, plan: @plan, java_home: @java, clock: clock
    )
    expect { executor.send(:collect_runtime, {}, [script], @dir) }
      .to raise_error(Mxrb::FunctionalTestError, /timed out/)
  end

  it "handles completed and disappearing runtime processes and simple clocks" do
    finished = instance_double(Process::Waiter, alive?: false, join: nil)
    expect(@executor.send(:terminate, finished)).to be_nil
    expect(@executor.send(:terminate, nil)).to be_nil

    thread = instance_double(Process::Waiter, alive?: true, pid: 123, join: nil)
    allow(Process).to receive(:kill).and_raise(Errno::ESRCH)
    expect(@executor.send(:terminate, thread)).to be_nil

    expect(@executor.send(:capture, "true").last).to be_success
    clock = -> { 42 }
    executor = described_class.new(
      @project, @definition, plan: @plan, java_home: @java, clock: clock
    )
    expect(executor.send(:monotonic_time)).to eq(42)
  end

  it "handles closed runtime streams, select timeouts, and forced termination" do
    stdin = instance_double(IO, close: nil)
    stream = instance_double(IO)
    thread = instance_double(Process::Waiter, alive?: false, join: nil)
    allow(Open3).to receive(:popen2e).and_yield(stdin, stream, thread)

    allow(IO).to receive(:select).and_return(nil)
    expect {
      @executor.send(:collect_runtime, {}, ["runtime"], @dir)
    }.to raise_error(Mxrb::FunctionalTestError, /timed out/)

    allow(IO).to receive(:select).and_return([stream])
    allow(stream).to receive(:gets).and_return(nil)
    expect(@executor.send(:collect_runtime, {}, ["runtime"], @dir)).to eq("")

    stubborn = instance_double(Process::Waiter, pid: 321, join: nil)
    allow(stubborn).to receive(:alive?).and_return(true, true)
    expect(Process).to receive(:kill).with("TERM", 321)
    expect(Process).to receive(:kill).with("KILL", 321)
    @executor.send(:terminate, stubborn)
  end

  it "collects successful runtime output without a streaming observer" do
    script = File.join(@dir, "quiet-runtime")
    File.write(script, "#!/bin/sh\nprintf '[MXRB_TEST] DONE\\n'\n")
    FileUtils.chmod(0o755, script)

    expect(@executor.send(:collect_runtime, {}, [script], @dir))
      .to include("[MXRB_TEST] DONE")
  end
end

RSpec.describe Mxrb::Runtime::DockerExecutor do
  DockerStatus = Struct.new(:success?)

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      @project = File.join(dir, "Demo.mpr")
      File.write(@project, "mpr")
      @mx = File.join(dir, "mx")
      @mxbuild = File.join(dir, "mxbuild")
      [@mx, @mxbuild].each do |path|
        File.write(path, "#!/bin/sh\n")
        FileUtils.chmod(0o755, path)
      end
      @plan = Mxrb::Runtime::Plan.new(
        "11.12.1", "21", dir, @mx, @mxbuild,
        "jdk", "jre", "builder", "runtime"
      )
      @definition = Mxrb::Functional::Definition.new([
        Mxrb::Functional::TestCase.new("works", "Demo.Noop", {}.freeze, 1.0)
      ].freeze)
      @executor = described_class.new(
        @project, @definition, plan: @plan, java_home: nil
      )
      example.run
    end
  end

  it "validates Docker and prepares a missing Java-family builder image" do
    allow(@executor).to receive(:capture).and_return(
      ["docker", DockerStatus.new(true)],
      ["missing", DockerStatus.new(false)],
      ["built", DockerStatus.new(true)]
    )
    expect { @executor.send(:validate_environment!) }.not_to raise_error

    allow(@executor).to receive(:capture).and_return(
      ["docker", DockerStatus.new(true)],
      ["present", DockerStatus.new(true)]
    )
    expect { @executor.send(:validate_environment!) }.not_to raise_error

    allow(@executor).to receive(:capture)
      .and_return(["missing daemon", DockerStatus.new(false)])
    expect { @executor.send(:validate_environment!) }
      .to raise_error(Mxrb::ToolchainError, /daemon/)
  end

  it "reports unavailable toolchains and builder image failures" do
    missing = @plan.with(mx_path: File.join(@dir, "missing"))
    executor = described_class.new(
      @project, @definition, plan: missing, java_home: nil
    )
    expect { executor.send(:validate_environment!) }
      .to raise_error(Mxrb::ToolchainError, /toolchain/)

    allow(@executor).to receive(:capture).and_return(
      ["missing", DockerStatus.new(false)],
      ["failed image", DockerStatus.new(false)]
    )
    expect { @executor.send(:ensure_builder_image) }
      .to raise_error(Mxrb::ToolchainError, /failed image/)
  end

  it "builds the portable package in a read-only project mount" do
    allow(@executor).to receive(:capture)
      .and_return(["built", DockerStatus.new(true)])
    package = @executor.send(:build, @project, @dir)
    expect(package).to eq(File.join(@dir, "runtime.zip"))
    expect(@executor.send(:build_output, package)).to eq("built")
    expect(@executor.send(:check, @project, @dir)).to include("Docker")

    allow(@executor).to receive(:capture)
      .and_return(["bad Docker build", DockerStatus.new(false)])
    expect { @executor.send(:build, @project, @dir) }
      .to raise_error(Mxrb::FunctionalTestError, /bad Docker build/)
  end

  it "starts the runtime as the host user and reports unpack failures" do
    allow(@executor).to receive(:capture)
      .and_return(["unzipped", DockerStatus.new(true)])
    expect(@executor).to receive(:collect_runtime) do |_environment, command, root|
      expect(command).to include(
        "--user", "#{Process.uid}:#{Process.gid}", "HOME=/tmp", "runtime"
      )
      expect(root).to eq(@dir)
      "runtime output"
    end
    expect(@executor.send(:start_runtime, "runtime.zip", @dir))
      .to eq("runtime output")

    allow(@executor).to receive(:capture)
      .and_return(["bad zip", DockerStatus.new(false)])
    expect { @executor.send(:start_runtime, "runtime.zip", @dir) }
      .to raise_error(Mxrb::FunctionalTestError, /bad zip/)

    expect(@executor.send(:bind_mount, "/source", "/target", readonly: true))
      .to end_with(",readonly")
  end
end
