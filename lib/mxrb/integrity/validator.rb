# frozen_string_literal: true

require "set"

module Mxrb
  module Integrity
    Result = Struct.new(:errors, :warnings, keyword_init: true) do
      def valid? = errors.empty?
    end

    class Validator
      def initialize(path)
        @path = path
        @progress = Progress::NullTask.instance
      end

      def validate
        Progress.with("Validating #{File.basename(@path)}") do |progress|
          @progress = progress
          @errors = []
          @warnings = []
          @mpr = IO::MprFile.open(@path, readonly: true)
          validate_tables
          progress.advance(detail: "MPR tables")
          validate_units
          validate_v2_files
          progress.advance(detail: "v2 contents")
          Result.new(errors: @errors, warnings: @warnings)
        end
      rescue Error => e
        Result.new(errors: [e.message], warnings: @warnings || [])
      ensure
        @progress = Progress::NullTask.instance
        @mpr&.close
      end

      private

      def validate_tables
        require_table("Unit")
        require_table("_MetaData")
        require_unit_column("UnitID")
        require_unit_column("ContainerID")
        require_unit_column("ContainmentName")
        require_unit_column("ContentsHash")
      end

      def validate_units
        @units = @mpr.all_units
        @legacy_identity_mismatches = @mpr.legacy_unit_identity_mismatches.to_set do |entry|
          [entry.fetch(:unit_id), entry.fetch(:content_id), entry.fetch(:type)]
        end
        @progress.update(total: @units.size + 3, detail: "#{@units.size} units")
        validate_root
        validate_unit_ids
        @progress.advance(detail: "unit tree")
        validate_contents
      end

      def validate_root
        roots = @units.select { _1["UnitID"] == _1["ContainerID"] }
        add_error("expected exactly one root unit, found #{roots.size}") unless roots.size == 1
      end

      def validate_unit_ids
        ids = @units.map { _1["UnitID"] }
        ids.each { add_error("blank UnitID") if _1.to_s.empty? }
        duplicates = ids.tally.select { |_id, count| count > 1 }.keys
        duplicates.each { add_error("duplicate UnitID #{_1}") }

        id_set = ids.to_set
        @units.each do |unit|
          parent = unit["ContainerID"]
          next if parent == unit["UnitID"]

          add_error("unit #{unit['UnitID']} references missing container #{parent}") unless id_set.include?(parent)
        end
      end

      def validate_contents
        @units.each do |unit|
          bytes = @mpr.content_bytes(unit)
          if bytes.nil? || bytes.empty?
            add_error("unit #{unit['UnitID']} has no content bytes")
            next
          end

          validate_hash(unit, bytes)
          doc = parse_unit(unit)
          next unless doc

          validate_doc_identity(unit, doc)
        ensure
          @progress&.advance(detail: "unit #{unit['UnitID']}")
        end
      end

      def validate_hash(unit, bytes)
        expected = unit["ContentsHash"].to_s
        actual = IO::BsonCodec.contents_hash(bytes)
        add_error("unit #{unit['UnitID']} ContentsHash mismatch") unless expected == actual
      end

      def parse_unit(unit)
        @mpr.parse_contents(unit)
      rescue IO::MxunitCodec::UnsupportedFormat, SerializationError => e
        add_error("unit #{unit['UnitID']} content parse failed: #{e.message}")
        nil
      end

      def validate_doc_identity(unit, doc)
        type = doc["$Type"] || doc["\$Type"]
        add_error("unit #{unit['UnitID']} missing $Type") if type.to_s.empty?

        doc_id = IO::BsonCodec.extract_id(doc["$ID"] || doc["\$ID"])
        if doc_id.to_s.empty?
          add_error("unit #{unit['UnitID']} missing $ID")
        elsif doc_id != unit["UnitID"]
          record_identity_mismatch(unit, doc_id, type)
        end
      end

      def record_identity_mismatch(unit, doc_id, type)
        mismatch = [unit["UnitID"], doc_id, type]
        if @legacy_identity_mismatches&.include?(mismatch)
          add_warning(
            "unit #{unit['UnitID']} preserves legacy content $ID mismatch #{doc_id}"
          )
        else
          add_error("unit #{unit['UnitID']} content $ID mismatch #{doc_id}")
        end
      end

      def validate_v2_files
        return unless @mpr.format_version == :v2

        expected = @units.filter_map { @mpr.content_path(_1) }.to_set
        actual = @mpr.content_files.to_set
        (expected - actual).each { add_error("missing mxunit file #{_1}") }
        (actual - expected).each { add_warning("orphan mxunit file #{_1}") }
      end

      def require_table(name)
        add_error("missing #{name} table") unless @mpr.tables.include?(name)
      end

      def require_unit_column(name)
        columns = @mpr.table_info("Unit").map { _1["name"] || _1[:name] }
        add_error("missing Unit.#{name} column") unless columns.include?(name)
      end

      def add_error(message)
        @errors << message
      end

      def add_warning(message)
        @warnings << message
      end
    end
  end
end
