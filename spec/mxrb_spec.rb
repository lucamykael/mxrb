# frozen_string_literal: true

require "spec_helper"
require "sqlite3"
require "bson"
require "tmpdir"
require "securerandom"

RSpec.describe Mxrb do
  # ── Fixture helpers ──────────────────────────────────────────────────────
  def uuid_blob(uuid = SecureRandom.uuid)
    Mxrb::IO::BsonCodec.uuid_to_blob(uuid)
  end

  def make_bson(doc)
    buf = BSON::ByteBuffer.new
    BSON::Document.new(doc).to_bson(buf)
    buf.get_bytes(buf.length)
  end

  def contents_hash(bytes)
    require "digest"; require "base64"
    Base64.strict_encode64(Digest::SHA256.digest(bytes))
  end

  # Build a minimal v1 .mpr with one module + one entity embedded in DomainModel
  def make_mpr(path)
    project_uuid = SecureRandom.uuid
    module_uuid  = SecureRandom.uuid
    dm_uuid      = SecureRandom.uuid

    db = SQLite3::Database.new(path)
    db.execute(<<~SQL)
      CREATE TABLE _MetaData (
        _ProductVersion TEXT, _BuildVersion TEXT, _SchemaHash TEXT
      )
    SQL
    db.execute(<<~SQL)
      CREATE TABLE Unit (
        UnitID BLOB, ContainerID BLOB, ContainmentName TEXT,
        TreeConflict LONG, ContentsHash TEXT, ContentsConflict TEXT, Contents BLOB,
        PRIMARY KEY (UnitID)
      )
    SQL
    db.execute("INSERT INTO _MetaData VALUES ('10.18.0', '123', 'fakehash')")

    # Root project unit (UnitID == ContainerID)
    proj_blob = make_bson({ "$Type" => "Projects$Project", "Name" => "TestProject" })
    pb = uuid_blob(project_uuid)
    db.execute("INSERT INTO Unit VALUES (?,?,?,0,?,NULL,?)", [pb, pb, "ProjectDocuments", contents_hash(proj_blob), proj_blob])

    # Module unit
    mod_blob = make_bson({ "$Type" => "Projects$Module", "Name" => "MyModule", "SortIndex" => 0 })
    db.execute("INSERT INTO Unit VALUES (?,?,?,0,?,NULL,?)", [uuid_blob(module_uuid), pb, "Modules", contents_hash(mod_blob), mod_blob])

    # DomainModel unit (with one entity embedded)
    entity_uuid = SecureRandom.uuid
    attr_uuid   = SecureRandom.uuid
    dm_blob = make_bson({
      "$Type"        => "DomainModels$DomainModel",
      "documentation" => "",
      "entities"     => [3, {
        "$ID"           => entity_uuid,
        "$Type"         => "DomainModels$Entity",
        "$QualifiedName" => "MyModule.Customer",
        "name"          => "Customer",
        "documentation" => "",
        "persistable"   => true,
        "attributes"    => [3, {
          "$ID"   => attr_uuid,
          "$Type" => "DomainModels$Attribute",
          "name"  => "Name",
          "type"  => { "$Type" => "DomainModels$StringAttributeType" },
          "value" => { "$Type" => "DomainModels$StoredValue", "defaultValue" => "" },
        }],
        "validationRules" => [3],
        "eventHandlers"   => [3],
        "indexes"         => [3],
        "accessRules"     => [3],
        "generalization"  => { "$Type" => "DomainModels$NoGeneralization", "persistable" => true },
      }],
      "associations"      => [3],
      "crossAssociations" => [3],
      "annotations"       => [3],
    })
    db.execute("INSERT INTO Unit VALUES (?,?,?,0,?,NULL,?)", [uuid_blob(dm_uuid), uuid_blob(module_uuid), "DomainModel", contents_hash(dm_blob), dm_blob])

    db.close
    { project_uuid: project_uuid, module_uuid: module_uuid, dm_uuid: dm_uuid }
  end

  around do |ex|
    Dir.mktmpdir do |dir|
      @mpr_path = File.join(dir, "test.mpr")
      @uuids    = make_mpr(@mpr_path)
      ex.run
    end
  end

  # ── BsonCodec ────────────────────────────────────────────────────────────
  describe Mxrb::IO::BsonCodec do
    let(:uuid) { "c67c5271-da7d-45f1-81df-ceb6946b8abe" }

    it "round-trips UUID through blob" do
      blob = described_class.uuid_to_blob(uuid)
      expect(blob.bytesize).to eq(16)
      expect(described_class.blob_to_uuid(blob)).to eq(uuid)
    end

    it "extracts $ID from string" do
      expect(described_class.extract_id(uuid)).to eq(uuid)
    end

    it "extracts $ID from BSON::Binary" do
      blob   = described_class.uuid_to_blob(uuid)
      binary = BSON::Binary.new(blob)
      expect(described_class.extract_id(binary)).to eq(uuid)
    end

    it "parses arrays with marker" do
      result = described_class.parse_array([3, "a", "b"])
      expect(result[:marker]).to eq(3)
      expect(result[:items]).to eq(["a", "b"])
    end

    it "returns empty items for empty array" do
      expect(described_class.parse_array([3])[:items]).to eq([])
      expect(described_class.parse_array(nil)[:items]).to eq([])
    end

    it "computes contentsHash as Base64(SHA256(bytes))" do
      bytes = "hello"
      hash  = described_class.contents_hash(bytes)
      expected = Base64.strict_encode64(Digest::SHA256.digest(bytes))
      expect(hash).to eq(expected)
    end

    it "round-trips BSON parse/serialize" do
      doc   = { "$Type" => "Test", "name" => "foo", "count" => 42 }
      bytes = described_class.serialize(doc)
      back  = described_class.parse(bytes)
      expect(back["$Type"]).to eq("Test")
      expect(back["name"]).to eq("foo")
      expect(back["count"]).to eq(42)
    end
  end

  # ── MprFile ──────────────────────────────────────────────────────────────
  describe Mxrb::IO::MprFile do
    subject(:mpr) { described_class.open(@mpr_path) }
    after { mpr.close }

    it "detects v1 format" do
      expect(mpr.format_version).to eq(:v1)
    end

    it "reads mendix version" do
      expect(mpr.mendix_version).to eq("10.18.0")
    end

    it "lists tables" do
      expect(mpr.tables).to include("Unit", "_MetaData")
    end

    it "finds units by containment name" do
      units = mpr.units_by_containment("Modules")
      expect(units).not_to be_empty
    end

    it "finds root unit" do
      expect(mpr.root_unit).not_to be_nil
    end

    it "finds children by parent UUID" do
      children = mpr.children_of(@uuids[:project_uuid])
      expect(children).not_to be_empty
    end
  end

  # ── Project ──────────────────────────────────────────────────────────────
  describe Mxrb::Model::Project do
    subject(:proj) { described_class.open(@mpr_path) }
    after { proj.close }

    it "returns modules" do
      expect(proj.modules).not_to be_empty
    end

    it "returns module name from BSON" do
      expect(proj.modules.first.name).to eq("MyModule")
    end

    it "returns entities via modules" do
      entities = proj.entities
      expect(entities).not_to be_empty
      expect(entities.first.name).to eq("Customer")
    end

    it "returns attributes embedded in entity" do
      entity = proj.entities.first
      expect(entity.attributes).not_to be_empty
      expect(entity.attributes.first.name).to eq("Name")
      expect(entity.attributes.first.type).to eq(:string)
    end
  end

  # ── DSL ──────────────────────────────────────────────────────────────────
  describe Mxrb::Dsl::Builder do
    it "builds a definition hash from the DSL" do
      builder = described_class.new("x.mpr")
      builder.instance_eval do
        mendix_version "10.18.0"
        self.module :Orders do
          entity :Order do
            string   :Description
            datetime :OrderDate
            decimal  :Total, default: 0
          end
          page :OrderList do
            layout "Atlas_Default"
            title  "Orders"
          end
          microflow :CreateOrder do
            parameter :NewOrder, type: :Order
            return_type :Order
          end
        end
      end

      defn = builder.definition
      expect(defn[:version]).to eq("10.18.0")
      mod = defn[:modules].first
      expect(mod[:name]).to eq("Orders")
      expect(mod[:entities].first[:attributes].size).to eq(3)
      expect(mod[:pages].first[:layout]).to eq("Atlas_Default")
      expect(mod[:microflows].first[:return_type]).to eq("Order")
    end
  end
end
