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

      def close = @mpr.close

      def inspect
        "#<Mxrb::Project name=#{name.inspect} version=#{mendix_version.inspect} format=#{format_version}>"
      end
    end
  end
end
