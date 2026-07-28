# frozen_string_literal: true

require "sqlite3"
require "securerandom"
require_relative "bson_codec"

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
          return nil unless root && root["Contents"]

          doc = BsonCodec.parse(root["Contents"])
          doc["Name"] || doc["name"] || File.basename(@path, ".mpr")
        end
      end

      # ── Unit access ───────────────────────────────────────────────────────

      # The root Unit is the one where UnitID == ContainerID.
      def root_unit
        @root_unit ||= begin
          row = @db.get_first_row(
            "SELECT UnitID, ContainerID, ContainmentName, ContentsHash, Contents FROM Unit " \
            "WHERE UnitID = ContainerID LIMIT 1"
          )
          row ? raw_to_hash(row) : nil
        end
      end

      # All units with a given ContainmentName.
      def units_by_containment(name)
        @db.execute(
          "SELECT UnitID, ContainerID, ContainmentName, ContentsHash, Contents FROM Unit " \
          "WHERE ContainmentName = ?",
          [name]
        ).map { raw_to_hash(_1) }
      end

      # Units directly contained by a given parent UUID.
      def children_of(parent_uuid)
        blob = BsonCodec.uuid_to_blob(parent_uuid)
        @db.execute(
          "SELECT UnitID, ContainerID, ContainmentName, ContentsHash, Contents FROM Unit " \
          "WHERE ContainerID = ? AND UnitID != ContainerID",
          [blob]
        ).map { raw_to_hash(_1) }
      end

      # Single unit by UUID string.
      def unit(uuid)
        blob = BsonCodec.uuid_to_blob(uuid)
        row  = @db.get_first_row(
          "SELECT UnitID, ContainerID, ContainmentName, ContentsHash, Contents FROM Unit WHERE UnitID = ?",
          [blob]
        )
        row ? raw_to_hash(row) : nil
      end

      # All units (for exploration / reverse engineering).
      def all_units
        @db.execute(
          "SELECT UnitID, ContainerID, ContainmentName, ContentsHash, Contents FROM Unit"
        ).map { raw_to_hash(_1) }
      end

      # Parse BSON from a raw unit hash.
      def parse_contents(raw_unit)
        blob = raw_unit["Contents"]
        return {} if blob.nil? || blob.empty?

        BsonCodec.parse(blob)
      end

      # ── Writes ────────────────────────────────────────────────────────────

      # Insert a new unit. Returns the assigned UUID.
      def insert_unit(container_uuid:, containment_name:, contents_doc:)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        uuid         = SecureRandom.uuid
        unit_blob    = BsonCodec.uuid_to_blob(uuid)
        parent_blob  = BsonCodec.uuid_to_blob(container_uuid)
        bson_bytes   = BsonCodec.serialize(contents_doc)
        hash         = BsonCodec.contents_hash(bson_bytes)

        @db.execute(
          "INSERT INTO Unit (UnitID, ContainerID, ContainmentName, ContentsHash, Contents) " \
          "VALUES (?, ?, ?, ?, ?)",
          [unit_blob, parent_blob, containment_name, hash, bson_bytes]
        )
        uuid
      end

      # Update an existing unit's contents. Recalculates ContentsHash automatically.
      def update_unit(uuid, contents_doc)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        blob       = BsonCodec.uuid_to_blob(uuid)
        bson_bytes = BsonCodec.serialize(contents_doc)
        hash       = BsonCodec.contents_hash(bson_bytes)

        @db.execute(
          "UPDATE Unit SET Contents = ?, ContentsHash = ? WHERE UnitID = ?",
          [bson_bytes, hash, blob]
        )
      end

      def delete_unit(uuid)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly
        @db.execute("DELETE FROM Unit WHERE UnitID = ?", [BsonCodec.uuid_to_blob(uuid)])
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
        dir = File.join(File.dirname(@path), "mprcontents")
        File.directory?(dir) ? :v2 : :v1
      end

      def raw_to_hash(row)
        keys = %w[UnitID ContainerID ContainmentName ContentsHash Contents]
        h    = keys.zip(row).to_h
        # Convert blob UUIDs to strings for ergonomics
        h["UnitID"]      = BsonCodec.blob_to_uuid(h["UnitID"])      if h["UnitID"].is_a?(String)
        h["ContainerID"] = BsonCodec.blob_to_uuid(h["ContainerID"]) if h["ContainerID"].is_a?(String)
        h
      end
    end
  end
end
