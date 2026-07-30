# frozen_string_literal: true

require "sqlite3"
require "securerandom"
require "json"
require_relative "bson_codec"
require_relative "mxunit_codec"

module Mxrb
  module IO
    # Low-level SQLite wrapper for .mpr files.
    #
    # Schema reality (from reverse engineering):
    #   Unit(UnitID BLOB, ContainerID BLOB, ContainmentName TEXT,
    #        TreeConflict LONG, ContentsHash TEXT, ContentsConflict TEXT, Contents BLOB)
    #   _MetaData(_ProductVersion TEXT, _BuildVersion TEXT, _SchemaHash TEXT)
    #     (older MPRs use MendixVersion instead of _ProductVersion)
    #
    # UnitID and ContainerID are 16-byte MS-GUID blobs, not integers.
    # Contents is a BSON blob (v1) or NULL (v2, where .mxunit files hold the data).
    # The $Type of each unit is embedded in its BSON Contents, not in a separate table.
    class MprFile
      attr_reader :path, :format_version

      def initialize(path, readonly: false)
        @path     = File.expand_path(path)
        @readonly = readonly
        @db       = open_db
        validate!
        @format_version = detect_format
      end

      def self.open(path, readonly: false)
        new(path, readonly: readonly)
      end

      # ── Metadata ─────────────────────────────────────────────────────────

      def mendix_version
        @mendix_version ||= begin
          row = @db.get_first_row("SELECT _ProductVersion FROM _MetaData LIMIT 1") rescue nil
          row ||= @db.get_first_row("SELECT MendixVersion FROM _MetaData LIMIT 1") rescue nil
          row&.first
        end
      end

      def project_name
        @project_name ||= begin
          # Name lives in the root Unit's BSON ($QualifiedName or Name field)
          root = root_unit
          return nil unless root

          doc = parse_contents(root)
          doc["Name"] || doc["name"] || File.basename(@path, ".mpr")
        end
      end

      # ── Unit access ───────────────────────────────────────────────────────

      # The root Unit is the one where UnitID == ContainerID.
      def root_unit
        @root_unit ||= begin
          row = @db.get_first_row(
            "SELECT #{unit_select_columns} FROM Unit " \
            "WHERE UnitID = ContainerID LIMIT 1"
          )
          row ? raw_to_hash(row) : nil
        end
      end

      # All units with a given ContainmentName.
      def units_by_containment(name)
        @db.execute(
          "SELECT #{unit_select_columns} FROM Unit " \
          "WHERE ContainmentName = ?",
          [name]
        ).map { raw_to_hash(_1) }
      end

      # Units directly contained by a given parent UUID.
      def children_of(parent_uuid)
        blob = BsonCodec.uuid_to_blob(parent_uuid)
        @db.execute(
          "SELECT #{unit_select_columns} FROM Unit " \
          "WHERE ContainerID = ? AND UnitID != ContainerID",
          [blob]
        ).map { raw_to_hash(_1) }
      end

      # Single unit by UUID string.
      def unit(uuid)
        blob = BsonCodec.uuid_to_blob(uuid)
        row  = @db.get_first_row(
          "SELECT #{unit_select_columns} FROM Unit WHERE UnitID = ?",
          [blob]
        )
        row ? raw_to_hash(row) : nil
      end

      # All units (for exploration / reverse engineering).
      def all_units
        @db.execute(
          "SELECT #{unit_select_columns} FROM Unit"
        ).map { raw_to_hash(_1) }
      end

      # Parse BSON from a raw unit hash.
      def parse_contents(raw_unit)
        blob = raw_unit["Contents"]
        if (blob.nil? || blob.empty?) && @format_version == :v2
          unit_path = MxunitCodec.path_for(contents_dir, raw_unit.fetch("UnitID"))
          return {} unless File.file?(unit_path)
          return MxunitCodec.read(unit_path)
        end
        return {} if blob.nil? || blob.empty?

        BsonCodec.parse(blob)
      end

      def content_bytes(raw_unit)
        blob = raw_unit["Contents"]
        if (blob.nil? || blob.empty?) && @format_version == :v2
          unit_path = MxunitCodec.path_for(contents_dir, raw_unit.fetch("UnitID"))
          return nil unless File.file?(unit_path)

          return File.binread(unit_path)
        end
        blob
      end

      def content_path(raw_unit)
        return nil unless @format_version == :v2

        MxunitCodec.path_for(contents_dir, raw_unit.fetch("UnitID"))
      end

      def content_files
        return [] unless @format_version == :v2 && File.directory?(contents_dir)

        Dir.glob(File.join(contents_dir, "**", "*.mxunit")).sort
      end

      # ── Writes ────────────────────────────────────────────────────────────

      # Insert a new unit. Returns the assigned UUID.
      def insert_unit(container_uuid:, containment_name:, contents_doc:)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        uuid         = BsonCodec.extract_id(contents_doc["$ID"] || contents_doc["\$ID"]) || SecureRandom.uuid
        contents_doc = contents_doc.merge("$ID" => uuid) unless contents_doc.key?("$ID") || contents_doc.key?("\$ID")
        unit_blob    = BsonCodec.uuid_to_blob(uuid)
        parent_blob  = BsonCodec.uuid_to_blob(container_uuid)
        bson_bytes   = BsonCodec.serialize(contents_doc)
        hash         = BsonCodec.contents_hash(bson_bytes)
        stored_bytes = @format_version == :v2 ? nil : bson_bytes
        columns = %w[UnitID ContainerID ContainmentName TreeConflict ContentsHash]
        values = [unit_blob, parent_blob, containment_name, 0, hash]
        if (conflicts = conflicts_column)
          columns << conflicts
          values << ""
        end
        if contents_column?
          columns << "Contents"
          values << stored_bytes
        end
        placeholders = (["?"] * columns.length).join(", ")
        @db.execute(
          "INSERT INTO Unit (#{columns.join(', ')}) VALUES (#{placeholders})",
          values
        )
        write_v2_unit(uuid, bson_bytes) if @format_version == :v2
        uuid
      end

      # Update an existing unit's contents. Recalculates ContentsHash automatically.
      def update_unit(uuid, contents_doc)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        blob       = BsonCodec.uuid_to_blob(uuid)
        bson_bytes = BsonCodec.serialize(contents_doc)
        hash       = BsonCodec.contents_hash(bson_bytes)

        if contents_column?
          @db.execute(
            "UPDATE Unit SET Contents = ?, ContentsHash = ? WHERE UnitID = ?",
            [@format_version == :v2 ? nil : bson_bytes, hash, blob]
          )
        else
          @db.execute(
            "UPDATE Unit SET ContentsHash = ? WHERE UnitID = ?",
            [hash, blob]
          )
        end
        write_v2_unit(uuid, bson_bytes) if @format_version == :v2
      end

      def delete_unit(uuid)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly
        @db.execute("DELETE FROM Unit WHERE UnitID = ?", [BsonCodec.uuid_to_blob(uuid)])
        FileUtils.rm_f(MxunitCodec.path_for(contents_dir, uuid)) if @format_version == :v2
      end

      def relocate_unit(uuid, container_uuid:, containment_name:)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        @db.execute(
          "UPDATE Unit SET ContainerID = ?, ContainmentName = ? WHERE UnitID = ?",
          [
            BsonCodec.uuid_to_blob(container_uuid),
            containment_name.to_s,
            BsonCodec.uuid_to_blob(uuid)
          ]
        )
      end

      def transaction(&)
        @db.transaction(&)
      end

      # ── Exploration helpers ───────────────────────────────────────────────

      def tables
        @db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").flatten
      end

      def table_info(name)
        @db.table_info(name)
      end

      def query(sql, *binds)
        @db.execute(sql, *binds)
      end

      # mxrb-only architecture metadata for concepts without a native Mendix
      # unit (ports/repositories) or bindings awaiting a concrete widget tree.
      def architecture_definition
        return nil unless tables.include?("_MxrbArchitecture")
        json = @db.get_first_value("SELECT Definition FROM _MxrbArchitecture WHERE ID = 1")
        json && JSON.parse(json, symbolize_names: true)
      end

      def write_architecture_definition(definition)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly
        @db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS _MxrbArchitecture (
            ID INTEGER PRIMARY KEY CHECK (ID = 1),
            Version INTEGER NOT NULL,
            Definition TEXT NOT NULL
          )
        SQL
        @db.execute(
          "INSERT OR REPLACE INTO _MxrbArchitecture (ID, Version, Definition) VALUES (1, 1, ?)",
          [JSON.generate(definition)]
        )
      end

      def close
        @db.close
      end

      private

      def open_db
        mode = @readonly ? SQLite3::Constants::Open::READONLY : SQLite3::Constants::Open::READWRITE
        SQLite3::Database.new(@path, { flags: mode })
      rescue SQLite3::CantOpenException => e
        raise NotMprError, "Cannot open #{@path}: #{e.message}"
      end

      def validate!
        magic = File.binread(@path, 16) rescue nil
        raise NotMprError, "#{@path}: not a valid SQLite file" unless magic&.start_with?("SQLite format 3")
        raise NotMprError, "#{@path}: Unit table missing — not a valid .mpr file" unless tables.include?("Unit")
      end

      # MPR v2 stores unit contents in mprcontents/ folder next to the .mpr.
      def detect_format
        File.directory?(contents_dir) ? :v2 : :v1
      end

      def contents_dir
        File.join(File.dirname(@path), "mprcontents")
      end

      def unit_columns
        @unit_columns ||= table_info("Unit").map { _1["name"] || _1[:name] }
      end

      def contents_column?
        unit_columns.include?("Contents")
      end

      def conflicts_column
        return "ContentsConflicts" if unit_columns.include?("ContentsConflicts")
        return "ContentsConflict" if unit_columns.include?("ContentsConflict")

        nil
      end

      def unit_select_columns
        contents = contents_column? ? "Contents" : "NULL AS Contents"
        "UnitID, ContainerID, ContainmentName, ContentsHash, #{contents}"
      end

      def write_v2_unit(uuid, bytes)
        MxunitCodec.write_atomic(MxunitCodec.path_for(contents_dir, uuid), bytes)
      end

      def raw_to_hash(row)
        keys = %w[UnitID ContainerID ContainmentName ContentsHash Contents]
        h    = keys.zip(row).to_h
        # Convert blob UUIDs to strings for ergonomics
        h["UnitID"]      = BsonCodec.blob_to_uuid(h["UnitID"])      if h["UnitID"]
        h["ContainerID"] = BsonCodec.blob_to_uuid(h["ContainerID"]) if h["ContainerID"]
        h
      end
    end
  end
end
