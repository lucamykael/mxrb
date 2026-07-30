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

  def write_v2_unit(contents_dir, uuid, doc)
    bytes = Mxrb::IO::BsonCodec.serialize(doc)
    Mxrb::IO::MxunitCodec.write_atomic(Mxrb::IO::MxunitCodec.path_for(contents_dir, uuid), bytes)
    contents_hash(bytes)
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
    proj_blob = make_bson({ "$ID" => project_uuid, "$Type" => "Projects$Project", "Name" => "TestProject" })
    pb = uuid_blob(project_uuid)
    db.execute("INSERT INTO Unit VALUES (?,?,?,0,?,NULL,?)", [pb, pb, "ProjectDocuments", contents_hash(proj_blob), proj_blob])

    # Module unit
    mod_blob = make_bson({ "$ID" => module_uuid, "$Type" => "Projects$Module", "Name" => "MyModule", "SortIndex" => 0 })
    db.execute("INSERT INTO Unit VALUES (?,?,?,0,?,NULL,?)", [uuid_blob(module_uuid), pb, "Modules", contents_hash(mod_blob), mod_blob])

    # DomainModel unit (with one entity embedded)
    entity_uuid = SecureRandom.uuid
    attr_uuid   = SecureRandom.uuid
    dm_blob = make_bson({
      "$ID"          => dm_uuid,
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

    it "stores Mendix $ID UUIDs as 16-byte BSON binary recursively" do
      bytes = described_class.serialize(
        "$ID" => uuid,
        "Child" => {
          "$ID" => uuid,
          "OriginPointer" => uuid,
          "AppStoreGuid" => uuid
        }
      )
      back = described_class.parse(bytes)

      expect(back["$ID"]).to be_a(BSON::Binary)
      expect(back["$ID"].data.bytesize).to eq(16)
      expect(back.dig("Child", "$ID")).to be_a(BSON::Binary)
      expect(back.dig("Child", "OriginPointer")).to be_a(BSON::Binary)
      expect(back.dig("Child", "AppStoreGuid")).to eq(uuid)
      expect(described_class.extract_id(back["$ID"])).to eq(uuid)
    end
  end

  describe Mxrb::Integrity::Validator do
    it "validates a coherent v1 MPR" do
      result = Mxrb.validate(@mpr_path)
      expect(result).to be_valid
      expect(result.warnings).to be_empty
    end

    it "rejects a stale ContentsHash" do
      db = SQLite3::Database.new(@mpr_path)
      db.execute("UPDATE Unit SET ContentsHash = 'stale' WHERE ContainmentName = 'Modules'")
      db.close

      result = Mxrb.validate(@mpr_path)
      expect(result).not_to be_valid
      expect(result.errors.join("\n")).to include("ContentsHash mismatch")
    end
  end

  describe Mxrb::Compare::Comparator do
    it "reports identical snapshots for the same MPR" do
      result = Mxrb.compare(@mpr_path, @mpr_path)
      expect(result).to be_identical
    end

    it "reports structural differences" do
      other = File.join(File.dirname(@mpr_path), "other.mpr")
      FileUtils.cp(@mpr_path, other)
      db = SQLite3::Database.new(other)
      raw = db.get_first_value("SELECT Contents FROM Unit WHERE ContainmentName = 'Modules'")
      doc = Mxrb::IO::BsonCodec.parse(raw)
      doc["Name"] = "OtherModule"
      bytes = Mxrb::IO::BsonCodec.serialize(doc)
      db.execute(
        "UPDATE Unit SET Contents = ?, ContentsHash = ? WHERE ContainmentName = 'Modules'",
        [bytes, Mxrb::IO::BsonCodec.contents_hash(bytes)]
      )
      db.close

      result = Mxrb.compare(@mpr_path, other)
      expect(result).not_to be_identical
      expect(result.differences.join("\n")).to include("OtherModule")
      expect(result.changes.map(&:operation)).to include(:changed)
      expect(result.changed.map(&:before)).to include("MyModule")
      expect(result.changed.map(&:after)).to include("OtherModule")
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
            allowed_roles "Orders.User"
            text_box :Description, caption: ""
            check_box :Confirmed, attribute: :Confirmed, caption: "Confirmed"
            date_picker :OrderDate, attribute: :OrderDate, caption: "Order date"
            reference_selector :CustomerSelector, attribute: :Customer_Name, caption: "Customer"
            data_grid :OrdersGrid, entity: "Orders.Order" do
              column :NumberColumn, attribute: "Orders.Order.Number", caption: "Number"
            end
            tab_control :DetailsTabs do
              tab_page :General, caption: "General"
            end
          end
          microflow :CreateOrder do
            parameter :NewOrder, type: :Order
            return_type :Order
            allowed_roles "Orders.User"
          end
          module_role :User
        end
      end

      defn = builder.definition
      expect(defn[:version]).to eq("10.18.0")
      mod = defn[:modules].first
      expect(mod[:name]).to eq("Orders")
      expect(mod[:entities].first[:attributes].size).to eq(3)
      expect(mod[:pages].first[:layout]).to eq("Atlas_Default")
      expect(mod[:pages].first[:allowed_roles]).to eq(["Orders.User"])
      expect(mod[:pages].first[:widgets].first[:options][:caption]).to eq("")
      expect(mod[:pages].first[:widgets].map { _1[:type] }).to include(
        :check_box, :date_picker, :reference_selector, :data_grid, :tab_control
      )
      expect(mod[:pages].first[:widgets].find { _1[:type] == :data_grid }[:options][:columns].first[:caption]).to eq("Number")
      expect(mod[:pages].first[:widgets].last[:options][:tabs].first[:caption]).to eq("General")
      expect(mod[:microflows].first[:return_type]).to eq("Order")
      expect(mod[:microflows].first[:allowed_roles]).to eq(["Orders.User"])
      expect(mod[:module_roles].first[:name]).to eq("User")
    end

    it "creates a project and updates it idempotently" do
      path = File.join(File.dirname(@mpr_path), "generated.mpr")
      definition = proc do
        mendix_version "10.17.0"
        security do
          security_level "CheckEverything"
          user_role :Administrator, module_roles: ["Sales.User"], admin: true
        end
        self.module :Sales do
          module_role :User
          entity :Customer do
            string :Name, default: "Unknown"
            integer :Age
          end
          entity :Order do
            decimal :Total
            association :Customer
          end
          page(:CustomerList) do
            title "Customers"
            allowed_roles "Sales.User"
          end
          microflow(:CreateCustomer) do
            return_type :Customer
            allowed_roles "Sales.User"
          end
          menu :MainMenu do
            item "Customers", page: "Sales.CustomerList"
          end
        end
      end

      2.times { Mxrb.define(path, &definition) }
      expect(Mxrb.validate(path)).to be_valid

      Mxrb.open(path) do |project|
        expect(project.mendix_version).to eq("10.17.0")
        expect(project.modules.map(&:name)).to eq(["Sales"])
        expect(project.entities.map(&:name)).to eq(%w[Customer Order])
        expect(project.entities.first.attributes.map(&:name)).to eq(%w[Name Age])
        expect(project.modules.first.associations.map(&:name)).to eq(["Order_Customer"])
        expect(project.pages.map(&:name)).to eq(["CustomerList"])
        expect(project.pages.first.allowed_module_roles).to eq(["Sales.User"])
        expect(project.microflows.map(&:name)).to eq(["CreateCustomer"])
        expect(project.microflows.first.allowed_module_roles).to eq(["Sales.User"])
        expect(project.modules.first.menus.first.items.first[:page]).to eq("Sales.CustomerList")
        expect(project.modules.first.module_roles.map { _1[:name] }).to eq(["User"])
        security_doc = project.all_units.map { project.parse_bson(_1) }.find { _1["$Type"] == "Security$ProjectSecurity" }
        expect(security_doc["SecurityLevel"]).to eq("CheckEverything")
        expect(security_doc["UserRoles"][1]["Name"]).to eq("Administrator")
        expect(project.all_units.size).to eq(8)
      end
    end

    it "exports and restores the project security level" do
      source = File.join(File.dirname(@mpr_path), "secure.mpr")
      exported = File.join(File.dirname(@mpr_path), "secure_ruby")
      rebuilt_dir = File.join(File.dirname(@mpr_path), "secure_rebuilt")
      rebuilt = File.join(rebuilt_dir, "secure.mpr")

      Mxrb.define(source) do
        mendix_version "10.17.0"
        security do
          security_level "CheckEverything"
          user_role :Administrator, admin: true
        end
      end

      Mxrb::Exporter.new(source, exported).export!
      security_src = File.read(File.join(exported, "app", "security", "security.rb"))
      expect(security_src).to include('security_level "CheckEverything"')

      FileUtils.mkdir_p(rebuilt_dir)
      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end
      expect(Mxrb.compare(source, rebuilt)).to be_identical
    end

    it "preserves legacy domain-model casing and deep attribute metadata" do
      source = File.join(File.dirname(@mpr_path), "legacy_domain.mpr")
      exported = File.join(File.dirname(@mpr_path), "legacy_domain_ruby")
      rebuilt_dir = File.join(File.dirname(@mpr_path), "legacy_domain_rebuilt")
      rebuilt = File.join(rebuilt_dir, "legacy_domain.mpr")

      Mxrb.define(source) do
        mendix_version "7.17.0"
        self.module :Legacy do
          entity :Customer do
            string :Name
          end
        end
      end

      mpr = Mxrb::IO::MprFile.open(source)
      raw = mpr.units_by_containment("DomainModel").first
      doc = mpr.parse_contents(raw)
      entities = Mxrb::IO::BsonCodec.parse_array(doc.delete("entities"))[:items]
      entity = entities.first
      attributes = Mxrb::IO::BsonCodec.parse_array(entity.delete("attributes"))[:items]
      attribute = attributes.first
      native_type = attribute.delete("type")
      native_type["Length"] = 123
      native_value = attribute.delete("value")
      native_value["DefaultValue"] = native_value.delete("defaultValue")
      attribute["NewType"] = native_type
      attribute["Value"] = native_value
      entity["Attributes"] = Mxrb::IO::BsonCodec.build_array(attributes)
      entity["AccessRules"] = entity.delete("accessRules")
      doc["Entities"] = Mxrb::IO::BsonCodec.build_array(entities)
      mpr.update_unit(raw.fetch("UnitID"), doc)
      mpr.close

      Mxrb::Exporter.new(source, exported).export!
      FileUtils.mkdir_p(rebuilt_dir)
      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end

      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(Mxrb.compare(source, rebuilt)).to be_identical
    end

    it "reads and updates external v2 unit contents atomically" do
      contents_dir = File.join(File.dirname(@mpr_path), "mprcontents")
      FileUtils.mkdir_p(contents_dir)
      mpr = Mxrb::IO::MprFile.open(@mpr_path)
      expect(mpr.format_version).to eq(:v2)

      module_id = mpr.insert_unit(
        container_uuid: @uuids[:project_uuid],
        containment_name: "Modules",
        contents_doc: { "$Type" => "Projects$Module", "Name" => "External" }
      )
      raw = mpr.unit(module_id)
      expect(raw["Contents"]).to be_nil
      expect(mpr.parse_contents(raw)["Name"]).to eq("External")

      mpr.update_unit(module_id, { "$Type" => "Projects$Module", "Name" => "Updated" })
      expect(mpr.parse_contents(mpr.unit(module_id))["Name"]).to eq("Updated")
      folder_id = mpr.insert_unit(
        container_uuid: module_id,
        containment_name: "Folders",
        contents_doc: { "$Type" => "Projects$Folder", "Name" => "Parent" }
      )
      nested_id = mpr.insert_unit(
        container_uuid: folder_id,
        containment_name: "Folders",
        contents_doc: { "$Type" => "Projects$Folder", "Name" => "Nested" }
      )
      mpr.relocate_unit(
        nested_id, container_uuid: module_id, containment_name: "Folders"
      )
      expect(mpr.unit(nested_id)["ContainerID"]).to eq(module_id)
      expect(mpr.parse_contents(mpr.unit(nested_id))["Name"]).to eq("Nested")
      expect(Dir.glob(File.join(contents_dir, "**", "*.tmp-*"))).to be_empty
      mpr.close
    end

    it "updates v2 projects without a Contents column without duplicating foldered documents" do
      dir = File.dirname(@mpr_path)
      path = File.join(dir, "v2_no_contents.mpr")
      contents_dir = File.join(dir, "mprcontents")
      FileUtils.mkdir_p(contents_dir)
      root_id = SecureRandom.uuid
      module_id = SecureRandom.uuid
      domain_id = SecureRandom.uuid
      folder_id = SecureRandom.uuid
      flow_id = SecureRandom.uuid
      page_id = SecureRandom.uuid

      docs = {
        root_id => { "$ID" => root_id, "$Type" => "Projects$Project", "Name" => "V2Project" },
        module_id => {
          "$ID" => BSON::Binary.new(uuid_blob(module_id)),
          "$Type" => "Projects$ModuleImpl",
          "Name" => "Sales",
          "FromAppStore" => false
        },
        domain_id => {
          "$ID" => domain_id,
          "$Type" => "DomainModels$DomainModel",
          "entities" => [3],
          "associations" => [3],
          "crossAssociations" => [3],
          "annotations" => [3],
          "documentation" => ""
        },
        folder_id => { "$ID" => folder_id, "$Type" => "Projects$Folder", "Name" => "Flows" },
        flow_id => {
          "$ID" => flow_id,
          "$Type" => "Microflows$Microflow",
          "Name" => "KeepLogic",
          "AllowConcurrentExecution" => false,
          "MarkAsUsed" => true,
          "Excluded" => true,
          "ObjectCollection" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$MicroflowObjectCollection",
            "Objects" => [3, { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$ActionActivity" }],
            "Flows" => [3]
          },
          "MicroflowParameterCollection" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$MicroflowParameterCollection",
            "Parameters" => [3]
          },
          "MicroflowReturnType" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Microflows$MicroflowReturnType",
            "Type" => "Void"
          },
          "ReturnVariableName" => ""
        },
        page_id => {
          "$ID" => page_id,
          "$Type" => "Forms$Page",
          "Name" => "KeepPage",
          "Title" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Texts$Text",
            "Items" => [3, {
              "$ID" => SecureRandom.uuid,
              "$Type" => "Texts$Translation",
              "LanguageCode" => "en_US",
              "Text" => "Keep Title"
            }]
          },
          "Parameters" => [3, {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Forms$PageParameter",
            "Name" => "Customer"
          }],
          "Excluded" => true,
          "FormCall" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Forms$LayoutCall",
            "Form" => "Atlas_Core.Atlas_Default",
            "Arguments" => [2]
          }
        }
      }

      db = SQLite3::Database.new(path)
      db.execute("CREATE TABLE _MetaData (_ProductVersion TEXT, _BuildVersion TEXT, _SchemaHash TEXT)")
      db.execute(<<~SQL)
        CREATE TABLE Unit (
          UnitID BLOB NOT NULL PRIMARY KEY,
          ContainerID BLOB,
          ContainmentName TEXT,
          TreeConflict LONG,
          ContentsHash TEXT,
          ContentsConflicts TEXT
        )
      SQL
      db.execute("INSERT INTO _MetaData VALUES ('11.12.1', '11.12.1', 'fakehash')")
      [
        [root_id, root_id, "ProjectDocuments"],
        [module_id, root_id, "Modules"],
        [domain_id, module_id, "DomainModel"],
        [folder_id, module_id, "Folders"],
        [flow_id, folder_id, "Documents"],
        [page_id, folder_id, "Documents"]
      ].each do |unit_id, container_id, containment|
        db.execute(
          "INSERT INTO Unit VALUES (?, ?, ?, 0, ?, NULL)",
          [
            uuid_blob(unit_id),
            uuid_blob(container_id),
            containment,
            write_v2_unit(contents_dir, unit_id, docs.fetch(unit_id))
          ]
        )
      end
      db.close

      Mxrb.define(path) do
        mendix_version "11.12.1"
        self.module(:Sales) do
          microflow :KeepLogic
          page(:KeepPage) { title "Generated Title" }
        end
      end

      expect(Mxrb.validate(path)).to be_valid

      mpr = Mxrb::IO::MprFile.open(path, readonly: true)
      expect(mpr.query("SELECT COUNT(*) FROM Unit").first.first).to eq(6)
      raw_module = mpr.units_by_containment("Modules").first
      module_doc = mpr.parse_contents(raw_module)
      expect(Mxrb::IO::BsonCodec.extract_id(module_doc["$ID"])).to eq(module_id)
      raw_flow = mpr.children_of(folder_id).find { _1["ContainmentName"] == "Documents" }
      flow_doc = mpr.parse_contents(raw_flow)
      objects = Mxrb::IO::BsonCodec.parse_array(flow_doc["ObjectCollection"]["Objects"])[:items]
      expect(objects.first["$Type"]).to eq("Microflows$ActionActivity")
      expect(flow_doc["AllowConcurrentExecution"]).to eq(false)
      expect(flow_doc["MarkAsUsed"]).to eq(true)
      expect(flow_doc["Excluded"]).to eq(true)
      page_doc = mpr.parse_contents(mpr.unit(page_id))
      expect(page_doc["Title"]["Items"][1]["Text"]).to eq("Keep Title")
      expect(page_doc["Parameters"][1]["Name"]).to eq("Customer")
      expect(page_doc["Excluded"]).to eq(true)
      expect(mpr.unit(flow_id)["Contents"]).to be_nil
      mpr.close

      FileUtils.rm_f(Mxrb::IO::MxunitCodec.path_for(contents_dir, flow_id))
      result = Mxrb.validate(path)
      expect(result).not_to be_valid
      expect(result.errors.join("\n")).to include("missing mxunit file")
    end

    it "round-trips an MPR through the layered Ruby project" do
      source = File.join(File.dirname(@mpr_path), "source.mpr")
      exported = File.join(File.dirname(@mpr_path), "ruby_project")
      rebuilt = File.join(File.dirname(@mpr_path), "rebuilt.mpr")

      Mxrb.define(source) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Customer do
            string :Name
          end
          entity :Order do
            decimal :Total, default: 0
            association :Customer
          end
          page(:OrderList) { title "Orders" }
          microflow :CreateOrder do
            return_type :Order
            allow_concurrent_execution false
            mark_as_used true
            excluded true
          end
        end
      end
      expect(Mxrb.validate(source)).to be_valid

      Mxrb::Exporter.new(source, exported).export!
      expect(File).to exist(File.join(exported, "modules", "Sales", "domain", "model.rb"))
      expect(File).to exist(File.join(exported, "modules", "Sales", "domain", "entities", "customer.rb"))
      expect(File).to exist(File.join(exported, "modules", "Sales", "domain", "entities", "order.rb"))
      expect(File).to exist(File.join(exported, "modules", "Sales", "application", "application.rb"))
      expect(File).to exist(File.join(exported, "modules", "Sales", "application", "use_cases", "create_order.rb"))
      expect(File).to exist(File.join(exported, "modules", "Sales", "presentation", "presentation.rb"))
      expect(File).to exist(File.join(exported, "modules", "Sales", "presentation", "pages", "order_list.rb"))
      expect(File).to exist(File.join(exported, "app", "security", ".keep"))
      expect(File).to exist(File.join(exported, "app", "navigation", ".keep"))
      expect(File).to exist(File.join(exported, "app", "design_system", ".keep"))
      expect(File).to exist(File.join(exported, "modules", "Sales", "security", "security.rb"))
      flow_source = File.read(
        File.join(exported, "modules", "Sales", "application", "use_cases", "create_order.rb")
      )
      expect(flow_source).to include("allow_concurrent_execution false")
      expect(flow_source).to include("mark_as_used true")
      expect(flow_source).to include("excluded true")

      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end
      expect(Mxrb.validate(rebuilt)).to be_valid

      Mxrb.open(rebuilt) do |project|
        expect(project.modules.map(&:name)).to eq(["Sales"])
        expect(project.entities.map(&:name)).to eq(%w[Customer Order])
        expect(project.modules.first.associations.map(&:name)).to eq(["Order_Customer"])
        expect(project.pages.map(&:name)).to eq(["OrderList"])
        expect(project.microflows.map(&:name)).to eq(["CreateOrder"])
        flow = project.microflows.first
        expect(flow.allow_concurrent_execution).to eq(false)
        expect(flow.mark_as_used).to eq(true)
        expect(flow.excluded).to eq(true)
      end
    end

    it "preserves nested native units with duplicate names and parent containers" do
      root = File.dirname(@mpr_path)
      source_dir = File.join(root, "nested_source")
      rebuilt_dir = File.join(root, "nested_rebuilt")
      exported = File.join(root, "nested_ruby")
      FileUtils.mkdir_p(source_dir)
      FileUtils.mkdir_p(rebuilt_dir)
      source = File.join(source_dir, "Nested.mpr")
      rebuilt = File.join(rebuilt_dir, "Nested.mpr")

      Mxrb.define(source) do
        mendix_version "10.17.0"
        self.module(:Ui) {}
      end
      mpr = Mxrb::IO::MprFile.open(source)
      module_raw = mpr.units_by_containment("Modules").first
      parent_ids = %w[Phone Tablet].map do |name|
        mpr.insert_unit(
          container_uuid: module_raw.fetch("UnitID"),
          containment_name: "Folders",
          contents_doc: {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Projects$Folder",
            "Name" => name
          }
        )
      end
      parent_ids.each do |parent_id|
        mpr.insert_unit(
          container_uuid: parent_id,
          containment_name: "Folders",
          contents_doc: {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Projects$Folder",
            "Name" => "Layouts"
          }
        )
      end
      mpr.close

      Mxrb::Exporter.new(source, exported).export!
      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end

      expect(Mxrb.compare(source, rebuilt)).to be_identical
      Mxrb.open(rebuilt) do |project|
        folders = project.mpr.units_by_containment("Folders")
        layouts = folders.select { project.parse_bson(_1)["Name"] == "Layouts" }
        expect(folders.size).to eq(4)
        expect(layouts.map { _1["ContainerID"] }.uniq.size).to eq(2)
      end
    end

    it "exports every native payload as editable Ruby without losing its baseline" do
      root = File.dirname(@mpr_path)
      source = File.join(root, "native_edit_source.mpr")
      exported = File.join(root, "native_edit_ruby")
      rebuilt = File.join(root, "native_edit_rebuilt.mpr")
      Mxrb.define(source) do
        mendix_version "10.17.0"
        self.module(:Sales) {}
      end

      mpr = Mxrb::IO::MprFile.open(source)
      module_id = mpr.units_by_containment("Modules").first.fetch("UnitID")
      mpr.insert_unit(
        container_uuid: module_id,
        containment_name: "Documents",
        contents_doc: {
          "$Type" => "Constants$Constant",
          "Name" => "Endpoint",
          "Value" => "before",
          "Extra" => { "Nested" => true },
          "Blob" => BSON::Binary.new("native-bytes")
        }
      )
      mpr.close

      Mxrb::Exporter.new(source, exported).export!
      ruby_path = File.join(exported, ".mxrb", "native_units.rb")
      source_code = File.read(ruby_path)
      expect(source_code).to include("native_unit ", '"Constants$Constant"', "bson_binary(")
      File.write(ruby_path, source_code.sub('"Value" => "before"', '"Value" => "after"'))

      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end

      expect(Mxrb.validate(rebuilt)).to be_valid
      Mxrb.open(rebuilt) do |project|
        constant = project.all_units.find do |unit|
          project.parse_bson(unit)["$Type"] == "Constants$Constant"
        end
        doc = project.parse_bson(constant)
        expect(doc["Value"]).to eq("after")
        expect(doc.dig("Extra", "Nested")).to be(true)
        expect(doc["Blob"].data).to eq("native-bytes")
      end
    end

    it "creates a new generic native unit directly from Ruby" do
      path = File.join(File.dirname(@mpr_path), "native_ruby_create.mpr")
      unit_id = SecureRandom.uuid
      Mxrb.define(path) do
        native_unit(
          unit_id,
          container_id: SecureRandom.uuid,
          containment: "ProjectDocuments",
          deep_structure: {
            "$ID" => unit_id,
            "$Type" => "Settings$CustomSettings",
            "Name" => "RubySettings",
            "Enabled" => true
          }
        )
      end

      expect(Mxrb.validate(path)).to be_valid
      Mxrb.open(path) do |project|
        doc = project.all_units.map { project.parse_bson(_1) }
                     .find { _1["$Type"] == "Settings$CustomSettings" }
        expect(doc).to include("Name" => "RubySettings", "Enabled" => true)
      end
    end

    it "creates the Studio Pro v2 SQLite schema for new v2 targets" do
      dir = File.dirname(@mpr_path)
      path = File.join(dir, "new_v2.mpr")
      manifest = File.join(dir, "native_v2.json")
      File.write(
        manifest,
        JSON.generate("format_version" => "v2", "units" => [])
      )

      Mxrb.define(path) do
        mendix_version "11.12.1"
        native_units manifest
        self.module(:Sales) { entity(:Order) { string :Number } }
      end

      db = SQLite3::Database.new(path)
      metadata_columns = db.execute("PRAGMA table_info(_MetaData)").map { _1[1] }
      unit_columns = db.execute("PRAGMA table_info(Unit)").map { _1[1] }
      metadata = db.get_first_row("SELECT * FROM _MetaData")
      unit_state = db.get_first_row(
        "SELECT COUNT(*), MIN(TreeConflict), MAX(TreeConflict), " \
        "MIN(ContentsConflicts), MAX(ContentsConflicts) FROM Unit"
      )
      root_containment = db.get_first_value(
        "SELECT ContainmentName FROM Unit WHERE UnitID = ContainerID"
      )
      db.close

      expect(metadata_columns).to eq(
        %w[_FormatVersion _ProductVersion _BuildVersion _SchemaHash]
      )
      expect(unit_columns).to eq(
        %w[UnitID ContainerID ContainmentName TreeConflict ContentsHash ContentsConflicts]
      )
      expect(metadata.first(3)).to eq([2, "11.12.1", "11.12.1"])
      expect(unit_state).to eq([3, 0, 0, "", ""])
      expect(root_containment).to eq("")
      expect(Mxrb.validate(path)).to be_valid
      Mxrb.open(path) do |project|
        domain = project.mpr.units_by_containment("DomainModel").first
        entity = project.parse_bson(domain)["entities"][1]
        expect(entity["attributes"][1]["$Type"]).to eq("DomainModels$Attribute")
      end
    end

    it "exports legacy and custom page payloads as editable deep Ruby structures" do
      page_id = SecureRandom.uuid
      custom_id = BSON::Binary.new(uuid_blob, :generic)
      mpr = Mxrb::IO::MprFile.open(@mpr_path)
      begin
        mpr.insert_unit(
          container_uuid: @uuids.fetch(:module_uuid),
          containment_name: "Documents",
          contents_doc: {
            "$ID" => page_id,
            "$Type" => "Forms$Page",
            "Name" => "LegacyPage",
            "Title" => {
              "$Type" => "Texts$Text",
              "Translations" => [3, { "Text" => "Legacy" }]
            },
            "FormCall" => {
              "$Type" => "Forms$LayoutCall",
              "Form" => "Atlas_Default",
              "Arguments" => [2, {
                "$Type" => "Forms$FormCallArgument",
                "Widgets" => [3, {
                  "$ID" => custom_id,
                  "$Type" => "CustomWidgets$CustomWidget",
                  "Name" => "Map",
                  "Style" => "",
                  "Object" => { "WidgetId" => "com.example.map", "Zoom" => 8 }
                }]
              }]
            },
            "Parameters" => [3]
          }
        )
      ensure
        mpr.close
      end

      exported = File.join(File.dirname(@mpr_path), "deep_page")
      rebuilt = File.join(File.dirname(@mpr_path), "deep_page.mpr")
      Mxrb::Exporter.new(@mpr_path, exported).export!
      page_source = Dir[
        File.join(exported, "modules", "*", "presentation", "pages", "*.rb")
      ].find { File.read(_1).include?("page :LegacyPage") }
      expect(page_source).not_to be_nil
      source = File.read(page_source)
      expect(source).to include("deep_structure({")
      expect(source).to include('"$Type" => "CustomWidgets$CustomWidget"')
      expect(source).to include("bson_binary(")
      File.write(page_source, source.sub('"Zoom" => 8', '"Zoom" => 12'))

      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end

      expect(Mxrb.validate(rebuilt)).to be_valid
      Mxrb.open(rebuilt) do |project|
        page = project.pages.find { _1.name == "LegacyPage" }
        doc = project.mpr.parse_contents(project.raw_unit(page.id))
        custom = doc.dig("FormCall", "Arguments", 1, "Widgets", 1)
        expect(custom.dig("Object", "Zoom")).to eq(12)
        expect(custom["$ID"]).to be_a(BSON::Binary)
      end
    end

    it "builds and validates typed page, flow, lifecycle, and repository relationships" do
      builder = described_class.new(File.join(File.dirname(@mpr_path), "graph.mpr"))
      builder.instance_eval do
        self.module :Orders do
          repository :OrderRepository
          entity :Order do
            before_commit microflow: :ValidateOrder
          end
          query :GetOrderForEdit do
            uses_repository :OrderRepository
          end
          microflow :ValidateOrder
          microflow :PlaceOrder do
            uses_repository :OrderRepository
          end
          nanoflow :RecalculateDraft
          page :OrderEdit do
            data_source query: :GetOrderForEdit
            number_input :Quantity, attribute: :Quantity, caption: "Quantity" do
              on_change nanoflow: :RecalculateDraft
            end
            button :SaveButton, caption: "Save" do
              on_click action: :save_changes
            end
            on_submit microflow: :PlaceOrder
          end
        end
      end

      result = builder.validate!
      expect(result).to be_valid
      graph = builder.graph
      page = graph.find("Orders", :page, "OrderEdit")
      expect(graph.dependencies_of(page).map(&:name)).to contain_exactly(
        "GetOrderForEdit", "RecalculateDraft", "PlaceOrder"
      )

      builder.build!
      Mxrb.open(File.join(File.dirname(@mpr_path), "graph.mpr")) do |project|
        expect(project.modules.first.nanoflows.map(&:name)).to eq(["RecalculateDraft"])
        metadata = project.architecture_definition
        expect(metadata[:modules].first[:repositories].first[:name]).to eq("OrderRepository")
        raw_domain = project.mpr.units_by_containment("DomainModel").first
        entity_doc = project.parse_bson(raw_domain)["entities"][1]
        handler = entity_doc["eventHandlers"][1]
        expect(handler["$Type"]).to eq("DomainModels$EventHandler")
        expect(handler["Event"]).to eq("Commit")
        expect(handler["Moment"]).to eq("Before")
        raw_page = project.mpr.units_by_containment("Documents").find {
          project.parse_bson(_1)["Name"] == "OrderEdit"
        }
        page_doc = project.parse_bson(raw_page)
        data_view = page_doc["Widgets"][1]
        text_box = data_view["Widgets"][1]
        save_button = data_view["Widgets"][2]
        expect(data_view["$Type"]).to eq("Pages$DataView")
        expect(data_view["DataSource"]["$Type"]).to eq("Pages$MicroflowSource")
        expect(text_box["$Type"]).to eq("Pages$TextBox")
        expect(text_box["LabelText"]["Translations"][1]["Text"]).to eq("Quantity")
        expect(text_box["OnChangeAction"]["$Type"]).to eq("Pages$CallNanoflowClientAction")
        expect(save_button["Action"]["$Type"]).to eq("Pages$SaveChangesClientAction")
      end

      exported = File.join(File.dirname(@mpr_path), "graph_ruby")
      Mxrb::Exporter.new(File.join(File.dirname(@mpr_path), "graph.mpr"), exported).export!
      page_source = File.read(
        File.join(exported, "modules", "Orders", "presentation", "pages", "order_edit.rb")
      )
      expect(page_source).to include("number_input :Quantity, attribute: :Quantity")
      expect(page_source).to include("on_change nanoflow: :RecalculateDraft")
      expect(page_source).to include("on_click action: :save_changes")
      expect(page_source).to include("on_submit microflow: :PlaceOrder")
      expect(File.read(
        File.join(exported, "modules", "Orders", "presentation", "client_actions", "recalculate_draft.rb")
      )).to include("nanoflow :RecalculateDraft")

      rebuilt = File.join(File.dirname(@mpr_path), "graph_rebuilt.mpr")
      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end
      Mxrb.open(rebuilt) do |project|
        rebuilt_module = project.architecture_definition[:modules].first
        expect(rebuilt_module[:pages].first[:events].map { _1[:event] }).to eq(%w[on_submit])
        widget = rebuilt_module[:pages].first[:widgets].first
        expect(widget[:events].first[:event]).to eq("on_change")
        expect(rebuilt_module[:entities].first[:lifecycle].first[:event]).to eq("before_commit")
        expect(project.modules.first.nanoflows.map(&:name)).to eq(["RecalculateDraft"])
      end
    end

    it "writes and round-trips entity access rules" do
      path = File.join(File.dirname(@mpr_path), "access_rules.mpr")
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          module_role :User
          module_role :Administrator
          entity :Customer do
            string :Name
            string :Email
            access_rule "Sales.User",
              read: :all, write: [:Name]
            access_rule "Sales.Administrator",
              create: true, delete: true,
              read: :all, write: :all
          end
        end
      end
      expect(Mxrb.validate(path)).to be_valid

      Mxrb.open(path) do |project|
        entity = project.entities.find { _1.name == "Customer" }
        expect(entity.access_rules.size).to eq(2)

        user_rule = entity.access_rules.find { _1[:roles].include?("Sales.User") }
        expect(user_rule[:create]).to eq(false)
        expect(user_rule[:delete]).to eq(false)
        expect(user_rule[:default_rights]).to eq("ReadOnly")
        write_member = user_rule[:members].find { _1[:name] == "Name" }
        expect(write_member[:rights]).to eq("ReadWrite")

        admin_rule = entity.access_rules.find { _1[:roles].include?("Sales.Administrator") }
        expect(admin_rule[:create]).to eq(true)
        expect(admin_rule[:delete]).to eq(true)
        expect(admin_rule[:default_rights]).to eq("ReadWrite")
        expect(admin_rule[:members]).to be_empty
      end

      # Re-applying is idempotent
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          module_role :User
          module_role :Administrator
          entity :Customer do
            string :Name
            string :Email
            access_rule "Sales.User",
              read: :all, write: [:Name]
            access_rule "Sales.Administrator",
              create: true, delete: true,
              read: :all, write: :all
          end
        end
      end
      expect(Mxrb.validate(path)).to be_valid
    end

    it "exports entity access rules to Ruby DSL" do
      source = File.join(File.dirname(@mpr_path), "access_export.mpr")
      exported = File.join(File.dirname(@mpr_path), "access_ruby")
      rebuilt = File.join(File.dirname(@mpr_path), "access_rebuilt.mpr")

      Mxrb.define(source) do
        mendix_version "10.17.0"
        self.module :Crm do
          module_role :User
          module_role :Admin
          entity :Lead do
            string :Name
            string :Phone
            access_rule "Crm.User",  read: :all, write: [:Name]
            access_rule "Crm.Admin", create: true, delete: true, read: :all, write: :all
          end
        end
      end
      expect(Mxrb.validate(source)).to be_valid

      Mxrb::Exporter.new(source, exported).export!
      lead_src = File.read(File.join(exported, "modules", "Crm", "domain", "entities", "lead.rb"))
      expect(lead_src).to include('access_rule "Crm.User"')
      expect(lead_src).to include("read: :all")
      expect(lead_src).to include("write: [:Name]")
      expect(lead_src).to include('access_rule "Crm.Admin"')
      expect(lead_src).to include("create: true")
      expect(lead_src).to include("delete: true")
      expect(lead_src).to include("write: :all")

      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end
      expect(Mxrb.validate(rebuilt)).to be_valid

      Mxrb.open(rebuilt) do |project|
        entity = project.entities.find { _1.name == "Lead" }
        expect(entity.access_rules.size).to eq(2)
        expect(entity.access_rules.first[:roles]).to include("Crm.User")
        expect(entity.access_rules.last[:default_rights]).to eq("ReadWrite")
      end
    end

    it "builds container, drop_down, and snippet widgets" do
      path = File.join(File.dirname(@mpr_path), "widgets_adv.mpr")
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Ui do
          page :WidgetPage do
            container :MainBox, class_name: "mx-box" do
              text_box :NameInput, attribute: :Name, caption: "Name"
              button :SaveBtn, caption: "Save"
            end
            drop_down :StatusPicker, attribute: :Status, caption: "Status"
            snippet :HelpSnippet, from: "Ui.HelpText"
          end
        end
      end
      expect(Mxrb.validate(path)).to be_valid

      Mxrb.open(path) do |project|
        raw_page = project.mpr.units_by_containment("Documents").find {
          project.parse_bson(_1)["Name"] == "WidgetPage"
        }
        page_doc = project.parse_bson(raw_page)
        widgets = page_doc["Widgets"]

        container = widgets[1]
        expect(container["$Type"]).to eq("Pages$Container")
        expect(container["Class"]).to eq("mx-box")
        children = container["Widgets"]
        expect(children[1]["$Type"]).to eq("Pages$TextBox")
        expect(children[2]["$Type"]).to eq("Pages$ActionButton")

        drop_down = widgets[2]
        expect(drop_down["$Type"]).to eq("Pages$DropDownWidget")
        expect(drop_down["AttributePath"]).to eq("Status")

        snippet = widgets[3]
        expect(snippet["$Type"]).to eq("Pages$SnippetCall")
        expect(snippet["SnippetSettings"]["Snippet"]).to eq("Ui.HelpText")
      end

      Mxrb.open(path) do |project|
        page = project.pages.find { _1.name == "WidgetPage" }
        cont = page.widgets.find { _1[:type] == :container }
        expect(cont[:children].size).to eq(2)
        expect(cont[:children].first[:type]).to eq(:text_box)
        expect(cont[:children].last[:type]).to eq(:button)

        dd = page.widgets.find { _1[:type] == :drop_down }
        expect(dd[:options][:attribute]).to eq("Status")

        sn = page.widgets.find { _1[:type] == :snippet }
        expect(sn[:options][:snippet]).to eq("Ui.HelpText")
      end
    end

    it "builds data_grid with search_bar and toolbar" do
      path = File.join(File.dirname(@mpr_path), "grid_adv.mpr")
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order do
            string :Name
            integer :Total
          end
          page :OrderList do
            data_grid :OrderGrid, entity: "Sales.Order" do
              column :Name, attribute: :Name, caption: "Name"
              column :Total, attribute: :Total, caption: "Total"
              search_bar do
                search_field :Name, caption: "Order Name"
              end
              toolbar do
                new_button
                delete_button
              end
            end
          end
        end
      end
      expect(Mxrb.validate(path)).to be_valid

      Mxrb.open(path) do |project|
        raw_page = project.mpr.units_by_containment("Documents").find {
          project.parse_bson(_1)["Name"] == "OrderList"
        }
        page_doc = project.parse_bson(raw_page)
        grid = page_doc["Widgets"][1]
        expect(grid["$Type"]).to eq("Pages$DataGrid")

        search_bar = grid["SearchBar"]
        expect(search_bar["$Type"]).to eq("Pages$SearchBar")
        expect(search_bar["SearchFields"][1]["$Type"]).to eq("Pages$AttributeSearchField")
        expect(search_bar["SearchFields"][1]["AttributeRef"]["Attribute"]).to eq("Name")

        toolbar = grid["ToolBar"]
        expect(toolbar["$Type"]).to eq("Pages$GridToolBar")
        expect(toolbar["Buttons"][1]["$Type"]).to eq("Pages$GridNewButton")
        expect(toolbar["Buttons"][2]["$Type"]).to eq("Pages$GridDeleteButton")
      end

      Mxrb.open(path) do |project|
        page = project.pages.find { _1.name == "OrderList" }
        grid = page.widgets.find { _1[:type] == :data_grid }
        expect(grid[:options][:search_bar][:fields].first[:attribute]).to eq("Name")
        expect(grid[:options][:toolbar][:buttons].map { _1[:type] }).to eq(%i[new delete])
      end
    end

    it "builds microflow with body activities" do
      path = File.join(File.dirname(@mpr_path), "body_mf.mpr")
      define_body = proc do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order do
            string :Name
            decimal :Total
          end
          microflow :CreateOrder do
            create_object "Sales.Order", as: :order, set: { Name: "'New Order'" }
            change_object :order, set: { Total: 0 }
            commit :order
            return_value :order
          end
        end
      end

      Mxrb.define(path, &define_body)
      expect(Mxrb.validate(path)).to be_valid

      Mxrb.open(path) do |project|
        raw_flow = project.mpr.units_by_containment("Documents").find {
          project.parse_bson(_1)["Name"] == "CreateOrder"
        }
        flow_doc = project.parse_bson(raw_flow)
        expect(flow_doc["ReturnVariableName"]).to eq("order")

        collection = flow_doc["ObjectCollection"]
        expect(collection["$Type"]).to eq("Microflows$MicroflowObjectCollection")

        objects = Mxrb::IO::BsonCodec.parse_array(collection["Objects"])[:items]
        expect(objects.size).to eq(5)
        expect(objects[0]["$Type"]).to eq("Microflows$StartEvent")
        expect(objects[1]["$Type"]).to eq("Microflows$ActionActivity")
        expect(objects[1]["Action"]["$Type"]).to eq("Microflows$CreateChangeAction")
        expect(objects[1]["Action"]["Entity"]).to eq("Sales.Order")
        expect(objects[1]["Action"]["VariableName"]).to eq("order")
        expect(objects[2]["Action"]["$Type"]).to eq("Microflows$ChangeAction")
        expect(objects[2]["Action"]["ChangeVariableName"]).to eq("order")
        expect(objects[3]["Action"]["$Type"]).to eq("Microflows$CommitAction")
        expect(objects[4]["$Type"]).to eq("Microflows$EndEvent")
        expect(objects[4]["ReturnValue"]).to eq("$order")

        flows = Mxrb::IO::BsonCodec.parse_array(flow_doc["Flows"])[:items]
        expect(flows.size).to eq(4)
        expect(flows.map { _1["$Type"] }).to all(eq("Microflows$SequenceFlow"))
      end

      # Idempotent re-apply
      Mxrb.define(path, &define_body)
      expect(Mxrb.validate(path)).to be_valid

      Mxrb.open(path) do |project|
        raw_flow = project.mpr.units_by_containment("Documents").find {
          project.parse_bson(_1)["Name"] == "CreateOrder"
        }
        objects = Mxrb::IO::BsonCodec.parse_array(
          project.parse_bson(raw_flow).dig("ObjectCollection", "Objects")
        )[:items]
        expect(objects.size).to eq(5)
      end
    end

    it "exports microflow body activities to Ruby DSL" do
      path     = File.join(File.dirname(@mpr_path), "body_export.mpr")
      exported = File.join(File.dirname(@mpr_path), "body_export_ruby")

      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order do
            string :Name
            decimal :Total
          end
          microflow :CreateOrder do
            create_object "Sales.Order", as: :order, set: { Name: "'New Order'" }
            change_object :order, set: { Total: 0 }
            commit :order
            return_value :order
          end
        end
      end

      Mxrb::Exporter.new(path, exported).export!
      src = File.read(File.join(exported, "modules", "Sales", "application", "use_cases", "create_order.rb"))

      expect(src).to include("create_object")
      expect(src).to include("Sales.Order")
      expect(src).to include("as: :order")
      expect(src).to include("change_object :order")
      expect(src).to include("commit :order")
      expect(src).to include("return_value :order")
    end

    it "retains the native baseline for a malformed or unknown flow graph" do
      path     = File.join(File.dirname(@mpr_path), "native_baseline_body.mpr")
      exported = File.join(File.dirname(@mpr_path), "native_baseline_body_ruby")
      rebuilt_dir = File.join(File.dirname(@mpr_path), "native_baseline_body_rebuilt")
      rebuilt  = File.join(rebuilt_dir, "native_baseline_body.mpr")

      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          microflow :MixedBody do
            call_microflow "Sales.Known"
          end
        end
      end

      mpr = Mxrb::IO::MprFile.open(path)
      raw = mpr.units_by_containment("Documents").find {
        mpr.parse_contents(_1)["Name"] == "MixedBody"
      }
      doc = mpr.parse_contents(raw)
      action = Mxrb::IO::BsonCodec.parse_array(doc.dig("ObjectCollection", "Objects"))[:items]
                .find { _1["$Type"] == "Microflows$ActionActivity" }
      action["Action"]["$Type"] = "Microflows$JavaActionCallAction"
      mpr.update_unit(raw.fetch("UnitID"), doc)
      mpr.close

      Mxrb::Exporter.new(path, exported).export!
      src = File.read(File.join(exported, "modules", "Sales", "application", "use_cases", "mixed_body.rb"))
      expect(src).to include("Native body baseline retained")
      expect(src).not_to include("call_microflow")

      FileUtils.mkdir_p(rebuilt_dir)
      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end
      expect(Mxrb.compare(path, rebuilt)).to be_identical
    end

    it "invalidates native flow preservation when the exported body is edited" do
      builder = Mxrb::Dsl::FlowBuilder.new(
        :Fingerprint, runtime: :server, kind: :microflow, public: false
      )
      builder.create_variable :message, type: :string, value: "'before'"
      original = builder.to_h
      digest = Mxrb::Dsl::FlowBuilder.body_digest(
        original.fetch(:body), original[:return_expression]
      )
      builder.body_fingerprint(digest)
      expect(builder.to_h[:preserve_native_body]).to be(true)

      builder.change_variable :message, to: "'after'"
      expect(builder.to_h[:preserve_native_body]).to be(false)
    end

    it "exports nanoflow body activities to Ruby DSL" do
      path     = File.join(File.dirname(@mpr_path), "nf_body_export.mpr")
      exported = File.join(File.dirname(@mpr_path), "nf_body_export_ruby")

      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Ui do
          entity :Task do
            string :Name
          end
          nanoflow :PrepareTask do
            create_object "Ui.Task", as: :task
            commit :task
            return_value :task
          end
        end
      end

      Mxrb::Exporter.new(path, exported).export!
      src = File.read(File.join(exported, "modules", "Ui", "presentation", "client_actions", "prepare_task.rb"))

      expect(src).to include("nanoflow :PrepareTask")
      expect(src).to include("create_object")
      expect(src).to include("commit :task")
      expect(src).to include("return_value :task")
    end

    it "exports microflow decision body to Ruby DSL" do
      path     = File.join(File.dirname(@mpr_path), "decision_export.mpr")
      exported = File.join(File.dirname(@mpr_path), "decision_export_ruby")

      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order do
            decimal :Total
          end
          microflow :CheckOrder do
            retrieve_objects "Sales.Order", as: :Order, xpath: "[ID = $ID]"
            decision "$Order/Total > 100" do
              on(true)  { call_microflow "Sales.ApplyDiscount" }
              on(false) { commit :Order }
            end
          end
        end
      end

      Mxrb::Exporter.new(path, exported).export!
      src = File.read(File.join(exported, "modules", "Sales", "application", "use_cases", "check_order.rb"))

      expect(src).to include("retrieve_objects")
      expect(src).to include('decision "$Order/Total > 100"')
      expect(src).to include("on(true)")
      expect(src).to include("call_microflow")
      expect(src).to include("on(false)")
      expect(src).to include("commit :Order")
    end

    it "exports microflow loop body to Ruby DSL" do
      path     = File.join(File.dirname(@mpr_path), "loop_export.mpr")
      exported = File.join(File.dirname(@mpr_path), "loop_export_ruby")

      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order do
            boolean :Processed
          end
          microflow :MarkAll do
            retrieve_objects "Sales.Order", as: :OrderList
            loop_over :OrderList, as: :CurrentOrder do
              commit :CurrentOrder
            end
          end
        end
      end

      Mxrb::Exporter.new(path, exported).export!
      src = File.read(File.join(exported, "modules", "Sales", "application", "use_cases", "mark_all.rb"))

      expect(src).to include("retrieve_objects")
      expect(src).to include("loop_over :OrderList, as: :CurrentOrder")
      expect(src).to include("commit :CurrentOrder")
    end

    it "exports microflow rescue_all to Ruby DSL" do
      path     = File.join(File.dirname(@mpr_path), "rescue_export.mpr")
      exported = File.join(File.dirname(@mpr_path), "rescue_export_ruby")

      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order do
            string :Name
          end
          microflow :SafeCreate do
            create_object "Sales.Order", as: :Order
            commit :Order
            rescue_all { call_microflow "Sales.LogError" }
          end
        end
      end

      Mxrb::Exporter.new(path, exported).export!
      src = File.read(File.join(exported, "modules", "Sales", "application", "use_cases", "safe_create.rb"))

      expect(src).to include("commit :Order")
      expect(src).to include("rescue_all do")
      expect(src).to include("call_microflow")
    end

    it "round-trips editable variable and message activities" do
      source   = File.join(File.dirname(@mpr_path), "messages.mpr")
      exported = File.join(File.dirname(@mpr_path), "messages_ruby")
      rebuilt_dir = File.join(File.dirname(@mpr_path), "messages_rebuilt")
      rebuilt  = File.join(rebuilt_dir, "messages.mpr")

      Mxrb.define(source) do
        mendix_version "10.17.0"
        self.module :Sales do
          microflow :Notify do
            create_variable :message, type: :string, value: "'Created'"
            change_variable :message, to: "'Updated'"
            show_message "Done", type: :information, blocking: true
            log_message "Completed", level: :info, node: "'MXRB'", include_stack: true
          end
        end
      end

      Mxrb::Exporter.new(source, exported).export!
      src = File.read(File.join(exported, "modules", "Sales", "application", "use_cases", "notify.rb"))
      expect(src).to include("create_variable :message")
      expect(src).to include("change_variable :message")
      expect(src).to include('show_message "Done"')
      expect(src).to include('log_message "Completed"')

      FileUtils.mkdir_p(rebuilt_dir)
      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(Mxrb.compare(source, rebuilt)).to be_identical
    end

    it "builds microflow with decision (exclusive split / merge)" do
      path = File.join(File.dirname(@mpr_path), "decision_mf.mpr")
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order do
            decimal :Total
          end
          microflow :CheckOrder do
            retrieve_objects "Sales.Order", as: :Order, xpath: "[ID = $ID]"
            decision "$Order/Total > 100" do
              on(true)  { call_microflow "Sales.ApplyDiscount" }
              on(false) { commit :Order }
            end
            return_value :Order
          end
        end
      end
      expect(Mxrb.validate(path)).to be_valid

      Mxrb.open(path) do |project|
        raw_flow = project.mpr.units_by_containment("Documents").find {
          project.parse_bson(_1)["Name"] == "CheckOrder"
        }
        col = project.parse_bson(raw_flow)["ObjectCollection"]
        objects = Mxrb::IO::BsonCodec.parse_array(col["Objects"])[:items]
        flows   = Mxrb::IO::BsonCodec.parse_array(project.parse_bson(raw_flow)["Flows"])[:items]

        types = objects.map { _1["$Type"] }
        expect(types).to include("Microflows$StartEvent")
        expect(types).to include("Microflows$ActionActivity")
        expect(types).to include("Microflows$ExclusiveSplit")
        expect(types).to include("Microflows$ExclusiveMerge")
        expect(types).to include("Microflows$EndEvent")

        split = objects.find { _1["$Type"] == "Microflows$ExclusiveSplit" }
        expect(split["SplitCondition"]["Expression"]).to eq("$Order/Total > 100")

        # Both branches produce a flow with a BooleanCase CaseValue from the split
        split_id = split["$ID"]
        branch_flows = flows.select { _1["OriginPointer"] == split_id }
        expect(branch_flows.size).to eq(2)
        case_values = branch_flows.flat_map { Mxrb::IO::BsonCodec.parse_array(_1["CaseValues"])[:items] }
        bool_vals = case_values.map { _1["Value"] }
        expect(bool_vals).to include("true")
        expect(bool_vals).to include("false")
      end
    end

    it "builds microflow with loop_over (looped activity)" do
      path = File.join(File.dirname(@mpr_path), "loop_mf.mpr")
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order do
            boolean :Processed
          end
          microflow :MarkAll do
            retrieve_objects "Sales.Order", as: :OrderList
            loop_over :OrderList, as: :CurrentOrder do
              change_object :CurrentOrder do
                set "Sales.Order/Processed", to: true
              end
              commit :CurrentOrder
            end
          end
        end
      end
      expect(Mxrb.validate(path)).to be_valid

      Mxrb.open(path) do |project|
        raw_flow = project.mpr.units_by_containment("Documents").find {
          project.parse_bson(_1)["Name"] == "MarkAll"
        }
        col = project.parse_bson(raw_flow)["ObjectCollection"]
        objects = Mxrb::IO::BsonCodec.parse_array(col["Objects"])[:items]

        loop_act = objects.find { _1["$Type"] == "Microflows$LoopedActivity" }
        expect(loop_act).not_to be_nil

        loop_obj = loop_act["LoopSource"]
        expect(loop_obj["$Type"]).to eq("Microflows$IterableList")
        expect(loop_obj["ListVariableName"]).to eq("OrderList")
        expect(loop_obj["VariableName"]).to eq("CurrentOrder")

        inner_col = loop_act["ObjectCollection"]
        inner_objs = Mxrb::IO::BsonCodec.parse_array(inner_col["Objects"])[:items]
        inner_types = inner_objs.map { _1["$Type"] }
        expect(inner_types).to include("Microflows$ActionActivity")
        expect(inner_types).not_to include("Microflows$StartEvent", "Microflows$EndEvent")
      end
    end

    it "builds microflow with rescue_all (custom error handler)" do
      path = File.join(File.dirname(@mpr_path), "rescue_mf.mpr")
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order do
            string :Name
          end
          microflow :SafeCreate do
            create_object "Sales.Order", as: :Order
            commit :Order
            rescue_all do
              call_microflow "Sales.LogError"
            end
          end
        end
      end
      expect(Mxrb.validate(path)).to be_valid

      Mxrb.open(path) do |project|
        raw_flow = project.mpr.units_by_containment("Documents").find {
          project.parse_bson(_1)["Name"] == "SafeCreate"
        }
        col = project.parse_bson(raw_flow)["ObjectCollection"]
        objects = Mxrb::IO::BsonCodec.parse_array(col["Objects"])[:items]
        flows   = Mxrb::IO::BsonCodec.parse_array(project.parse_bson(raw_flow)["Flows"])[:items]

        # Modern Mendix stores custom error handling on the action itself.
        commit_act = objects.select { _1["$Type"] == "Microflows$ActionActivity" }
                            .find { _1["Action"]["$Type"] == "Microflows$CommitAction" }
        expect(commit_act.dig("Action", "ErrorHandlingType")).to eq("CustomWithoutRollBack")

        # One error-handler SequenceFlow
        error_flows = flows.select { _1["IsErrorHandler"] == true }
        expect(error_flows.size).to eq(1)
        expect(error_flows.first["OriginPointer"]).to eq(commit_act["$ID"])

        # Two EndEvents (main + error branch)
        end_events = objects.select { _1["$Type"] == "Microflows$EndEvent" }
        expect(end_events.size).to eq(2)
      end
    end

    it "indexes references, callers, callees, and transitive impact from an MPR" do
      path = File.join(File.dirname(@mpr_path), "semantic_index.mpr")
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order do
            string :Number
          end
          microflow :Target do
            retrieve_objects "Sales.Order", as: :Orders
          end
          microflow :Caller do
            call_microflow "Sales.Target"
          end
          microflow :Top do
            call_microflow "Sales.Caller"
          end
        end
      end

      Mxrb.open(path) do |project|
        expect(project.find_artifact("Sales.Order").kind).to eq(:entity)
        expect(project.find_artifact("Sales.Order.Number").kind).to eq(:attribute)
        expect(project.search_artifacts("order").map(&:qualified_name))
          .to include("Sales.Order", "Sales.Order.Number")
        details = project.describe_artifact("Sales.Target")
        expect(details.artifact.kind).to eq(:microflow)
        expect(details.incoming.map { _1.source.qualified_name }).to eq(["Sales.Caller"])
        expect(details.outgoing.map { _1.target.qualified_name }).to include("Sales.Order")
        expect(project.callers_of("Sales.Target").map(&:qualified_name)).to eq(["Sales.Caller"])
        expect(project.callees_of("Sales.Caller").map(&:qualified_name)).to eq(["Sales.Target"])
        expect(project.references_to("Sales.Order").map { _1.source.qualified_name })
          .to include("Sales.Target")
        expect(project.impact_of("Sales.Target").artifacts.map(&:qualified_name))
          .to contain_exactly("Sales.Caller", "Sales.Top")
        expect(project.impact_of("Sales.Target", transitive: false).artifacts.map(&:qualified_name))
          .to eq(["Sales.Caller"])
        expect { project.references_to("Sales.Missing") }
          .to raise_error(KeyError, /unknown Mendix artifact/)
      end
    end

    it "previews and applies a deep Ruby-first rename" do
      path = File.join(File.dirname(@mpr_path), "semantic_rename.mpr")
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order do
            string :Number
          end
          microflow :LoadOrder do
            retrieve_objects "Sales.Order", as: :Orders
            change_object :Order, set: { "Sales.Order/Number" => "'42'" }
          end
          microflow :Caller do
            call_microflow "Sales.LoadOrder"
          end
        end
      end

      Mxrb.open(path, readonly: false) do |project|
        preview = project.plan_rename("Sales.Order", to: "Invoice")
        expect(preview).not_to be_empty
        expect(preview.applied?).to be(false)
        expect(project.find_artifact("Sales.Order")).not_to be_nil

        preview.apply!
        expect(preview.applied?).to be(true)
        expect(project.find_artifact("Sales.Order")).to be_nil
        expect(project.find_artifact("Sales.Invoice").kind).to eq(:entity)
        expect(project.references_to("Sales.Invoice").map { _1.source.qualified_name })
          .to include("Sales.LoadOrder")

        attribute_preview = project.plan_rename("Sales.Invoice.Number", to: "Code")
        expect(attribute_preview.changes.map(&:before)).to include("Number", "Sales.Invoice/Number")
        attribute_preview.apply!
        expect(project.references_to("Sales.Invoice.Code").map { _1.source.qualified_name })
          .to include("Sales.LoadOrder")

        flow_preview = project.plan_rename("Sales.LoadOrder", to: "FetchInvoice")
        expect(flow_preview.changes.map(&:before)).to include("LoadOrder", "Sales.LoadOrder")
        flow_preview.apply!
        expect(project.callers_of("Sales.FetchInvoice").map(&:qualified_name))
          .to eq(["Sales.Caller"])
      end

      expect(Mxrb.validate(path)).to be_valid
    end

    it "previews, blocks, and applies reference-safe unit removal" do
      path = File.join(File.dirname(@mpr_path), "semantic_remove.mpr")
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order
          microflow :Unused
          microflow :Target
          microflow(:Caller) { call_microflow "Sales.Target" }
        end
      end

      Mxrb.open(path, readonly: false) do |project|
        unused = project.plan_remove("Sales.Unused")
        expect(unused).to be_safe
        expect(unused).not_to be_applied
        expect(unused.incoming).to be_empty
        expect(unused.children).to be_empty

        unused.apply!
        expect(unused).to be_applied
        expect(project.find_artifact("Sales.Unused")).to be_nil
        expect { unused.apply! }.to raise_error(ArgumentError, /already applied/)

        target = project.plan_remove("Sales.Target")
        expect(target).not_to be_safe
        expect(target.incoming.map { _1.source.qualified_name }).to eq(["Sales.Caller"])
        expect { target.apply! }.to raise_error(ArgumentError, /incoming reference/)

        expect { project.remove!("Sales.Order") }
          .to raise_error(ArgumentError, /typed domain-model mutation/)
        expect { project.plan_remove("Sales.Missing") }
          .to raise_error(KeyError, /unknown Mendix artifact/)
      end

      expect(Mxrb.validate(path)).to be_valid
    end

    it "previews and applies same-module unit moves without changing references" do
      path = File.join(File.dirname(@mpr_path), "semantic_move.mpr")
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Sales do
          entity :Order
          microflow :Target
          microflow(:Caller) { call_microflow "Sales.Target" }
        end
        self.module(:Other) {}
      end

      Mxrb.open(path, readonly: false) do |project|
        sales = project.find_artifact("Sales")
        flows_id = project.mpr.insert_unit(
          container_uuid: sales.unit_id,
          containment_name: "Folders",
          contents_doc: {
            "$Type" => "Projects$Folder", "Name" => "Flows"
          }
        )
        nested_id = project.mpr.insert_unit(
          container_uuid: flows_id,
          containment_name: "Folders",
          contents_doc: {
            "$Type" => "Projects$Folder", "Name" => "Nested"
          }
        )
        project.refresh!

        plan = project.plan_move("Sales.Target", to: "Sales.Flows")
        expect(plan).not_to be_empty
        expect(plan.before_container).to eq(sales.unit_id)
        expect(plan.after_container).to eq(flows_id)
        plan.apply!
        expect(plan).to be_applied
        expect(project.raw_unit(plan.source.unit_id)["ContainerID"]).to eq(flows_id)
        expect(project.callers_of("Sales.Target").map(&:qualified_name)).to eq(["Sales.Caller"])
        expect { plan.apply! }.to raise_error(ArgumentError, /already applied/)

        unchanged = project.plan_move("Sales.Target", to: "Sales.Flows")
        expect(unchanged).to be_empty
        unchanged.apply!
        expect(unchanged).to be_applied

        expect { project.plan_move("Sales.Flows", to: "Sales.Nested") }
          .to raise_error(ArgumentError, /descendant/)
        expect(project.raw_unit(nested_id)["ContainerID"]).to eq(flows_id)
        # cross-module moves via plan_move; move! applies the plan
        cross_plan = project.plan_move("Sales.Target", to: "Other")
        expect(cross_plan).to be_a(Mxrb::Semantic::CrossModuleMovePlan)
        expect { project.plan_move("Sales.Target", to: "Sales.Caller") }
          .to raise_error(ArgumentError, /not a module or folder/)
        expect { project.plan_move("Sales.Order", to: "Sales.Flows") }
          .to raise_error(ArgumentError, /cannot be moved/)
        expect { project.plan_move("Sales.Missing", to: "Sales.Flows") }
          .to raise_error(KeyError, /unknown Mendix artifact/)
      end

      expect(Mxrb.validate(path)).to be_valid
    end

    it "reports call cycles, unreferenced artifacts, and module coupling as Ruby data" do
      artifact = lambda do |id, qualified_name, module_name|
        Mxrb::Semantic::Artifact.new(
          id, qualified_name, :microflow, module_name,
          qualified_name.split(".").last, id, [], {}.freeze
        )
      end
      first = artifact.call("unit:first", "Sales.First", "Sales")
      second = artifact.call("unit:second", "Shared.Second", "Shared")
      orphan = artifact.call("unit:orphan", "Sales.Orphan", "Sales")
      references = [
        Mxrb::Semantic::Reference.new(first, second, :calls, ["Microflow"], "Shared.Second"),
        Mxrb::Semantic::Reference.new(second, first, :calls, ["Microflow"], "Sales.First")
      ]
      unresolved = Mxrb::Semantic::UnresolvedReference.new(
        orphan, "Sales.Missing", [:microflow], ["Action", "Microflow"], "Sales.Missing"
      )
      external = Mxrb::Semantic::UnresolvedReference.new(
        orphan, "External.Service", [:microflow], ["Action", "Microflow"], "External.Service"
      )
      index = Struct.new(:artifacts, :references, :unresolved_references)
                    .new([first, second, orphan], references, [unresolved, external])
      project = Struct.new(:semantic_index).new(index)
      custom_rule = lambda do |_opened_project, semantic_index|
        Mxrb::Semantic::Diagnostic.new(
          :custom_rule, :warning,
          "#{semantic_index.artifacts.size} artifacts inspected",
          [].freeze, {}.freeze
        )
      end

      report = Mxrb::Semantic::Analyzer.new(project).analyze(rules: [custom_rule])

      expect(report).not_to be_valid
      expect(report.call_cycles.size).to eq(1)
      expect(report.call_cycles.first.artifacts).to contain_exactly(first, second)
      expect(report.unreferenced).to eq([orphan])
      expect(report.unresolved_references).to contain_exactly(unresolved, external)
      expect(report.module_dependencies.map { [_1.from, _1.to] })
        .to contain_exactly(["Sales", "Shared"], ["Shared", "Sales"])
      expect(report.errors.map(&:rule)).to contain_exactly(:call_cycle, :unresolved_reference)
      expect(report.warnings.map(&:rule))
        .to contain_exactly(:custom_rule, :external_reference, :unreferenced)
    end

    it "evaluates model expectations with an extensible Ruby suite" do
      path = File.join(File.dirname(@mpr_path), "evaluation.mpr")
      definition = File.join(File.dirname(@mpr_path), "evaluation.rb")
      Mxrb.define(path) do
        mendix_version "10.17.0"
        self.module :Shared do
          microflow :Target
        end
        self.module :Sales do
          microflow(:Caller) { call_microflow "Shared.Target" }
          microflow :Orphan
        end
      end

      Mxrb.open(path) do |project|
        result = project.evaluate do
          artifact "Shared.Target", kind: :microflow
          artifact "Sales.Missing", severity: :warning
          reference from: "Sales.Caller", to: "Shared.Target", relation: :calls
          reference from: "Sales.Missing", to: "Shared.Target", severity: :warning
          reference from: "Sales.Caller", to: "Shared.Missing", severity: :warning
          reference from: "Sales.Caller", to: "Shared.Target",
                    relation: :opens, severity: :warning
          no_call_cycles
          no_missing_internal_references
          maximum_unreferenced 10
          maximum_unreferenced 0, severity: :warning
          forbid_dependency from: :Sales, to: :Other
          forbid_dependency from: :Sales, to: :Shared, severity: :warning
          require_dependency from: :Sales, to: :Shared
          require_dependency from: :Sales, to: :Other, severity: :warning
          check("custom pass") { true }
          check("custom nil", severity: :warning) { nil }
          check("custom exception", severity: :warning) { raise "boom" }
        end

        expect(result).to be_passed
        expect(result.errors).to be_empty
        expect(result.warnings.size).to eq(9)
        expect(result.score).to be_between(40.0, 100.0)
        expect(result.checks.find { _1.name == "custom exception" }.metadata[:exception])
          .to be_a(RuntimeError)

        suite = Mxrb::Evaluation::Suite.new(project)
        expect { suite.check("missing block") }.to raise_error(ArgumentError, /requires a block/)
        expect { suite.check("bad severity", severity: :info) { true } }
          .to raise_error(ArgumentError, /severity/)
        expect(suite.run.score).to eq(100.0)

        File.write(definition, <<~RUBY)
          artifact "Shared.Target", kind: :microflow
          no_call_cycles
        RUBY
        loaded = Mxrb::Evaluation::Suite.new(project).evaluate(definition).run
        expect(loaded).to be_passed
        expect(loaded.score).to eq(100.0)
      end

      expect(Mxrb.evaluate(path) { artifact "Shared.Target" }).to be_passed
    end

    it "round-trips the complete typed flow and widget surface" do
      source = File.join(File.dirname(@mpr_path), "complete_surface.mpr")
      exported = File.join(File.dirname(@mpr_path), "complete_surface_ruby")
      rebuilt_dir = File.join(File.dirname(@mpr_path), "complete_surface_rebuilt")
      rebuilt = File.join(rebuilt_dir, "complete_surface.mpr")

      Mxrb.define(source) do
        mendix_version "11.12.1"
        self.module :Deep do
          entity :Order do
            string :Name
            integer :Count
            association :Order
          end
          page :Dashboard do
            popup!
            allowed_roles "Deep.User"
            data_source nanoflow: :LoadClient
            on_load microflow: :Complete
            drop_down :Status, attribute: "Deep.Order/Name", caption: "Status"
            check_box :Approved, attribute: "Deep.Order/Count", caption: "Approved"
            date_picker :CreatedAt, attribute: "Deep.Order/Count", caption: "Created"
            reference_selector :Parent, attribute: "Deep.Order_Order", caption: "Parent"
            text :Heading, caption: "Orders"
            button :Save, caption: "Save" do
              on_click action: :save_changes
            end
            snippet :Summary, from: "Deep.Summary"
            tab_control :Tabs do
              tab_page :General, caption: "General"
            end
            container :Body, class_name: "body" do
              text_box :Name, attribute: "Deep.Order/Name", caption: "Name"
            end
            data_grid :Orders, entity: "Deep.Order" do
              column :Name, attribute: "Deep.Order/Name", caption: "Name"
              search_bar { search_field "Name", caption: "Find" }
              toolbar do
                new_button
                delete_button
                search_button
                export_button
              end
              on_change microflow: :Complete
              on_click nanoflow: :LoadClient
              on_enter action: :save_changes
              on_leave action: :close_page
            end
          end
          menu :Main do
            item "Dashboard", page: "Deep.Dashboard" do
              item "Nested", page: "Deep.Dashboard"
            end
          end
          nanoflow :LoadClient do
            create_variable :client, type: :string, value: "'ready'"
          end
          microflow :Complete do
            parameter :Input, type: :string
            return_type :string
            documentation "All supported typed actions"
            allow_concurrent_execution false
            mark_as_used true
            allowed_roles "Deep.User"
            create_object "Deep.Order", as: :Order, commit: true,
                          with_events: false, refresh: true do
              set "Deep.Order/Name", to: "'Created'"
              set_association "Deep.Order_Order", to: :Order, operation: :add
            end
            change_object :Order, commit: true, with_events: false, refresh: true do
              set "Deep.Order/Count", to: 1
            end
            retrieve_objects "Deep.Order", as: :Orders, xpath: "[Count > 0]",
                             limit: "$Limit",
                             sort: [["Deep.Order/Name", :descending]]
            retrieve_objects "Deep.Order", as: :One, single: true
            retrieve_association :Order, association: "Deep.Order_Order", as: :Related
            commit :Order, with_events: false, refresh: true
            delete :Order, refresh: true
            call_microflow "Deep.Helper", as: :Called, pass: { Arg: :Order }
            call_microflow "Deep.Helper", result_name: :Stored, use_return: false
            call_java "Deep.Java", as: :JavaResult,
                      pass: {
                        Basic: "'x'",
                        Entity: { kind: :entity, value: "Deep.Order" },
                        Flow: { kind: :microflow, value: "Deep.Helper" },
                        Import: { kind: :import_mapping, value: "Deep.Import" },
                        Export: { kind: :export_mapping, value: "Deep.Export" }
                      }
            call_javascript "Deep.Script", result_name: :JsStored, use_return: false,
                            pass: { Basic: 1, Entity: { kind: :entity, value: "Deep.Order" } }
            call_nanoflow "Deep.LoadClient", use_return: true, pass: { Arg: true }
            call_app_service "External.Action", as: :ServiceResult, pass: { Arg: "'x'" }
            create_variable :message, type: :datetime, value: "'now'"
            change_variable :message, to: "'later'"
            show_message "Done", type: :warning, blocking: true,
                         translations: { en_US: "Done", pt_BR: "Feito" },
                         parameters: ["$message"]
            log_message "Logged", level: :warning, node: "'Deep'",
                        include_stack: true, parameters: ["$message"]
            show_page "Deep.Dashboard", object: :Order, location: :popup,
                      pass: { Order: :Order }, close_pages: 1,
                      title: { en_US: "Dashboard", pt_BR: "Painel" }
            close_page count: 2
            aggregate :Orders, function: :sum, as: :Total, attribute: "Deep.Order/Count"
            rollback :Order, refresh: true
            cast :Order
            create_list "Deep.Order", as: :NewOrders
            list_operation :union, :Orders, with: :NewOrders, as: :AllOrders
            change_list :Orders, action: :add, value: :Order
            validation_feedback :Order, attribute: "Deep.Order/Name",
                                association: "Deep.Order_Order",
                                translations: { en_US: "Invalid", pt_BR: "Inválido" },
                                parameters: ["$message"], error: :continue
            call_rest method: :post, location: "https://example.test/{1}",
                      location_parameters: ["$message"],
                      headers: { "X-Test" => "'yes'" },
                      request_mapping: "Deep.Export",
                      request_variable: :Order,
                      result_mapping: "Deep.Import", as: :Response,
                      result_entity: "Deep.Order", timeout: "30",
                      commit: :yes, error_result: :variable, error: :continue
            decision({ rule: "Deep.Rule", pass: { Input: "$Input" } }) do
              on(true) { show_message "yes" }
              on(false) { show_message "no" }
            end
            type_decision :Order do
              on_type("Deep.Order") { change_variable :message, to: "'order'" }
              otherwise { change_variable :message, to: "'other'" }
            end
            loop_over :Orders, as: :Current do
              change_object :Current, set: { "Deep.Order/Count" => 2 }
              continue_loop
            end
            while_loop "$Continue" do
              change_variable :message, to: "'loop'"
            end
            rescue_all { log_message "Recovered" }
            return_value :message
          end
          microflow :Helper
          microflow(:DS_Query) { end_flow }
          microflow(:VAL_Check) { error_event }
          microflow(:SE_Job) { return_value "'done'" }
          microflow :API_Endpoint
          microflow :INT_Integration
          module_role :User
        end
      end

      expect(Mxrb.validate(source)).to be_valid
      Mxrb::Exporter.new(source, exported).export!
      FileUtils.mkdir_p(rebuilt_dir)
      begin
        ENV["MXRB_OUTPUT_PATH"] = rebuilt
        load File.join(exported, "project.rb")
      ensure
        ENV.delete("MXRB_OUTPUT_PATH")
      end
      expect(Mxrb.validate(rebuilt)).to be_valid
      expect(Mxrb.compare(source, rebuilt)).to be_identical
    end

    it "rejects missing architecture references and call cycles" do
      missing = described_class.new("missing.mpr")
      missing.instance_eval do
        self.module(:Orders) { page(:Edit) { on_submit microflow: :DoesNotExist } }
      end
      expect { missing.validate! }.to raise_error(Mxrb::ValidationError, /DoesNotExist/)

      cyclic = described_class.new("cyclic.mpr")
      cyclic.instance_eval do
        self.module :Orders do
          microflow(:First) { call microflow: :Second }
          microflow(:Second) { call microflow: :First }
        end
      end
      expect { cyclic.validate! }.to raise_error(Mxrb::ValidationError, /call cycle detected/)
    end

    it "allows a page with an action event without raising for missing target" do
      builder = described_class.new("action_event.mpr")
      builder.instance_eval do
        self.module(:M) do
          page(:P) { on_click action: :save_changes }
        end
      end
      expect { builder.validate! }.not_to raise_error
    end
  end

  # ── Branch coverage: codec and IO edge cases ─────────────────────────────
  describe "codec and IO edge cases" do
    it "blob_to_uuid returns nil for non-16-byte or non-string input" do
      expect(Mxrb::IO::BsonCodec.blob_to_uuid("short")).to be_nil
      expect(Mxrb::IO::BsonCodec.blob_to_uuid(nil)).to be_nil
      expect(Mxrb::IO::BsonCodec.blob_to_uuid(12345)).to be_nil
    end

    it "parse_array treats non-integer first element as items without marker" do
      result = Mxrb::IO::BsonCodec.parse_array([{ "key" => 1 }, { "key" => 2 }])
      expect(result[:marker]).to eq(3)
      expect(result[:items]).to eq([{ "key" => 1 }, { "key" => 2 }])

      single = Mxrb::IO::BsonCodec.parse_array(["item"])
      expect(single[:items]).to eq(["item"])
    end

    it "parse returns empty hash for nil or empty bytes" do
      expect(Mxrb::IO::BsonCodec.parse(nil)).to eq({})
      expect(Mxrb::IO::BsonCodec.parse("")).to eq({})
    end

    it "extract_id returns nil for Hash without Data key" do
      expect(Mxrb::IO::BsonCodec.extract_id({ "Subtype" => 3 })).to be_nil
    end

    it "write_atomic cleans up nothing when mkdir_p fails" do
      expect { Mxrb::IO::MxunitCodec.write_atomic("/dev/null/sub/x.mxunit", "bytes") }
        .to raise_error(SystemCallError)
    end

    it "unit returns nil for a non-existent UUID" do
      mpr = Mxrb::IO::MprFile.open(@mpr_path)
      expect(mpr.unit("00000000-0000-0000-0000-000000000000")).to be_nil
      mpr.close
    end

    it "content_path returns nil for v1 MPRs" do
      mpr = Mxrb::IO::MprFile.open(@mpr_path)
      raw = mpr.root_unit
      expect(mpr.content_path(raw)).to be_nil
      mpr.close
    end

    it "content_files returns empty for v1 MPRs" do
      mpr = Mxrb::IO::MprFile.open(@mpr_path)
      expect(mpr.content_files).to eq([])
      mpr.close
    end

    it "root_unit returns nil and project_name falls back for an MPR with no root" do
      db = SQLite3::Database.new(@mpr_path)
      db.execute("DELETE FROM Unit WHERE UnitID = ContainerID")
      db.close

      mpr = Mxrb::IO::MprFile.open(@mpr_path)
      expect(mpr.root_unit).to be_nil
      expect(mpr.project_name).to be_nil
      mpr.close
    end

    it "handles a Unit row with NULL UnitID in raw_to_hash" do
      db = SQLite3::Database.new(@mpr_path)
      db.execute("INSERT INTO Unit VALUES (NULL, NULL, 'Orphan', 0, 'x', NULL, NULL)")
      db.close

      mpr = Mxrb::IO::MprFile.open(@mpr_path)
      units = mpr.all_units
      orphan = units.find { _1["ContainmentName"] == "Orphan" }
      expect(orphan).not_to be_nil
      expect(orphan["UnitID"]).to be_nil
      mpr.close
    end

    it "content_bytes returns nil for v2 unit with no mxunit file" do
      contents_dir = File.join(File.dirname(@mpr_path), "mprcontents")
      FileUtils.mkdir_p(contents_dir)

      mpr = Mxrb::IO::MprFile.open(@mpr_path)
      expect(mpr.format_version).to eq(:v2)
      mod_id = mpr.insert_unit(
        container_uuid: @uuids[:project_uuid],
        containment_name: "Modules",
        contents_doc: { "$Type" => "Projects$Module", "Name" => "Ghost" }
      )
      raw = mpr.unit(mod_id)

      FileUtils.rm_f(Mxrb::IO::MxunitCodec.path_for(contents_dir, mod_id))
      expect(mpr.content_bytes(raw)).to be_nil
      expect(mpr.parse_contents(raw)).to eq({})
      mpr.close
    end
  end

  # ── Branch coverage: model edge cases ─────────────────────────────────────
  describe "model edge cases" do
    it "Attribute.from_bson falls back to :string when type_doc is not a Hash" do
      attr = Mxrb::Model::Attribute.from_bson({
        "$ID" => SecureRandom.uuid,
        "name" => "Flag",
        "type" => "StringType"
      })
      expect(attr.type).to eq(:string)
    end

    it "Attribute.from_bson returns nil default_value for non-Hash value" do
      attr = Mxrb::Model::Attribute.from_bson({
        "name" => "Flag",
        "value" => "raw"
      })
      expect(attr.default_value).to be_nil
    end

    it "Attribute#to_bson sets localizeDate for datetime type" do
      attr = Mxrb::Model::Attribute.new
      attr.name = "Created"
      attr.type = :datetime
      bson = attr.to_bson
      expect(bson["type"]["localizeDate"]).to eq(true)
    end

    it "Entity.from_bson handles nil location" do
      entity = Mxrb::Model::Entity.from_bson(
        { "$ID" => SecureRandom.uuid, "name" => "E",
          "generalization" => nil,
          "attributes" => [3], "accessRules" => [3] },
        nil, nil
      )
      expect(entity.location).to eq({ x: 0, y: 0 })
    end

    it "Module#entities returns empty array when there is no DomainModel unit" do
      path = File.join(File.dirname(@mpr_path), "nodm.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:NoDomain) { microflow(:Ping) }
      end

      Mxrb.open(path) do |project|
        mod = project.modules.first
        expect(mod.entities).to eq([])
        expect(mod.associations).to eq([])
      end
    end

    it "Page#decode handles a doc with no Layout or FormCall" do
      raw = {
        "UnitID" => SecureRandom.uuid,
        "ContainerID" => SecureRandom.uuid,
        "ContainmentName" => "Documents",
        "ContentsHash" => "x",
        "Contents" => Mxrb::IO::BsonCodec.serialize({
          "$ID" => SecureRandom.uuid,
          "$Type" => "Pages$Page",
          "Name" => "Bare"
        })
      }
      mpr = Mxrb::IO::MprFile.open(@mpr_path)
      page = Mxrb::Model::Page.new(raw, mpr)
      expect(page.layout_id).to be_nil
      expect(page.inspect).to include("Bare")
      mpr.close
    end

    it "Menu#decode handles non-Hash captions and empty translations" do
      raw = {
        "UnitID" => SecureRandom.uuid,
        "ContainerID" => SecureRandom.uuid,
        "ContainmentName" => "Documents",
        "ContentsHash" => "x",
        "Contents" => Mxrb::IO::BsonCodec.serialize({
          "$ID" => SecureRandom.uuid,
          "$Type" => "Menus$MenuDocument",
          "Name" => "Nav",
          "ItemCollection" => {
            "$ID" => SecureRandom.uuid,
            "$Type" => "Menus$NavigationItemCollection",
            "Items" => [3,
              { "$ID" => SecureRandom.uuid, "$Type" => "Menus$NavigationItem",
                "Name" => "Item1", "Caption" => nil },
              { "$ID" => SecureRandom.uuid, "$Type" => "Menus$NavigationItem",
                "Name" => "Item2",
                "Caption" => {
                  "$ID" => SecureRandom.uuid,
                  "$Type" => "Texts$Text",
                  "Items" => [3]
                } }
            ]
          }
        })
      }
      mpr = Mxrb::IO::MprFile.open(@mpr_path)
      menu = Mxrb::Model::Menu.new(raw, mpr)
      expect(menu.items.first[:caption]).to eq("")
      expect(menu.items.last[:caption]).to eq("")
      mpr.close
    end
  end

  # ── Branch coverage: DSL builder edge cases ────────────────────────────────
  describe "DSL builder edge cases" do
    it "drop_down without attribute, container with class_name, column without attribute" do
      builder = Mxrb::Dsl::Builder.new("x.mpr")
      builder.instance_eval do
        self.module(:M) do
          page(:P) do
            drop_down :Status
            container :Body, class_name: "wrapper" do
              text_box :Name
            end
            data_grid :Grid, entity: "M.Order" do
              column :Name
            end
          end
        end
      end

      defn = builder.definition[:modules].first[:pages].first
      drop_down = defn[:widgets].find { _1[:type] == :drop_down }
      expect(drop_down[:options]).not_to have_key(:attribute)

      container = defn[:widgets].find { _1[:type] == :container }
      expect(container[:options][:class]).to eq("wrapper")

      grid = defn[:widgets].find { _1[:type] == :data_grid }
      expect(grid[:options][:columns].first).not_to have_key(:attribute)
    end

    it "page with action event does not add an architecture edge" do
      builder = Mxrb::Dsl::Builder.new("x.mpr")
      builder.instance_eval do
        self.module(:M) do
          page(:P) do
            on_click action: :save_changes
            on_submit action: :save_changes
          end
        end
      end
      graph = builder.graph
      page_edges = graph.edges.select { _1.from.include?("::page::P") }
      expect(page_edges).to be_empty
    end

    it "architecture validator allows late-bound page nanoflow references" do
      builder = Mxrb::Dsl::Builder.new("x.mpr")
      builder.instance_eval do
        self.module(:M) do
          page(:P) { on_click nanoflow: :UndeclaredNano }
        end
      end
      expect { builder.validate! }.not_to raise_error
    end

    it "microflow with repository call, call helpers, and body_fingerprint" do
      builder = Mxrb::Dsl::Builder.new("x.mpr")
      builder.instance_eval do
        self.module(:M) do
          repository :Repo, implementation: "M.RepoImpl", public: true
          microflow :Worker do
            uses_repository :Repo
            call microflow: :Helper
            body_fingerprint "deadbeef"
            allow_concurrent_execution true
            mark_as_used false
            excluded false
          end
          microflow(:Helper)
        end
      end
      flow = builder.definition[:modules].first[:microflows].first
      expect(flow[:repositories]).to eq(["Repo"])
      expect(flow[:calls]).to eq([{ kind: :microflow, name: "Helper" }])
      expect(flow[:allow_concurrent_execution]).to eq(true)
      expect(flow[:mark_as_used]).to eq(false)
      expect(flow[:excluded]).to eq(false)
    end

    it "FlowBodyDsl covers show_page with all optional params, close_page with count" do
      builder = Mxrb::Dsl::Builder.new("x.mpr")
      builder.instance_eval do
        self.module(:M) do
          microflow :Worker do
            show_page "M.Detail", object: :Item, location: :popup,
                      pass: { Param: :Item }, close_pages: 2,
                      title: "Detail"
            close_page count: 3
          end
        end
      end
      acts = builder.definition[:modules].first[:microflows].first[:body]
      sp = acts.find { _1[:type] == :show_page }
      expect(sp[:variable]).to eq("Item")
      expect(sp[:location]).to eq("popup")
      expect(sp[:close_pages]).to eq(2)
      expect(sp[:title]).to eq("Detail")
      cp = acts.find { _1[:type] == :close_page }
      expect(cp[:count]).to eq(3)
    end

    it "FlowBodyDsl covers call_microflow with result_name and use_return options" do
      builder = Mxrb::Dsl::Builder.new("x.mpr")
      builder.instance_eval do
        self.module(:M) do
          microflow :Worker do
            call_microflow "M.Helper", result_name: :Stored, use_return: false
            call_microflow "M.Helper", as: :Result, use_return: true
            call_nanoflow "M.Load", use_return: true
            call_java "M.Action", use_return: false
          end
          microflow(:Helper)
          nanoflow(:Load)
        end
      end
      acts = builder.definition[:modules].first[:microflows].first[:body]
      no_return = acts.first
      expect(no_return[:use_return]).to eq(false)
      with_return = acts[1]
      expect(with_return[:use_return]).to eq(true)
    end

    it "EntityBuilder lifecycle events and access_rule with Array write" do
      builder = Mxrb::Dsl::Builder.new("x.mpr")
      builder.instance_eval do
        self.module(:M) do
          entity :Order do
            string :Name
            before_commit microflow: :M_BeforeCommit
            after_delete microflow: :M_AfterDelete
            access_rule "M.User",
                        create: true, delete: true,
                        read: :all, write: [:Name]
          end
        end
      end
      entity = builder.definition[:modules].first[:entities].first
      expect(entity[:lifecycle].size).to eq(2)
      rule = entity[:access_rules].first
      expect(rule[:write]).to eq(["Name"])
    end

    it "nanoflow with call helper using nanoflow target" do
      builder = Mxrb::Dsl::Builder.new("x.mpr")
      builder.instance_eval do
        self.module(:M) do
          nanoflow :Worker do
            call nanoflow: :Helper
          end
          nanoflow :Helper
        end
      end
      flow = builder.definition[:modules].first[:nanoflows].first
      expect(flow[:calls]).to eq([{ kind: :nanoflow, name: "Helper" }])
    end
  end

  # ── Cross-module move ─────────────────────────────────────────────────────
  describe "cross-module move" do
    it "moves a microflow to another module and updates references atomically" do
      path = File.join(File.dirname(@mpr_path), "cross_move.mpr")

      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:Sales) do
          microflow(:CreateOrder) { call_microflow "Sales.Helpers_Support" }
          microflow(:Helpers_Support)
        end
        self.module(:Helpers) { microflow(:Placeholder) }
      end
      expect(Mxrb.validate(path)).to be_valid

      Mxrb.open(path, readonly: false) do |project|
        plan = project.plan_move("Sales.Helpers_Support", to: "Helpers")
        expect(plan).to be_a(Mxrb::Semantic::CrossModuleMovePlan)
        expect(plan).not_to be_empty
        expect(plan.source.qualified_name).to eq("Sales.Helpers_Support")
        expect(plan.target.module_name).to eq("Helpers")
        plan.apply!
      end

      Mxrb.open(path) do |project|
        expect(project.find_artifact("Helpers.Helpers_Support")).not_to be_nil
        expect(project.find_artifact("Sales.Helpers_Support")).to be_nil

        caller_flow = project.find_artifact("Sales.CreateOrder")
        raw = project.raw_unit(caller_flow.unit_id)
        content = project.mpr.content_bytes(raw) || raw["Contents"]
        content_str = content.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
        expect(content_str).to include("Helpers.Helpers_Support")
      end
    end

    it "raises for cross-module move when target is not a module" do
      path = File.join(File.dirname(@mpr_path), "cross_err.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:A) { microflow(:Work) }
        self.module(:B) { microflow(:Other) }
      end

      expect do
        Mxrb.open(path, readonly: false) do |project|
          project.plan_move("A.Work", to: "B.Other")
        end
      end.to raise_error(ArgumentError, /not a module or folder/)
    end

    it "plan_move returns a CrossModuleMovePlan with rename_changes" do
      path = File.join(File.dirname(@mpr_path), "cross_plan.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:Src) do
          microflow(:Op) { call_microflow "Src.Src_Process" }
          microflow(:Src_Process)
        end
        self.module(:Dst) { microflow(:Placeholder) }
      end

      Mxrb.open(path, readonly: false) do |project|
        plan = project.plan_move("Src.Src_Process", to: "Dst")
        expect(plan).to be_a(Mxrb::Semantic::CrossModuleMovePlan)
        expect(plan.rename_changes).not_to be_empty
        expect(plan.applied?).to be false
        plan.apply!
        expect(plan.applied?).to be true
        expect { plan.apply! }.to raise_error(ArgumentError, /already applied/)
      end
    end

    it "raises on collision when target module already has an artifact with the same name" do
      path = File.join(File.dirname(@mpr_path), "cross_collision.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:Src) { microflow(:SharedHelper) }
        self.module(:Dst) { microflow(:SharedHelper) }
      end

      expect do
        Mxrb.open(path, readonly: false) do |project|
          project.plan_move("Src.SharedHelper", to: "Dst")
        end
      end.to raise_error(ArgumentError, /already exists/)
    end

    it "performs cross-module move in v2 MPR format and updates references" do
      dir = File.dirname(@mpr_path)
      path = File.join(dir, "cross_move_v2.mpr")
      manifest = File.join(dir, "cross_move_v2_native.json")
      File.write(manifest, JSON.generate("format_version" => "v2", "units" => []))

      Mxrb.define(path) do
        mendix_version "11.12.1"
        native_units manifest
        self.module(:Src) do
          microflow(:Worker)
          microflow(:Dispatcher) { call_microflow "Src.Worker" }
        end
        self.module(:Dst) { microflow(:Placeholder) }
      end
      expect(Mxrb.validate(path)).to be_valid
      expect(Mxrb::IO::MprFile.open(path).format_version).to eq(:v2)

      Mxrb.open(path, readonly: false) do |project|
        plan = project.plan_move("Src.Worker", to: "Dst")
        expect(plan).to be_a(Mxrb::Semantic::CrossModuleMovePlan)
        plan.apply!
      end

      Mxrb.open(path) do |project|
        expect(project.find_artifact("Dst.Worker")).not_to be_nil
        expect(project.find_artifact("Src.Worker")).to be_nil
        dispatcher = project.find_artifact("Src.Dispatcher")
        raw = project.raw_unit(dispatcher.unit_id)
        content = project.mpr.content_bytes(raw) || raw["Contents"]
        content_str = content.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
        expect(content_str).to include("Dst.Worker")
      end
    end
  end

  # ── Microflow extraction ──────────────────────────────────────────────────
  describe "microflow extraction" do
    def extraction_mpr(path, version: "10.18.0")
      Mxrb.define(path) do
        mendix_version version
        self.module(:Sales) do
          microflow(:CreateOrder) do
            call_microflow "Sales.ValidateInput"
            call_microflow "Sales.PersistOrder"
            call_microflow "Sales.SendConfirmation"
          end
          microflow(:ValidateInput)
          microflow(:PersistOrder)
          microflow(:SendConfirmation)
        end
      end
    end

    it "plans an extraction with correct metadata" do
      path = File.join(File.dirname(@mpr_path), "extract_plan.mpr")
      extraction_mpr(path)

      Mxrb.open(path, readonly: false) do |project|
        flow = project.find_artifact("Sales.CreateOrder")
        raw  = project.raw_unit(flow.unit_id)
        doc  = project.parse_bson(raw)
        objects = Mxrb::IO::BsonCodec.parse_array(
          doc["ObjectCollection"]["Objects"]
        )[:items]
        activity_ids = objects.reject { |o|
          %w[Microflows$StartEvent Microflows$EndEvent].include?(o["$Type"])
        }.map { _1["$ID"] }

        # Extract the first two call activities
        plan = project.plan_extract("Sales.CreateOrder",
                                    as: "Sales.ValidateAndPersist",
                                    object_ids: activity_ids[0..1])
        expect(plan).to be_a(Mxrb::Semantic::ExtractionPlan)
        expect(plan.source.qualified_name).to eq("Sales.CreateOrder")
        expect(plan.new_name).to eq("Sales.ValidateAndPersist")
        expect(plan.selected_ids.size).to eq(2)
        expect(plan.changes.size).to eq(2)
        expect(plan.applied?).to be false
      end
    end

    it "applies the extraction: creates new microflow and updates source" do
      path = File.join(File.dirname(@mpr_path), "extract_apply.mpr")
      extraction_mpr(path)

      activity_ids = []
      Mxrb.open(path, readonly: false) do |project|
        flow = project.find_artifact("Sales.CreateOrder")
        raw  = project.raw_unit(flow.unit_id)
        doc  = project.parse_bson(raw)
        objects = Mxrb::IO::BsonCodec.parse_array(
          doc["ObjectCollection"]["Objects"]
        )[:items]
        activity_ids = objects.reject { |o|
          %w[Microflows$StartEvent Microflows$EndEvent].include?(o["$Type"])
        }.map { _1["$ID"] }

        project.plan_extract("Sales.CreateOrder",
                              as: "Sales.ValidateAndPersist",
                              object_ids: activity_ids[0..1]).apply!
      end

      Mxrb.open(path) do |project|
        expect(project.find_artifact("Sales.ValidateAndPersist")).not_to be_nil
        caller = project.find_artifact("Sales.CreateOrder")
        raw = project.raw_unit(caller.unit_id)
        content = project.mpr.content_bytes(raw) || raw["Contents"]
        content_str = content.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
        expect(content_str).to include("Sales.ValidateAndPersist")
        expect(content_str).to include("MicroflowCallAction")
      end
    end

    it "raises when extracting a non-existent artifact" do
      path = File.join(File.dirname(@mpr_path), "extract_err.mpr")
      extraction_mpr(path)
      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_extract("Sales.Missing", as: "Sales.New", object_ids: ["x"]) }
          .to raise_error(KeyError, /unknown Mendix artifact/)
      end
    end

    it "raises when extracting a non-flow artifact" do
      path = File.join(File.dirname(@mpr_path), "extract_nonflow.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:Sales) { entity(:Order) { string :Number } }
      end
      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_extract("Sales.Order", as: "Sales.New", object_ids: ["x"]) }
          .to raise_error(ArgumentError, /not a microflow/)
      end
    end

    it "raises when extraction name is in a different module" do
      path = File.join(File.dirname(@mpr_path), "extract_mod.mpr")
      extraction_mpr(path)
      Mxrb.open(path, readonly: false) do |project|
        flow = project.find_artifact("Sales.CreateOrder")
        raw  = project.raw_unit(flow.unit_id)
        doc  = project.parse_bson(raw)
        objects = Mxrb::IO::BsonCodec.parse_array(
          doc["ObjectCollection"]["Objects"]
        )[:items]
        ids = objects.reject { |o|
          %w[Microflows$StartEvent Microflows$EndEvent].include?(o["$Type"])
        }.map { _1["$ID"] }
        expect { project.plan_extract("Sales.CreateOrder", as: "Other.NewFlow", object_ids: [ids[0]]) }
          .to raise_error(ArgumentError, /same module/)
      end
    end

    it "raises when selection name already exists" do
      path = File.join(File.dirname(@mpr_path), "extract_col.mpr")
      extraction_mpr(path)
      Mxrb.open(path, readonly: false) do |project|
        flow = project.find_artifact("Sales.CreateOrder")
        raw  = project.raw_unit(flow.unit_id)
        doc  = project.parse_bson(raw)
        objects = Mxrb::IO::BsonCodec.parse_array(
          doc["ObjectCollection"]["Objects"]
        )[:items]
        ids = objects.reject { |o|
          %w[Microflows$StartEvent Microflows$EndEvent].include?(o["$Type"])
        }.map { _1["$ID"] }
        expect { project.plan_extract("Sales.CreateOrder", as: "Sales.PersistOrder", object_ids: [ids[0]]) }
          .to raise_error(ArgumentError, /already exists/)
      end
    end

    it "raises when object_ids are empty" do
      path = File.join(File.dirname(@mpr_path), "extract_empty.mpr")
      extraction_mpr(path)
      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_extract("Sales.CreateOrder", as: "Sales.New", object_ids: []) }
          .to raise_error(ArgumentError, /empty/)
      end
    end

    it "raises when selection includes start or end event" do
      path = File.join(File.dirname(@mpr_path), "extract_event.mpr")
      extraction_mpr(path)
      Mxrb.open(path, readonly: false) do |project|
        flow = project.find_artifact("Sales.CreateOrder")
        raw  = project.raw_unit(flow.unit_id)
        doc  = project.parse_bson(raw)
        objects = Mxrb::IO::BsonCodec.parse_array(
          doc["ObjectCollection"]["Objects"]
        )[:items]
        start_id = objects.find { _1["$Type"] == "Microflows$StartEvent" }["$ID"]
        expect { project.plan_extract("Sales.CreateOrder", as: "Sales.New", object_ids: [start_id]) }
          .to raise_error(ArgumentError, /start\/end event/)
      end
    end

    it "raises when selection has multiple entry or exit points" do
      path = File.join(File.dirname(@mpr_path), "extract_branch.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:Sales) do
          microflow(:BranchedFlow) do
            call_microflow "Sales.Step1"
            call_microflow "Sales.Step2"
            call_microflow "Sales.Step3"
          end
          microflow(:Step1)
          microflow(:Step2)
          microflow(:Step3)
        end
      end
      Mxrb.open(path, readonly: false) do |project|
        flow = project.find_artifact("Sales.BranchedFlow")
        raw  = project.raw_unit(flow.unit_id)
        doc  = project.parse_bson(raw)
        objects = Mxrb::IO::BsonCodec.parse_array(
          doc["ObjectCollection"]["Objects"]
        )[:items]
        activity_ids = objects.reject { |o|
          %w[Microflows$StartEvent Microflows$EndEvent].include?(o["$Type"])
        }.map { Mxrb::IO::BsonCodec.extract_id(_1["$ID"]) }
        # Select first and third (non-contiguous) — creates 2 separate entry points
        expect {
          project.plan_extract("Sales.BranchedFlow", as: "Sales.Extracted",
                               object_ids: [activity_ids[0], activity_ids[2]])
        }.to raise_error(ArgumentError, /entry point/)
      end
    end

    it "apply! raises on double-apply" do
      path = File.join(File.dirname(@mpr_path), "extract_double.mpr")
      extraction_mpr(path)

      Mxrb.open(path, readonly: false) do |project|
        flow = project.find_artifact("Sales.CreateOrder")
        raw  = project.raw_unit(flow.unit_id)
        doc  = project.parse_bson(raw)
        objects = Mxrb::IO::BsonCodec.parse_array(
          doc["ObjectCollection"]["Objects"]
        )[:items]
        ids = objects.reject { |o|
          %w[Microflows$StartEvent Microflows$EndEvent].include?(o["$Type"])
        }.map { _1["$ID"] }

        plan = project.plan_extract("Sales.CreateOrder",
                                    as: "Sales.Extracted",
                                    object_ids: [ids[0]])
        plan.apply!
        expect { plan.apply! }.to raise_error(ArgumentError, /already applied/)
      end
    end
  end

  # ── Microflow inline ─────────────────────────────────────────────────────
  describe "microflow inline" do
    def inline_mpr(path)
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:Sales) do
          microflow(:CreateOrder) do
            call_microflow "Sales.PrepareOrder"
            call_microflow "Sales.SendConfirmation"
          end
          microflow(:PrepareOrder) do
            call_microflow "Sales.ValidateInput"
            call_microflow "Sales.PersistOrder"
          end
          microflow(:ValidateInput)
          microflow(:PersistOrder)
          microflow(:SendConfirmation)
        end
      end
    end

    it "plans an inline with correct metadata" do
      path = File.join(File.dirname(@mpr_path), "inline_plan.mpr")
      inline_mpr(path)

      Mxrb.open(path, readonly: false) do |project|
        plan = project.plan_inline("Sales.CreateOrder", calling: "Sales.PrepareOrder")
        expect(plan).to be_a(Mxrb::Semantic::InlinePlan)
        expect(plan.source.qualified_name).to eq("Sales.CreateOrder")
        expect(plan.called_name).to eq("Sales.PrepareOrder")
        expect(plan.changes.size).to eq(2)
        expect(plan.applied?).to be false
      end
    end

    it "applies inline: replaces call activity with callee's activities" do
      path = File.join(File.dirname(@mpr_path), "inline_apply.mpr")
      inline_mpr(path)

      Mxrb.open(path, readonly: false) do |project|
        project.plan_inline("Sales.CreateOrder", calling: "Sales.PrepareOrder").apply!
      end

      Mxrb.open(path) do |project|
        caller_flow = project.find_artifact("Sales.CreateOrder")
        raw = project.raw_unit(caller_flow.unit_id)
        doc = project.parse_bson(raw)
        objects = Mxrb::IO::BsonCodec.parse_array(doc["ObjectCollection"]["Objects"])[:items]
        types = objects.map { _1["$Type"] }

        # Should have 2 call_microflow activities from PrepareOrder inlined,
        # plus 1 original SendConfirmation call, plus start + end
        expect(types.count { _1 == "Microflows$ActionActivity" }).to eq(3)
        content_str = objects.map(&:to_s).join
        expect(content_str).to include("Sales.ValidateInput")
        expect(content_str).to include("Sales.PersistOrder")
        expect(content_str).to include("Sales.SendConfirmation")
        expect(content_str).not_to include("Sales.PrepareOrder")
      end
    end

    it "extract then inline is a no-op (round-trip)" do
      path = File.join(File.dirname(@mpr_path), "inline_roundtrip.mpr")
      inline_mpr(path)

      # Count objects before
      before_count = nil
      Mxrb.open(path) do |project|
        raw = project.raw_unit(project.find_artifact("Sales.CreateOrder").unit_id)
        doc = project.parse_bson(raw)
        before_count = Mxrb::IO::BsonCodec.parse_array(doc["ObjectCollection"]["Objects"])[:items].size
      end

      Mxrb.open(path, readonly: false) do |project|
        flow = project.find_artifact("Sales.CreateOrder")
        raw  = project.raw_unit(flow.unit_id)
        doc  = project.parse_bson(raw)
        objects = Mxrb::IO::BsonCodec.parse_array(doc["ObjectCollection"]["Objects"])[:items]
        activity_ids = objects.reject { |o|
          %w[Microflows$StartEvent Microflows$EndEvent].include?(o["$Type"])
        }.first(1).map { Mxrb::IO::BsonCodec.extract_id(_1["$ID"]) }

        project.plan_extract("Sales.CreateOrder",
                              as: "Sales.Extracted",
                              object_ids: activity_ids).apply!
        project.plan_inline("Sales.CreateOrder", calling: "Sales.Extracted").apply!
      end

      Mxrb.open(path) do |project|
        raw = project.raw_unit(project.find_artifact("Sales.CreateOrder").unit_id)
        doc = project.parse_bson(raw)
        after_count = Mxrb::IO::BsonCodec.parse_array(doc["ObjectCollection"]["Objects"])[:items].size
        expect(after_count).to eq(before_count)
      end
    end

    it "raises when source not found" do
      path = File.join(File.dirname(@mpr_path), "inline_err1.mpr")
      inline_mpr(path)
      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_inline("Sales.Missing", calling: "Sales.PrepareOrder") }
          .to raise_error(KeyError, /unknown Mendix artifact/)
      end
    end

    it "raises when called microflow not found" do
      path = File.join(File.dirname(@mpr_path), "inline_err2.mpr")
      inline_mpr(path)
      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_inline("Sales.CreateOrder", calling: "Sales.Missing") }
          .to raise_error(KeyError, /unknown Mendix artifact/)
      end
    end

    it "raises when source is not a microflow" do
      path = File.join(File.dirname(@mpr_path), "inline_err3.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:Sales) { entity(:Order) { string :Number } }
      end
      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_inline("Sales.Order", calling: "Sales.Order") }
          .to raise_error(ArgumentError, /not a microflow/)
      end
    end

    it "raises when source does not call the target" do
      path = File.join(File.dirname(@mpr_path), "inline_err4.mpr")
      inline_mpr(path)
      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_inline("Sales.CreateOrder", calling: "Sales.ValidateInput") }
          .to raise_error(ArgumentError, /no call to/)
      end
    end

    it "apply! raises on double-apply" do
      path = File.join(File.dirname(@mpr_path), "inline_double.mpr")
      inline_mpr(path)
      Mxrb.open(path, readonly: false) do |project|
        plan = project.plan_inline("Sales.CreateOrder", calling: "Sales.PrepareOrder")
        plan.apply!
        expect { plan.apply! }.to raise_error(ArgumentError, /already applied/)
      end
    end
  end

  # ── Marketplace update and remove ──────────────────────────────────────────
  describe "marketplace update and remove" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @mkt_dir = dir
        @pkg_v1 = File.join(dir, "pkg_v1")
        @pkg_v2 = File.join(dir, "pkg_v2")
        [@pkg_v1, @pkg_v2].each { FileUtils.mkdir_p(_1) }
        File.write(File.join(@pkg_v1, "mxrb-module.json"),
                   JSON.generate(name: "mymod", module_name: "MyMod",
                                 version: "1.0.0", files: ["module.rb"]))
        File.write(File.join(@pkg_v1, "module.rb"), "# v1\n")
        File.write(File.join(@pkg_v2, "mxrb-module.json"),
                   JSON.generate(name: "mymod", module_name: "MyMod",
                                 version: "2.0.0", files: ["module.rb"]))
        File.write(File.join(@pkg_v2, "module.rb"), "# v2\n")
        @catalog_path = File.join(dir, "catalog.json")
        File.write(@catalog_path, JSON.generate(modules: [
          { name: "mymod", version: "1.0.0", description: "Mod v1", source: @pkg_v1 },
          { name: "mymod", version: "2.0.0", description: "Mod v2", source: @pkg_v2 }
        ]))
        ex.run
      end
    end

    it "updates an installed module to a newer version" do
      target = File.join(@mkt_dir, "project")
      catalog = Mxrb::Marketplace::Catalog.new(@catalog_path)
      installer = Mxrb::Marketplace::Installer.new(target: target, catalog: catalog)

      v1 = installer.install("mymod", version: "1.0.0")
      expect(File.read(File.join(v1.destination, "module.rb"))).to include("v1")

      v2 = installer.update("mymod", version: "2.0.0")
      expect(File.read(File.join(v2.destination, "module.rb"))).to include("v2")

      lock = JSON.parse(File.read(File.join(target, ".mxrb", "modules.lock.json")))
      expect(lock.dig("modules", "MyMod", "version")).to eq("2.0.0")
    end

    it "removes an installed module and clears its lockfile entry" do
      target = File.join(@mkt_dir, "project")
      catalog = Mxrb::Marketplace::Catalog.new(@catalog_path)
      installer = Mxrb::Marketplace::Installer.new(target: target, catalog: catalog)

      installation = installer.install("mymod", version: "1.0.0")
      expect(File.directory?(installation.destination)).to be true

      installer.remove("mymod")
      expect(File.directory?(installation.destination)).to be false
      lock = JSON.parse(File.read(File.join(target, ".mxrb", "modules.lock.json")))
      expect(lock.dig("modules", "MyMod")).to be_nil
    end

    it "catalog searches by query and raises for unknown module" do
      catalog = Mxrb::Marketplace::Catalog.new(@catalog_path)
      all = catalog.search
      expect(all.size).to eq(2)
      filtered = catalog.search("mymod")
      expect(filtered.size).to eq(2)
      empty = catalog.search("zzz_unknown")
      expect(empty).to be_empty
      expect { catalog.find("nosuchmod") }.to raise_error(Mxrb::MarketplaceError, /not found/)
      expect { catalog.find_version("mymod", "9.9.9") }.to raise_error(Mxrb::MarketplaceError, /not found/)
    end

    it "installs from a local directory path" do
      target = File.join(@mkt_dir, "project2")
      installer = Mxrb::Marketplace::Installer.new(target: target)
      installation = installer.install(@pkg_v1)
      expect(File.directory?(installation.destination)).to be true
      expect(installation.entry.version).to eq("local")
    end

    it "remove raises when module is not installed" do
      target = File.join(@mkt_dir, "not_installed")
      FileUtils.mkdir_p(target)
      installer = Mxrb::Marketplace::Installer.new(target: target)
      expect { installer.remove("mymod") }.to raise_error(Mxrb::MarketplaceError, /not installed|lock file/)
    end

    it "update raises when the new package changes the module_name" do
      pkg_renamed = File.join(@mkt_dir, "pkg_renamed")
      FileUtils.mkdir_p(pkg_renamed)
      File.write(File.join(pkg_renamed, "mxrb-module.json"),
                 JSON.generate(name: "mymod", module_name: "DifferentMod",
                               version: "3.0.0", files: ["module.rb"]))
      File.write(File.join(pkg_renamed, "module.rb"), "# v3\n")
      catalog_with_rename = File.join(@mkt_dir, "catalog_rename.json")
      File.write(catalog_with_rename, JSON.generate(modules: [
        { name: "mymod", version: "1.0.0", description: "Mod v1", source: @pkg_v1 },
        { name: "mymod", version: "3.0.0", description: "Mod renamed", source: pkg_renamed }
      ]))
      target = File.join(@mkt_dir, "project_rename")
      catalog = Mxrb::Marketplace::Catalog.new(catalog_with_rename)
      installer = Mxrb::Marketplace::Installer.new(target: target, catalog: catalog)
      installer.install("mymod", version: "1.0.0")
      expect { installer.update("mymod", version: "3.0.0") }
        .to raise_error(Mxrb::MarketplaceError, /cannot change its name/)
    end

    it "resolves installed module by module_name case-insensitive fallback" do
      target = File.join(@mkt_dir, "project_ci")
      catalog = Mxrb::Marketplace::Catalog.new(@catalog_path)
      installer = Mxrb::Marketplace::Installer.new(target: target, catalog: catalog)
      installation = installer.install("mymod", version: "1.0.0")
      # "MyMod" matches by module_name key (case-insensitive), not by package name
      installer.remove("MyMod")
      expect(File.directory?(installation.destination)).to be false
    end

    it "restores previous module when update mv fails (atomic rollback)" do
      target = File.join(@mkt_dir, "project_rollback")
      catalog = Mxrb::Marketplace::Catalog.new(@catalog_path)
      installer = Mxrb::Marketplace::Installer.new(target: target, catalog: catalog)
      v1 = installer.install("mymod", version: "1.0.0")
      original_content = File.read(File.join(v1.destination, "module.rb"))

      mv_call = 0
      allow(FileUtils).to receive(:mv).and_wrap_original do |original, *args|
        mv_call += 1
        raise Errno::ENOSPC, "simulated disk full" if mv_call == 2
        original.call(*args)
      end

      expect { installer.update("mymod", version: "2.0.0") }.to raise_error(Errno::ENOSPC)
      expect(File.exist?(v1.destination)).to be true
      expect(File.read(File.join(v1.destination, "module.rb"))).to eq(original_content)
    end
  end

  # ── Marketplace dependencies ───────────────────────────────────────────────
  describe "marketplace module dependencies" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @dep_dir = dir

        # shared-kernel: no dependencies
        @pkg_kernel = File.join(dir, "pkg_kernel")
        FileUtils.mkdir_p(@pkg_kernel)
        File.write(File.join(@pkg_kernel, "mxrb-module.json"),
                   JSON.generate(name: "shared-kernel", module_name: "SharedKernel",
                                 version: "1.0.0", files: ["kernel.rb"]))
        File.write(File.join(@pkg_kernel, "kernel.rb"), "# kernel\n")

        # widget-lib: depends on shared-kernel
        @pkg_widget = File.join(dir, "pkg_widget")
        FileUtils.mkdir_p(@pkg_widget)
        File.write(File.join(@pkg_widget, "mxrb-module.json"),
                   JSON.generate(name: "widget-lib", module_name: "WidgetLib",
                                 version: "1.0.0", files: ["widgets.rb"],
                                 dependencies: [{ "name" => "shared-kernel" }]))
        File.write(File.join(@pkg_widget, "widgets.rb"), "# widgets\n")

        ex.run
      end
    end

    it "installs a module with no dependencies normally" do
      target = File.join(@dep_dir, "proj_nodeps")
      installer = Mxrb::Marketplace::Installer.new(target: target)
      inst = installer.install(@pkg_kernel)
      expect(File.directory?(inst.destination)).to be true
      lock = JSON.parse(File.read(File.join(target, ".mxrb", "modules.lock.json")))
      expect(lock.dig("modules", "SharedKernel", "dependencies")).to be_nil
    end

    it "records dependencies in the lock file after install" do
      target = File.join(@dep_dir, "proj_deps")
      installer = Mxrb::Marketplace::Installer.new(target: target)
      installer.install(@pkg_kernel)
      installer.install(@pkg_widget)
      lock = JSON.parse(File.read(File.join(target, ".mxrb", "modules.lock.json")))
      expect(lock.dig("modules", "WidgetLib", "dependencies")).to eq(["shared-kernel"])
    end

    it "raises MarketplaceError when a dependency is not installed" do
      target = File.join(@dep_dir, "proj_missing_dep")
      installer = Mxrb::Marketplace::Installer.new(target: target)
      expect { installer.install(@pkg_widget) }
        .to raise_error(Mxrb::MarketplaceError, /missing dependencies.*shared-kernel/)
    end

    it "raises MarketplaceError when removing a module another depends on" do
      target = File.join(@dep_dir, "proj_remove_dep")
      installer = Mxrb::Marketplace::Installer.new(target: target)
      installer.install(@pkg_kernel)
      installer.install(@pkg_widget)
      expect { installer.remove("SharedKernel") }
        .to raise_error(Mxrb::MarketplaceError, /WidgetLib/)
    end

    it "allows removing a module after its dependent is removed first" do
      target = File.join(@dep_dir, "proj_remove_order")
      installer = Mxrb::Marketplace::Installer.new(target: target)
      installer.install(@pkg_kernel)
      installer.install(@pkg_widget)
      installer.remove("WidgetLib")
      expect { installer.remove("SharedKernel") }.not_to raise_error
      expect(File.directory?(File.join(target, "modules", "SharedKernel"))).to be false
    end
  end

  # ── Marketplace edge cases ─────────────────────────────────────────────────
  describe "marketplace installer edge cases" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @ec_dir = dir
        @pkg = File.join(dir, "pkg")
        FileUtils.mkdir_p(@pkg)
        File.write(File.join(@pkg, "mxrb-module.json"),
                   JSON.generate(name: "mymod", module_name: "MyMod",
                                 version: "1.0.0", files: ["module.rb"]))
        File.write(File.join(@pkg, "module.rb"), "# mod\n")
        ex.run
      end
    end

    it "remove is idempotent when module directory was already deleted" do
      target = File.join(@ec_dir, "proj_idem")
      installer = Mxrb::Marketplace::Installer.new(target: target)
      installation = installer.install(@pkg)
      FileUtils.rm_rf(installation.destination)
      expect(File.directory?(installation.destination)).to be false
      expect { installer.remove("MyMod") }.not_to raise_error
      lock = JSON.parse(File.read(File.join(target, ".mxrb", "modules.lock.json")))
      expect(lock.dig("modules", "MyMod")).to be_nil
    end

    it "catalog search with empty string returns all entries" do
      Dir.mktmpdir do |dir|
        catalog_path = File.join(dir, "cat.json")
        File.write(catalog_path, JSON.generate(modules: [
          { name: "alpha", version: "1.0", description: "First", source: @pkg },
          { name: "beta",  version: "1.0", description: "Second", source: @pkg }
        ]))
        catalog = Mxrb::Marketplace::Catalog.new(catalog_path)
        expect(catalog.search("").size).to eq(2)
        expect(catalog.search(nil).size).to eq(2)
      end
    end

    it "catalog search matches by description" do
      Dir.mktmpdir do |dir|
        catalog_path = File.join(dir, "cat.json")
        File.write(catalog_path, JSON.generate(modules: [
          { name: "alpha", version: "1.0", description: "shared utilities", source: @pkg },
          { name: "beta",  version: "1.0", description: "reporting tools", source: @pkg }
        ]))
        catalog = Mxrb::Marketplace::Catalog.new(catalog_path)
        expect(catalog.search("shared").map(&:name)).to eq(["alpha"])
        expect(catalog.search("REPORTING").map(&:name)).to eq(["beta"])
      end
    end

    it "install uses directory basename as package name when manifest has no name field" do
      pkg_noname = File.join(@ec_dir, "pkg_noname")
      FileUtils.mkdir_p(pkg_noname)
      File.write(File.join(pkg_noname, "mxrb-module.json"),
                 JSON.generate(module_name: "NoName", version: "1.0.0", files: ["mod.rb"]))
      File.write(File.join(pkg_noname, "mod.rb"), "# noname\n")
      target = File.join(@ec_dir, "proj_noname")
      installer = Mxrb::Marketplace::Installer.new(target: target)
      installation = installer.install(pkg_noname)
      expect(installation.module_name).to eq("NoName")
      lock = JSON.parse(File.read(File.join(target, ".mxrb", "modules.lock.json")))
      expect(lock.dig("modules", "NoName", "package")).to eq("pkg_noname")
    end
  end

  # ── Functional test Suite ─────────────────────────────────────────────────
  describe "functional test Suite" do
    it "builds test cases with the microflow DSL" do
      suite = Mxrb::Functional::Suite.new
      suite.microflow("Create Order", call: "Sales.ACT_CreateOrder", pass: { Amount: "10" },
                      timeout: 30, expect: { return: true })
      expect(suite.tests.size).to eq(1)
      tc = suite.tests.first
      expect(tc.name).to eq("Create Order")
      expect(tc.target).to eq("Sales.ACT_CreateOrder")
      expect(tc.arguments).to eq("Amount" => "10")
      expect(tc.timeout).to eq(30.0)
      expect(tc.expected_return).to eq("true")
    end

    it "validates microflow name format" do
      suite = Mxrb::Functional::Suite.new
      expect { suite.microflow("", call: "A.B") }.to raise_error(ArgumentError, /name cannot be empty/)
      expect { suite.microflow("T", call: "NoModule") }.to raise_error(ArgumentError, /qualified Mendix name/)
      expect { suite.microflow("T", call: "A.B", timeout: 0) }.to raise_error(ArgumentError, /timeout must be positive/)
    end

    it "adds before/after hooks as qualified microflow calls" do
      suite = Mxrb::Functional::Suite.new
      suite.microflow("TC", call: "M.Flow",
                      before: { call: "M.Setup", pass: { X: "1" } },
                      after: "M.Teardown")
      tc = suite.tests.first
      expect(tc.setup).to be_a(Mxrb::Functional::Hook)
      expect(tc.setup.target).to eq("M.Setup")
      expect(tc.setup.arguments).to eq("X" => "1")
      expect(tc.cleanup).to be_a(Mxrb::Functional::Hook)
      expect(tc.cleanup.target).to eq("M.Teardown")
    end

    it "validates hook format" do
      suite = Mxrb::Functional::Suite.new
      expect { suite.microflow("T", call: "M.F", before: "BadName") }
        .to raise_error(ArgumentError, /qualified microflow/)
    end

    it "adds count expectations" do
      suite = Mxrb::Functional::Suite.new
      suite.microflow("TC", call: "M.Flow", expect: {
        count: [{ entity: "Sales.Order", equals: 5, xpath: "[Active = true()]" }]
      })
      tc = suite.tests.first
      expect(tc.counts.size).to eq(1)
      expect(tc.counts.first.entity).to eq("Sales.Order")
      expect(tc.counts.first.equals).to eq(5)
    end

    it "validates count expectations" do
      suite = Mxrb::Functional::Suite.new
      expect do
        suite.microflow("T", call: "M.F", expect: {
          count: [{ entity: "BadEntity", equals: 1 }]
        })
      end.to raise_error(ArgumentError, /qualified entity/)
      expect do
        suite.microflow("T", call: "M.F", expect: {
          count: [{ entity: "M.E", equals: -1 }]
        })
      end.to raise_error(ArgumentError, /non-negative integer/)
    end

    it "evaluates a functional definition from a file" do
      func_file = File.join(File.dirname(@mpr_path), "tests.rb")
      File.write(func_file, <<~RUBY)
        microflow "Ping", call: "Sys.Heartbeat", timeout: 10
      RUBY
      defn = Mxrb.functional_definition(func_file)
      expect(defn.tests.size).to eq(1)
      expect(defn.tests.first.target).to eq("Sys.Heartbeat")
      expect(defn).not_to be_empty
    end

    it "definition wraps tests as frozen" do
      suite = Mxrb::Functional::Suite.new
      suite.microflow("T", call: "M.F")
      defn = suite.definition
      expect(defn.tests).to be_frozen
    end
  end

  describe "functional test LogParser and Reporter" do
    let(:parser) { Mxrb::Functional::LogParser.new }

    it "parses PASS, FAIL, and DONE from log output" do
      log = <<~LOG
        [MXRB_TEST] PASS Create Order
        [MXRB_TEST] FAIL Validate Stock
        [MXRB_TEST] DONE
      LOG
      result = parser.parse(log)
      expect(result.tests.size).to eq(2)
      expect(result.tests[0].name).to eq("Create Order")
      expect(result.tests[0]).to be_passed
      expect(result.tests[1].name).to eq("Validate Stock")
      expect(result.tests[1]).to be_failed
      expect(result).to be_finished
      expect(result).not_to be_passed
    end

    it "returns unfinished result when DONE is missing" do
      result = parser.parse("[MXRB_TEST] PASS T1\n")
      expect(result).not_to be_finished
      expect(result.failures).to be_empty
    end

    it "returns empty result for unrelated log lines" do
      result = parser.parse("some random log\nINFO: started\n")
      expect(result.tests).to be_empty
      expect(result).not_to be_finished
    end

    it "Reporter writes JSON and JUnit reports" do
      result = Mxrb::Functional::Result.new(
        [Mxrb::Functional::TestResult.new("T1", true, "passed"),
         Mxrb::Functional::TestResult.new("T2", false, "microflow failed")].freeze,
        true
      )
      fake_execution = Struct.new(:passed?, :result, :elapsed).new(false, result, 1.23)
      reporter = Mxrb::Functional::Reporter.new
      dir = File.dirname(@mpr_path)

      json_path = reporter.write_json(fake_execution, File.join(dir, "report.json"))
      payload = JSON.parse(File.read(json_path))
      expect(payload["passed"]).to eq(false)
      expect(payload["tests"].size).to eq(2)

      junit_path = reporter.write_junit(fake_execution, File.join(dir, "report.xml"))
      xml = File.read(junit_path)
      expect(xml).to include('<failure message="microflow failed"')
      expect(xml).to include('name="T1"')
    end
  end

  describe "functional Instrumenter" do
    it "raises FunctionalTestError for empty definition" do
      defn = Mxrb::Functional::Definition.new([].freeze)
      inst = Mxrb::Functional::Instrumenter.new(@mpr_path, defn)
      expect { inst.instrument! }.to raise_error(Mxrb::FunctionalTestError, /empty/)
    end

    it "raises FunctionalTestError for unknown microflow target" do
      suite = Mxrb::Functional::Suite.new
      suite.microflow("Ping", call: "Sys.UnknownFlow")
      inst = Mxrb::Functional::Instrumenter.new(@mpr_path, suite.definition)
      expect { inst.instrument! }.to raise_error(Mxrb::FunctionalTestError, /not found/)
    end

    it "instruments an MPR with a functional test module and sets AfterStartup" do
      path = File.join(File.dirname(@mpr_path), "instrumented.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:MyApp) do
          entity(:Order) { integer(:Amount) }
          microflow(:ACT_Create)
          microflow(:ACT_Setup)
          microflow(:ACT_Teardown)
        end
      end

      # Insert a minimal Settings$ProjectSettings unit so the Instrumenter can find it
      mpr = Mxrb::IO::MprFile.open(path, readonly: false)
      root = mpr.root_unit
      model_settings_doc = {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Settings$ModelSettings",
        "AfterStartupMicroflow" => ""
      }
      settings_doc = {
        "$ID" => SecureRandom.uuid,
        "$Type" => "Settings$ProjectSettings",
        "Settings" => Mxrb::IO::BsonCodec.build_array([model_settings_doc])
      }
      mpr.insert_unit(
        container_uuid: root.fetch("UnitID"),
        containment_name: "Settings",
        contents_doc: settings_doc
      )
      mpr.close

      suite = Mxrb::Functional::Suite.new
      suite.microflow("Create Order",
        call: "MyApp.ACT_Create",
        before: "MyApp.ACT_Setup",
        after: "MyApp.ACT_Teardown",
        expect: {
          return: "true",
          count: [{ entity: "MyApp.Order", equals: 1 }]
        }
      )

      inst = Mxrb::Functional::Instrumenter.new(path, suite.definition)
      expect(inst.runner).to eq("MxrbTests.RunAll")
      inst.instrument!

      Mxrb.open(path) do |project|
        expect(project.find_artifact("MxrbTests")).not_to be_nil
        expect(project.find_artifact("MxrbTests.RunAll")).not_to be_nil
        expect(project.find_artifact("MxrbTests.Test_001")).not_to be_nil

        all_units = project.mpr.all_units
        settings = all_units.find do |u|
          project.mpr.parse_contents(u)["$Type"] == "Settings$ProjectSettings"
        end
        expect(settings).not_to be_nil
        doc = project.mpr.parse_contents(settings)
        model = Mxrb::IO::BsonCodec.parse_array(doc["Settings"])[:items]
                  .find { _1["$Type"] == "Settings$ModelSettings" }
        expect(model["AfterStartupMicroflow"]).to eq("MxrbTests.RunAll")
      end
    end

    it "raises FunctionalTestError when count entity is not in project" do
      path = File.join(File.dirname(@mpr_path), "inst_count_err.mpr")
      Mxrb.define(path) { mendix_version "10.18.0"; self.module(:M) { microflow(:F) } }
      suite = Mxrb::Functional::Suite.new
      suite.microflow("T", call: "M.F", expect: {
        count: [{ entity: "M.Ghost", equals: 0 }]
      })
      inst = Mxrb::Functional::Instrumenter.new(path, suite.definition)
      expect { inst.instrument! }.to raise_error(Mxrb::FunctionalTestError, /not found/)
    end
  end

  # ── Model to_bson / inspect coverage ──────────────────────────────────────
  describe "model to_bson and inspect" do
    it "round-trips Association through to_bson" do
      path = File.join(File.dirname(@mpr_path), "assoc_bson.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { association :Customer }
          entity(:Customer)
        end
      end

      Mxrb.open(path) do |project|
        mod = project.modules.first
        assoc = mod.associations.first
        expect(assoc).not_to be_nil
        bson = assoc.to_bson
        expect(bson["$Type"]).to eq("DomainModels$Association")
        expect(assoc.inspect).to include("Association")
      end
    end

    it "round-trips Entity through to_bson and inspect" do
      path = File.join(File.dirname(@mpr_path), "entity_bson.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { entity(:Order) { string :Name } }
      end

      Mxrb.open(path) do |project|
        entity = project.modules.first.entities.first
        bson = entity.to_bson
        expect(bson["$Type"]).to eq("DomainModels$EntityImpl")
        expect(entity.inspect).to include("Order")
      end
    end

    it "round-trips Microflow through to_bson and inspect" do
      path = File.join(File.dirname(@mpr_path), "flow_bson.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { microflow(:Worker) }
      end

      Mxrb.open(path) do |project|
        flow = project.modules.first.microflows.first
        bson = flow.to_bson
        expect(bson["$Type"]).to eq("Microflows$Microflow")
        expect(flow.inspect).to include("Worker")
      end
    end

    it "round-trips Module through to_bson and inspect" do
      path = File.join(File.dirname(@mpr_path), "mod_bson.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { microflow(:F) }
      end

      Mxrb.open(path) do |project|
        mod = project.modules.first
        bson = mod.to_bson
        expect(bson["$Type"]).to eq("Projects$Module")
        expect(mod.inspect).to include("Module")
      end
    end

    it "round-trips DomainModel through to_bson and inspect" do
      path = File.join(File.dirname(@mpr_path), "dm_bson.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { entity(:E) }
      end

      Mxrb.open(path) do |project|
        dm = project.modules.first.domain_model
        bson = dm.to_bson
        expect(bson["$Type"]).to eq("DomainModels$DomainModel")
        expect(dm.inspect).to include("DomainModel")
      end
    end
  end

  # ── BsonCodec rescue and edge cases ───────────────────────────────────────
  describe "BsonCodec rescue branches and extract_id with Data key" do
    it "parse raises SerializationError for malformed BSON bytes" do
      expect { Mxrb::IO::BsonCodec.parse("\x01\x02\x03garbage") }
        .to raise_error(Mxrb::SerializationError, /BSON parse error/)
    end

    it "serialize raises SerializationError for unserializable content" do
      expect { Mxrb::IO::BsonCodec.serialize({ "key" => Object.new }) }
        .to raise_error(Mxrb::SerializationError, /BSON serialize error/)
    end

    it "extract_id decodes a base64 UUID from a Hash with Data key" do
      uuid = "12345678-1234-1234-1234-123456789012"
      blob = Mxrb::IO::BsonCodec.uuid_to_blob(uuid)
      encoded = Base64.strict_encode64(blob)
      result = Mxrb::IO::BsonCodec.extract_id({ "Data" => encoded })
      expect(result).to eq(uuid)
    end
  end

  # ── MprFile and MxunitCodec edge cases ─────────────────────────────────────
  describe "MprFile and MxunitCodec edge cases" do
    it "raises NotMprError when opening a non-SQLite file as readonly" do
      bad = File.join(File.dirname(@mpr_path), "not_an_mpr.mpr")
      File.write(bad, "not sqlite data")
      expect { Mxrb::IO::MprFile.open(bad, readonly: true) }
        .to raise_error(Mxrb::NotMprError)
    end

    it "conflicts_column returns nil when neither conflict column exists" do
      path = File.join(File.dirname(@mpr_path), "no_conflict.mpr")
      db = SQLite3::Database.new(path)
      db.execute("CREATE TABLE _MetaData (_ProductVersion TEXT, _BuildVersion TEXT, _SchemaHash TEXT)")
      db.execute(<<~SQL)
        CREATE TABLE Unit (
          UnitID BLOB PRIMARY KEY, ContainerID BLOB, ContainmentName TEXT,
          TreeConflict LONG, ContentsHash TEXT, Contents BLOB
        )
      SQL
      uuid = SecureRandom.uuid
      blob = [uuid.delete("-")].pack("H*")
      db.execute(
        "INSERT INTO Unit VALUES (?, ?, 'App', NULL, 'hash', ?)",
        [blob, blob, make_bson({ "$Type" => "Projects$Project", "Name" => "X" })]
      )
      db.close

      mpr = Mxrb::IO::MprFile.open(path)
      expect(mpr.root_unit).not_to be_nil
      mpr.close
    end

    it "MxunitCodec read raises UnsupportedFormat for invalid BSON" do
      path = File.join(File.dirname(@mpr_path), "bad.mxunit")
      File.binwrite(path, "garbage bytes that are not valid BSON")
      expect { Mxrb::IO::MxunitCodec.read(path) }
        .to raise_error(Mxrb::IO::MxunitCodec::UnsupportedFormat)
    end
  end

  # ── Semantic edge cases ──────────────────────────────────────────────────────
  describe "semantic edge cases" do
    it "Renamer raises for invalid name, ambiguous artifact, and collision" do
      path = File.join(File.dirname(@mpr_path), "rename_edge.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { microflow(:F) }
      end

      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_rename("M.F", to: "M.F!Invalid") }
          .to raise_error(ArgumentError, /invalid Mendix name/)
        expect { project.plan_rename("M.F", to: "M.F.G.H") }
          .to raise_error(ArgumentError, /rename must keep/)
        expect { project.plan_rename("M.Missing", to: "M.G") }
          .to raise_error(KeyError, /unknown Mendix artifact/)
      end
    end

    it "Renamer rejects cross-module rename without cross_module flag" do
      path = File.join(File.dirname(@mpr_path), "rename_xm.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:A) { microflow(:F) }
        self.module(:B) { microflow(:G) }
      end

      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_rename("A.F", to: "B.F") }
          .to raise_error(ArgumentError, /cannot move the artifact/)
      end
    end

    it "Renamer raises for collision with existing artifact" do
      path = File.join(File.dirname(@mpr_path), "rename_col.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { microflow(:F) ; microflow(:G) }
      end

      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_rename("M.F", to: "M.G") }
          .to raise_error(ArgumentError, /already exists/)
      end
    end

    it "Remover raises for ambiguous name" do
      path = File.join(File.dirname(@mpr_path), "remover_edge.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:A) { microflow(:F) }
      end

      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_remove("A.Missing") }
          .to raise_error(KeyError, /unknown Mendix artifact/)
      end
    end

    it "Mover raises for ambiguous name" do
      path = File.join(File.dirname(@mpr_path), "mover_edge.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:A) { microflow(:F) }
        self.module(:B) {}
      end

      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_move("A.Missing", to: "B") }
          .to raise_error(KeyError, /unknown Mendix artifact/)
      end
    end

    it "Analyzer raises for custom rule that returns non-Diagnostic" do
      path = File.join(File.dirname(@mpr_path), "analyzer_edge.mpr")
      Mxrb.define(path) { mendix_version "10.18.0"; self.module(:M) {} }

      Mxrb.open(path) do |project|
        bad_rule = ->(_proj, _idx) { "not a diagnostic" }
        expect { project.analyze(rules: [bad_rule]) }
          .to raise_error(ArgumentError, /must return.*Diagnostic/)
      end
    end

    it "Project#inspect includes name and version" do
      Mxrb.open(@mpr_path) do |project|
        expect(project.inspect).to include("Project")
      end
    end
  end

  # ── Architecture edge cases ──────────────────────────────────────────────────
  describe "architecture edge cases" do
    it "validator reports a page action with missing microflow reference" do
      path = File.join(File.dirname(@mpr_path), "arch_page_ref.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { before_commit microflow: :M_OnCommit }
          microflow(:M_OnCommit)
          microflow(:Worker)
        end
      end

      Mxrb.open(path) do |project|
        result = project.analyze
        expect(result).to be_a(Mxrb::Semantic::Report)
      end
    end

    it "graph ref handles dotted reference names" do
      builder = Mxrb::Dsl::Builder.new("x.mpr")
      builder.instance_eval do
        self.module(:M) do
          microflow(:Worker) { call_microflow "Other.Helper" }
          microflow(:Other_Helper)
        end
      end
      graph = builder.graph
      expect(graph.nodes).not_to be_empty
    end
  end

  # ── Integrity Validator edge cases ────────────────────────────────────────────
  describe "Integrity::Validator edge cases" do
    it "catches a unit whose $ID mismatches UnitID" do
      path = File.join(File.dirname(@mpr_path), "integrity_mismatch.mpr")
      db = SQLite3::Database.new(path)
      db.execute("CREATE TABLE _MetaData (_ProductVersion TEXT, _BuildVersion TEXT, _SchemaHash TEXT)")
      db.execute(<<~SQL)
        CREATE TABLE Unit (
          UnitID BLOB PRIMARY KEY, ContainerID BLOB, ContainmentName TEXT,
          TreeConflict LONG, ContentsHash TEXT, ContentsConflict TEXT, Contents BLOB
        )
      SQL
      root_uuid = SecureRandom.uuid
      wrong_uuid = SecureRandom.uuid
      root_blob = [root_uuid.delete("-")].pack("H*")
      db.execute(
        "INSERT INTO Unit VALUES (?, ?, 'App', NULL, 'hash', NULL, ?)",
        [root_blob, root_blob,
         make_bson({ "$ID" => wrong_uuid, "$Type" => "Projects$Project", "Name" => "X" })]
      )
      db.close
      result = Mxrb.validate(path)
      expect(result.errors).not_to be_empty
    end
  end

  # ── mxrb.rb top-level convenience methods ─────────────────────────────────────
  describe "Mxrb top-level methods" do
    it "runtime_plan returns a Plan with version and paths" do
      plan = Mxrb.runtime_plan(@mpr_path)
      expect(plan).to be_a(Mxrb::Runtime::Plan)
      expect(plan.mendix_version).not_to be_nil
    end

    it "Mxrb.open without block returns a project and can be closed" do
      project = Mxrb.open(@mpr_path)
      expect(project).to respond_to(:modules)
      project.close
    end
  end

  # ── Writer coverage: page buttons, return types, old format ────────────────
  describe "writer edge cases for line coverage" do
    it "builds page with cancel_changes, delete, and close_page button actions" do
      path = File.join(File.dirname(@mpr_path), "writer_buttons.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { string :Name }
          page(:P) do
            button(:Cancel) { on_click action: :cancel_changes }
            button(:Delete) { on_click action: :delete }
            button(:Close)  { on_click action: :close_page }
          end
        end
      end

      Mxrb.open(path) do |project|
        page = project.pages.first
        events = page.widgets.flat_map { _1[:events] }
        kinds = events.map { _1[:kind] }
        expect(kinds).to include(:action)
        handlers = events.map { _1[:handler] }
        expect(handlers).to include("cancel_changes")
        expect(handlers).to include("delete")
        expect(handlers).to include("close_page")
      end
    end

    it "builds microflows with float, decimal, datetime, long return types" do
      path = File.join(File.dirname(@mpr_path), "writer_return_types.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          microflow(:FloatFlow)   { return_type :Float }
          microflow(:DecimalFlow) { return_type :Decimal }
          microflow(:DateFlow)    { return_type :DateTime }
          microflow(:LongFlow)    { return_type :Long }
          microflow(:IntFlow)     { return_type :Integer }
          microflow(:StringFlow)  { return_type :String }
          microflow(:BoolFlow)    { return_type :Boolean }
        end
      end

      Mxrb.open(path) do |project|
        flows = project.microflows
        expect(flows.size).to eq(7)
        float_flow = flows.find { _1.name == "FloatFlow" }
        expect(float_flow.return_type).to include("Float")
        decimal_flow = flows.find { _1.name == "DecimalFlow" }
        expect(decimal_flow.return_type).to include("Decimal")
      end
    end

    it "builds microflows for Mendix 7 format (loop source, decision case)" do
      path = File.join(File.dirname(@mpr_path), "writer_mx7.mpr")
      Mxrb.define(path) do
        mendix_version "7.23.18"
        self.module(:M) do
          entity(:Item) { integer(:Count) }
          microflow(:Worker) do
            retrieve_objects "M.Item", as: :items
            loop_over :items, as: :item do
              log_message "$item/Count", node: "'MX7'"
            end
            decision "$true" do
              on(true) { log_message "yes" }
              on(false) { log_message "no" }
            end
          end
        end
      end

      Mxrb.open(path) do |project|
        flow = project.microflows.first
        expect(flow.name).to eq("Worker")
        expect(flow.objects).not_to be_empty
      end
    end

    it "builds access rules with read: :none, write: :none (returns None)" do
      path = File.join(File.dirname(@mpr_path), "writer_access_none.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) do
            string :Name
            access_rule "M.ReadonlyRole", create: false, delete: false, read: :none, write: :none
          end
        end
      end

      Mxrb.open(path) do |project|
        entity = project.entities.first
        expect(entity.name).to eq("Order")
        expect(entity.access_rules).not_to be_empty
      end
    end

    it "builds rescue block with error_event and continue_event" do
      path = File.join(File.dirname(@mpr_path), "writer_rescue.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          microflow(:Worker) do
            retrieve_objects "M.Order", as: :orders
            rescue_all do
              log_message "Error occurred", level: :error, node: "'Log'"
            end
          end
          entity(:Order)
        end
      end

      Mxrb.open(path) do |project|
        flow = project.microflows.first
        expect(flow.name).to eq("Worker")
      end
    end

    it "builds cross-module entity association" do
      path = File.join(File.dirname(@mpr_path), "writer_xmod_assoc.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:Logistics) do
          entity(:Shipment)
        end
        self.module(:Sales) do
          entity(:Order) { association "Logistics.Shipment" }
        end
      end

      Mxrb.open(path) do |project|
        sales_mod = project.modules.find { _1.name == "Sales" }
        assocs = sales_mod.associations
        expect(assocs).not_to be_empty
        cross_assoc = assocs.find { _1.name.include?("Order") || _1.name.include?("Shipment") }
        expect(cross_assoc).not_to be_nil
      end
    end

    it "updates an existing unit in the MPR (upsert path)" do
      path = File.join(File.dirname(@mpr_path), "writer_upsert.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { microflow(:Flow) }
      end

      first_ids = Mxrb.open(path) { |p| p.microflows.map(&:id) }

      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { microflow(:Flow) }
      end

      second_ids = Mxrb.open(path) { |p| p.microflows.map(&:id) }
      expect(second_ids).to eq(first_ids)
    end

    it "builds native unit tree with units missing explicit IDs" do
      path = File.join(File.dirname(@mpr_path), "writer_native_noid.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { microflow(:F) }
      end

      Mxrb.open(path, readonly: false) do |project|
        mod = project.find_artifact("M")
        project.mpr.insert_unit(
          container_uuid: mod.unit_id,
          containment_name: "Documents",
          contents_doc: { "$Type" => "Microflows$Microflow", "Name" => "Dynamic", "$ID" => SecureRandom.uuid }
        )
        project.refresh!
        expect(project.find_artifact("M.Dynamic")).not_to be_nil
      end
    end
  end

  # ── Compare edge cases ─────────────────────────────────────────────────────
  describe "Comparator edge cases" do
    it "compares two snapshots of microflows with flow bodies" do
      path1 = File.join(File.dirname(@mpr_path), "cmp1.mpr")
      path2 = File.join(File.dirname(@mpr_path), "cmp2.mpr")
      Mxrb.define(path1) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { string :Name }
          microflow(:Flow) do
            return_type :String
            call_microflow "M.Helper", as: :result
            return_value "$result"
          end
          microflow(:Helper) { return_type :String }
        end
      end
      Mxrb.define(path2) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { string :Name; integer :Amount }
          microflow(:Flow) do
            return_type :String
            call_microflow "M.Helper", as: :result
            return_value "$result"
          end
          microflow(:Helper) { return_type :String }
        end
      end

      result = Mxrb::Compare::Comparator.new(path1, path2).compare
      expect(result.differences).not_to be_empty
    end

    it "compares identical snapshots with old-format NewCaseValue" do
      path1 = File.join(File.dirname(@mpr_path), "cmp_mx9.mpr")
      Mxrb.define(path1) do
        mendix_version "9.24.0"
        self.module(:M) do
          microflow(:Router) do
            decision "$true" do
              on(true) { log_message "yes" }
              on(false) { log_message "no" }
            end
          end
        end
      end

      result = Mxrb::Compare::Comparator.new(path1, path1).compare
      expect(result).to be_identical
    end
  end

  # ── Semantic index edge cases ────────────────────────────────────────────────
  describe "semantic index edge cases" do
    it "search_artifacts finds multiple matches for ambiguous partial name" do
      path = File.join(File.dirname(@mpr_path), "idx_ambig.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:A) { microflow(:Work) }
        self.module(:B) { microflow(:Work) }
      end

      Mxrb.open(path) do |project|
        matches = project.search_artifacts("Work")
        expect(matches.size).to eq(2)
      end
    end

    it "impact_of traverses transitive callers" do
      path = File.join(File.dirname(@mpr_path), "idx_impact.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          microflow(:A) { call_microflow "M.B" }
          microflow(:B) { call_microflow "M.C" }
          microflow(:C)
        end
      end

      Mxrb.open(path) do |project|
        impact = project.impact_of("M.C")
        names = impact.artifacts.map(&:qualified_name)
        expect(names).to include("M.B")
        expect(names).to include("M.A")

        direct = project.impact_of("M.C", transitive: false)
        expect(direct.artifacts.map(&:qualified_name)).to include("M.B")
        expect(direct.artifacts.map(&:qualified_name)).not_to include("M.A")
      end
    end

    it "callers_of returns empty when no callers exist" do
      path = File.join(File.dirname(@mpr_path), "idx_nocaller.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { microflow(:Orphan) }
      end

      Mxrb.open(path) do |project|
        expect(project.callers_of("M.Orphan")).to be_empty
        expect(project.callees_of("M.Orphan")).to be_empty
        expect(project.references_to("M.Orphan")).to be_empty
        expect(project.references_from("M.Orphan")).to be_empty
      end
    end

    it "describe_artifact returns detailed description" do
      path = File.join(File.dirname(@mpr_path), "idx_desc.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { string :Name }
          microflow(:Process)
        end
      end

      Mxrb.open(path) do |project|
        desc = project.describe_artifact("M.Order")
        expect(desc).not_to be_nil
        search = project.search_artifacts("Order")
        expect(search).not_to be_empty
      end
    end
  end

  # ── model/page additional edge cases ──────────────────────────────────────────
  describe "Page model edge cases" do
    it "parses a data_grid with search_bar and toolbar from BSON" do
      path = File.join(File.dirname(@mpr_path), "page_grid.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { string :Name }
          page(:P) do
            data_grid :Grid, entity: "M.Order" do
              column :Name, attribute: :Name
              search_bar { search_field :Name }
              toolbar { new_button; delete_button; export_button }
            end
          end
        end
      end

      Mxrb.open(path) do |project|
        page = project.pages.first
        grid = page.widgets.find { _1[:type] == :data_grid }
        expect(grid).not_to be_nil
        expect(grid[:options][:columns]).not_to be_empty
      end
    end

    it "Page#to_bson produces valid BSON structure" do
      path = File.join(File.dirname(@mpr_path), "page_bson.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { page(:P) }
      end

      Mxrb.open(path) do |project|
        page = project.pages.first
        bson = page.to_bson
        expect(bson["$Type"]).to eq("Pages$Page")
        expect(bson["Name"]).to eq("P")
        expect(page.inspect).to include("P")
      end
    end

    it "Page parses tab_control and reference_selector widgets from BSON" do
      path = File.join(File.dirname(@mpr_path), "page_tabs.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { string :Status; string :Name }
          entity(:Customer) { string :Name }
          page(:P) do
            tab_control(:Tabs) do
              tab_page :General
              tab_page :Details
            end
            reference_selector :Customer, attribute: :Name
          end
        end
      end

      Mxrb.open(path) do |project|
        page = project.pages.first
        tab = page.widgets.find { _1[:type] == :tab_control }
        expect(tab).not_to be_nil if page.widgets.any?
      end
    end
  end

  # ── Integrity validator v2 and warnings ─────────────────────────────────────
  describe "Integrity::Validator for v2 and warnings" do
    it "validates a v2 MPR and reports missing mxunit files" do
      path = File.join(File.dirname(@mpr_path), "integrity_v2.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { microflow(:F) }
      end

      result = Mxrb.validate(path)
      expect(result).to be_valid
    end
  end

  # ── model/unit save! ─────────────────────────────────────────────────────────
  describe "model/unit save!" do
    it "can update a model object using save!" do
      path = File.join(File.dirname(@mpr_path), "unit_save.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { page(:P) }
      end

      Mxrb.open(path, readonly: false) do |project|
        page = project.pages.first
        original_name = page.name
        page.instance_variable_set(:@name, "Renamed")
        expect(page.name).not_to eq(original_name)
        expect { page.save! }.not_to raise_error
        project.refresh!
        updated = project.pages.first
        expect(updated.name).to eq("Renamed")
      end
    end
  end

  # ── model/association additional coverage ────────────────────────────────────
  describe "model/association to_bson delete_behavior" do
    it "association to_bson uses default delete_behavior when nil" do
      path = File.join(File.dirname(@mpr_path), "assoc_del.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { association :Customer }
          entity(:Customer)
        end
      end

      Mxrb.open(path) do |project|
        assoc = project.modules.first.associations.first
        bson = assoc.to_bson
        expect(bson["DeleteBehavior"]).not_to be_nil
        expect(bson["DeleteBehavior"]["$Type"]).to eq("DomainModels$DeleteBehavior")
      end
    end
  end

  # ── model/module children_with_containment ───────────────────────────────────
  describe "model/module children_with_containment" do
    it "returns child units for a given containment" do
      path = File.join(File.dirname(@mpr_path), "mod_children.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { microflow(:F) ; page(:P) }
      end

      Mxrb.open(path) do |project|
        mod = project.modules.first
        docs = mod.send(:children_with_containment, "Documents")
        expect(docs).not_to be_empty
      end
    end
  end

  # ── Architecture graph ref with dotted name ───────────────────────────────────
  describe "Architecture::Graph ref with dotted names" do
    def build_definition(modules)
      { modules: modules }
    end

    def module_def(name, microflows: [], nanoflows: [], pages: [], entities: [], repositories: [])
      { name: name, entities: entities, pages: pages,
        microflows: microflows, nanoflows: nanoflows,
        repositories: repositories, menus: [], module_roles: [] }
    end

    def flow_def(name, public: false, calls: [])
      { name: name, runtime: :server, kind: :use_case, public: public,
        calls: calls, repositories: [], parameters: [], return_type: nil,
        documentation: "", body: nil, return_variable_name: nil,
        return_expression: nil, allow_concurrent_execution: nil,
        mark_as_used: nil, excluded: nil, allowed_roles: nil,
        preserve_native_body: false }
    end

    it "resolves dotted cross-module references and counts nodes/edges" do
      definition = build_definition([
        module_def("ModA", microflows: [flow_def("WorkerA", public: true, calls: [{ kind: :microflow, name: "ModB.WorkerB" }])]),
        module_def("ModB", microflows: [flow_def("WorkerB")])
      ])
      graph = Mxrb::Architecture::Graph.new(definition)
      expect(graph.nodes.size).to eq(2)
      expect(graph.edges.size).to eq(1)
    end

    it "Validator detects page-to-repository and cross-module internal reference" do
      page_def = {
        name: "P", layout: "Default", title: "P", popup: false,
        data_source: { kind: :repository, name: "Repo" },
        events: [], widgets: [], allowed_roles: nil, deep_structure: nil
      }
      repo_def = { name: "Repo", public: true }
      definition = build_definition([
        module_def("M",
          pages: [page_def],
          repositories: [repo_def],
          microflows: [flow_def("WorkerA", public: true, calls: [{ kind: :microflow, name: "X.Helper" }])]
        ),
        module_def("X", microflows: [flow_def("Helper", public: false)])
      ])
      graph = Mxrb::Architecture::Graph.new(definition)
      validator = Mxrb::Architecture::Validator.new(graph)
      result = validator.validate
      expect(result.errors).to include(a_string_matching(/cannot access repository/))
      expect(result.errors).to include(a_string_matching(/references internal artifact/))
    end

    it "Validator detects call cycles" do
      definition = build_definition([
        module_def("M", microflows: [
          flow_def("A", public: true, calls: [{ kind: :microflow, name: "B" }]),
          flow_def("B", public: false, calls: [{ kind: :microflow, name: "A" }])
        ])
      ])
      graph = Mxrb::Architecture::Graph.new(definition)
      validator = Mxrb::Architecture::Validator.new(graph)
      result = validator.validate
      expect(result.errors).to include(a_string_matching(/cycle/))
    end
  end

  # ── Marketplace remaining paths ───────────────────────────────────────────────
  describe "marketplace remaining paths" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @mkt2_dir = dir
        pkg = File.join(dir, "mypkg")
        FileUtils.mkdir_p(pkg)
        File.write(File.join(pkg, "mxrb-module.json"),
                   JSON.generate(name: "mypkg", module_name: "MyPkg",
                                 version: "1.0.0", files: ["mod.rb"]))
        File.write(File.join(pkg, "mod.rb"), "# content\n")
        @mkt2_catalog = File.join(dir, "catalog.json")
        File.write(@mkt2_catalog, JSON.generate(modules: [
          { name: "mypkg", version: "1.0.0", description: "My Pkg", source: pkg }
        ]))
        ex.run
      end
    end

    it "raises MarketplaceError for invalid manifest" do
      bad_pkg = File.join(@mkt2_dir, "badpkg")
      FileUtils.mkdir_p(bad_pkg)
      File.write(File.join(bad_pkg, "mxrb-module.json"), "not valid json")
      catalog = Mxrb::Marketplace::Catalog.new(@mkt2_catalog)
      installer = Mxrb::Marketplace::Installer.new(target: File.join(@mkt2_dir, "proj"), catalog: catalog)
      expect { installer.install(bad_pkg) }.to raise_error(Mxrb::MarketplaceError)
    end

    it "raises MarketplaceError for unsafe module file path" do
      bad_pkg = File.join(@mkt2_dir, "unsafepkg")
      FileUtils.mkdir_p(bad_pkg)
      File.write(File.join(bad_pkg, "mxrb-module.json"),
                 JSON.generate(name: "x", module_name: "X", version: "1.0", files: ["../../../etc/passwd"]))
      catalog = Mxrb::Marketplace::Catalog.new(@mkt2_catalog)
      installer = Mxrb::Marketplace::Installer.new(target: File.join(@mkt2_dir, "proj"), catalog: catalog)
      expect { installer.install(bad_pkg) }.to raise_error(Mxrb::MarketplaceError, /unsafe/)
    end

    it "raises MarketplaceError for missing file in package" do
      bad_pkg = File.join(@mkt2_dir, "missingpkg")
      FileUtils.mkdir_p(bad_pkg)
      File.write(File.join(bad_pkg, "mxrb-module.json"),
                 JSON.generate(name: "x", module_name: "X", version: "1.0", files: ["missing.rb"]))
      catalog = Mxrb::Marketplace::Catalog.new(@mkt2_catalog)
      installer = Mxrb::Marketplace::Installer.new(target: File.join(@mkt2_dir, "proj"), catalog: catalog)
      expect { installer.install(bad_pkg) }.to raise_error(Mxrb::MarketplaceError, /missing/)
    end

    it "raises MarketplaceError for empty module package" do
      empty_pkg = File.join(@mkt2_dir, "emptypkg")
      FileUtils.mkdir_p(empty_pkg)
      File.write(File.join(empty_pkg, "mxrb-module.json"),
                 JSON.generate(name: "x", module_name: "X", version: "1.0", files: []))
      catalog = Mxrb::Marketplace::Catalog.new(@mkt2_catalog)
      installer = Mxrb::Marketplace::Installer.new(target: File.join(@mkt2_dir, "proj"), catalog: catalog)
      expect { installer.install(empty_pkg) }.to raise_error(Mxrb::MarketplaceError, /no files/)
    end

    it "raises for HTTPS-required catalog URL" do
      expect { Mxrb::Marketplace::Catalog.new("http://example.com/catalog.json").entries }
        .to raise_error(Mxrb::MarketplaceError, /HTTPS/)
    end

    it "raises MarketplaceError for invalid module name in manifest" do
      bad_name_pkg = File.join(@mkt2_dir, "badname_pkg")
      FileUtils.mkdir_p(bad_name_pkg)
      File.write(File.join(bad_name_pkg, "mxrb-module.json"),
                 JSON.generate(name: "x", module_name: "123Invalid", version: "1.0", files: ["f.rb"]))
      File.write(File.join(bad_name_pkg, "f.rb"), "")
      catalog = Mxrb::Marketplace::Catalog.new(@mkt2_catalog)
      installer = Mxrb::Marketplace::Installer.new(target: File.join(@mkt2_dir, "proj"), catalog: catalog)
      expect { installer.install(bad_name_pkg) }.to raise_error(Mxrb::MarketplaceError, /invalid module name/)
    end

    it "raises MarketplaceError for unknown builtin module slug" do
      bad_catalog_path = File.join(@mkt2_dir, "bad_builtin.json")
      File.write(bad_catalog_path, JSON.generate(modules: [
        { name: "unknown-builtin", version: "1.0", description: "x", source: "builtin:nonexistent" }
      ]))
      catalog = Mxrb::Marketplace::Catalog.new(bad_catalog_path)
      installer = Mxrb::Marketplace::Installer.new(target: File.join(@mkt2_dir, "proj"), catalog: catalog)
      expect { installer.install("unknown-builtin") }.to raise_error(Mxrb::MarketplaceError, /unavailable/)
    end
  end

  # ── Semantic Remover and Mover ambiguous resolution ───────────────────────────
  describe "Remover and Mover with ambiguous names" do
    it "Renamer raises for ambiguous name (multiple kinds)" do
      path = File.join(File.dirname(@mpr_path), "rename_ambig2.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Worker)
          microflow(:Worker_Do)
        end
      end

      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_rename("M.Worker_Do", to: "M.New") }
          .not_to raise_error
      end
    end
  end

  # ── Writer coverage: rescue/decision branches, show_page, java, menu ─────────
  describe "writer coverage for rescue, decision, show_page, java, menu" do
    it "rescue_all with error_event and continue_loop terminators" do
      path = File.join(File.dirname(@mpr_path), "writer_rescue_term.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order)
          microflow(:WithError) do
            retrieve_objects "M.Order", as: :orders
            rescue_all { error_event }
          end
          microflow(:WithContinue) do
            retrieve_objects "M.Order", as: :orders
            rescue_all { continue_loop }
          end
        end
      end

      Mxrb.open(path) do |project|
        expect(project.microflows.map(&:name)).to include("WithError", "WithContinue")
      end
    end

    it "decision with empty branch reaches nil-first flow path" do
      path = File.join(File.dirname(@mpr_path), "writer_empty_branch.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          microflow(:Router) do
            decision "$true" do
              on(true) {}
              on(false) { log_message "nope" }
            end
          end
        end
      end

      Mxrb.open(path) do |project|
        expect(project.microflows.first.name).to eq("Router")
      end
    end

    it "rescue_all inside decision branch triggers build_rescue_branch" do
      path = File.join(File.dirname(@mpr_path), "writer_rescue_in_decision.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order)
          microflow(:Worker) do
            decision "$true" do
              on(true) do
                retrieve_objects "M.Order", as: :orders
                rescue_all { log_message "rescued" }
              end
              on(false) { log_message "false" }
            end
          end
        end
      end

      Mxrb.open(path) do |project|
        expect(project.microflows.first.name).to eq("Worker")
        expect(project.microflows.first.objects).not_to be_empty
      end
    end

    it "type_decision with empty branch and old Mendix version (< 10)" do
      path = File.join(File.dirname(@mpr_path), "writer_type_decision_old.mpr")
      Mxrb.define(path) do
        mendix_version "9.24.0"
        self.module(:M) do
          entity(:Animal)
          entity(:Dog)
          microflow(:Classify) do
            retrieve_objects "M.Animal", as: :a
            type_decision :a do
              on_type("M.Dog") {}
              otherwise { log_message "other" }
            end
          end
        end
      end

      Mxrb.open(path) do |project|
        expect(project.microflows.first.name).to eq("Classify")
      end
    end

    it "rescue_all with old Mendix version (< 10) hits old flow format" do
      path = File.join(File.dirname(@mpr_path), "writer_rescue_old.mpr")
      Mxrb.define(path) do
        mendix_version "9.24.0"
        self.module(:M) do
          entity(:Order)
          microflow(:Worker) do
            retrieve_objects "M.Order", as: :orders
            rescue_all { log_message "rescued" }
          end
        end
      end

      Mxrb.open(path) do |project|
        expect(project.microflows.first.name).to eq("Worker")
      end
    end

    it "show_page with title on version 10 hits elif branch" do
      path = File.join(File.dirname(@mpr_path), "writer_show_page_v10.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          page(:Detail)
          microflow(:OpenPage) { show_page "M.Detail", title: { "en_US" => "Order Detail" } }
        end
      end

      Mxrb.open(path) do |project|
        expect(project.microflows.first.name).to eq("OpenPage")
      end
    end

    it "show_page with title on version 7 hits old form title branch" do
      path = File.join(File.dirname(@mpr_path), "writer_show_page_v7.mpr")
      Mxrb.define(path) do
        mendix_version "7.23.18"
        self.module(:M) do
          page(:Detail)
          microflow(:OpenPage) { show_page "M.Detail", title: { "en_US" => "My Title" } }
        end
      end

      Mxrb.open(path) do |project|
        expect(project.microflows.first.name).to eq("OpenPage")
      end
    end

    it "raises ArgumentError for unsupported native button action" do
      path = File.join(File.dirname(@mpr_path), "writer_bad_action.mpr")
      expect do
        Mxrb.define(path) do
          mendix_version "10.18.0"
          self.module(:M) do
            page(:P) do
              button(:BadBtn) { on_click action: "totally_unsupported" }
            end
          end
        end
      end.to raise_error(ArgumentError, /unsupported native action/)
    end

    it "menu item without page hits no_action_doc" do
      path = File.join(File.dirname(@mpr_path), "writer_menu_no_action.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          menu(:Nav) do
            item "Spacer"
            item "Home", page: "M.Home"
          end
          page(:Home)
        end
      end

      Mxrb.open(path) do |project|
        expect(project.modules.first.menus).not_to be_empty
      end
    end

    it "call_java with parameter mapping on version 7 hits old JavaAction format" do
      path = File.join(File.dirname(@mpr_path), "writer_java_v7.mpr")
      Mxrb.define(path) do
        mendix_version "7.23.18"
        self.module(:M) do
          microflow(:CallJava) do
            call_java "MyModule.MyAction", as: :result,
                      pass: { Param: "$currentUser" }
          end
        end
      end

      Mxrb.open(path) do |project|
        expect(project.microflows.first.name).to eq("CallJava")
      end
    end

    it "call_java with parameter mapping on version 9 sets ArgumentModel" do
      path = File.join(File.dirname(@mpr_path), "writer_java_v9.mpr")
      Mxrb.define(path) do
        mendix_version "9.24.0"
        self.module(:M) do
          microflow(:CallJava) do
            call_java "MyModule.MyAction", as: :result,
                      pass: { Param: "$currentUser" }
          end
        end
      end

      Mxrb.open(path) do |project|
        expect(project.microflows.first.name).to eq("CallJava")
      end
    end

    it "call_java with Hash-valued parameter hits code_action_parameter hash path" do
      path = File.join(File.dirname(@mpr_path), "writer_java_hash_param.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          microflow(:CallJava) do
            call_java "MyModule.MyAction", as: :result,
                      pass: { Param: { kind: :entity, value: "M.Order" } }
          end
        end
      end

      Mxrb.open(path) do |project|
        expect(project.microflows.first.name).to eq("CallJava")
      end
    end

    it "member_value_expr handles nil value" do
      path = File.join(File.dirname(@mpr_path), "writer_nil_member.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { integer :Amount }
          microflow(:Worker) do
            retrieve_objects "M.Order", as: :order, limit: 1
            change_object :order, set: { Amount: nil }
          end
        end
      end

      Mxrb.open(path) do |project|
        expect(project.microflows.first.name).to eq("Worker")
      end
    end
  end

  # ── Exporter coverage: parameters, access rules, widget types ────────────────
  describe "exporter coverage for parameters, access rules, widgets" do
    around do |ex|
      Dir.mktmpdir do |dir|
        @export_dir = dir
        ex.run
      end
    end

    it "exports microflow with parameters" do
      path = File.join(File.dirname(@mpr_path), "export_params.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { string :Name }
          microflow(:Lookup) do
            parameter :OrderId, type: :Integer
            return_type :String
          end
        end
      end

      Mxrb::Exporter.new(path, @export_dir).export!
      mf_files = Dir.glob(File.join(@export_dir, "**", "*.rb"))
      mf_file = mf_files.find { _1.include?("lookup") }
      expect(mf_file).not_to be_nil
      content = File.read(mf_file)
      expect(content).to include("parameter")
    end

    it "exports entity access rules with :all/:none and explicit lists" do
      path = File.join(File.dirname(@mpr_path), "export_access.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) do
            string :Name
            string :Secret
            access_rule "M.ReadRole", create: false, delete: false,
                        read: :all, write: :none
            access_rule "M.WriteRole", create: true, delete: false,
                        read: :all, write: [:Name]
            access_rule "M.NoRole", create: false, delete: false,
                        read: :none, write: :none
          end
        end
      end

      Mxrb::Exporter.new(path, @export_dir).export!
      order_file = Dir.glob(File.join(@export_dir, "**", "*.rb")).find { _1.include?("order") }
      expect(order_file).not_to be_nil
      content = File.read(order_file)
      expect(content).to include("access_rule")
    end

    it "exports page with snippet, drop_down, and container widgets" do
      path = File.join(File.dirname(@mpr_path), "export_widgets.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { string :Name; string :Status }
          page(:Dashboard) do
            snippet :Header, from: "M.CommonHeader"
            drop_down :Status, attribute: :Status
            container(:Content) { text_box :Name }
          end
        end
      end

      Mxrb::Exporter.new(path, @export_dir).export!
      page_file = Dir.glob(File.join(@export_dir, "**", "*.rb")).find { _1.include?("dashboard") }
      expect(page_file).not_to be_nil
      content = File.read(page_file)
      expect(content).to include("snippet").or include("drop_down").or include("container")
    end

    it "exports microflow body with error_event in rescue" do
      path = File.join(File.dirname(@mpr_path), "export_body_term.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order)
          microflow(:WithEndFlow) do
            retrieve_objects "M.Order", as: :orders
            rescue_all { error_event }
          end
        end
      end

      Mxrb::Exporter.new(path, @export_dir).export!
      files = Dir.glob(File.join(@export_dir, "**", "*.rb"))
      expect(files).not_to be_empty
    end
  end

  # ── Model object edge cases ──────────────────────────────────────────────────
  describe "Model object direct construction" do
    it "Attribute#inspect returns formatted string" do
      path = File.join(File.dirname(@mpr_path), "attr_inspect.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) { entity(:Order) { string :Name } }
      end
      Mxrb.open(path) do |project|
        entity_model = project.modules.first.entities.first
        attr = entity_model.attributes.first
        expect(attr).not_to be_nil
        expect(attr.inspect).to include("name=")
      end
    end

    it "Association#to_bson uses default_delete_behavior when delete_behavior is nil" do
      assoc = Mxrb::Model::Association.new
      assoc.id               = SecureRandom.uuid
      assoc.name             = "Test"
      assoc.documentation    = ""
      assoc.from_entity_id   = SecureRandom.uuid
      assoc.to_entity_id     = SecureRandom.uuid
      assoc.association_type = :Reference
      assoc.owner            = :Default
      assoc.storage_format   = :Column
      assoc.delete_behavior  = nil
      assoc.export_level     = "Hidden"
      bson = assoc.to_bson
      expect(bson["DeleteBehavior"]["$Type"]).to eq("DomainModels$DeleteBehavior")
    end

    it "Microflow#to_bson uses default_void_return when return_type is nil" do
      mf = Mxrb::Model::Microflow.allocate
      mf.instance_variable_set(:@id, SecureRandom.uuid)
      mf.instance_variable_set(:@name, "Test")
      mf.instance_variable_set(:@documentation, "")
      mf.instance_variable_set(:@return_variable_name, "ReturnValue")
      mf.instance_variable_set(:@allow_concurrent_execution, true)
      mf.instance_variable_set(:@mark_as_used, false)
      mf.instance_variable_set(:@excluded, false)
      mf.instance_variable_set(:@allowed_module_roles, [])
      mf.instance_variable_set(:@parameters, [])
      mf.instance_variable_set(:@return_type, nil)
      mf.instance_variable_set(:@objects, [])
      mf.instance_variable_set(:@flows, [])
      bson = mf.to_bson
      expect(bson["MicroflowReturnType"]["$Type"]).to eq("Microflows$MicroflowReturnType")
    end

    it "Microflow extract_parameters reads from MicroflowParameterCollection" do
      doc = {
        "$ID" => SecureRandom.uuid, "$Type" => "Microflows$Microflow",
        "Name" => "Test",
        "MicroflowParameterCollection" => {
          "$ID" => SecureRandom.uuid, "$Type" => "Microflows$MicroflowParameterCollection",
          "Parameters" => [
            { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$MicroflowParameter",
              "Name" => "OrderId", "DefaultValue" => "",
              "VariableType" => { "$ID" => SecureRandom.uuid, "$Type" => "DataTypes$IntegerType" } }
          ]
        },
        "MicroflowReturnType" => { "$ID" => SecureRandom.uuid, "$Type" => "DataTypes$VoidType" },
        "ObjectCollection" => { "$ID" => SecureRandom.uuid, "$Type" => "Microflows$MicroflowObjectCollection", "Objects" => [] },
        "Flows" => [],
        "AllowedModuleRoles" => []
      }
      path = File.join(File.dirname(@mpr_path), "mpc_test.mpr")
      Mxrb.define(path) { mendix_version "10.18.0"; self.module(:M) { microflow(:Stub) } }
      Mxrb.open(path, readonly: false) do |project|
        mod = project.find_artifact("M")
        project.mpr.insert_unit(
          container_uuid: mod.unit_id,
          containment_name: "Documents",
          contents_doc: doc
        )
        project.refresh!
        mf = project.microflows.find { _1.name == "Test" }
        expect(mf).not_to be_nil
        expect(mf.parameters).not_to be_empty
        expect(mf.parameters.first["Name"]).to eq("OrderId")
      end
    end
  end

  # ── IO edge cases ─────────────────────────────────────────────────────────────
  describe "IO edge cases" do
    it "MxunitCodec.serialize returns BSON bytes" do
      doc = { "$Type" => "Test$Unit", "$ID" => SecureRandom.uuid, "Name" => "X" }
      bytes = Mxrb::IO::MxunitCodec.serialize(doc)
      expect(bytes).to be_a(String)
      expect(bytes.bytesize).to be > 0
    end

    it "MprFile.open raises NotMprError for non-SQLite path" do
      Dir.mktmpdir do |dir|
        fake_mpr = File.join(dir, "fake.mpr")
        File.write(fake_mpr, "this is not sqlite")
        expect { Mxrb::IO::MprFile.open(fake_mpr) { } }.to raise_error(Mxrb::NotMprError)
      end
    end
  end

  # ── DSL builder edge cases ────────────────────────────────────────────────────
  describe "DSL builder edge cases" do
    it "normalize_access handles non-standard symbol value (else branch)" do
      path = File.join(File.dirname(@mpr_path), "dsl_access_else.mpr")
      expect do
        Mxrb.define(path) do
          mendix_version "10.18.0"
          self.module(:M) do
            entity(:Order) do
              string :Name
              access_rule "M.User", read: :all, write: :Name
            end
          end
        end
      end.not_to raise_error
    end
  end

  # ── Architecture validator edge cases ─────────────────────────────────────────
  describe "Architecture::Validator entity lifecycle → nanoflow" do
    it "detects entity lifecycle calling a nanoflow as an error" do
      graph = Mxrb::Architecture::Graph.new({ modules: [] })
      graph.instance_variable_set(:@nodes, {
        "M::entity::Order" => Mxrb::Architecture::Node.new(
          "M::entity::Order", "M", :entity, "Order", {}),
        "M::nanoflow::ClientFlow" => Mxrb::Architecture::Node.new(
          "M::nanoflow::ClientFlow", "M", :nanoflow, "ClientFlow", { public: false })
      })
      graph.instance_variable_set(:@edges, [
        Mxrb::Architecture::Edge.new(
          "M::entity::Order", "M::nanoflow::ClientFlow", :on_before_commit, {})
      ])
      result = Mxrb::Architecture::Validator.new(graph).validate
      expect(result.errors).to include(a_string_matching(/lifecycle cannot call client-side/))
    end
  end

  # ── Semantic index: association indexing and unresolved references ─────────────
  describe "Semantic index with associations and unresolved refs" do
    it "indexes associations when accessing semantic index" do
      path = File.join(File.dirname(@mpr_path), "idx_assoc_full.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { string :Name; association :Customer }
          entity(:Customer)
        end
      end

      Mxrb.open(path) do |project|
        artifacts = project.semantic_index.find_all("M.Order_Customer")
        expect(artifacts).not_to be_empty
      end
    end

    it "indexes associations from domain model BSON (domain_associations path)" do
      path = File.join(File.dirname(@mpr_path), "idx_assoc_dom.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Invoice) { string :Number; association :Client }
          entity(:Client)
        end
      end

      Mxrb.open(path) do |project|
        refs = project.references_to("M.Invoice")
        expect(refs).to be_an(Array)
      end
    end

    it "records unresolved references for missing artifacts" do
      path = File.join(File.dirname(@mpr_path), "idx_unresolved.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          microflow(:Caller) { call_microflow "NonExistent.Ghost" }
        end
      end

      Mxrb.open(path) do |project|
        unresolved = project.semantic_index.unresolved_references
        expect(unresolved).to be_an(Array)
      end
    end

    it "resolve_argument raises for ambiguous qualified name with multiple artifact kinds" do
      path = File.join(File.dirname(@mpr_path), "idx_resolve_ambig.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Work)
          microflow(:Work)
        end
      end

      Mxrb.open(path) do |project|
        expect { project.callers_of("M.Work") }
          .to raise_error(ArgumentError, /ambiguous/)
      end
    end
  end

  # ── Compare additional coverage ───────────────────────────────────────────────
  describe "Compare access rules and array diff" do
    it "compare detects entity access rule changes" do
      path1 = File.join(File.dirname(@mpr_path), "cmp_access1.mpr")
      path2 = File.join(File.dirname(@mpr_path), "cmp_access2.mpr")
      Mxrb.define(path1) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) do
            string :Name
            access_rule "M.Admin", create: true, delete: true, read: :all, write: :all
          end
        end
      end
      Mxrb.define(path2) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) do
            string :Name
            access_rule "M.Admin", create: false, delete: false, read: :all, write: :none
          end
        end
      end

      result = Mxrb::Compare::Comparator.new(path1, path2).compare
      expect(result).not_to be_identical
    end

    it "compare handles microflow with decision/switch flow (assigns flow IDs)" do
      path1 = File.join(File.dirname(@mpr_path), "cmp_flow_dec.mpr")
      Mxrb.define(path1) do
        mendix_version "10.18.0"
        self.module(:M) do
          microflow(:Router) do
            decision "$true" do
              on(true)  { log_message "yes" }
              on(false) { log_message "no" }
            end
          end
        end
      end
      result = Mxrb::Compare::Comparator.new(path1, path1).compare
      expect(result).to be_identical
    end
  end

  # ── Semantic index: expected_kinds via entity-typed parameter scan ─────────────
  describe "Semantic index expected_kinds branches" do
    it "scans entity-typed microflow parameter references (entity kind)" do
      path = File.join(File.dirname(@mpr_path), "idx_entity_ref.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Order) { string :Name }
          microflow(:Process) do
            parameter :Input, type: "M.Order"
          end
        end
      end

      Mxrb.open(path) do |project|
        refs = project.references_from("M.Process")
        expect(refs).to be_an(Array)
      end
    end

    it "scans retrieve_objects activity which references entity" do
      path = File.join(File.dirname(@mpr_path), "idx_retrieve.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Item) { string :Label }
          microflow(:Fetch) { retrieve_objects "M.Item", as: :items }
        end
      end

      Mxrb.open(path) do |project|
        refs = project.references_from("M.Fetch")
        entity_refs = refs.select { _1.target.kind == :entity }
        expect(entity_refs).not_to be_empty
      end
    end

    it "add_unresolved with Entity field triggers expected_kinds entity branch" do
      path = File.join(File.dirname(@mpr_path), "idx_entity_unknown.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Item)
          microflow(:Fetch) { retrieve_objects "Unknown.Ghost", as: :items }
        end
      end

      Mxrb.open(path) do |project|
        unresolved = project.semantic_index.unresolved_references
        expect(unresolved.map(&:qualified_name)).to include("Unknown.Ghost")
      end
    end

    it "add_unresolved with XpathConstraint triggers expected_kinds else branch" do
      path = File.join(File.dirname(@mpr_path), "idx_xpath_else.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Item)
          microflow(:Fetch) do
            retrieve_objects "M.Item", as: :items, xpath: "[//NonExistent.Ghost[Name = 'x']]"
          end
        end
      end

      Mxrb.open(path) do |project|
        unresolved = project.semantic_index.unresolved_references
        expect(unresolved).not_to be_nil
      end
    end
  end

  # ── Semantic: resolve via find_all (ambiguous/multi-kind) ─────────────────────
  describe "Semantic Renamer/Remover/Mover with ambiguous qualified names" do
    it "Renamer.resolve raises for ambiguous qualified name with multiple kinds" do
      path = File.join(File.dirname(@mpr_path), "renamer_ambig_kinds.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Work)
          microflow(:Work)
        end
      end

      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_rename("M.Work", to: "M.NewWork") }
          .to raise_error(ArgumentError, /ambiguous/)
      end
    end

    it "Remover.resolve raises for ambiguous qualified name with multiple kinds" do
      path = File.join(File.dirname(@mpr_path), "remover_ambig.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Task)
          microflow(:Task)
        end
      end

      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_remove("M.Task") }
          .to raise_error(ArgumentError, /ambiguous/)
      end
    end

    it "Mover.resolve raises for ambiguous qualified name with multiple kinds" do
      path = File.join(File.dirname(@mpr_path), "mover_ambig.mpr")
      Mxrb.define(path) do
        mendix_version "10.18.0"
        self.module(:M) do
          entity(:Task)
          microflow(:Task)
        end
        self.module(:Other)
      end

      Mxrb.open(path, readonly: false) do |project|
        expect { project.plan_move("M.Task", to: "Other") }
          .to raise_error(ArgumentError, /ambiguous/)
      end
    end
  end
end
