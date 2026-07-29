# frozen_string_literal: true

require "bson"
require "digest"
require "base64"

module Mxrb
  module IO
    # BSON codec with Mendix-specific conventions:
    #   - UUIDs stored as 16-byte blobs with partial little-endian byte-swap (MS GUID format)
    #   - Arrays have a 4-byte int32 marker as first element (1=by-name, 2=part-secondary, 3=part-primary)
    #   - $ID can appear as String, BSON Binary, or {Data:, Subtype:} map
    #   - $Type uses storage names ("DomainModels$Entity") not SDK qualified names
    module BsonCodec
      # ── UUID / BLOB conversion ─────────────────────────────────────────────

      # Convert a 16-byte MS-GUID blob to UUID string.
      # MS-GUID layout: bytes 0-3 little-endian, 4-5 little-endian, 6-7 little-endian,
      # bytes 8-15 big-endian.
      def self.blob_to_uuid(blob)
        return nil unless blob.is_a?(String) && blob.bytesize == 16

        b = blob.bytes
        p1 = b[0..3].reverse.map { "%02x" % _1 }.join
        p2 = b[4..5].reverse.map { "%02x" % _1 }.join
        p3 = b[6..7].reverse.map { "%02x" % _1 }.join
        p4 = b[8..9].map  { "%02x" % _1 }.join
        p5 = b[10..15].map { "%02x" % _1 }.join
        "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
      end

      # Convert a UUID string to a 16-byte MS-GUID blob.
      def self.uuid_to_blob(uuid)
        hex   = uuid.delete("-")
        parts = hex.scan(/../).map { _1.to_i(16).chr(Encoding::BINARY) }
        (parts[0..3].reverse + parts[4..5].reverse + parts[6..7].reverse + parts[8..15]).join
      end

      # ── $ID extraction ─────────────────────────────────────────────────────

      # Extract the Mendix $ID value from any of its three representations:
      #   1. String UUID:  "c67c5271-da7d-45f1-81df-ceb6946b8abe"
      #   2. BSON Binary:  <16-byte blob>  → converted to UUID string
      #   3. Map:          { "Data" => "base64...", "Subtype" => 3 } → decoded + converted
      def self.extract_id(value)
        case value
        when String
          value  # already a UUID string
        when BSON::Binary
          blob_to_uuid(value.data)
        when Hash
          data = value["Data"] || value[:Data]
          return nil unless data
          blob_to_uuid(Base64.strict_decode64(data.to_s))
        end
      end

      # ── Array parsing ───────────────────────────────────────────────────────

      # Mendix arrays have an int32 marker as first element.
      # Returns { marker: Integer, items: Array }
      # Marker values: 1=by-name refs, 2=part-secondary, 3=part-primary
      def self.parse_array(raw)
        return { marker: 3, items: [] } if raw.nil? || raw.empty?

        marker = raw.first.is_a?(Integer) ? raw.first : 3
        items  = raw.first.is_a?(Integer) ? raw[1..] : raw
        { marker: marker, items: Array(items) }
      end

      # Build a Mendix-style array (prepend marker).
      def self.build_array(items, marker: 3)
        [marker] + Array(items)
      end

      # ── BSON parse / serialize ──────────────────────────────────────────────

      # Parse raw BSON bytes → Ruby Hash (with string keys).
      def self.parse(bytes)
        return {} if bytes.nil? || bytes.empty?

        buf = BSON::ByteBuffer.new(bytes.b)
        BSON::Document.from_bson(buf).to_h
      rescue => e
        raise SerializationError, "BSON parse error: #{e.message}"
      end

      # Serialize a Ruby Hash → BSON bytes.
      def self.serialize(doc)
        bson_doc = BSON::Document.new(storage_value(doc))
        buf = BSON::ByteBuffer.new
        bson_doc.to_bson(buf)
        buf.get_bytes(buf.length)
      rescue => e
        raise SerializationError, "BSON serialize error: #{e.message}"
      end

      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      BINARY_UUID_KEYS = %w[
        $ID ChildPointer CloseButtonPointer DefaultButtonPointer
        DefaultPagePointer DestinationPointer GUID OriginPointer ParentPointer
        StableId TypeParameterPointer TypePointer
      ].freeze

      def self.storage_value(value, key = nil)
        if BINARY_UUID_KEYS.include?(key) &&
            value.is_a?(String) && value.match?(UUID_PATTERN)
          return BSON::Binary.new(uuid_to_blob(value), :generic)
        end

        case value
        when Hash
          value.to_h { |child_key, child| [child_key, storage_value(child, child_key.to_s)] }
        when Array
          value.map { storage_value(_1) }
        else
          value
        end
      end
      private_class_method :storage_value

      # ── ContentHash ────────────────────────────────────────────────────────

      # Compute the Mendix ContentsHash: Base64(SHA256(bson_bytes)).
      def self.contents_hash(bson_bytes)
        Base64.strict_encode64(Digest::SHA256.digest(bson_bytes.b))
      end

      # ── Storage name helpers ───────────────────────────────────────────────

      # Map ContainmentName → expected $Type prefix for quick type detection.
      CONTAINMENT_TO_TYPE = {
        "Modules"             => "Projects$Module",
        "DomainModel"         => "DomainModels$DomainModel",
        "Documents"           => nil,  # could be Page, Microflow, etc — read $Type
        "Folders"             => "Projects$Folder",
        "ModuleSecurity"      => "Security$ModuleSecurity",
        "Settings"            => "Settings$ProjectSettings",
        "Security"            => "Security$ProjectSecurity",
        "NavigationDocuments" => "Navigation$NavigationDocument",
        "SystemTexts"         => "Texts$SystemTextCollection",
      }.freeze
    end
  end
end
