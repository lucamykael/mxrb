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

      # ── Low-level exploration ───────────────────────────────────────────

      def all_units   = @mpr.all_units
      def tables      = @mpr.tables
      def table_info(n) = @mpr.table_info(n)
      def query(sql, *b) = @mpr.query(sql, *b)
      def raw_unit(uuid) = @mpr.unit(uuid)
      def children_of(uuid) = @mpr.children_of(uuid)
      def parse_bson(raw)   = @mpr.parse_contents(raw)
      def architecture_definition = @mpr.architecture_definition

      # ── Semantic analysis ───────────────────────────────────────────────

      def semantic_index = (@semantic_index ||= Semantic::Index.new(self))
      def find_artifact(name, kind: nil) = semantic_index.find(name, kind: kind)
      def search_artifacts(query, **filters) = semantic_index.search(query, **filters)
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
      def analyze(**options) = Semantic::Analyzer.new(self).analyze(**options)
      alias lint analyze
      def evaluate(&block)
        Evaluation::Suite.new(self).tap { _1.instance_eval(&block) }.run
      end

      def refresh!
        @modules = nil
        @semantic_index = nil
        self
      end

      def close = @mpr.close

      def inspect
        "#<Mxrb::Project name=#{name.inspect} version=#{mendix_version.inspect} format=#{format_version}>"
      end
    end
  end
end
