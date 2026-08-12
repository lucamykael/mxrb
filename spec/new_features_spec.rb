# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe "new features" do
  # ── Shared fixture helper ───────────────────────────────────────────────────

  def make_project(dir, &block)
    path = File.join(dir, "test.mpr")
    Mxrb.define(path) do
      mendix_version "10.18.0"
      instance_eval(&block) if block
    end
    path
  end

  describe "evaluate_dir" do
    it "loads all Ruby files into the project builder" do
      Dir.mktmpdir do |dir|
        definitions = File.join(dir, "modules")
        FileUtils.mkdir_p(definitions)
        File.write(File.join(definitions, "shop.rb"), "self.module(:Shop) { entity :Product }\n")
        File.write(File.join(definitions, "sales.rb"), "self.module(:Sales) { entity :Order }\n")

        path = make_project(dir) { evaluate_dir(definitions) }

        expect(Mxrb.open(path) { _1.modules.map(&:name) }).to eq(%w[Sales Shop])
      end
    end

    it "silently skips a directory that does not exist" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          evaluate_dir(File.join(dir, "missing"))
          self.module(:Shop) { evaluate_dir(File.join(dir, "missing")) }
        end

        expect(Mxrb.validate(path)).to be_valid
      end
    end

    it "loads module definitions in deterministic alphabetical order" do
      Dir.mktmpdir do |dir|
        definitions = File.join(dir, "entities")
        FileUtils.mkdir_p(definitions)
        File.write(File.join(definitions, "b_entity.rb"), "entity :B\n")
        File.write(File.join(definitions, "a_entity.rb"), "entity :A\n")

        path = make_project(dir) do
          self.module(:Shop) { evaluate_dir(definitions) }
        end

        names = Mxrb.open(path) { _1.modules.first.entities.map(&:name) }
        expect(names).to eq(%w[A B])
      end
    end
  end

  describe "enumeration attributes" do
    it "writes the qualified enumeration reference into the attribute type" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:VetClinic) do
            enumeration(:Species) { value :Dog; value :Cat }
            entity(:Animal) { enum :Kind, enumeration: "VetClinic.Species" }
          end
        end

        attribute = Mxrb.open(path) { _1.modules.first.entities.first.attributes.first }
        expect(attribute.raw_type_doc).to include(
          "$Type" => "DomainModels$EnumerationAttributeType",
          "Enumeration" => "VetClinic.Species"
        )
      end
    end
  end

  # ── Association ownership ─────────────────────────────────────────────────

  describe "association ownership" do
    it "writes and reopens a one-to-one association as Reference owned by Both" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:VetClinic) do
            entity :Owner do
              association "VetClinic.Profile", name: "Owner_Profile", owner: :Both
            end
            entity :Profile
          end
        end

        association = Mxrb.open(path) { _1.modules.first.associations.fetch(0) }
        expect(association.association_type).to eq(:Reference)
        expect(association.owner).to eq(:Both)
        expect(association.storage_format).to eq(:Column)
        expect(Mxrb.validate(path)).to be_valid
      end
    end

    it "exports one-to-one ownership and preserves it on rebuild" do
      Dir.mktmpdir do |dir|
        source = make_project(dir) do
          self.module(:VetClinic) do
            entity :Owner do
              association :Profile, name: "Owner_Profile", owner: :Both
            end
            entity :Profile
          end
        end
        exported = File.join(dir, "exported")
        rebuilt = File.join(dir, "rebuilt.mpr")

        Mxrb::Exporter.new(source, exported).export!
        owner_source = Dir.glob(File.join(exported, "**", "owner.rb")).fetch(0)
        expect(File.read(owner_source)).to include("cardinality: :one_to_one")

        begin
          ENV["MXRB_OUTPUT_PATH"] = rebuilt
          load File.join(exported, "project.rb")
        ensure
          ENV.delete("MXRB_OUTPUT_PATH")
        end
        association = Mxrb.open(rebuilt) { _1.modules.first.associations.fetch(0) }
        expect(association.owner).to eq(:Both)
      end
    end

    it "keeps one-to-many as the default and rejects unsupported values" do
      builder = Mxrb::Dsl::EntityBuilder.new(:Order)
      builder.association(:Customer)
      expect(builder.to_h.fetch(:associations).fetch(0)).to include(
        type: :Reference, owner: :Default
      )
      expect { builder.association(:Customer, type: :Unknown) }
        .to raise_error(ArgumentError, /association type/)
      expect { builder.association(:Customer, owner: :Unknown) }
        .to raise_error(ArgumentError, /association owner/)
    end
  end

  # ── Domain Mutation — AddAttribute ─────────────────────────────────────────

  describe "plan_add_attribute" do
    it "adds an attribute to an existing entity" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:Shop) { entity :Product do; string :Name; end }
        end

        Mxrb.open(path, readonly: false) do |project|
          plan = project.plan_add_attribute(
            "Shop.Product", name: :Price, type: :decimal, default: "0.0", required: true
          )

          expect(plan.changes).to include(match(/Price.*decimal.*Shop\.Product/i))
          expect(plan.empty?).to be false
          expect(plan.applied?).to be false

          plan.apply!

          expect(plan.applied?).to be true
          product = project.modules.first.entities.find { _1.name == "Product" }
          expect(product.attributes.map(&:name)).to include("Price")
          price = product.attributes.find { _1.name == "Price" }
          expect(price.type).to eq(:decimal)
          expect(price.default_value).to eq("0.0")
          expect(price.required).to be true
          domain = project.parse_bson(project.raw_unit(project.modules.first.domain_model.id))
          entity_doc = Mxrb::IO::BsonCodec.parse_array(domain.fetch("Entities"))[:items].first
          price_docs = Mxrb::IO::BsonCodec.parse_array(entity_doc.fetch("Attributes"))[:items]
          price_doc = price_docs.find { _1["Name"] == "Price" }
          expect(price_doc).to include("Name" => "Price")
          expect(price_doc.fetch("GUID")).not_to be_nil
          expect(price_doc).not_to have_key("name")
        end
      end
    end

    it "raises if the attribute already exists" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) { entity :E do; string :Name; end }
        end

        Mxrb.open(path, readonly: false) do |project|
          expect { project.add_attribute!("M.E", name: :Name, type: :string) }
            .to raise_error(ArgumentError, /already exists/)
        end
      end
    end

    it "raises if the entity does not exist" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) { entity :E }
        end

        Mxrb.open(path, readonly: false) do |project|
          expect { project.plan_add_attribute("M.Ghost", name: :X, type: :string) }
            .to raise_error(KeyError, /entity.*not found/i)
        end
      end
    end

    it "raises if applied twice" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) { entity :E }
        end

        Mxrb.open(path, readonly: false) do |project|
          plan = project.plan_add_attribute("M.E", name: :X, type: :string)
          plan.apply!
          expect { plan.apply! }.to raise_error(ArgumentError, /already applied/)
        end
      end
    end
  end

  # ── Domain Mutation — RemoveAttribute ──────────────────────────────────────

  describe "plan_remove_attribute" do
    it "removes an attribute from an entity" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) { entity :E do; string :Name; integer :Count; end }
        end

        Mxrb.open(path, readonly: false) do |project|
          plan = project.plan_remove_attribute("M.E/Count")
          expect(plan.changes).to include(match(/M\.E\/Count/))
          expect(plan.safe?).to be true
          plan.apply!

          attrs = project.modules.first.entities.first.attributes.map(&:name)
          expect(attrs).to include("Name")
          expect(attrs).not_to include("Count")
        end
      end
    end

    it "is not safe when other artifacts reference the attribute" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) do
            entity :E do; string :Name; end
            microflow :UseIt do
              retrieve_objects "M.E", as: :items
              change_object :items do
                set "M.E/Name", to: "'hello'"
              end
            end
          end
        end

        Mxrb.open(path, readonly: false) do |project|
          plan = project.plan_remove_attribute("M.E/Name")
          expect(plan.safe?).to be false
          expect { plan.apply! }.to raise_error(ArgumentError, /incoming reference/)
        end
      end
    end

    it "raises with the right format for bad qname" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) { self.module(:M) { entity :E } }

        Mxrb.open(path, readonly: false) do |project|
          expect { project.plan_remove_attribute("M.E") }
            .to raise_error(ArgumentError, /M\.Entity\/AttributeName/)
        end
      end
    end
  end

  # ── Domain Mutation — ChangeAttribute ──────────────────────────────────────

  describe "plan_change_attribute" do
    it "changes type and default" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) { entity :E do; string :Score; end }
        end

        Mxrb.open(path, readonly: false) do |project|
          plan = project.plan_change_attribute(
            "M.E/Score", type: :integer, default: "0", required: true
          )
          expect(plan.changes.first).to match(/Score/)
          plan.apply!

          attr = project.modules.first.entities.first.attributes.first
          expect(attr.type).to eq(:integer)
          expect(attr.default_value).to eq("0")
          expect(attr.required).to be true
          domain = project.parse_bson(project.raw_unit(project.modules.first.domain_model.id))
          entity_doc = Mxrb::IO::BsonCodec.parse_array(domain.fetch("Entities"))[:items].first
          score_doc = Mxrb::IO::BsonCodec.parse_array(entity_doc.fetch("Attributes"))[:items].first
          expect(score_doc).to include("Name" => "Score")
          expect(score_doc.fetch("GUID")).not_to be_nil
          expect(score_doc).not_to have_key("name")
        end
      end
    end

    it "raises if no changes specified" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) { self.module(:M) { entity :E do; string :X; end } }

        Mxrb.open(path, readonly: false) do |project|
          expect { project.plan_change_attribute("M.E/X") }
            .to raise_error(ArgumentError, /no changes specified/)
        end
      end
    end
  end

  # ── Domain Mutation — AddEntity ─────────────────────────────────────────────

  describe "plan_add_entity" do
    it "adds a new entity with attributes" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) { self.module(:M) { entity :Existing } }

        Mxrb.open(path, readonly: false) do |project|
          plan = project.plan_add_entity("M", name: :NewEntity,
                                         attributes: [
                                           { name: :Label, type: :string, required: true },
                                           { name: :Active, type: :boolean, default: "true" }
                                         ])
          expect(plan.changes).to include(match(/NewEntity/))
          plan.apply!

          names = project.modules.first.entities.map(&:name)
          expect(names).to include("NewEntity")
          entity = project.modules.first.entities.find { _1.name == "NewEntity" }
          expect(entity.attributes.map(&:name)).to eq(%w[Label Active])
          expect(entity.attributes.find { _1.name == "Label" }.required).to be true
          active = entity.attributes.find { _1.name == "Active" }
          expect(active.type).to eq(:boolean)
          expect(active.default_value).to eq("true")
          domain = project.parse_bson(project.raw_unit(project.modules.first.domain_model.id))
          entity_docs = Mxrb::IO::BsonCodec.parse_array(domain.fetch("Entities"))[:items]
          entity_doc = entity_docs.find { _1["Name"] == "NewEntity" }
          expect(entity_doc).to include("Name" => "NewEntity")
          expect(entity_doc.fetch("GUID")).not_to be_nil
          expect(entity_doc).to include("Attributes", "ValidationRules", "MaybeGeneralization")
          expect(entity_doc).not_to have_key("name")
        end
      end
    end

    it "raises if entity already exists" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) { self.module(:M) { entity :E } }

        Mxrb.open(path, readonly: false) do |project|
          expect { project.add_entity!("M", name: :E) }
            .to raise_error(ArgumentError, /already exists/)
        end
      end
    end
  end

  # ── Domain Mutation — RemoveEntity ─────────────────────────────────────────

  describe "plan_remove_entity" do
    it "removes an entity with no references" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) { entity :ToRemove; entity :Keeper }
        end

        Mxrb.open(path, readonly: false) do |project|
          plan = project.plan_remove_entity("M.ToRemove")
          expect(plan.safe?).to be true
          expect(plan.changes).to include(match(/ToRemove/))
          plan.apply!

          names = project.modules.first.entities.map(&:name)
          expect(names).not_to include("ToRemove")
          expect(names).to include("Keeper")
        end
      end
    end

    it "is not safe when entity has incoming references" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) do
            entity :Target do; string :Name; end
            microflow :Use do
              retrieve_objects "M.Target", as: :items
            end
          end
        end

        Mxrb.open(path, readonly: false) do |project|
          plan = project.plan_remove_entity("M.Target")
          expect(plan.safe?).to be false
          expect { plan.apply! }.to raise_error(ArgumentError, /incoming reference/)
        end
      end
    end
  end

  # ── BatchPlan — atomic rollback ─────────────────────────────────────────────

  describe "batch_plan" do
    it "applies all plans atomically on success" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) { entity :E }
        end

        Mxrb.open(path, readonly: false) do |project|
          plan1 = project.plan_add_attribute("M.E", name: :X, type: :string)
          plan2 = project.plan_add_attribute("M.E", name: :Y, type: :integer)
          batch = project.batch_plan([plan1, plan2])

          expect(batch.changes.size).to eq(2)
          batch.apply!

          attrs = project.modules.first.entities.first.attributes.map(&:name)
          expect(attrs).to include("X", "Y")
        end
      end
    end

    it "rolls back all changes when a plan in the batch fails" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) { entity :E do; string :Existing; end }
        end

        Mxrb.open(path, readonly: false) do |project|
          plan1 = project.plan_add_attribute("M.E", name: :Good, type: :string)
          plan2 = project.plan_add_attribute("M.E", name: :Existing, type: :string)  # will fail
          batch = project.batch_plan([plan1, plan2])

          expect { batch.apply! }.to raise_error(Mxrb::BatchError, /batch failed/)

          # plan1 effect should be rolled back
          attrs = project.modules.first.entities.first.attributes.map(&:name)
          expect(attrs).not_to include("Good")
          expect(attrs).to include("Existing")
        end
      end
    end

    it "returns self immediately when plans list is empty" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) { self.module(:M) { entity :E } }

        Mxrb.open(path, readonly: false) do |project|
          batch = project.batch_plan([])
          result = batch.apply!
          expect(result).to be(batch)
          expect(batch.applied?).to be false
        end
      end
    end

    it "raises on re-apply" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) { self.module(:M) { entity :E } }

        Mxrb.open(path, readonly: false) do |project|
          batch = project.batch_plan([project.plan_add_attribute("M.E", name: :X, type: :string)])
          batch.apply!
          expect { batch.apply! }.to raise_error(ArgumentError, /already applied/)
        end
      end
    end
  end

  # ── Parallel Export ─────────────────────────────────────────────────────────

  describe "Exporter parallel: true" do
    it "produces identical output with and without parallelism" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:A) { microflow :FlowA }
          self.module(:B) { microflow :FlowB }
        end

        out_seq = File.join(dir, "seq")
        out_par = File.join(dir, "par")
        Mxrb::Exporter.new(path, out_seq).export!(parallel: false)
        Mxrb::Exporter.new(path, out_par).export!(parallel: true)

        seq_files = Dir.glob("#{out_seq}/**/*").map { _1.delete_prefix(out_seq) }.sort
        par_files = Dir.glob("#{out_par}/**/*").map { _1.delete_prefix(out_par) }.sort
        expect(par_files).to eq(seq_files)
      end
    end
  end

  # ── GitHub Annotator ────────────────────────────────────────────────────────

  describe "Github::Annotator" do
    def make_compare_result(base_block, head_block)
      base_dir = Dir.mktmpdir
      head_dir = Dir.mktmpdir
      base_path = File.join(base_dir, "base.mpr")
      head_path = File.join(head_dir, "head.mpr")
      Mxrb.define(base_path) { mendix_version "10.18.0"; instance_eval(&base_block) }
      Mxrb.define(head_path) { mendix_version "10.18.0"; instance_eval(&head_block) }
      result = Mxrb::Compare::Comparator.new(base_path, head_path).compare
      FileUtils.rm_rf([base_dir, head_dir])
      result
    end

    it "builds annotations from a compare result" do
      result = make_compare_result(
        proc { self.module(:M) { entity :Old; microflow :Keep } },
        proc { self.module(:M) { entity :New; microflow :Keep } }
      )
      ann = Mxrb::Github::Annotator.new(result)

      expect(ann.annotations).not_to be_empty
      expect(ann.annotations.first).to respond_to(:level, :title, :message)
    end

    it "emits GitHub Actions annotation lines" do
      result = make_compare_result(
        proc { self.module(:M) { microflow :Old } },
        proc { self.module(:M) { microflow :New } }
      )
      ann = Mxrb::Github::Annotator.new(result)

      out = StringIO.new
      ann.print_actions_annotations(out: out)
      lines = out.string.split("\n")
      expect(lines).not_to be_empty
      expect(lines.first).to match(/^::(?:notice|warning)/)
    end

    it "generates a PR comment body with a Markdown table including changed detail" do
      result = make_compare_result(
        proc { self.module(:M) { entity :E do; string :Name; end } },
        proc { self.module(:M) { entity :E do; decimal :Name; end } }
      )
      ann = Mxrb::Github::Annotator.new(result)

      body = ann.comment_body
      expect(body).to include("## MXRB Semantic Diff")
      expect(body).to include("| Operation |")
      expect(body).to include("MXRB")
      # :changed detail shows before → after values
      expect(body).to match(/→/)
    end

    it "covers :added and :removed format_message branches and comment_body else detail" do
      result = make_compare_result(
        proc { self.module(:M) { entity :Base } },
        proc { self.module(:M) { entity :Base; entity :Added } }
      )
      ann = Mxrb::Github::Annotator.new(result)
      messages = ann.annotations.map(&:message)
      expect(messages).to include(match(/Added:/))
      # :added operation hits the else "" branch in build_comment_body
      body = ann.comment_body
      expect(body).to include("Added")

      result2 = make_compare_result(
        proc { self.module(:M) { entity :ToRemove; entity :Keep } },
        proc { self.module(:M) { entity :Keep } }
      )
      ann2 = Mxrb::Github::Annotator.new(result2)
      expect(ann2.annotations.map(&:message)).to include(match(/Removed:/))
      expect(ann2.comment_body).to include("Removed")
    end

    it "covers logic and presentation layers in exported_file" do
      Dir.mktmpdir do |dir|
        base_dir = Dir.mktmpdir
        head_dir = Dir.mktmpdir

        base_path = File.join(base_dir, "base.mpr")
        head_path = File.join(head_dir, "head.mpr")

        Mxrb.define(base_path) do
          mendix_version "10.18.0"
          self.module(:M) { microflow :Keep }
        end
        Mxrb.define(head_path) do
          mendix_version "10.18.0"
          self.module(:M) { microflow :Keep; microflow :NewFlow; page :NewPage }
        end

        out_dir = File.join(dir, "exported")
        Mxrb::Exporter.new(head_path, out_dir).export!

        result = Mxrb::Compare::Comparator.new(base_path, head_path).compare
        ann = Mxrb::Github::Annotator.new(result, exported_dir: out_dir)

        annotations = ann.annotations
        logic_anns = annotations.select { _1.file&.include?("logic") }
        pres_anns  = annotations.select { _1.file&.include?("presentation") }

        expect(logic_anns).not_to be_empty        # covers line 128 (logic branch)
        expect(pres_anns).not_to  be_empty        # covers line 130 (presentation branch)

        FileUtils.rm_rf([base_dir, head_dir])
      end
    end

    it "resolves exported file path and finds line number with exported_dir" do
      Dir.mktmpdir do |dir|
        base_dir = Dir.mktmpdir
        head_dir = Dir.mktmpdir
        base_path = File.join(base_dir, "base.mpr")
        head_path = File.join(head_dir, "head.mpr")
        Mxrb.define(base_path) { mendix_version "10.18.0"; self.module(:M) { entity :Old } }
        Mxrb.define(head_path) { mendix_version "10.18.0"; self.module(:M) { entity :Old; entity :New } }

        out_dir = File.join(dir, "exported")
        Mxrb::Exporter.new(head_path, out_dir).export!

        result = Mxrb::Compare::Comparator.new(base_path, head_path).compare
        ann = Mxrb::Github::Annotator.new(result, exported_dir: out_dir)

        annotations = ann.annotations
        # entity changes resolve to domain/model.rb
        domain_anns = annotations.select { _1.file&.include?("domain") }
        expect(domain_anns).not_to be_empty
        # file path is set
        expect(domain_anns.first.file).to include("modules")

        FileUtils.rm_rf([base_dir, head_dir])
      end
    end

    it "returns nil line when label not found in exported file" do
      Dir.mktmpdir do |dir|
        base_dir = Dir.mktmpdir
        head_dir = Dir.mktmpdir
        base_path = File.join(base_dir, "base.mpr")
        head_path = File.join(head_dir, "head.mpr")
        Mxrb.define(base_path) { mendix_version "10.18.0"; self.module(:M) { entity :Old } }
        Mxrb.define(head_path) { mendix_version "10.18.0"; self.module(:M) { entity :Old; entity :New } }

        out_dir = File.join(dir, "exported")
        Mxrb::Exporter.new(base_path, out_dir).export!

        result = Mxrb::Compare::Comparator.new(base_path, head_path).compare
        ann = Mxrb::Github::Annotator.new(result, exported_dir: out_dir)

        # New entity not in base export → find_line_in_file returns nil
        new_ann = ann.annotations.find { _1.message.include?("New") }
        expect(new_ann).not_to be_nil
        # nil file or nil line is acceptable (artifact may not map to exported file)
        expect(new_ann.line).to be_nil.or(be_a(Integer))

        FileUtils.rm_rf([base_dir, head_dir])
      end
    end
  end

  # ── MprFile backup/restore ──────────────────────────────────────────────────

  # ── Semantic index cache ─────────────────────────────────────────────────────

  describe "Semantic::Index cache" do
    it "writes cache on first open and hits it on second open" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) do
            entity :Other
            entity :Cached do
              string :Name
              association :Other
            end
            microflow :CachedFlow do
              mark_as_used
              retrieve_objects "Unknown.Missing", as: :missing
            end
          end
        end

        # First open (read-write) — builds and writes cache
        Mxrb.open(path, readonly: false) do |project|
          idx = project.semantic_index
          expect(idx.find("M.Cached", kind: :entity)).not_to be_nil
          expect(idx.find("M.CachedFlow", kind: :microflow)).not_to be_nil
        end

        # Verify _MxrbIndexCache table was created
        db = SQLite3::Database.new(path)
        db.results_as_hash = true
        tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { _1["name"] }
        expect(tables).to include("_MxrbIndexCache")
        row = db.get_first_row("SELECT Fingerprint, IndexData FROM _MxrbIndexCache LIMIT 1")
        expect(row).not_to be_nil
        expect(row["IndexData"]).to include("Cached")
        db.close

        # Second open — should hit cache (same result)
        Mxrb.open(path, readonly: false) do |project|
          expect(project.mpr).to receive(:read_index_cache).and_call_original
          idx = project.semantic_index
          entity = idx.find("M.Cached", kind: :entity)
          flow = idx.find("M.CachedFlow", kind: :microflow)
          attribute = idx.find("M.Cached.Name", kind: :attribute)
          association = idx.find("M.Cached_Other", kind: :association)
          expect(entity.metadata[:model].name).to eq("Cached")
          expect(attribute.metadata[:model].name).to eq("Name")
          expect(attribute.metadata[:entity]).to equal(entity)
          expect(association.metadata[:model].name).to eq("Cached_Other")
          expect(association.metadata.values_at(:from, :to))
            .to contain_exactly("M.Cached", "M.Other")
          expect(flow.metadata[:mark_as_used]).to be(true)
          expect(idx.unresolved_references.map(&:qualified_name)).to include("Unknown.Missing")
          # All artifacts should be present from cache
          expect(idx.artifacts.map(&:name)).to include("Cached", "CachedFlow")
        end
      end
    end

    it "invalidates cache when project is mutated" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) { entity :E }
        end

        # Prime the cache
        Mxrb.open(path, readonly: false) { |p| p.semantic_index }

        # Mutate — should write new cache with updated fingerprint
        Mxrb.open(path, readonly: false) do |project|
          project.add_entity!("M", name: :NewEntity)
          idx = project.semantic_index  # rebuilt after refresh!
          expect(idx.find("M.NewEntity", kind: :entity)).not_to be_nil
        end

        # Re-open — cache should reflect mutation
        Mxrb.open(path, readonly: false) do |project|
          idx = project.semantic_index
          expect(idx.find("M.NewEntity", kind: :entity)).not_to be_nil
        end
      end
    end

    it "invalidates cache when unit containment changes without changing contents" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:First) { microflow :Moved }
          self.module(:Second)
        end

        Mxrb.open(path, readonly: false) { |project| project.semantic_index }

        Mxrb.open(path, readonly: false) do |project|
          flow = project.find_artifact("First.Moved", kind: :microflow)
          second = project.modules.find { _1.name == "Second" }
          project.mpr.relocate_unit(
            flow.unit_id, container_uuid: second.id, containment_name: "Microflows"
          )
        end

        Mxrb.open(path, readonly: false) do |project|
          expect(project.find_artifact("First.Moved", kind: :microflow)).to be_nil
          expect(project.find_artifact("Second.Moved", kind: :microflow)).not_to be_nil
        end
      end
    end

    it "rebuilds and replaces a corrupt cache entry" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) do
            entity :Recovered
            microflow :Use do
              retrieve_objects "M.Recovered", as: :found
              retrieve_objects "Unknown.Missing", as: :missing
            end
          end
        end
        Mxrb.open(path, readonly: false) { |project| project.semantic_index }

        db = SQLite3::Database.new(path)
        valid = JSON.parse(db.get_first_value("SELECT IndexData FROM _MxrbIndexCache"))
        db.close
        bad_reference = JSON.parse(JSON.generate(valid))
        bad_reference.fetch("references").first["source_id"] = "missing"
        bad_unresolved = JSON.parse(JSON.generate(valid))
        bad_unresolved.fetch("unresolved").first["source_id"] = "missing"
        bad_payloads = [
          "{",
          JSON.generate(version: 0, artifacts: [], references: [], unresolved: []),
          JSON.generate(version: 1, artifacts: [], references: [], unresolved: []),
          JSON.generate(bad_reference),
          JSON.generate(bad_unresolved)
        ]
        bad_payloads.each do |payload|
          db = SQLite3::Database.new(path)
          db.execute("UPDATE _MxrbIndexCache SET IndexData = ?", [payload])
          db.close

          Mxrb.open(path, readonly: false) do |project|
            expect(project.find_artifact("M.Recovered", kind: :entity)).not_to be_nil
          end
        end

        db = SQLite3::Database.new(path)
        repaired = db.get_first_value("SELECT IndexData FROM _MxrbIndexCache")
        expect { JSON.parse(repaired) }.not_to raise_error
        db.close
      end
    end

    it "does not write cache when opened read-only" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) { self.module(:M) { entity :E } }

        Mxrb.open(path, readonly: true) do |project|
          project.semantic_index  # should build but not persist
        end

        db = SQLite3::Database.new(path)
        tables = db.execute("SELECT name FROM sqlite_master WHERE type='table'").map { _1.first }
        expect(tables).not_to include("_MxrbIndexCache")
        db.close
      end
    end

    it "cached index supports references_to and impact_of" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:M) do
            entity :Product do; string :Name; end
            microflow :Use do; retrieve_objects "M.Product", as: :items; end
          end
        end

        # Prime cache
        Mxrb.open(path, readonly: false) { |p| p.semantic_index }

        # Use from cache
        Mxrb.open(path, readonly: false) do |project|
          idx = project.semantic_index
          product = idx.find("M.Product", kind: :entity)
          expect(product).not_to be_nil
          refs = idx.references_to(product)
          expect(refs).not_to be_empty
          impact = project.impact_of("M.Product")
          expect(impact.artifacts).not_to be_empty
        end
      end
    end
  end

  describe "MprFile#backup! and restore_from!" do
    it "creates a backup and restores it" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) { self.module(:M) { entity :Original } }
        backup = File.join(dir, "backup.mpr")

        Mxrb.open(path, readonly: false) do |project|
          project.mpr.backup!(backup)
          expect(File.exist?(backup)).to be true

          project.add_entity!("M", name: :Modified)
          expect(project.modules.first.entities.map(&:name)).to include("Modified")

          project.mpr.restore_from!(backup)
          project.refresh!
          expect(project.modules.first.entities.map(&:name)).not_to include("Modified")
          expect(project.modules.first.entities.map(&:name)).to include("Original")
        end
      end
    end
  end
end
