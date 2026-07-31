# frozen_string_literal: true

require_relative "../io/mpr_file"

module Mxrb
  module Model
    class Project
      attr_reader :mpr

      def self.open(path, readonly: true)
        new(IO::MprFile.open(path, readonly: readonly))
      end

      def initialize(mpr)
        @mpr = mpr
      end

      def name            = @mpr.project_name
      def mendix_version  = @mpr.mendix_version
      def format_version  = @mpr.format_version

      # ── Artefacts ──────────────────────────────────────────────────────

      def modules
        @modules ||= @mpr.units_by_containment("Modules").map { Module.new(_1, @mpr) }
      end

      def entities    = modules.flat_map(&:entities)
      def pages       = modules.flat_map(&:pages)
      def microflows  = modules.flat_map(&:microflows)

      def navigation
        @navigation ||= begin
          raw = all_units.find { parse_bson(_1)["$Type"] == "Navigation$NavigationDocument" }
          Navigation.new(raw && parse_bson(raw))
        end
      end

      def design_system = (@design_system ||= DesignSystem.new(File.dirname(@mpr.path)))
      def plan_design_token_migration(replacements) =
        design_system.plan_literal_migration(replacements)

      # ── Low-level exploration ───────────────────────────────────────────

      def all_units   = @mpr.all_units
      def tables      = @mpr.tables
      def table_info(n) = @mpr.table_info(n)
      def query(sql, *b) = @mpr.query(sql, *b)
      def raw_unit(uuid) = @mpr.unit(uuid)
      def children_of(uuid) = @mpr.children_of(uuid)
      def parse_bson(raw)   = @mpr.parse_contents(raw)
      def architecture_definition = @mpr.architecture_definition

      # ── Native OQL inspection ───────────────────────────────────────────

      def oql_queries = (@oql_catalog ||= Oql::Catalog.new(self)).queries
      def oql? = !oql_queries.empty?
      def oql_sql_views(dialect: :postgresql)
        translator = Oql::Translator.new(dialect:)
        oql_queries.map { translator.translate(_1) }.freeze
      end
      def oql_analysis(dialect: :postgresql)
        analyzer = Oql::Analyzer.new(dialect:)
        oql_queries.map { analyzer.analyze(_1) }.freeze
      end

      # ── Semantic analysis ───────────────────────────────────────────────

      def semantic_index = (@semantic_index ||= Semantic::Index.new(self))
      def semantic_cache_info
        @mpr.index_cache_info(
          current_fingerprint: Semantic::Index.fingerprint(self)
        )
      end
      def warm_semantic_cache!
        semantic_index
        semantic_cache_info
      end
      def clear_semantic_cache!
        removed = @mpr.clear_index_cache!
        @semantic_index = nil
        removed
      end
      def find_artifact(name, kind: nil) = semantic_index.find(name, kind: kind)
      def search_artifacts(query, **filters) = semantic_index.search(query, **filters)
      def semantic_search_artifacts(query, **options) =
        semantic_index.semantic_search_artifacts(query, **options)
      def semantic_search_hits(query, **options) =
        semantic_index.semantic_search_hits(query, **options)
      def describe_artifact(name) = semantic_index.describe(name)
      def references_to(name) = semantic_index.references_to(name)
      def references_from(name) = semantic_index.references_from(name)
      def callers_of(name) = semantic_index.callers_of(name)
      def callees_of(name) = semantic_index.callees_of(name)
      def impact_of(name, transitive: true) =
        semantic_index.impact_of(name, transitive: transitive)
      def plan_rename(name, to:) = Semantic::Renamer.new(self).plan(name, to: to)
      def rename!(name, to:) = plan_rename(name, to: to).apply!
      def plan_remove(name) = Semantic::Remover.new(self).plan(name)
      def remove!(name) = plan_remove(name).apply!
      def plan_move(name, to:) = Semantic::Mover.new(self).plan(name, to: to)
      def move!(name, to:) = plan_move(name, to: to).apply!
      def plan_extract(name, as:, object_ids:) =
        Semantic::Extractor.new(self).plan(name, as: as, object_ids: object_ids)
      def extract!(name, as:, object_ids:) = plan_extract(name, as: as, object_ids: object_ids).apply!
      def plan_inline(name, calling:) = Semantic::Inliner.new(self).plan(name, calling: calling)
      def inline!(name, calling:) = plan_inline(name, calling: calling).apply!
      def analyze(**options) = Semantic::Analyzer.new(self).analyze(**options)
      alias lint analyze

      # ── Domain model mutation ───────────────────────────────────────────────

      def plan_add_attribute(entity, name:, type: :string, **opts) =
        Semantic::DomainMutator.new(self).plan_add_attribute(entity, name: name, type: type, **opts)
      def add_attribute!(entity, name:, type: :string, **opts) =
        plan_add_attribute(entity, name: name, type: type, **opts).apply!

      def plan_remove_attribute(attribute) =
        Semantic::DomainMutator.new(self).plan_remove_attribute(attribute)
      def remove_attribute!(attribute) = plan_remove_attribute(attribute).apply!

      def plan_change_attribute(attribute, **updates) =
        Semantic::DomainMutator.new(self).plan_change_attribute(attribute, **updates)
      def change_attribute!(attribute, **updates) = plan_change_attribute(attribute, **updates).apply!

      def plan_add_entity(mod, name:, **opts) =
        Semantic::DomainMutator.new(self).plan_add_entity(mod, name: name, **opts)
      def add_entity!(mod, name:, **opts) = plan_add_entity(mod, name: name, **opts).apply!

      def plan_remove_entity(entity) =
        Semantic::DomainMutator.new(self).plan_remove_entity(entity)
      def remove_entity!(entity) = plan_remove_entity(entity).apply!

      # ── Batch plan ──────────────────────────────────────────────────────────

      def batch_plan(plans) = Semantic::BatchPlan.new(project: self, plans: Array(plans))
      def evaluate(&block)
        Evaluation::Suite.new(self).tap { _1.instance_eval(&block) }.run
      end

      # Structurally migrates the project to a different Mendix version.
      # Requires an MXRB architecture definition stored in the MPR
      # (i.e. the project was generated by MXRB). Re-runs the Writer with
      # the target version so all version-specific BSON structures are
      # regenerated correctly. Idempotent — safe to call multiple times.
      def migrate_to!(version)
        v = version.to_s
        raise ArgumentError, "version must be a non-empty string" if v.empty?

        definition = @mpr.architecture_definition
        raise ArgumentError,
              "no MXRB architecture definition found in this MPR — " \
              "structural migration requires a project generated by MXRB" unless definition

        path    = @mpr.path
        readonly = @mpr.readonly?
        raise ArgumentError, "project is opened read-only; reopen with readonly: false" if readonly

        updated = definition.merge(version: v)
        @mpr.close
        Writer.new(path, updated).write!
        @mpr = IO::MprFile.open(path, readonly: false)
        @mpr.update_version!(v)
        refresh!
        self
      end

      alias upgrade_to!   migrate_to!
      alias downgrade_to! migrate_to!

      def refresh!
        @modules = nil
        @semantic_index = nil
        @navigation = nil
        @design_system = nil
        @oql_catalog = nil
        self
      end

      def close = @mpr.close

      def inspect
        "#<Mxrb::Project name=#{name.inspect} version=#{mendix_version.inspect} format=#{format_version}>"
      end
    end
  end
end
