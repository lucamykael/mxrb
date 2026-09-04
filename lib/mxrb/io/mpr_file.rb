# frozen_string_literal: true

require "sqlite3"
require "securerandom"
require "json"
require "fileutils"
require_relative "bson_codec"
require_relative "mxunit_codec"
require_relative "../studio_compatibility"

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

      def initialize(path, readonly: false, apply_studio_compatibility: true)
        @path = File.expand_path(path)
        @readonly = readonly
        @apply_studio_compatibility = apply_studio_compatibility
        @db = open_db
        @write_stats = { inserted: 0, updated: 0, skipped: 0, deleted: 0 }
        @v2_transaction = nil
        validate!
        recover_interrupted_v2_transaction!
        @format_version = detect_format
      end

      def self.open(path, readonly: false, apply_studio_compatibility: true)
        new(path, readonly:, apply_studio_compatibility:)
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
        schema_hash = StudioCompatibility.new(version_str).schema_hash
        # Try new-style column first, fall back to old-style
        begin
          @db.execute(
            "UPDATE _MetaData SET _ProductVersion = ?, _BuildVersion = ?, _SchemaHash = ?",
            [version_str, version_str, schema_hash]
          )
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
          staged, bytes = staged_v2_content(raw_unit.fetch("UnitID"))
          return bytes ? BsonCodec.parse(bytes) : {} if staged

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
          staged, bytes = staged_v2_content(raw_unit.fetch("UnitID"))
          return bytes if staged

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

      # Studio Pro 11 requires both the transaction marker table and a
      # filename sidecar for externally stored v2 unit contents.
      def ensure_v2_contract!
        return self unless @format_version == :v2
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        @db.execute('CREATE TABLE IF NOT EXISTS _Transaction (LastTransactionID TEXT)')
        if @db.get_first_value('SELECT LastTransactionID FROM _Transaction LIMIT 1').to_s.empty?
          @db.execute('INSERT INTO _Transaction (LastTransactionID) VALUES (?)', [SecureRandom.uuid])
        end
        write_mpr_name!
        self
      end

      # Studio Pro 11 requires split v2 storage, while Studio Pro 9 only
      # understands monolithic v1 storage.
      def ensure_storage_for_version!(version)
        major = version.to_s.split('.').first.to_i
        target = if major >= 11
                   :v2
                 elsif major <= 9
                   :v1
                 else
                   @format_version
                 end
        migrate_storage_format!(target)
      end

      def migrate_storage_format!(target)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        requested = target.to_sym
        raise ArgumentError, "storage format must be v1 or v2" unless %i[v1 v2].include?(requested)
        return self if requested == @format_version

        units = storage_migration_units
        requested == :v2 ? migrate_units_to_v2!(units) : migrate_units_to_v1!(units)
        @unit_columns = nil
        @format_version = requested
        ensure_v2_contract! if requested == :v2
        self
      end

      # ── Writes ────────────────────────────────────────────────────────────

      # Insert a new unit. Returns the assigned UUID.
      def insert_unit(container_uuid:, containment_name:, contents_doc:, unit_uuid: nil)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        contents_doc = compatible_document(contents_doc)
        uuid = unit_uuid || BsonCodec.extract_id(contents_doc["$ID"] || contents_doc["\$ID"]) || SecureRandom.uuid
        unless contents_doc.key?("$ID") || contents_doc.key?("\$ID")
          contents_doc = { "$ID" => uuid }.merge(contents_doc)
        end
        unit_blob    = BsonCodec.uuid_to_blob(uuid)
        parent_blob  = BsonCodec.uuid_to_blob(container_uuid)
        bson_bytes   = serialize_contents(contents_doc)
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

        contents_doc = compatible_document(contents_doc)
        blob       = BsonCodec.uuid_to_blob(uuid)
        bson_bytes = serialize_contents(contents_doc)
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

      # Projects every unit only after higher-level writers have completed
      # integrity checks against the source schema (notably page overlays).
      def apply_studio_compatibility!
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        previous = @apply_studio_compatibility
        begin
          @apply_studio_compatibility = true
          all_units.each do |raw_unit|
            update_unit(raw_unit.fetch('UnitID'), parse_contents(raw_unit))
          end
          self
        ensure
          @apply_studio_compatibility = previous
        end
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
        removed = delete_v2_unit(uuid) if @format_version == :v2
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

      def transaction(&block)
        return @db.transaction(&block) unless @format_version == :v2
        raise ValidationError, 'nested MPR v2 transactions are not supported' if @v2_transaction

        with_v2_transaction(&block)
      end

      # Creates a consistent point-in-time backup using SQLite's VACUUM INTO.
      # Falls back to a WAL checkpoint + file copy on older SQLite versions.
      def backup!(dest_path)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        cleanup_backup!(dest_path)
        begin
          begin
            @db.execute("VACUUM INTO ?", [dest_path])
          rescue SQLite3::Exception
            @db.execute("PRAGMA wal_checkpoint(FULL)") rescue nil
            FileUtils.cp(@path, dest_path)
          end
          backup_v2_contents!(dest_path) if @format_version == :v2
        rescue StandardError
          cleanup_backup!(dest_path)
          raise
        end
      end

      # Restores the database from a backup file, replacing the current contents.
      # Closes and reopens the underlying SQLite connection.
      def restore_from!(backup_path)
        raise ReadOnlyError, "Opened in read-only mode" if @readonly

        needs_snapshot = preflight_backup!(backup_path)
        @db.close
        FileUtils.cp(backup_path, @path)
        @db             = open_db
        @mendix_version = nil
        if needs_snapshot
          FileUtils.mkdir_p(contents_dir)
          restore_v2_contents!(backup_path)
        end
        @format_version = detect_format
      end

      # Removes all artifacts created by backup! for the supplied destination.
      def cleanup_backup!(dest_path)
        FileUtils.rm_f(dest_path)
        FileUtils.rm_rf(backup_contents_dir(dest_path))
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

      def storage_migration_units
        conflict = conflicts_column || "''"
        contents = contents_column? ? 'Contents' : 'NULL'
        @db.execute(<<~SQL).map do |row|
          SELECT UnitID, ContainerID, ContainmentName, TreeConflict,
                 ContentsHash, #{conflict}, #{contents}
          FROM Unit
        SQL
          uuid = BsonCodec.blob_to_uuid(row[0])
          bytes = row[6] || content_bytes('UnitID' => uuid, 'Contents' => nil)
          [*row.first(6), bytes]
        end
      end

      def migrate_units_to_v2!(units)
        stage = "#{contents_dir}.mxrb-convert-#{Process.pid}"
        FileUtils.rm_rf(stage)
        units.each do |row|
          uuid = BsonCodec.blob_to_uuid(row[0])
          MxunitCodec.write_atomic(MxunitCodec.path_for(stage, uuid), row[6])
        end
        rebuild_storage_tables!(:v2, units)
        FileUtils.rm_rf(contents_dir)
        FileUtils.mv(stage, contents_dir)
      ensure
        FileUtils.rm_rf(stage) if defined?(stage) && stage && File.directory?(stage)
      end

      def migrate_units_to_v1!(units)
        rebuild_storage_tables!(:v1, units)
        FileUtils.rm_rf(contents_dir)
      end

      def rebuild_storage_tables!(format, units)
        version = mendix_version
        schema_hash = StudioCompatibility.new(version).schema_hash
        @db.transaction do
          @db.execute('DROP TABLE IF EXISTS Unit_MxrbStorageMigration')
          @db.execute(storage_unit_table_sql(format))
          insert_storage_units!(format, units)
          @db.execute('DROP TABLE Unit')
          @db.execute('ALTER TABLE Unit_MxrbStorageMigration RENAME TO Unit')
          rebuild_storage_metadata!(format, version, schema_hash)
        end
      end

      def storage_unit_table_sql(format)
        contents = format == :v1 ? ', Contents BLOB' : ''
        <<~SQL
          CREATE TABLE Unit_MxrbStorageMigration (
            UnitID BLOB PRIMARY KEY NOT NULL, ContainerID BLOB,
            ContainmentName TEXT, TreeConflict LONG,
            ContentsHash TEXT, ContentsConflicts TEXT#{contents}
          )
        SQL
      end

      def insert_storage_units!(format, units)
        count = format == :v1 ? 7 : 6
        placeholders = (['?'] * count).join(', ')
        units.each do |row|
          values = format == :v1 ? row : row.first(6)
          @db.execute("INSERT INTO Unit_MxrbStorageMigration VALUES (#{placeholders})", values)
        end
      end

      def rebuild_storage_metadata!(format, version, schema_hash)
        @db.execute('DROP TABLE IF EXISTS _MetaData_MxrbStorageMigration')
        prefix = format == :v2 ? '_FormatVersion INTEGER, ' : ''
        @db.execute(<<~SQL)
          CREATE TABLE _MetaData_MxrbStorageMigration (
            #{prefix}_ProductVersion TEXT, _BuildVersion TEXT, _SchemaHash TEXT
          )
        SQL
        values = format == :v2 ? [2, version, version, schema_hash] : [version, version, schema_hash]
        placeholders = (['?'] * values.size).join(', ')
        @db.execute("INSERT INTO _MetaData_MxrbStorageMigration VALUES (#{placeholders})", values)
        @db.execute('DROP TABLE _MetaData')
        @db.execute('ALTER TABLE _MetaData_MxrbStorageMigration RENAME TO _MetaData')
      end

      # Studio Pro 11 serializes integer-valued model properties as BSON
      # int64 while retaining the Mendix array marker as BSON int32.
      def serialize_contents(document)
        BsonCodec.serialize(document, int64_properties: mendix_version == '11.12.1')
      end

      def compatible_document(document)
        return document unless @apply_studio_compatibility

        StudioCompatibility.new(mendix_version).apply_document!(document)
      end

      def write_mpr_name!
        target = File.join(contents_dir, 'mprname')
        expected = File.basename(@path)
        return if File.file?(target) && File.binread(target) == expected

        FileUtils.mkdir_p(contents_dir)
        temporary = "#{target}.mxrb-#{Process.pid}"
        File.binwrite(temporary, expected)
        FileUtils.mv(temporary, target)
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary) && temporary
      end

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

      def preflight_backup!(backup_path)
        magic = File.binread(backup_path, 16) if File.file?(backup_path)
        raise NotMprError, "#{backup_path}: not a valid SQLite file" \
          unless magic&.start_with?("SQLite format 3")

        backup_db = SQLite3::Database.new(
          backup_path,
          flags: SQLite3::Constants::Open::READONLY
        )
        unit_table = backup_db.get_first_value(
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'Unit'"
        )
        raise NotMprError, "#{backup_path}: Unit table missing — not a valid .mpr file" \
          unless unit_table

        contents_column = backup_db.execute("PRAGMA table_info(Unit)").any? { _1[1] == "Contents" }
        snapshot_dir = backup_contents_dir(backup_path)
        needs_snapshot = !contents_column || File.directory?(snapshot_dir)
        if needs_snapshot && !File.directory?(snapshot_dir)
          raise IncompletePackageError,
                "#{backup_path}: v2 MPR backup is missing contents snapshot #{snapshot_dir}"
        end

        needs_snapshot
      ensure
        backup_db&.close
      end

      # MPR v2 stores unit contents in mprcontents/ folder next to the .mpr.
      def detect_format
        unless contents_column?
          unless File.directory?(contents_dir)
            raise IncompletePackageError,
                  "#{@path}: MPR schema stores unit contents externally but sibling " \
                  "directory #{contents_dir} is missing"
          end

          return :v2
        end

        File.directory?(contents_dir) ? :v2 : :v1
      end

      def contents_dir
        File.join(File.dirname(@path), "mprcontents")
      end

      def backup_contents_dir(path)
        "#{path}.mprcontents"
      end

      def backup_v2_contents!(dest_path)
        snapshot_dir = backup_contents_dir(dest_path)
        FileUtils.rm_rf(snapshot_dir)
        FileUtils.cp_r(contents_dir, snapshot_dir)
      end

      def restore_v2_contents!(backup_path)
        snapshot_dir = backup_contents_dir(backup_path)
        unless File.directory?(snapshot_dir)
          raise IncompletePackageError,
                "#{backup_path}: v2 MPR backup is missing contents snapshot #{snapshot_dir}"
        end

        snapshot_files = relative_mxunit_paths(snapshot_dir)
        live_files = relative_mxunit_paths(contents_dir)
        snapshot_files.each do |relative_path|
          destination = File.join(contents_dir, relative_path)
          FileUtils.mkdir_p(File.dirname(destination))
          FileUtils.cp(File.join(snapshot_dir, relative_path), destination)
        end
        (live_files - snapshot_files).each do |relative_path|
          FileUtils.rm_f(File.join(contents_dir, relative_path))
        end
      end

      def relative_mxunit_paths(directory)
        prefix_length = directory.length + 1
        Dir.glob(File.join(directory, "**", "*.mxunit")).sort.map do |path|
          path[prefix_length..]
        end
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

      def with_v2_transaction(&block)
        @v2_transaction = {
          writes: {}, deletes: {}, applied: [], journal_dir: nil,
          write_stats: write_stats.dup, id: SecureRandom.uuid
        }
        committed = false
        result = @db.transaction do
          value = block.call
          apply_v2_transaction!
          value
        end
        committed = true
        cleanup_v2_transaction!
        clear_v2_transaction_marker!(@v2_transaction.fetch(:id))
        result
      rescue StandardError
        rollback_v2_transaction! unless committed
        @write_stats = @v2_transaction.fetch(:write_stats) if @v2_transaction && !committed
        raise
      ensure
        cleanup_v2_transaction!
        @v2_transaction = nil
      end

      def write_v2_unit(uuid, bytes)
        if @v2_transaction
          @v2_transaction.fetch(:writes)[uuid.to_s] = bytes
          @v2_transaction.fetch(:deletes).delete(uuid.to_s)
        else
          MxunitCodec.write_atomic(MxunitCodec.path_for(contents_dir, uuid), bytes)
        end
      end

      def delete_v2_unit(uuid)
        path = MxunitCodec.path_for(contents_dir, uuid)
        return FileUtils.rm_f(path) unless @v2_transaction

        key = uuid.to_s
        existed = File.file?(path) || @v2_transaction.fetch(:writes).key?(key)
        @v2_transaction.fetch(:writes).delete(key)
        @v2_transaction.fetch(:deletes)[key] = true
        existed ? [path] : []
      end

      def staged_v2_content(uuid)
        return [false, nil] unless @v2_transaction

        key = uuid.to_s
        writes = @v2_transaction.fetch(:writes)
        return [true, writes.fetch(key)] if writes.key?(key)
        return [true, nil] if @v2_transaction.fetch(:deletes).key?(key)

        [false, nil]
      end

      def apply_v2_transaction!
        state = @v2_transaction
        identifiers = (state.fetch(:writes).keys + state.fetch(:deletes).keys).uniq.sort
        return if identifiers.empty?

        state[:journal_dir] = transaction_journal_dir
        if File.exist?(state.fetch(:journal_dir))
          raise IncompletePackageError,
                "stale MPR transaction journal exists: #{state.fetch(:journal_dir)}"
        end
        write_v2_transaction_manifest!(state, identifiers)
        register_v2_transaction_marker!(state.fetch(:id))
        identifiers.each do |uuid|
          apply_v2_transaction_unit!(state, uuid)
        end
      end

      def apply_v2_transaction_unit!(state, uuid)
        path = MxunitCodec.path_for(contents_dir, uuid)
        relative = path.delete_prefix("#{contents_dir}/")
        backup = File.join(state.fetch(:journal_dir), 'original', relative)
        entry = { path:, backup:, existed: File.file?(path) }
        state.fetch(:applied) << entry
        if entry.fetch(:existed)
          FileUtils.mkdir_p(File.dirname(backup))
          File.rename(path, backup)
        end
        bytes = state.fetch(:writes)[uuid]
        MxunitCodec.write_atomic(path, bytes) if bytes
      end

      def rollback_v2_transaction!
        return unless @v2_transaction

        @v2_transaction.fetch(:applied).reverse_each do |entry|
          FileUtils.rm_f(entry.fetch(:path))
          next unless entry.fetch(:existed) && File.file?(entry.fetch(:backup))

          FileUtils.mkdir_p(File.dirname(entry.fetch(:path)))
          File.rename(entry.fetch(:backup), entry.fetch(:path))
        end
      end

      def cleanup_v2_transaction!
        journal_dir = @v2_transaction&.fetch(:journal_dir, nil)
        FileUtils.rm_rf(journal_dir) if journal_dir
      end

      def transaction_journal_dir
        "#{@path}.mxrb-transaction"
      end

      def transaction_manifest_path
        File.join(transaction_journal_dir, 'journal.json')
      end

      def write_v2_transaction_manifest!(state, identifiers)
        entries = identifiers.map do |uuid|
          path = MxunitCodec.path_for(contents_dir, uuid)
          {
            'uuid' => uuid, 'relative_path' => path.delete_prefix("#{contents_dir}/"),
            'existed' => File.file?(path),
            'action' => state.fetch(:writes).key?(uuid) ? 'write' : 'delete'
          }
        end
        FileUtils.mkdir_p(transaction_journal_dir)
        write_atomic_file(
          transaction_manifest_path,
          JSON.generate('version' => 1, 'id' => state.fetch(:id), 'entries' => entries)
        )
      end

      def register_v2_transaction_marker!(id)
        @db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS _MxrbFileTransaction (
            ID TEXT PRIMARY KEY NOT NULL
          )
        SQL
        @db.execute('INSERT INTO _MxrbFileTransaction (ID) VALUES (?)', [id])
      end

      def clear_v2_transaction_marker!(id)
        return unless tables.include?('_MxrbFileTransaction')

        @db.execute('DELETE FROM _MxrbFileTransaction WHERE ID = ?', [id])
        @db.execute('DROP TABLE _MxrbFileTransaction') if
          @db.get_first_value('SELECT COUNT(*) FROM _MxrbFileTransaction').to_i.zero?
      rescue SQLite3::Exception
        nil
      end

      def recover_interrupted_v2_transaction!
        return unless File.directory?(transaction_journal_dir)
        if @readonly
          raise IncompletePackageError,
                "MPR has an interrupted file transaction; open writable to recover: " \
                "#{transaction_journal_dir}"
        end

        manifest = JSON.parse(File.read(transaction_manifest_path))
        id = manifest.fetch('id')
        committed = tables.include?('_MxrbFileTransaction') &&
                    @db.get_first_value(
                      'SELECT 1 FROM _MxrbFileTransaction WHERE ID = ?', [id]
                    ) == 1
        restore_interrupted_v2_files!(manifest.fetch('entries')) unless committed
        FileUtils.rm_rf(transaction_journal_dir)
        clear_v2_transaction_marker!(id)
      rescue JSON::ParserError, KeyError => e
        raise IncompletePackageError,
              "invalid MPR transaction journal #{transaction_manifest_path}: #{e.message}"
      end

      def restore_interrupted_v2_files!(entries)
        entries.reverse_each do |entry|
          path = File.join(contents_dir, entry.fetch('relative_path'))
          backup = File.join(transaction_journal_dir, 'original', entry.fetch('relative_path'))
          if entry.fetch('existed') && File.file?(backup)
            FileUtils.rm_f(path)
            FileUtils.mkdir_p(File.dirname(path))
            File.rename(backup, path)
          elsif !entry.fetch('existed')
            FileUtils.rm_f(path)
          end
        end
      end

      def write_atomic_file(path, bytes)
        temporary = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
        File.binwrite(temporary, bytes)
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary) if temporary
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
