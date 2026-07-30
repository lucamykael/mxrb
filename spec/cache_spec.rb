# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe "Semantic index cache management" do
  def build_project(path)
    Mxrb.define(path) do
      mendix_version "10.18.0"
      self.module(:Inventory) do
        entity :Product do
          string :Name
        end
        microflow :List do
          retrieve_objects "Inventory.Product", as: :products
        end
      end
    end
  end

  it "reports, warms, replaces, and clears cache entries" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cache.mpr")
      build_project(path)

      Mxrb.open(path) do |project|
        info = project.semantic_cache_info
        expect(info).to include(
          present: false, entries: 0, bytes: 0, hit: false
        )
        expect(info[:current_fingerprint]).to match(/\A[0-9a-f]{64}\z/)
      end

      first_fingerprint = nil
      Mxrb.open(path, readonly: false) do |project|
        expect(project.clear_semantic_cache!).to eq(0)
        info = project.warm_semantic_cache!
        first_fingerprint = info.fetch(:current_fingerprint)
        expect(info).to include(present: true, entries: 1, hit: true)
        expect(info[:bytes]).to be_positive

        project.add_entity!("Inventory", name: :Category)
        refreshed = project.warm_semantic_cache!
        expect(refreshed).to include(present: true, entries: 1, hit: true)
        expect(refreshed[:current_fingerprint]).not_to eq(first_fingerprint)
        expect(refreshed[:fingerprints]).to eq([refreshed[:current_fingerprint]])

        expect(project.clear_semantic_cache!).to eq(1)
        expect(project.semantic_cache_info).to include(
          present: false, entries: 0, bytes: 0, hit: false
        )
        expect(project.clear_semantic_cache!).to eq(0)
      end
    end
  end

  it "rejects clear on read-only projects" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "readonly.mpr")
      build_project(path)

      Mxrb.open(path) do |project|
        expect { project.clear_semantic_cache! }
          .to raise_error(Mxrb::ReadOnlyError)
      end
    end
  end

  it "returns safe diagnostics when the cache table is incompatible" do
    file = Mxrb::IO::MprFile.allocate
    file.instance_variable_set(:@readonly, false)
    db = instance_double(SQLite3::Database)
    file.instance_variable_set(:@db, db)
    allow(file).to receive(:tables).and_return(["_MxrbIndexCache"])
    allow(db).to receive(:execute).and_raise(SQLite3::SQLException, "bad schema")

    expect(file.index_cache_info(current_fingerprint: "current")).to include(
      present: false, entries: 0, bytes: 0, hit: false,
      current_fingerprint: "current"
    )
    expect(file.write_index_cache("fingerprint", "{}")).to be_nil
  end

  it "supports cache status, warm, and clear through the CLI" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "cli-cache.mpr")
      build_project(path)
      command = [RbConfig.ruby, File.expand_path("../bin/mxrb", __dir__), "cache"]

      stdout, stderr, status = Open3.capture3(
        *command, "status", path, "--json"
      )
      expect(status).to be_success
      expect(stderr).to eq("")
      expect(JSON.parse(stdout)).to include("present" => false, "hit" => false)

      stdout, _stderr, status = Open3.capture3(*command, "warm", path, "--json")
      expect(status).to be_success
      expect(JSON.parse(stdout)).to include("present" => true, "hit" => true)

      stdout, _stderr, status = Open3.capture3(*command, "clear", path)
      expect(status).to be_success
      expect(stdout).to include("Removed     : 1", "Current hit : false")
    end
  end
end
