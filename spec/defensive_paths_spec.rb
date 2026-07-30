# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "unsuppressed defensive paths" do
  it "covers GitHub comment validation, success and command failure" do
    result = Mxrb::Compare::Result.new(differences: [], changes: [])
    expect { Mxrb::Github::Annotator.new(result).post_pr_comment!(pr_number: 1) }
      .to raise_error(ArgumentError, /repo required/)
    annotator = Mxrb::Github::Annotator.new(result, repo: "org/repo")
    expect { annotator.post_pr_comment!(pr_number: nil) }
      .to raise_error(ArgumentError, /pr_number required/)

    success = double(success?: true)
    failure = double(success?: false)
    allow(Open3).to receive(:capture3).and_return(["ok\n", "", success], ["", "denied", failure])
    expect(annotator.post_pr_comment!(pr_number: 1)).to eq("ok")
    expect { annotator.post_pr_comment!(pr_number: 2) }.to raise_error(/denied/)
  end

  it "covers exporter fallbacks for non-hash page data" do
    exporter = Mxrb::Exporter.new("unused.mpr", Dir.mktmpdir)
    page = double(raw_document: nil)
    expect(exporter.send(:page_deep_structure, page)).to be_nil
  end

  it "covers marketplace no-op cleanup and dependency guards" do
    Dir.mktmpdir do |dir|
      installer = Mxrb::Marketplace::Installer.new(target: dir)
      expect(installer.send(:remove_from_lock, "Missing")).to be_nil
      expect(installer.send(:validate_no_dependents!, "Missing")).to be_nil

      FileUtils.mkdir_p(File.join(dir, ".mxrb"))
      lock_path = File.join(dir, ".mxrb", "modules.lock.json")
      File.write(lock_path, JSON.generate("modules" => { "Missing" => {} }))
      expect(installer.send(:validate_no_dependents!, "Missing")).to be_nil

      entry = Mxrb::Marketplace::Entry.new("remote", "1", "", "https://example.invalid/repo", nil)
      status = double(success?: true)
      allow(Open3).to receive(:capture2e).and_return(["", status])
      destination = installer.send(:materialize, entry.source, entry, dir)
      expect(destination).to end_with("repository")
      expect(Open3).to have_received(:capture2e).with(
        "git", "clone", "--depth", "1", entry.source, destination
      )
    end
  end

  it "removes marketplace temporary lock files after atomic rename failures" do
    Dir.mktmpdir do |dir|
      installer = Mxrb::Marketplace::Installer.new(target: dir)
      FileUtils.mkdir_p(File.join(dir, ".mxrb"))
      lock_path = File.join(dir, ".mxrb", "modules.lock.json")
      File.write(lock_path, JSON.generate("modules" => { "Demo" => {} }))
      temporary = "#{lock_path}.tmp-#{Process.pid}"
      allow(File).to receive(:rename).and_raise(Errno::EACCES)
      expect { installer.send(:remove_from_lock, "Demo") }.to raise_error(Errno::EACCES)
      expect(File).not_to exist(temporary)

      entry = Mxrb::Marketplace::Entry.new("demo", "1", "", "local", nil)
      expect do
        installer.send(:write_lock, entry, "Demo", "digest")
      end.to raise_error(Errno::EACCES)
      expect(File).not_to exist(temporary)
    end
  end

  it "cleans a retained marketplace backup after a failed replacement" do
    Dir.mktmpdir do |dir|
      destination = File.join(dir, "modules", "Demo")
      FileUtils.mkdir_p(destination)
      installer = Mxrb::Marketplace::Installer.new(target: dir)
      entry = Mxrb::Marketplace::Entry.new("demo", "1", "", "local", nil)
      allow(installer).to receive(:resolve).and_return([entry, dir])
      allow(installer).to receive(:materialize).and_return(dir)
      allow(installer).to receive(:load_manifest).and_return("module_name" => "Demo")
      allow(installer).to receive(:validate_mendix_version!)
      allow(installer).to receive(:validate_dependencies!)
      allow(installer).to receive(:package_files).and_return([])

      original_mv = FileUtils.method(:mv)
      allow(FileUtils).to receive(:mv) do |source, target|
        if source.include?("/staging/")
          FileUtils.mkdir_p(target)
          raise Errno::EACCES, target
        end
        original_mv.call(source, target)
      end

      expect do
        installer.send(
          :install_package, "demo", version: nil, replace: true,
          installed_module_name: "Demo"
        )
      end.to raise_error(Errno::EACCES)
      backup_root = File.join(dir, ".mxrb", "backup")
      expect(Dir.glob(File.join(backup_root, "*"))).to be_empty
    end
  end

  it "covers absent model locations, domain models and explicit empty parameters" do
    entity = Mxrb::Model::Entity.new
    entity.location = nil
    entity.access_rules = []
    entity.instance_variable_set(:@attributes, [])
    expect(entity.to_bson.fetch("location")).to eq("x" => 0, "y" => 0)

    mpr = double(
      parse_contents: { "$Type" => "Projects$Module", "Name" => "Empty" },
      units_by_containment: []
    )
    mod = Mxrb::Model::Module.new(
      { "UnitID" => "m", "ContainerID" => "m", "ContainmentName" => "Modules" }, mpr
    )
    expect(mod.associations).to be_empty

    flow_doc = {
      "$Type" => "Microflows$Microflow", "Name" => "EmptyParameters",
      "MicroflowParameterCollection" => {
        "Parameters" => Mxrb::IO::BsonCodec.build_array([])
      },
      "ObjectCollection" => { "Objects" => Mxrb::IO::BsonCodec.build_array([]) },
      "Flows" => Mxrb::IO::BsonCodec.build_array([])
    }
    flow_mpr = double(parse_contents: flow_doc)
    flow = Mxrb::Model::Microflow.new(
      { "UnitID" => "f", "ContainerID" => "m", "ContainmentName" => "Documents" },
      flow_mpr
    )
    expect(flow.parameters).to be_empty
  end

  it "covers missing extraction modules and movable units" do
    source = double(module_name: "Missing", qualified_name: "Missing.Flow", kind: :microflow, unit_id: "f")
    plan = Mxrb::Semantic::ExtractionPlan.allocate
    plan.instance_variable_set(:@project, double(modules: []))
    plan.instance_variable_set(:@source, source)
    expect { plan.send(:find_module_unit_id) }.to raise_error(ArgumentError, /cannot find module/)

    target = double(module_name: "Missing", qualified_name: "Missing.Folder", kind: :folder, unit_id: "d")
    project = double
    allow(project).to receive(:find_artifact) { |name| name == "Missing.Flow" ? source : target }
    allow(project).to receive(:raw_unit).with("f").and_return(nil)
    mover = Mxrb::Semantic::Mover.new(project)
    expect { mover.plan("Missing.Flow", to: "Missing.Folder") }
      .to raise_error(ArgumentError, /not a movable unit/)
  end

  it "covers malformed caller and callee flow graphs" do
    source = double(qualified_name: "App.Source", kind: :microflow, unit_id: "source")
    called = double(qualified_name: "App.Called", kind: :microflow, unit_id: "called")
    call = {
      "$ID" => "call", "$Type" => "Microflows$ActionActivity",
      "Action" => { "MicroflowCall" => { "Microflow" => "App.Called" } }
    }
    event = ->(id, type) { { "$ID" => id, "$Type" => type } }
    activity = { "$ID" => "activity", "$Type" => "Microflows$ActionActivity" }
    entry = { "$ID" => "entry", "OriginPointer" => "start", "DestinationPointer" => "call" }
    exit_flow = { "$ID" => "exit", "OriginPointer" => "call", "DestinationPointer" => "end" }
    valid_called_objects = [
      event.call("callee-start", "Microflows$StartEvent"),
      activity,
      event.call("callee-end", "Microflows$EndEvent")
    ]
    valid_called_flows = [
      { "$ID" => "first", "OriginPointer" => "callee-start", "DestinationPointer" => "activity" },
      { "$ID" => "last", "OriginPointer" => "activity", "DestinationPointer" => "callee-end" }
    ]

    scenarios = [
      [[exit_flow], valid_called_objects, valid_called_flows, /entry flow/],
      [[entry], valid_called_objects, valid_called_flows, /exit flow/],
      [[entry, exit_flow], valid_called_objects[0, 2], valid_called_flows, /no end event/],
      [[entry, exit_flow], [valid_called_objects.first, valid_called_objects.last], valid_called_flows, /no activities/],
      [[entry, exit_flow], valid_called_objects, [valid_called_flows.last], /first activity/],
      [[entry, exit_flow], valid_called_objects, [valid_called_flows.first], /last activity/]
    ]

    scenarios.each do |source_flows, called_objects, called_flows, error|
      source_doc = {
        "ObjectCollection" => { "Objects" => Mxrb::IO::BsonCodec.build_array([call]) },
        "Flows" => Mxrb::IO::BsonCodec.build_array(source_flows)
      }
      called_doc = {
        "ObjectCollection" => { "Objects" => Mxrb::IO::BsonCodec.build_array(called_objects) },
        "Flows" => Mxrb::IO::BsonCodec.build_array(called_flows)
      }
      project = double
      allow(project).to receive(:find_artifact) { |name| name == "App.Source" ? source : called }
      allow(project).to receive(:raw_unit) { |id| id == "source" ? source_doc : called_doc }
      allow(project).to receive(:parse_bson) { _1 }

      expect { Mxrb::Semantic::Inliner.new(project).plan("App.Source", calling: "App.Called") }
        .to raise_error(ArgumentError, error)
    end
  end

  it "closes only resources that were opened during writer failures" do
    writer = Mxrb::Writer.new("/tmp/unused.mpr", version: "10.18.0", modules: [])
    allow(writer).to receive(:create_project!).and_raise("create failed")
    expect { writer.write! }.to raise_error("create failed")

    creator = Mxrb::Writer.new("/tmp/also-unused.mpr", version: "10.18.0", modules: [])
    allow(SQLite3::Database).to receive(:new).and_raise(SQLite3::CantOpenException)
    expect { creator.send(:create_project!) }.to raise_error(SQLite3::CantOpenException)
  end

  it "covers SQLite backup and cache-read fallbacks without hiding them" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "source.mpr")
      destination = File.join(dir, "backup.mpr")
      File.write(source, "database bytes")
      db = double
      allow(db).to receive(:execute).with("VACUUM INTO ?", [destination])
        .and_raise(SQLite3::SQLException)
      allow(db).to receive(:execute).with("PRAGMA wal_checkpoint(FULL)")

      mpr = Mxrb::IO::MprFile.allocate
      mpr.instance_variable_set(:@readonly, false)
      mpr.instance_variable_set(:@path, source)
      mpr.instance_variable_set(:@db, db)
      mpr.backup!(destination)
      expect(File.read(destination)).to eq("database bytes")

      allow(mpr).to receive(:tables).and_return(["_MxrbIndexCache"])
      allow(db).to receive(:get_first_value).and_raise(SQLite3::SQLException)
      expect(mpr.read_index_cache("fingerprint")).to be_nil
    end
  end
end
