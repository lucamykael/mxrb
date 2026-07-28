# frozen_string_literal: true

require_relative "../io/mpr_file"

module Mxrb
  module Model
    class Project
      attr_reader :path, :mpr

      def self.open(path)
        new(IO::MprFile.open(path))
      end

      def initialize(mpr)
        @mpr = mpr
      end

      def name
        @mpr.project_name
      end

      def mendix_version
        @mpr.mendix_version
      end

      # ── Top-level artefact accessors ──────────────────────────────────

      def modules
        @modules ||= @mpr.units_of_type("Mxmodels.Projects.Module").map { Module.new(_1, @mpr) }
      end

      def entities
        modules.flat_map(&:entities)
      end

      def pages
        modules.flat_map(&:pages)
      end

      def microflows
        modules.flat_map(&:microflows)
      end

      # ── Low-level exploration (reverse engineering helpers) ───────────

      def all_units
        @mpr.all_units
      end

      def tables
        @mpr.tables
      end

      def table_info(name)
        @mpr.table_info(name)
      end

      def query(sql, *binds)
        @mpr.query(sql, *binds)
      end

      def raw_unit(id)
        @mpr.unit(id)
      end

      def unit_types
        @mpr.unit_type_names
      end

      def close
        @mpr.close
      end

      def inspect
        "#<Mxrb::Project name=#{name.inspect} version=#{mendix_version.inspect}>"
      end
    end
  end
end
