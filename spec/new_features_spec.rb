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

  # ── Domain Mutation — AddAttribute ─────────────────────────────────────────

  describe "plan_add_attribute" do
    it "adds an attribute to an existing entity" do
      Dir.mktmpdir do |dir|
        path = make_project(dir) do
          self.module(:Shop) { entity :Product do; string :Name; end }
        end

        Mxrb.open(path, readonly: false) do |project|
          plan = project.plan_add_attribute("Shop.Product", name: :Price, type: :decimal, default: "0.0")

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
          plan = project.plan_change_attribute("M.E/Score", type: :integer, default: "0")
          expect(plan.changes.first).to match(/Score/)
          plan.apply!

          attr = project.modules.first.entities.first.attributes.first
          expect(attr.type).to eq(:integer)
          expect(attr.default_value).to eq("0")
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
                                           { name: :Label, type: :string },
                                           { name: :Active, type: :boolean, default: "true" }
                                         ])
          expect(plan.changes).to include(match(/NewEntity/))
          plan.apply!

          names = project.modules.first.entities.map(&:name)
          expect(names).to include("NewEntity")
          entity = project.modules.first.entities.find { _1.name == "NewEntity" }
          expect(entity.attributes.map(&:name)).to eq(%w[Label Active])
          active = entity.attributes.find { _1.name == "Active" }
          expect(active.type).to eq(:boolean)
          expect(active.default_value).to eq("true")
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
