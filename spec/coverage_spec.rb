# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "MXRB defensive and compatibility paths" do
  it "covers BSON and mxunit failure paths" do
    uuid = "00112233-4455-6677-8899-aabbccddeeff"
    encoded = Base64.strict_encode64(Mxrb::IO::BsonCodec.uuid_to_blob(uuid))
    expect(Mxrb::IO::BsonCodec.extract_id("Data" => encoded)).to eq(uuid)
    expect(Mxrb::IO::BsonCodec.extract_id({})).to be_nil
    expect { Mxrb::IO::BsonCodec.parse("invalid") }
      .to raise_error(Mxrb::SerializationError, /BSON parse error/)
    allow(BSON::Document).to receive(:new).and_raise("serialize")
    expect { Mxrb::IO::BsonCodec.serialize("bad") }
      .to raise_error(Mxrb::SerializationError, /serialize/)

    Dir.mktmpdir do |dir|
      path = File.join(dir, "bad.mxunit")
      File.binwrite(path, "invalid")
      expect { Mxrb::IO::MxunitCodec.read(path) }
        .to raise_error(Mxrb::IO::MxunitCodec::UnsupportedFormat)
      allow(Mxrb::IO::BsonCodec).to receive(:serialize).and_return("bytes")
      expect(Mxrb::IO::MxunitCodec.serialize({})).to eq("bytes")
    end
  end

  it "covers base unit persistence and model serialization defaults" do
    parsed = { "$Type" => "Test$Unit" }
    mpr = double("mpr", parse_contents: parsed)
    expect { Mxrb::Model::Unit.new({ "UnitID" => "id" }, mpr).to_bson }
      .to raise_error(NotImplementedError)

    klass = Class.new(Mxrb::Model::Unit) do
      def to_bson = { "$ID" => id, "$Type" => "Test$Unit" }
    end
    existing_mpr = double("existing", parse_contents: parsed)
    expect(existing_mpr).to receive(:update_unit)
    expect(klass.new({ "UnitID" => "id" }, existing_mpr).save!).to be_a(klass)

    inserted_mpr = double("inserted", parse_contents: parsed)
    expect(inserted_mpr).to receive(:insert_unit).and_return("new-id")
    inserted = klass.new(
      { "UnitID" => nil, "ContainerID" => "parent", "ContainmentName" => "Documents" },
      inserted_mpr
    )
    expect(inserted.save!.id).to eq("new-id")
    orphan = klass.new({ "UnitID" => nil }, double(parse_contents: parsed))
    expect { orphan.save! }.to raise_error(RuntimeError, /container_id/)

    attribute = Mxrb::Model::Attribute.new
    attribute.name = "When"
    attribute.type = :datetime
    expect(attribute.to_bson.dig("type", "localizeDate")).to be(true)
    expect(attribute.inspect).to include("When")
    unknown = Mxrb::Model::Attribute.from_bson(
      "Name" => "Unknown", "NewType" => { "$Type" => "Custom$Type" },
      "Value" => { "DefaultValue" => "x" }
    )
    expect(unknown.type).to eq(:string)
    expect(unknown.default_value).to eq("x")

    association = Mxrb::Model::Association.from_bson(
      "name" => "Link", "parentId" => "from", "childId" => "to",
      "type" => "ReferenceSet", "owner" => "Both", "deleteBehavior" => {}
    )
    expect(association.inspect).to include("Link")
    association.delete_behavior = nil
    association.association_type = nil
    association.owner = nil
    association.storage_format = nil
    expect(association.to_bson["DeleteBehavior"]["$Type"]).to eq("DomainModels$DeleteBehavior")
  end

  it "covers semantic ambiguity, rename guards, and custom-rule validation" do
    first = Mxrb::Semantic::Artifact.new(
      "a", "Sales.Item", :entity, "Sales", "Item", "unit", [], {}.freeze
    )
    second = Mxrb::Semantic::Artifact.new(
      "b", "Sales.Item", :page, "Shared", "Item", "unit2", [], {}.freeze
    )
    index = Mxrb::Semantic::Index.allocate
    index.instance_variable_set(:@by_name, Hash.new { |hash, key| hash[key] = [] })
    index.instance_variable_get(:@by_name)["Sales.Item"] = [first, second]
    expect { index.send(:resolve_argument, "Sales.Item") }
      .to raise_error(ArgumentError, /ambiguous/)
    expect(index.send(:resolve_candidate, "Sales.Item", first, ["Entity"])).to eq(first)
    expect(index.send(:resolve_candidate, "Sales.Item", first, ["Unknown"])).to eq(first)
    %w[Microflow Nanoflow JavaAction JavaScriptAction Workflow Form Page Layout
       Snippet Entity Attribute Association Enumeration].each do |field|
      expect(index.send(:expected_kinds, field)).not_to be_empty
    end

    semantic_index = double("index")
    project = double("project", semantic_index: semantic_index)
    renamer = Mxrb::Semantic::Renamer.new(project)
    allow(project).to receive(:find_artifact).and_return(nil)
    allow(semantic_index).to receive(:find_all).and_return([])
    expect { renamer.plan("Missing.Item", to: "New") }.to raise_error(KeyError)

    allow(project).to receive(:find_artifact).and_return(first)
    allow(semantic_index).to receive(:find_all).with("Sales.Item").and_return([first])
    allow(semantic_index).to receive(:find_all).with("Sales.Other").and_return([])
    allow(project).to receive(:all_units).and_return([])
    expect { renamer.plan(first, to: "") }.to raise_error(ArgumentError, /empty/)
    expect { renamer.plan(first, to: "bad-name") }.to raise_error(ArgumentError, /invalid/)
    expect { renamer.plan(first, to: "Other.Deep.Item") }.to raise_error(ArgumentError, /depth/)
    expect { renamer.plan(first, to: "Other.Item") }.to raise_error(ArgumentError, /container/)

    allow(semantic_index).to receive(:find_all).with("Sales.Other").and_return([second])
    expect { renamer.plan(first, to: "Other") }.to raise_error(ArgumentError, /already exists/)

    analyzer = Mxrb::Semantic::Analyzer.new(
      double(semantic_index: double(artifacts: [], references: [], unresolved_references: []))
    )
    expect { analyzer.analyze(rules: [->(*) { :bad }]) }
      .to raise_error(ArgumentError, /must return/)
  end

  it "covers removal resolution and structural safety guards" do
    flow = Mxrb::Semantic::Artifact.new(
      "unit:flow", "Sales.Flow", :microflow, "Sales", "Flow", "flow", [], {}.freeze
    )
    duplicate = Mxrb::Semantic::Artifact.new(
      "unit:other", "Sales.Flow", :page, "Sales", "Flow", "other", [], {}.freeze
    )
    index = double("removal index", find_all: [flow, duplicate])
    project = double("removal project", find_artifact: nil, semantic_index: index)
    remover = Mxrb::Semantic::Remover.new(project)
    expect { remover.plan("Sales.Flow") }.to raise_error(ArgumentError, /ambiguous/)
    allow(index).to receive(:find_all).and_return([flow])
    expect(remover.send(:resolve, "Sales.Flow")).to eq(flow)

    allow(project).to receive(:find_artifact).and_return(flow)
    allow(project).to receive(:raw_unit).and_return(nil)
    expect { remover.plan("Sales.Flow") }.to raise_error(ArgumentError, /not a removable unit/)

    allow(project).to receive(:raw_unit).and_return("UnitID" => "flow")
    self_reference = Mxrb::Semantic::Reference.new(
      flow, flow, :calls, ["Microflow"], "Sales.Flow"
    )
    allow(project).to receive(:references_to).and_return([self_reference])
    allow(project).to receive(:children_of).and_return(["child"])
    blocked = remover.plan("Sales.Flow")
    expect(blocked.incoming).to be_empty
    expect(blocked).not_to be_safe
    expect { blocked.apply! }.to raise_error(ArgumentError, /1 child unit/)
  end

  it "covers exporter formatting and fallback helpers" do
    exporter = Mxrb::Exporter.new("input.mpr", Dir.mktmpdir)
    expect(exporter.send(:flow_location, "DS_List")).to eq(%w[application queries])
    expect(exporter.send(:flow_location, "VAL_Check")).to eq(%w[application validations])
    expect(exporter.send(:flow_location, "SE_Run")).to eq(%w[application jobs])
    expect(exporter.send(:flow_location, "API_Get")).to eq(%w[infrastructure endpoints])
    expect(exporter.send(:flow_location, "INT_Send")).to eq(%w[infrastructure integrations])
    expect(exporter.send(:format_access, "custom")).to eq(":custom")
    expect(exporter.send(:reconstruct_access, "ReadOnly", [], "ReadWrite", nil)).to eq(:none)
    expect(
      exporter.send(
        :reconstruct_access, "None",
        [{ rights: "ReadOnly", name: "Name" }], "ReadOnly", "ReadWrite"
      )
    ).to eq(["Name"])

    duplicate = Struct.new(:id, :name)
    names = exporter.send(
      :unique_filenames,
      [duplicate.new("1", "Same"), duplicate.new("2", "Same")]
    )
    expect(names.values).to contain_exactly("same.rb", "same_2.rb")
    expect(exporter.send(:native_ruby, {})).to eq("{}")
    expect(exporter.send(:native_ruby, [])).to eq("[]")
    expect(exporter.send(:translated_text, nil)).to eq("")
    expect(exporter.send(:translated_text, "Items" => [3, { "Text" => "Hello" }])).to eq("Hello")
    expect(exporter.send(:code_action_parameter_value, "$x")).to eq(
      kind: :native, value: "$x"
    )
    expect(exporter.send(:ruby_val, { a: 1 })).to eq("{a: 1}")
    expect(exporter.send(:bson_items, Object.new)).to eq([])

    malformed_flow = Struct.new(:name).new("Broken")
    expect(exporter.send(:flow_body_fingerprint, ["not valid ruby !!!"], malformed_flow)).to be_nil
    expect(exporter.send(:loop_source, "ListVariableName" => "Items",
                                       "IteratorVariableName" => "Item"))
      .to include("$Type" => "Microflows$IterableList")
    expect(exporter.send(:loop_source, {})).to eq({})
    expect(exporter.send(:find_merge_node, "a", "b", {}, {})).to be_nil
  end

  it "covers legacy model readers and their serialization surfaces" do
    entity = Mxrb::Model::Entity.from_bson(
      {
        "$ID" => "entity-id", "Name" => "Legacy", "Documentation" => "doc",
        "DataStorageGuid" => "storage", "ExportLevel" => "Public",
        "Location" => { "x" => 3, "y" => 4 },
        "Generalization" => nil,
        "Attributes" => [3],
        "AccessRules" => [3, {
          "ModuleRoles" => [1, "Role"], "AllowCreate" => true,
          "AllowDelete" => true, "DefaultMemberAccessRights" => "ReadOnly",
          "MemberAccesses" => [3, {
            "Association" => "Legacy.Link", "AccessRights" => "ReadWrite"
          }], "XPathConstraint" => "[true()]"
        }]
      },
      "domain", nil
    )
    expect(entity.to_bson["location"]).to eq("x" => 3, "y" => 4)
    expect(entity.inspect).to include("Legacy")

    microflow_doc = {
      "$ID" => "flow-id", "$Type" => "Microflows$Microflow", "name" => "LegacyFlow",
      "documentation" => "doc", "ReturnType" => "String",
      "Parameters" => [3], "ObjectCollection" => { "Objects" => [3], "Flows" => [3] }
    }
    mpr = double(parse_contents: microflow_doc)
    flow = Mxrb::Model::Microflow.new(
      { "UnitID" => "flow-id", "ContainmentName" => "Documents" }, mpr
    )
    expect(flow.to_bson["MicroflowReturnType"]).to eq("String")
    expect(flow.inspect).to include("LegacyFlow")

    domain_doc = {
      "$ID" => "domain-id", "$Type" => "DomainModels$DomainModel",
      "Entities" => [3], "Associations" => [3], "CrossAssociations" => [3],
      "Annotations" => [3]
    }
    domain = Mxrb::Model::DomainModel.new(
      { "UnitID" => "domain-id", "ContainmentName" => "DomainModel" },
      double(parse_contents: domain_doc)
    )
    expect(domain.to_bson["crossAssociations"]).to eq([3])
    expect(domain.inspect).to include("entities=0")

    page_doc = {
      "$ID" => "page-id", "$Type" => "Forms$Page", "name" => "LegacyPage",
      "title" => "Legacy", "FormCall" => {
        "Form" => "Legacy.Layout",
        "Arguments" => [3, { "Widgets" => [3, {
          "$Type" => "Forms$LayoutGrid", "Rows" => [3, {
            "Columns" => [3, { "Widgets" => [3, {
              "$Type" => "Forms$CheckBox", "Name" => "Check"
            }, {
              "$Type" => "Forms$DatePicker", "Name" => "Date"
            }, {
              "$Type" => "Forms$InputReferenceSetSelector", "Name" => "Ref"
            }, {
              "$Type" => "Forms$DynamicText", "Name" => "Text"
            }] }]
          }]
        }] }]
      }
    }
    page = Mxrb::Model::Page.new(
      { "UnitID" => "page-id", "ContainmentName" => "Documents" },
      double(parse_contents: page_doc)
    )
    expect(page.widgets.map { _1[:type] })
      .to contain_exactly(:check_box, :date_picker, :reference_selector, :text)
    expect(page.to_bson["$Type"]).to eq("Pages$Page")
    expect(page.inspect).to include("LegacyPage")
  end

  it "covers writer compatibility branches and guarded native operations" do
    writer7 = Mxrb::Writer.new("legacy.mpr", version: "7.5.0", modules: [])
    writer8 = Mxrb::Writer.new("eight.mpr", version: "8.18.0", modules: [])

    expect(writer7.send(:show_form_action_doc, page: "M.P", title: { en_US: "T" },
                                               location: :popup, variable: :Object))
      .to include("FormObjectVariable" => "Object")
    expect(writer8.send(:show_form_action_doc, page: "M.P", title: { en_US: "T" },
                                               close_pages: 2))
      .to include("NumberOfPagesToClose" => "2")
    expect(writer7.send(:retrieve_sorting_doc, ["M.E/A", :ascending]))
      .to include("AttributePath" => "M.E/A")
    expect(writer7.send(:close_form_action_doc, count: 2))
      .not_to have_key("NumberOfPagesToClose")

    java7 = writer7.send(
      :java_action_call_doc,
      name: "M.Java", variable: "Result", mappings: [{ param: "p", value: "1" }]
    )
    expect(java7["ParameterMappings"][1]["Value"]["$Type"])
      .to eq("Microflows$BasicJavaActionParameterValue")
    java8 = writer8.send(
      :java_action_call_doc,
      name: "M.Java", variable: "Result", mappings: [{ param: "p", value: "1" }]
    )
    expect(java8["ParameterMappings"][1]["Value"]).to have_key("ArgumentModel")
    expect(
      writer8.send(
        :code_action_parameter_doc,
        { kind: :custom, value: { "Native" => true } },
        basic_type: "Basic", code: false
      )
    ).to eq("Native" => true)
    expect(writer8.send(:member_value_expr, nil)).to eq("")

    %w[cancel_changes delete close_page].each do |action|
      expect(writer8.send(:native_action_doc, action)["$Type"]).to include("Action")
    end
    expect { writer8.send(:native_action_doc, "unknown") }
      .to raise_error(ArgumentError, /unsupported/)

    legacy_loop = writer7.send(
      :loop_activity_doc,
      { type: :loop_over, variable: "Items", iterator: "Item", activities: [] },
      "loop", 0, 0, []
    )
    expect(legacy_loop).to include("ListVariableName" => "Items")
    legacy_flow = writer7.send(:sequence_flow_doc, "a", "b", case_value: true)
    expect(legacy_flow).to have_key("NewCaseValue")
    writer7.send(:set_flow_case, legacy_flow, "M.Type", kind: :inheritance)
    expect(legacy_flow["NewCaseValue"]["$Type"]).to eq("Microflows$InheritanceCase")

    %i[return_event error_event continue_event].each do |terminal|
      activity = terminal == :return_event ?
        { type: terminal, expression: "$x" } : { type: terminal }
      graph = writer8.send(
        :build_microflow_graph,
        [
          { type: :create_variable, variable: "x", variable_type: "string", value: "" },
          { type: :rescue_all, activities: [activity] }
        ],
        ""
      )
      expect(graph[:objects]).not_to be_empty
      expect(graph[:flows].any? { _1["IsErrorHandler"] == true }).to be(true)
    end

    decision = {
      type: :decision, condition: "$ok",
      branches: { true => [], false => [{ type: :return_event, expression: "" }] }
    }
    expect(writer8.send(:build_microflow_graph, [decision], "")[:objects]).not_to be_empty
    inheritance = {
      type: :type_decision, variable: "Object",
      branches: { "M.Type" => [], nil => [{ type: :return_event, expression: "" }] }
    }
    expect(writer8.send(:build_microflow_graph, [inheritance], "")[:objects]).not_to be_empty

    mpr = double("native mpr")
    allow(mpr).to receive(:children_of).and_return([])
    allow(mpr).to receive(:insert_unit).and_return("created")
    writer8.send(
      :apply_native_unit_tree, mpr, "root",
      [{ "unit_id" => "", "container_id" => "", "containment" => "Documents",
         "doc" => { "$Type" => "Custom$Unit" } }]
    )
    cyclic = [
      { "unit_id" => "a", "container_id" => "b" },
      { "unit_id" => "b", "container_id" => "a" }
    ]
    expect { writer8.send(:apply_native_unit_tree, mpr, "root", cyclic) }
      .to raise_error(Mxrb::SerializationError, /cycle/)
  end

  it "covers remaining exporter rendering and flow branches" do
    exporter = Mxrb::Exporter.new("input.mpr", Dir.mktmpdir)

    project = double(modules: [double(id: "module", name: "Sales")])
    allow(project).to receive(:raw_unit).with("child")
      .and_return("UnitID" => "child", "ContainerID" => "module")
    expect(exporter.send(:native_descendant_of?, project, "child", "module")).to be(true)

    expect(
      exporter.send(:reconstruct_access, "None", [{ rights: "ReadWrite", name: "A" }],
                    "ReadOnly", "ReadWrite")
    ).to eq(["A"])
    flow = double(
      name: "Run",
      parameters: [], return_type: nil, documentation: "", allow_concurrent_execution: false,
      mark_as_used: false, excluded: false, allowed_module_roles: [], objects: [], flows: []
    )
    metadata = { calls: [{ kind: :microflow, name: "Sales.Run" }],
                 repositories: ["Orders"] }
    expect(exporter.send(:microflow_source, flow, metadata)).to include("uses_repository")

    snippet = { type: :snippet, name: "Address", options: { snippet: "Shared.Address" } }
    drop_down = {
      type: :drop_down, name: :Status,
      options: { attribute: :Status, caption: "Status" }
    }
    empty_container = { type: :container, name: :Empty, options: { class: "box" }, children: [] }
    container = {
      type: :container, name: :Panel, options: {},
      children: [{ type: :text, name: :Label, options: {} }]
    }
    rendered = [snippet, drop_down, empty_container, container].flat_map do |widget|
      exporter.send(:render_widget, widget, 2)
    end
    expect(rendered.join("\n")).to include("snippet", "drop_down", "container")

    expect(
      exporter.send(
        :editable_action?,
        "$Type" => "Microflows$ChangeObjectAction", "Commit" => "No",
        "RefreshInClient" => false
      )
    ).to be(true)
    expect(
      exporter.send(
        :editable_action?,
        "$Type" => "Microflows$RetrieveAction",
        "RetrieveSource" => { "$Type" => "Custom$Source" }
      )
    ).to be(false)

    ids = %w[start unknown finish]
    objects = [
      { "$ID" => ids[0], "$Type" => "Microflows$StartEvent" },
      { "$ID" => ids[1], "$Type" => "Custom$Unknown" },
      { "$ID" => ids[2], "$Type" => "Microflows$EndEvent", "ReturnValue" => "'done'" }
    ]
    flows = [
      { "$Type" => "Microflows$SequenceFlow",
        "OriginPointer" => ids[0], "DestinationPointer" => ids[1] },
      { "$Type" => "Microflows$SequenceFlow",
        "OriginPointer" => ids[1], "DestinationPointer" => ids[2] }
    ]
    expect(exporter.send(:body_dsl_lines, objects, flows, 2)).to include(
      "  return_value \"'done'\""
    )
    %w[Microflows$ErrorEvent Microflows$ContinueEvent].each do |type|
      terminal = [{ "$ID" => "event", "$Type" => type }]
      expect(exporter.send(:body_dsl_lines, terminal, [], 2, nested: true)).not_to be_empty
    end

    call = {
      "$Type" => "Microflows$MicroflowCallAction",
      "UseReturnVariable" => true, "ResultVariableName" => "",
      "MicroflowCall" => { "Microflow" => "Sales.Run", "ParameterMappings" => [3] }
    }
    expect(exporter.send(:action_dsl_line, { "Action" => call }, 2))
      .to include("use_return: true")
    expect(exporter.send(:members_dsl, [{ attribute: "Name", value: "'x'" }]))
      .to include("Name")
  end

  it "covers writer preservation and nested rescue branches" do
    writer = Mxrb::Writer.new("compat.mpr", version: "11.12.1", modules: [])
    existing = {
      "UnitID" => "old", "Name" => "Same",
      "doc" => { "$ID" => "doc-id", "$Type" => "Custom$Unit", "Name" => "Same" }
    }
    mpr = double
    allow(mpr).to receive(:children_of).and_return([existing])
    allow(mpr).to receive(:parse_contents) { |raw| raw.fetch("doc") }
    expect(mpr).to receive(:update_unit).with("old", hash_including("$ID" => "doc-id"))
    unit = {
      "containment" => "Documents",
      "doc" => { "$Type" => "Custom$Unit", "Name" => "Same", "Value" => 1 }
    }
    expect(writer.send(:upsert_native_unit, mpr, "root", unit)).to eq("old")

    domain_mpr = double
    allow(domain_mpr).to receive(:units_by_containment).and_return([])
    expect do
      writer.send(
        :write_domain_model, domain_mpr, "module",
        { name: "Sales", entities: [{
          name: "A", persistable: true, documentation: "", attributes: [],
          access_rules: [], lifecycle: {},
          associations: [{ name: "Bad", target: "Missing" }]
        }] }
      )
    end.to raise_error(ArgumentError, /unknown association target/)

    expect(
      writer.send(:preserve_flow_metadata, { "Excluded" => true }, {}, {})
    ).not_to have_key("Excluded")
    merged_action = { "Action" => { "$Type" => "X", "ErrorHandlingType" => "None" } }
    original_action = { "Action" => { "$Type" => "X" } }
    writer.send(:preserve_flow_object_metadata, merged_action, original_action)
    expect(merged_action["Action"]).not_to have_key("ErrorHandlingType")
    expect(writer.send(:deep_merge_flow_metadata, { "Value" => 1 }, { "Value" => nil }))
      .to eq("Value" => 1)
    expect(writer.send(:access_default_rights, :none, :none)).to eq("None")

    page = { name: "Deep", deep_structure: { "$Type" => "Pages$Page" } }
    expect(writer.send(:page_doc, page)).to include("__mxrb_deep_structure_declared" => true)
    event_page = {
      name: "Events", layout: "Atlas", title: "Events",
      popup: false, widgets: [{ type: :button, name: "Run", caption: "Run" }],
      events: [{ target: "Missing", event: :click, kind: :microflow, handler: "Sales.Run" }]
    }
    expect(writer.send(:page_doc, event_page)["$Type"]).to eq("Pages$Page")
    expect(writer.send(:no_action_doc)["$Type"]).to eq("Forms$NoAction")

    graph = writer.send(
      :build_microflow_graph,
      [
        { type: :create_variable, variable: "x", variable_type: "string", value: "" },
        { type: :rescue_all, activities: [
          { type: :create_variable, variable: "a", variable_type: "string", value: "" },
          { type: :create_variable, variable: "b", variable_type: "string", value: "" }
        ] }
      ],
      ""
    )
    expect(graph[:flows].count { _1["IsErrorHandler"] == true }).to eq(1)

    objects = []
    flows = []
    split = "split"
    result = writer.send(
      :process_decision_branch,
      [
        { type: :create_variable, variable: "x", variable_type: "string", value: "" },
        { type: :rescue_all, activities: [{ type: :error_event }] }
      ],
      split, true, objects, flows, 1, 1
    )
    expect(result[:first]).not_to be_nil
    expect(flows.any? { _1["IsErrorHandler"] }).to be(true)

    inheritance = {
      type: :type_decision, variable: "Object",
      branches: { "Sales.Customer" => [], nil => [
        { type: :create_variable, variable: "x", variable_type: "string", value: "" }
      ] }
    }
    expect(writer.send(:build_microflow_graph, [inheritance], "")[:flows]).not_to be_empty
    expect(
      writer.send(:code_action_parameter_doc, { kind: :other, value: "x" },
                  basic_type: "Basic", code: false)
    ).to include("Argument" => "x")
  end

  it "covers MPR mutation guards and model utility surfaces" do
    file = Mxrb::IO::MprFile.allocate
    file.instance_variable_set(:@readonly, true)
    expect { file.delete_unit("00112233-4455-6677-8899-aabbccddeeff") }
      .to raise_error(Mxrb::ReadOnlyError)

    Dir.mktmpdir do |dir|
      uuid = "00112233-4455-6677-8899-aabbccddeeff"
      writable = Mxrb::IO::MprFile.allocate
      writable.instance_variable_set(:@readonly, false)
      writable.instance_variable_set(:@format_version, :v2)
      writable.instance_variable_set(:@path, File.join(dir, "model.mpr"))
      db = double
      expect(db).to receive(:execute).with("DELETE FROM Unit WHERE UnitID = ?", [kind_of(String)])
      writable.instance_variable_set(:@db, db)
      expect(writable.delete_unit(uuid)).to be_an(Array)
    end

    unopened = Mxrb::IO::MprFile.allocate
    unopened.instance_variable_set(:@path, "/missing/model.mpr")
    unopened.instance_variable_set(:@readonly, true)
    allow(SQLite3::Database).to receive(:new).and_raise(SQLite3::CantOpenException, "no")
    expect { unopened.send(:open_db) }.to raise_error(Mxrb::NotMprError, /Cannot open/)

    columns = Mxrb::IO::MprFile.allocate
    columns.instance_variable_set(:@unit_columns, %w[UnitID ContentsHash])
    expect(columns.send(:conflicts_column)).to be_nil

    empty_flow = Mxrb::Model::Microflow.new(
      { "UnitID" => "flow", "ContainmentName" => "Documents" },
      double(parse_contents: {
        "$ID" => "flow", "$Type" => "Microflows$Microflow", "Name" => "Empty",
        "Parameters" => [3], "ObjectCollection" => { "Objects" => [3] }
      })
    )
    expect(empty_flow.to_bson["MicroflowReturnType"]["Type"]).to be_nil

    page = Mxrb::Model::Page.allocate
    target = []
    page.send(
      :parse_form_call_arguments,
      [3, { "Widgets" => [3, { "$Type" => "Forms$CheckBox", "Name" => "Check" }] }],
      target
    )
    expect(target.first[:type]).to eq(:check_box)
    [
      ["Pages$MicroflowClientAction", { "Microflow" => "Sales.Run" }, :microflow],
      ["Pages$SaveChangesClientAction", {}, :action],
      ["Pages$CancelChangesClientAction", {}, :action],
      ["Pages$DeleteClientAction", {}, :action],
      ["Pages$ClosePageClientAction", {}, :action]
    ].each do |type, payload, kind|
      expect(page.send(:parse_action, payload.merge("$Type" => type))[:kind]).to eq(kind)
    end

    module_doc = { "$ID" => "mod", "$Type" => "Projects$Module", "Name" => "Sales" }
    module_mpr = double(parse_contents: module_doc)
    allow(module_mpr).to receive(:units_by_containment).and_return([])
    allow(module_mpr).to receive(:children_of).and_return([])
    mod = Mxrb::Model::Module.new(
      { "UnitID" => "mod", "ContainmentName" => "Modules" }, module_mpr
    )
    expect(mod.to_bson["$Type"]).to eq("Projects$Module")
    expect(mod.inspect).to include("Sales")
    expect(mod.send(:children_with_containment, "Documents")).to eq([])

    project = Mxrb::Model::Project.new(
      double(project_name: "Demo", mendix_version: "11.12.1", format_version: :v2)
    )
    expect(project.inspect).to include("Demo")
  end

  it "covers DSL coercions and validator error reporting" do
    entity = Mxrb::Dsl::EntityBuilder.new("Thing")
    entity.access_rule :User, read: "custom", write: :none
    expect(entity.to_h[:access_rules].first[:read]).to eq(:custom)

    flow = Mxrb::Dsl::FlowBuilder.new(
      "Run", runtime: :server, kind: :microflow, public: false
    )
    flow.return_value(:Result)
    flow.rescue_all do
      return_value :Result
      error_event
    end
    expect(flow.to_h[:body].map { _1[:type] }).to include(:rescue_all)
    expect(flow.to_h[:body].first[:activities].map { _1[:type] })
      .to include(:return_event, :error_event)
    nested_rescue = Mxrb::Dsl::RescueBuilder.new
    nested_rescue.rescue_all { continue_loop }
    expect(nested_rescue.activities.first[:type]).to eq(:rescue_all)

    validator = Mxrb::Integrity::Validator.allocate
    validator.instance_variable_set(:@errors, [])
    validator.instance_variable_set(:@warnings, [])
    validator.instance_variable_set(
      :@units,
      [
        { "UnitID" => "", "ContainerID" => "missing" },
        { "UnitID" => "same", "ContainerID" => "missing" },
        { "UnitID" => "same", "ContainerID" => "same" }
      ]
    )
    validator.send(:validate_unit_ids)
    expect(validator.instance_variable_get(:@errors).join(" ")).to include("blank", "duplicate")

    bad_mpr = double
    allow(bad_mpr).to receive(:parse_contents)
      .and_raise(Mxrb::SerializationError, "broken")
    validator.instance_variable_set(:@mpr, bad_mpr)
    expect(validator.send(:parse_unit, "UnitID" => "bad")).to be_nil
    validator.send(:validate_doc_identity, { "UnitID" => "expected" }, "$Type" => "")
    validator.send(
      :validate_doc_identity, { "UnitID" => "expected" },
      "$Type" => "X", "$ID" => "different"
    )
    validator.send(:add_warning, "warning")
    expect(validator.instance_variable_get(:@warnings)).to include("warning")

    allow(Mxrb::IO::MprFile).to receive(:open).and_raise(Mxrb::NotMprError, "not mpr")
    expect(Mxrb::Integrity::Validator.new("bad").validate.errors).to include("not mpr")
  end

  it "covers architecture rule failures and qualified graph references" do
    definition = {
      modules: [
        {
          name: "A",
          entities: [{
            name: "Entity", public: false, associations: [],
            lifecycle: [{ event: :on_create, kind: :nanoflow, handler: "B.Client" }]
          }],
          pages: [{
            name: "Page", public: false, widgets: [],
            events: [], repositories: ["B.Store"]
          }],
          microflows: [], nanoflows: [], repositories: [], ports: []
        },
        {
          name: "B",
          entities: [], pages: [], microflows: [],
          nanoflows: [{
            name: "Client", public: false, runtime: :client, calls: [], repositories: []
          }],
          repositories: [{ name: "Store", public: false }], ports: []
        }
      ]
    }
    built_graph = Mxrb::Architecture::Graph.new(definition)
    expect(built_graph.send(:ref, "A", :nanoflow, "B.Client"))
      .to eq("B::nanoflow::Client")
    graph = Mxrb::Architecture::Graph.allocate
    nodes = [
      Mxrb::Architecture::Node.new("A::page::Page", "A", :page, "Page", {}),
      Mxrb::Architecture::Node.new("A::entity::Entity", "A", :entity, "Entity", {}),
      Mxrb::Architecture::Node.new("B::repository::Store", "B", :repository, "Store", { public: false }),
      Mxrb::Architecture::Node.new("B::nanoflow::Client", "B", :nanoflow, "Client", { public: false })
    ].to_h { [_1.id, _1] }
    edges = [
      Mxrb::Architecture::Edge.new("A::page::Page", "B::repository::Store", :uses_repository, {}),
      Mxrb::Architecture::Edge.new("A::entity::Entity", "B::nanoflow::Client", :on_create, {})
    ]
    graph.instance_variable_set(:@nodes, nodes)
    graph.instance_variable_set(:@edges, edges)
    result = Mxrb::Architecture::Validator.new(graph).validate
    expect(result.errors.join("\n")).to include(
      "cannot access repository", "lifecycle cannot call", "internal artifact"
    )
  end

  it "covers semantic association indexing, unresolved deduplication, and ambiguity" do
    entity_artifact = Mxrb::Semantic::Artifact.new(
      "entity:e", "Sales.Entity", :entity, "Sales", "Entity", "domain",
      [], {}.freeze
    )
    association = double(
      id: "a", name: "Link", from_entity_id: "e", to_entity_id: "e"
    )
    domain = double(id: "domain", entities: [], associations: [association])
    mod = double(
      id: "module", name: "Sales", domain_model: domain,
      entities: [], associations: [association]
    )
    project = double(modules: [mod])
    allow(project).to receive(:raw_unit).with("domain").and_return("UnitID" => "domain")
    allow(project).to receive(:parse_bson).and_return(
      "associations" => [3, { "$ID" => "a", "$Type" => "DomainModels$Association" }]
    )
    index = Mxrb::Semantic::Index.allocate
    index.instance_variable_set(:@project, project)
    index.instance_variable_set(:@artifacts, [entity_artifact])
    index.instance_variable_set(:@by_id, { entity_artifact.id => entity_artifact })
    index.instance_variable_set(:@by_name, Hash.new { |h, k| h[k] = [] })
    index.instance_variable_set(:@documents, [])
    index.send(:index_modules_and_domain_models)
    expect(index.instance_variable_get(:@documents)).not_to be_empty

    index.instance_variable_set(:@unresolved_references, [])
    source = entity_artifact
    seen = []
    index.send(:add_unresolved, source, "Sales.Missing", ["Microflow"], "Sales.Missing", seen)
    index.send(:add_unresolved, source, "Sales.Missing", ["Microflow"], "Sales.Missing", seen)
    expect(index.instance_variable_get(:@unresolved_references).size).to eq(1)

    other = entity_artifact.with(id: "entity:other", kind: :page)
    semantic_index = double(find_all: [entity_artifact, other])
    renamer = Mxrb::Semantic::Renamer.new(double(semantic_index: semantic_index, find_artifact: nil))
    expect { renamer.plan("Sales.Entity", to: "Renamed") }
      .to raise_error(ArgumentError, /ambiguous/)
  end

  it "covers comparison normalization and recursive difference variants" do
    comparator = Mxrb::Compare::Comparator.allocate
    entity = double(
      name: "Entity", documentation: "", persistable: true,
      generalization: { "Type" => "None" }, access_rules: [{ "Role" => "User" }],
      attributes: []
    )
    expect(comparator.send(:entity_summary, entity)[:generalization]).to eq(Type: "None")

    ids = {}
    objects = [
      { "$ID" => "b", "$Type" => "X" },
      { "$ID" => "a", "$Type" => "X" }
    ]
    comparator.send(:assign_flow_ids, objects, [], ids)
    expect(ids.keys).to contain_exactly("a", "b")
    normalized = comparator.send(
      :normalize_flow_value,
      [{ "$ID" => "b", "Value" => 2 }, { "$ID" => "a", "Value" => 1 }],
      { "a" => 0, "b" => 1 }
    )
    expect(normalized.map { _1[:Value] }).to eq([1, 2])
    flow = double(
      objects: [], flows: [], name: "Parameterized", return_type: "String",
      allowed_module_roles: [], parameters: [{ "Name" => "Value" }]
    )
    expect(comparator.send(:flow_summary, flow)[:parameters])
      .to eq([{ Name: "Value" }])
    cyclic_objects = [
      { "$ID" => "a", "$Type" => "X" },
      { "$ID" => "b", "$Type" => "X" }
    ]
    cyclic_flows = [
      { "OriginPointer" => "a", "DestinationPointer" => "b" },
      { "OriginPointer" => "b", "DestinationPointer" => "a" }
    ]
    cycle_ids = {}
    comparator.send(:assign_flow_ids, cyclic_objects, cyclic_flows, cycle_ids)
    expect(cycle_ids.size).to eq(2)
    edge = { "NewCaseValue" => { "$ID" => "case", "$Type" => "X$NoCase" } }
    expect(comparator.send(:normalized_case_values, edge, ids)).to eq([])
    expect(comparator.send(:normalized_case_values, {}, ids)).to eq([])
    expect(comparator.send(:array_payload, Object.new)).to eq([])

    changes = comparator.send(
      :diff_values,
      [{ name: "A", value: 1 }, { name: "Removed", value: 3 }],
      [{ name: "A", value: 2 }, { name: "Added", value: 4 }]
    )
    expect(changes.map(&:operation)).to contain_exactly(:changed, :removed, :added)
    indexed = comparator.send(:diff_values, [1], [1, 2])
    expect(indexed.first.operation).to eq(:added)
  end

  it "covers final writer preservation and empty inheritance branch" do
    writer = Mxrb::Writer.new("compat.mpr", version: "11.12.1", modules: [])
    %i[Integer Long Decimal Float DateTime].each do |type|
      expect(writer.send(:microflow_data_type_doc, type, "Demo")["$Type"])
        .to start_with("DataTypes$")
    end
    exporter = Mxrb::Exporter.new("input.mpr", Dir.mktmpdir)
    parameterized = double(
      name: "Typed", parameters: [
        { "Name" => "Value", "VariableType" => "String" }, "opaque"
      ],
      return_type: nil, documentation: "", allow_concurrent_execution: true,
      mark_as_used: false, excluded: false, allowed_module_roles: [],
      objects: [], flows: []
    )
    expect(exporter.send(:microflow_source, parameterized))
      .to include("parameter :Value, type: :String")
    auxiliary = { "$ID" => "note", "$Type" => "Microflows$Annotation" }
    source = {
      "ObjectCollection" => { "Objects" => [3, auxiliary] },
      "Flows" => [3]
    }
    target = {
      "ObjectCollection" => { "Objects" => [3] },
      "Flows" => [3]
    }
    writer.send(:preserve_flow_auxiliary_objects, target, source)
    expect(target.dig("ObjectCollection", "Objects")).to include(auxiliary)

    inheritance = {
      type: :type_decision, variable: "Object",
      branches: {
        "Sales.Customer" => [],
        nil => [{ type: :create_variable, variable: "x", variable_type: "string", value: "" }]
      }
    }
    graph = writer.send(:build_microflow_graph, [inheritance], "")
    expect(graph[:flows]).not_to be_empty
    objects = []
    flows = []
    writer.send(:process_inheritance_decision, inheritance, "previous", objects, flows, 0, 0)
    expect(flows).not_to be_empty
  end

  it "covers the false native ancestry path" do
    exporter = Mxrb::Exporter.new("input.mpr", Dir.mktmpdir)
    project = double
    allow(project).to receive(:raw_unit).with("child")
      .and_return("UnitID" => "child", "ContainerID" => "parent")
    allow(project).to receive(:raw_unit).with("parent").and_return(nil)
    expect(exporter.send(:native_descendant_of?, project, "child", "other")).to be(false)
  end
end
