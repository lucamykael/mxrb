# frozen_string_literal: true

require "spec_helper"
require "sqlite3"
require "tmpdir"

RSpec.describe Mxrb do
  # ── Fixtures: create a minimal in-memory .mpr for testing ────────────────
  def make_mpr(path)
    db = SQLite3::Database.new(path)
    db.execute("CREATE TABLE _MetaData (MetaDataID INTEGER, MendixVersion TEXT, ProjectID TEXT, ProjectName TEXT)")
    db.execute("CREATE TABLE UnitType   (UnitTypeID INTEGER PRIMARY KEY AUTOINCREMENT, Name TEXT UNIQUE)")
    db.execute("CREATE TABLE Unit       (UnitID INTEGER PRIMARY KEY, ContainerID INTEGER, ContainmentName TEXT, UnitTypeID INTEGER, ContentsHash TEXT, Contents BLOB)")
    db.execute("INSERT INTO _MetaData VALUES (1, '10.18.0', 'test-uuid', 'TestProject')")
    db.execute("INSERT INTO UnitType (Name) VALUES ('Mxmodels.Projects.Module')")
    db.execute("INSERT INTO Unit VALUES (1, 0, 'MyModule', 1, 'abc', 'MyModule')")
    db.close
  end

  around do |ex|
    Dir.mktmpdir do |dir|
      @mpr_path = File.join(dir, "test.mpr")
      make_mpr(@mpr_path)
      ex.run
    end
  end

  describe ".open" do
    it "yields a Project" do
      described_class.open(@mpr_path) do |p|
        expect(p).to be_a(Mxrb::Model::Project)
      end
    end

    it "reads project name and version" do
      described_class.open(@mpr_path) do |p|
        expect(p.name).to eq("TestProject")
        expect(p.mendix_version).to eq("10.18.0")
      end
    end

    it "lists tables" do
      described_class.open(@mpr_path) do |p|
        expect(p.tables).to include("Unit", "_MetaData", "UnitType")
      end
    end

    it "lists unit types" do
      described_class.open(@mpr_path) do |p|
        expect(p.unit_types).to include("Mxmodels.Projects.Module")
      end
    end

    it "returns modules" do
      described_class.open(@mpr_path) do |p|
        expect(p.modules).not_to be_empty
      end
    end
  end

  describe ".define" do
    it "runs the DSL without errors" do
      expect {
        described_class.define(File.join(Dir.tmpdir, "new.mpr")) do
          mendix_version "10.18.0"
          self.module :MyModule do
            entity :Customer do
              string  :Name, required: true
              integer :Age
            end
            page :CustomerList do
              layout "Atlas_Default"
            end
          end
        end
      }.not_to raise_error
    end
  end

  describe "Dsl::Builder" do
    it "exposes the definition as a hash" do
      builder = Mxrb::Dsl::Builder.new("x.mpr")
      builder.instance_eval do
        mendix_version "10.0.0"
        self.module :Foo do
          entity :Bar do
            string :Name
          end
        end
      end
      defn = builder.definition
      expect(defn[:version]).to eq("10.0.0")
      expect(defn[:modules].first[:name]).to eq("Foo")
      expect(defn[:modules].first[:entities].first[:name]).to eq("Bar")
    end
  end
end
