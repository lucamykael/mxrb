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

      def write_stats
        @write_stats ||= { inserted: 0, updated: 0, skipped: 0, deleted: 0 }
      end

      def readonly? = @readonly

      def initialize(path, readonly: false)
        @path     = File.expand_path(path)
        @readonly = readonly
        @db       = open_db
        @write_stats = { inserted: 0, updated: 0, skipped: 0, deleted: 0 }
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

      def update_version!(version)
        version_str = version.to_s
        # Try new-style column first, fall back to old-style
        begin
          @db.execute("UPDATE _MetaData SET _ProductVersion = ?, _BuildVersion = ?",
                      [version_str, version_str])
        rescue SQLite3::Exception
          @db.execute("UPDATE _MetaData SET MendixVersion = ?", [version_str])
        end
        @mendix_version = version_str
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
      def insert_unit(container_uuid:, containment_name:, contents_doc:, unit_uuid: nil)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        uuid = unit_uuid || BsonCodec.extract_id(contents_doc["$ID"] || contents_doc["\$ID"]) || SecureRandom.uuid
        unless contents_doc.key?("$ID") || contents_doc.key?("\$ID")
          contents_doc = { "$ID" => uuid }.merge(contents_doc)
        end
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
        write_stats[:inserted] += 1
        uuid
      end

      # Update an existing unit's contents. Recalculates ContentsHash automatically.
      def update_unit(uuid, contents_doc)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        blob       = BsonCodec.uuid_to_blob(uuid)
        bson_bytes = BsonCodec.serialize(contents_doc)
        hash       = BsonCodec.contents_hash(bson_bytes)
        current = unit(uuid)
        if current && current['ContentsHash'] == hash
          write_stats[:skipped] += 1
          return false
        end

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
        write_stats[:updated] += 1
        true
      end

      # Repairs stale Unit.ContentsHash metadata without reserializing or
      # otherwise changing the BSON/mxunit payload. Returns an audit trail.
      def repair_content_hashes!
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        repairs = []
        transaction do
          all_units.each do |unit|
            bytes = content_bytes(unit)
            next if bytes.to_s.empty?

            previous = unit['ContentsHash'].to_s
            current = BsonCodec.contents_hash(bytes)
            next if previous == current

            @db.execute(
              'UPDATE Unit SET ContentsHash = ? WHERE UnitID = ?',
              [current, BsonCodec.uuid_to_blob(unit.fetch('UnitID'))]
            )
            repairs << { unit_id: unit.fetch('UnitID'), previous:, current: }
          end
        end
        repairs
      end

      def delete_unit(uuid)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly
        @db.execute("DELETE FROM Unit WHERE UnitID = ?", [BsonCodec.uuid_to_blob(uuid)])
        removed = FileUtils.rm_f(MxunitCodec.path_for(contents_dir, uuid)) if @format_version == :v2
        write_stats[:deleted] += 1
        removed
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

      # Creates a consistent point-in-time backup using SQLite's VACUUM INTO.
      # Falls back to a WAL checkpoint + file copy on older SQLite versions.
      def backup!(dest_path)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        FileUtils.rm_f(dest_path)
        @db.execute("VACUUM INTO ?", [dest_path])
      rescue SQLite3::Exception
        @db.execute("PRAGMA wal_checkpoint(FULL)") rescue nil
        FileUtils.cp(@path, dest_path)
      end

      # Restores the database from a backup file, replacing the current contents.
      # Closes and reopens the underlying SQLite connection.
      def restore_from!(backup_path)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        @db.close
        FileUtils.cp(backup_path, @path)
        @db             = open_db
        @mendix_version = nil
        @format_version = detect_format
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

      # ── Semantic index cache ──────────────────────────────────────────────────

      # Returns the cached index JSON if the fingerprint matches, nil otherwise.
      def read_index_cache(fingerprint)
        return nil unless tables.include?("_MxrbIndexCache")

        @db.get_first_value(
          "SELECT IndexData FROM _MxrbIndexCache WHERE Fingerprint = ?", [fingerprint]
        )
      rescue SQLite3::Exception
        nil
      end

      # Persists the index JSON keyed by fingerprint. No-op when read-only or on error.
      def write_index_cache(fingerprint, json)
        return if @readonly || json.nil?

        @db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS _MxrbIndexCache (
            Fingerprint TEXT PRIMARY KEY,
            IndexData   TEXT NOT NULL
          )
        SQL
        @db.execute(
          "INSERT INTO _MxrbIndexCache (Fingerprint, IndexData) VALUES (?, ?) " \
          "ON CONFLICT(Fingerprint) DO UPDATE SET IndexData = excluded.IndexData",
          [fingerprint, json]
        )
        @db.execute(
          "DELETE FROM _MxrbIndexCache WHERE Fingerprint <> ?", [fingerprint]
        )
      rescue SQLite3::Exception
        nil
      end

      # Returns cache size and fingerprints without parsing the cached payload.
      def index_cache_info(current_fingerprint: nil)
        unless tables.include?("_MxrbIndexCache")
          return {
            present: false, entries: 0, bytes: 0,
            fingerprints: [].freeze, current_fingerprint:,
            hit: false
          }.freeze
        end

        rows = @db.execute(
          "SELECT Fingerprint, LENGTH(IndexData) FROM _MxrbIndexCache ORDER BY Fingerprint"
        )
        fingerprints = rows.map { _1[0].to_s }.freeze
        {
          present: !rows.empty?,
          entries: rows.size,
          bytes: rows.sum { _1[1].to_i },
          fingerprints:,
          current_fingerprint:,
          hit: current_fingerprint && fingerprints.include?(current_fingerprint)
        }.freeze
      rescue SQLite3::Exception
        {
          present: false, entries: 0, bytes: 0,
          fingerprints: [].freeze, current_fingerprint:,
          hit: false
        }.freeze
      end

      # Clears cached semantic data while preserving the cache table.
      def clear_index_cache!
        raise ReadOnlyError, "Opened in read-only mode" if @readonly
        return 0 unless tables.include?("_MxrbIndexCache")

        count = @db.get_first_value("SELECT COUNT(*) FROM _MxrbIndexCache").to_i
        @db.execute("DELETE FROM _MxrbIndexCache")
        count
      end

      # ── Vector index (sqlite-vec) ─────────────────────────────────────────────

      # Loads the optional sqlite-vec extension into the active connection.
      def load_vec_extension!
        return true if @vec_loaded

        require "sqlite_vec"
        @db.enable_load_extension(true)
        begin
          SqliteVec.load(@db)
        ensure
          @db.enable_load_extension(false)
        end
        @vec_loaded = true
      end

      def ensure_vec_table!(table, dimension)
        ensure_vector_write!
        identifier = vector_identifier(table)
        size = Integer(dimension)
        raise ArgumentError, "vector dimension must be positive" unless size.positive?

        @db.execute(<<~SQL)
          CREATE VIRTUAL TABLE IF NOT EXISTS #{identifier}
          USING vec0(artifact_id TEXT PRIMARY KEY, embedding FLOAT[#{size}])
        SQL
      end

      def ensure_vec_meta_table!(table)
        ensure_vector_write!
        identifier = vector_identifier(table)
        @db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{identifier} (
            ID INTEGER PRIMARY KEY CHECK (ID = 1),
            Backend TEXT NOT NULL,
            Dimension INTEGER NOT NULL,
            Fingerprint TEXT NOT NULL
          )
        SQL
      end

      def write_vec_meta!(table, backend, dimension, fingerprint)
        ensure_vector_write!
        identifier = vector_identifier(table)
        @db.execute(
          "INSERT OR REPLACE INTO #{identifier} " \
          "(ID, Backend, Dimension, Fingerprint) VALUES (1, ?, ?, ?)",
          [backend, dimension, fingerprint]
        )
      end

      def vec_meta(table)
        name = table.to_s
        return nil unless tables.include?(name)

        identifier = vector_identifier(name)
        row = @db.get_first_row(
          "SELECT Backend, Dimension, Fingerprint FROM #{identifier} WHERE ID = 1"
        )
        return nil unless row

        { backend: row[0], dimension: row[1], fingerprint: row[2] }
      rescue SQLite3::Exception
        nil
      end

      def vec_upsert(table, artifact_id, json_vec)
        ensure_vector_write!
        identifier = vector_identifier(table)
        @db.execute(
          "INSERT INTO #{identifier}(artifact_id, embedding) VALUES (?, ?)",
          [artifact_id, json_vec]
        )
      end

      def vec_knn(table, json_vec, limit)
        identifier = vector_identifier(table)
        @db.execute(
          "SELECT artifact_id, distance FROM #{identifier} " \
          "WHERE embedding MATCH ? ORDER BY distance LIMIT ?",
          [json_vec, Integer(limit)]
        ).map { { id: _1[0], distance: _1[1] } }
      end

      def vec_transaction(&)
        ensure_vector_write!
        @db.transaction(&)
      end

      def vec_drop_index!(vec_table, meta_table)
        ensure_vector_write!
        @db.execute("DROP TABLE IF EXISTS #{vector_identifier(vec_table)}")
        @db.execute("DROP TABLE IF EXISTS #{vector_identifier(meta_table)}")
      end

      # ── Architecture metadata ─────────────────────────────────────────────────

      # mxrb-only architecture metadata for concepts without a native Mendix
      # unit (ports/repositories) or bindings awaiting a concrete widget tree.
      def architecture_definition
        return nil unless tables.include?("_MxrbArchitecture")
        json = @db.get_first_value("SELECT Definition FROM _MxrbArchitecture WHERE ID = 1")
        json && BsonCodec.restore_extended_json(JSON.parse(json, symbolize_names: true))
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

      # Ruby/React sources are stored outside the Mendix Unit tree. Mendix can
      # keep editing the native model while MXRB can later restore the exact
      # conventional application sources on a Ruby-mode export.
      def ruby_app_sources
        return [] unless tables.include?("_MxrbRubySource")

        has_mode = table_info("_MxrbRubySource").any? { (_1["name"] || _1[:name]) == "Mode" }
        columns = has_mode ? "Path, Contents, Sha256, Mode" : "Path, Contents, Sha256"
        @db.execute("SELECT #{columns} FROM _MxrbRubySource ORDER BY Path").map do |row|
          fallback = row[0].to_s.start_with?('bin/') ? 0o755 : 0o644
          { path: row[0], contents: row[1], sha256: row[2], mode: has_mode ? row[3] : fallback }
        end
      end

      def write_ruby_app_sources(files)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        @db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS _MxrbRubySource (
            Path TEXT PRIMARY KEY NOT NULL,
            Contents BLOB NOT NULL,
            Sha256 TEXT NOT NULL,
            Mode INTEGER NOT NULL DEFAULT 420
          )
        SQL
        unless table_info("_MxrbRubySource").any? { (_1["name"] || _1[:name]) == "Mode" }
          @db.execute("ALTER TABLE _MxrbRubySource ADD COLUMN Mode INTEGER NOT NULL DEFAULT 420")
        end
        @db.execute("DELETE FROM _MxrbRubySource")
        files.each do |file|
          @db.execute(
            "INSERT INTO _MxrbRubySource (Path, Contents, Sha256, Mode) VALUES (?, ?, ?, ?)",
            [
              file.fetch(:path), SQLite3::Blob.new(file.fetch(:contents)),
              file.fetch(:sha256), file.fetch(:mode, 0o644)
            ]
          )
        end
      end

      # Cross-module Mendix associations do not expose native visual
      # connection fields. Keep their ER-editor anchors in an MXRB-only table
      # so the diagram remains editable without inventing unsupported BSON.
      def domain_diagram_anchors
        return {} unless tables.include?("_MxrbDomainDiagramAssociation")

        @db.execute(<<~SQL).to_h do |row|
          SELECT AssociationID, SourceAnchor, TargetAnchor
          FROM _MxrbDomainDiagramAssociation
        SQL
          [row[0], { source_anchor: row[1], target_anchor: row[2] }]
        end
      end

      def write_domain_diagram_anchors(layouts)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly
        items = Array(layouts)
        return 0 if items.empty?

        @db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS _MxrbDomainDiagramAssociation (
            AssociationID TEXT PRIMARY KEY NOT NULL,
            SourceAnchor TEXT NOT NULL,
            TargetAnchor TEXT NOT NULL
          )
        SQL
        current = domain_diagram_anchors
        items.count do |layout|
          id = layout.fetch(:id).to_s
          anchors = {
            source_anchor: layout.fetch(:source_anchor).to_s,
            target_anchor: layout.fetch(:target_anchor).to_s
          }
          next false if current[id] == anchors

          @db.execute(
            "INSERT OR REPLACE INTO _MxrbDomainDiagramAssociation " \
            "(AssociationID, SourceAnchor, TargetAnchor) VALUES (?, ?, ?)",
            [id, anchors.fetch(:source_anchor), anchors.fetch(:target_anchor)]
          )
          true
        end
      end

      def legacy_unit_identity_mismatches
        return [] unless tables.include?("_MxrbCompatibility")

        @db.execute(<<~SQL).map do |row|
          SELECT UnitID, ContentID, UnitType
          FROM _MxrbCompatibility
          WHERE Kind = 'legacy-unit-identity'
        SQL
          { unit_id: row[0], content_id: row[1], type: row[2] }
        end
      end

      def write_legacy_unit_identity_mismatches(mismatches)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        @db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS _MxrbCompatibility (
            Kind TEXT NOT NULL,
            UnitID TEXT NOT NULL,
            ContentID TEXT NOT NULL,
            UnitType TEXT NOT NULL,
            PRIMARY KEY (Kind, UnitID, ContentID)
          )
        SQL
        @db.execute("DELETE FROM _MxrbCompatibility WHERE Kind = 'legacy-unit-identity'")
        mismatches.each do |mismatch|
          @db.execute(
            "INSERT INTO _MxrbCompatibility (Kind, UnitID, ContentID, UnitType) VALUES (?, ?, ?, ?)",
            ["legacy-unit-identity", mismatch.fetch(:unit_id),
             mismatch.fetch(:content_id), mismatch.fetch(:type)]
          )
        end
      end

      def close
        @db.close
      end

      private

      def ensure_vector_write!
        raise ReadOnlyError, "Opened in read-only mode" if @readonly
      end

      def vector_identifier(value)
        name = value.to_s
        raise ArgumentError, "invalid vector table name: #{value.inspect}" \
          unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)

        name
      end

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
