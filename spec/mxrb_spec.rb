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
  end
end
