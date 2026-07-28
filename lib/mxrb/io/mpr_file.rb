# frozen_string_literal: true

require "sqlite3"
require "securerandom"

module Mxrb
  module IO
    # Low-level SQLite wrapper around a .mpr file.
    # All higher-level models delegate here for raw reads and writes.
    class MprFile
      MPR_MAGIC = "SQLite format 3\x00"

      attr_reader :path

      def initialize(path, readonly: false)
        @path     = File.expand_path(path)
        @readonly = readonly
        @db       = open_db
        validate!
        load_unit_type_map
      end

      def self.open(path, readonly: false)
        new(path, readonly: readonly)
      end

      # ── Metadata ────────────────────────────────────────────────────────

      def metadata
        @metadata ||= begin
          row = @db.get_first_row("SELECT * FROM _MetaData LIMIT 1")
          row ? Hash[@db.table_info("_MetaData").map { _1["name"] }.zip(row)] : {}
        end
      end

      def mendix_version
        metadata["MendixVersion"]
      end

      def project_name
        metadata["ProjectName"]
      end

      # ── Unit queries ─────────────────────────────────────────────────────

      # All units of a given type name (e.g. "Mxmodels.Projects.Module")
      def units_of_type(type_name)
        type_id = @unit_type_map[type_name]
        return [] unless type_id

        @db.execute(
          "SELECT UnitID, ContainerID, ContainmentName, Contents FROM Unit WHERE UnitTypeID = ?",
          [type_id]
        ).map { |row| row_to_hash(row, %w[UnitID ContainerID ContainmentName Contents]) }
      end

      # Single unit by ID
      def unit(id)
        row = @db.get_first_row(
          "SELECT UnitID, ContainerID, ContainmentName, UnitTypeID, ContentsHash, Contents FROM Unit WHERE UnitID = ?",
          [id]
        )
        return nil unless row
        hash = row_to_hash(row, %w[UnitID ContainerID ContainmentName UnitTypeID ContentsHash Contents])
        hash["TypeName"] = @unit_type_map.key(hash["UnitTypeID"])
        hash
      end

      # All units as raw rows (for exploration / reverse engineering)
      def all_units
        @db.execute("SELECT UnitID, ContainerID, ContainmentName, UnitTypeID FROM Unit").map do |row|
          h = row_to_hash(row, %w[UnitID ContainerID ContainmentName UnitTypeID])
          h["TypeName"] = @unit_type_map.key(h["UnitTypeID"])
          h
        end
      end

      # ── Unit type map ────────────────────────────────────────────────────

      def unit_type_names
        @unit_type_map.keys
      end

      # ── Writes ───────────────────────────────────────────────────────────

      def insert_unit(container_id:, containment_name:, type_name:, contents:)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        type_id = ensure_unit_type(type_name)
        uid     = next_unit_id
        hash    = contents_hash(contents)

        @db.execute(
          "INSERT INTO Unit (UnitID, ContainerID, ContainmentName, UnitTypeID, ContentsHash, Contents) VALUES (?, ?, ?, ?, ?, ?)",
          [uid, container_id, containment_name, type_id, hash, contents]
        )
        uid
      end

      def update_unit(unit_id, contents)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        @db.execute(
          "UPDATE Unit SET Contents = ?, ContentsHash = ? WHERE UnitID = ?",
          [contents, contents_hash(contents), unit_id]
        )
      end

      def delete_unit(unit_id)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly
        @db.execute("DELETE FROM Unit WHERE UnitID = ?", [unit_id])
      end

      def transaction(&block)
        @db.transaction(&block)
      end

      # ── Inspection helpers (reverse engineering) ─────────────────────────

      # Dump all table names in the .mpr
      def tables
        @db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").flatten
      end

      # Schema of a specific table
      def table_info(table)
        @db.table_info(table)
      end

      # Raw SQL execution (read-only queries only for safety)
      def query(sql, *binds)
        @db.execute(sql, *binds)
      end

      def close
        @db.close
      end

      private

      def open_db
        flags = @readonly ? SQLite3::Constants::Open::READONLY : SQLite3::Constants::Open::READWRITE
        SQLite3::Database.new(@path, { flags: flags })
      rescue SQLite3::CantOpenException => e
        raise NotMprError, "Cannot open #{@path}: #{e.message}"
      end

      def validate!
        magic = File.read(@path, 16) rescue nil
        raise NotMprError, "#{@path} is not a valid SQLite file" unless magic&.start_with?("SQLite format 3")

        tbls = tables
        raise NotMprError, "Missing Unit table — not a valid .mpr file" unless tbls.include?("Unit")
      end

      def load_unit_type_map
        # Maps type name → numeric ID (and reverse)
        @unit_type_map = {}
        rows = @db.execute("SELECT UnitTypeID, Name FROM UnitType") rescue []
        rows.each { |id, name| @unit_type_map[name] = id }
      end

      def ensure_unit_type(type_name)
        return @unit_type_map[type_name] if @unit_type_map.key?(type_name)

        @db.execute("INSERT INTO UnitType (Name) VALUES (?)", [type_name])
        id = @db.last_insert_row_id
        @unit_type_map[type_name] = id
        id
      end

      def next_unit_id
        max = @db.get_first_value("SELECT MAX(UnitID) FROM Unit") || 0
        max + 1
      end

      def contents_hash(blob)
        require "digest"
        Digest::SHA256.hexdigest(blob || "")
      end

      def row_to_hash(row, keys)
        keys.zip(row).to_h
      end
    end
  end
end
