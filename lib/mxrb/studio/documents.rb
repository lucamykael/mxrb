# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require_relative '../io/mpr_file'
require_relative 'files'

# rubocop:disable Metrics
module Mxrb
  module Studio
    # Native document properties backed by exact BSON revisions. This editor
    # replaces existing scalar values; structural edits belong to typed writers.
    class Documents
      REFERENCE_KEY = /
        (?:Pointer|Reference|Ref|Guid|GUID|Id|ID)\z |
        \A(?:Entity|Association|Microflow|Nanoflow|Page|Role|Generalization|Attribute)\z
      /x
      attr_reader :model_path

      def initialize(model_path)
        @model_path = File.realpath(model_path)
        raise ArgumentError, 'model must be a file' unless File.file?(@model_path)
      end

      def list
        open_model { |mpr| mpr.all_units.map { metadata(mpr, _1) } }
      end

      def read(unit_id)
        open_model { |mpr| representation(mpr, fetch_unit(mpr, unit_id)) }
      end

      def patch(unit_id, revision:, changes:)
        entries = normalize_changes(changes)
        original = open_model do |mpr|
          raw = fetch_unit(mpr, unit_id)
          bytes = mpr.content_bytes(raw)
          check_revision(bytes, revision)
          document = mpr.parse_contents(raw)
          entries.each { |path, value| validate_change(document, path, value) }
          entries.reduce(bytes) { |current, (path, value)| NativePatch.new(current).replace(path, value) }
        end
        with_lock do
          open_model(readonly: false) do |mpr|
            mpr.transaction do
              raw = fetch_unit(mpr, unit_id)
              check_revision(mpr.content_bytes(raw), revision)
              mpr.update_unit_bytes(unit_id, original) unless Digest::SHA256.hexdigest(original) == revision
            end
            representation(mpr, fetch_unit(mpr, unit_id))
          end
        end
      end

      private

      def open_model(readonly: true)
        mpr = IO::MprFile.open(model_path, readonly:, apply_studio_compatibility: false)
        yield mpr
      ensure
        mpr&.close
      end

      def fetch_unit(mpr, unit_id)
        unless unit_id.is_a?(String) && unit_id.match?(IO::BsonCodec::UUID_PATTERN)
          raise ArgumentError, 'unit_id must be a UUID'
        end

        mpr.unit(unit_id) || raise(ArgumentError, "unknown unit: #{unit_id}")
      end

      def metadata(mpr, raw)
        document = mpr.parse_contents(raw)
        { unit_id: raw.fetch('UnitID'), container_id: raw.fetch('ContainerID'),
          containment_name: raw.fetch('ContainmentName'), type: document['$Type'], name: document['Name'],
          revision: Digest::SHA256.hexdigest(mpr.content_bytes(raw)) }
      end

      def representation(mpr, raw)
        document = mpr.parse_contents(raw)
        metadata(mpr, raw).merge(document: json_value(document), properties: properties(document))
      end

      def json_value(value)
        case value
        when Hash then value.to_h { |key, child| [key, json_value(child)] }
        when Array then value.map { json_value(_1) }
        when String, Integer, TrueClass, FalseClass, NilClass then value
        when Float then value.finite? ? value : { '$numberDouble' => value.to_s }
        else json_value(value.as_extended_json) # every other parsed BSON value
        end
      end

      def properties(document, path = [], root: document)
        document.flat_map do |key, value|
          current = path + [key]
          if value.is_a?(Hash) || value.is_a?(Array)
            children = value.is_a?(Hash) ? value : value.each_with_index.to_h { |child, index| [index, child] }
            properties(children, current, root:)
          else
            { path: pointer(current), type: value.class.name, value: json_value(value),
              editable: editable?(document_root: root, path: current, value:) }
          end
        end
      end

      def pointer(parts) = "/#{parts.map { _1.to_s.gsub('~', '~0').gsub('/', '~1') }.join('/')}"

      def normalize_changes(changes)
        entries = case changes
                  when Hash then changes.to_a
                  when Array
                    changes.map do |entry|
                      raise ArgumentError, 'changes must contain path/value objects' unless entry.is_a?(Hash)

                      [entry.fetch('path') { entry.fetch(:path) }, entry.fetch('value') { entry.fetch(:value) }]
                    end
                  else raise ArgumentError, 'changes must be a property map or array of path/value objects'
                  end
        raise ArgumentError, 'select at least one property to edit' if entries.empty?

        entries.map { |path, value| [path_parts(path), value] }
      rescue KeyError
        raise ArgumentError, 'each change requires path and value'
      end

      def path_parts(path)
        return path if path.is_a?(Array) && !path.empty? && path.all? { _1.is_a?(String) || _1.is_a?(Integer) }

        unless path.is_a?(String) && path.start_with?('/') && !path.match?(/~(?![01])/)
          raise ArgumentError, 'path must be a nonempty JSON pointer or array of keys'
        end

        path.delete_prefix('/').split('/', -1).map { _1.gsub('~1', '/').gsub('~0', '~') }
      end

      def locate(document, path)
        path.reduce(document) do |value, key|
          if value.is_a?(Hash) && value.key?(key)
            value.fetch(key)
          elsif value.is_a?(Array) && key.to_s.match?(/\A(?:0|[1-9]\d*)\z/) && key.to_i < value.length
            value.fetch(key.to_i)
          else
            raise ArgumentError, "property does not exist: #{pointer(path)}"
          end
        end
      end

      def editable?(document_root:, path:, value:)
        return false if path.any? { _1.to_s.start_with?('$') || _1.to_s.match?(REFERENCE_KEY) }
        return false if path.last.is_a?(Integer) || path.last.to_s.match?(/\A\d+\z/)
        return false if value.is_a?(String) && value.match?(IO::BsonCodec::UUID_PATTERN)
        return false unless [String, Integer, Float, TrueClass, FalseClass, NilClass].include?(value.class)

        path.each_index.none? do |index|
          parent = locate(document_root, path.take(index))
          parent.is_a?(Array) && parent.first == 1
        end
      end

      def validate_change(document, path, value)
        current = locate(document, path)
        unless editable?(document_root: document, path:, value: current)
          raise ArgumentError, "property is structural, a reference, or not a scalar: #{pointer(path)}"
        end

        compatible = case current
                     when TrueClass, FalseClass then [true, false].include?(value)
                     when Float then value.is_a?(Float) && value.finite?
                     when String then value.is_a?(String) && value.encoding == Encoding::UTF_8 && value.valid_encoding?
                     else value.instance_of?(current.class)
                     end
        raise ArgumentError, "incompatible scalar type: #{pointer(path)}" unless compatible
      end

      def check_revision(bytes, revision)
        return if bytes && Digest::SHA256.hexdigest(bytes) == revision

        raise Conflict, 'document changed outside the editor; both versions are preserved'
      end

      def with_lock(&) = WriteLock.synchronize(model_path, &)

      # Rebuild only the length prefixes and changed scalar payload. Unchanged
      # BSON element slices retain exact bytes, including noncanonical widths.
      class NativePatch
        FIXED_SIZES = { 1 => 8, 6 => 0, 7 => 12, 8 => 1, 9 => 8, 10 => 0, 16 => 4,
                        17 => 8, 18 => 8, 19 => 16, 127 => 0, 255 => 0 }.freeze

        def initialize(bytes) = @bytes = bytes

        def replace(path, value)
          fields = []
          matches = 0
          offset = 4
          while offset < @bytes.bytesize - 1
            type = @bytes.getbyte(offset)
            key_end = @bytes.index("\0", offset + 1) || raise(ArgumentError, 'invalid BSON field')
            name = @bytes.byteslice(offset + 1, key_end - offset - 1)
            start = key_end + 1
            length = payload_length(type, start)
            payload = @bytes.byteslice(start, length)
            if name == path.first.to_s.b
              matches += 1
              payload = if path.length == 1
                          scalar(type, value)
                        else
                          raise ArgumentError, 'path crosses a BSON scalar' unless [3, 4].include?(type)

                          self.class.new(payload).replace(path.drop(1), value)
                        end
            end
            fields << @bytes.byteslice(offset, start - offset) + payload
            offset = start + length
          end
          raise ArgumentError, 'ambiguous or absent BSON property' unless matches == 1

          body = "#{fields.join}\0"
          [body.bytesize + 4].pack('l<') + body
        end

        private

        def payload_length(type, offset)
          return FIXED_SIZES.fetch(type) if FIXED_SIZES.key?(type)

          case type
          when 2, 13, 14 then 4 + @bytes.byteslice(offset, 4).unpack1('l<')
          when 3, 4, 15 then @bytes.byteslice(offset, 4).unpack1('l<')
          when 5 then 5 + @bytes.byteslice(offset, 4).unpack1('l<')
          when 11
            last = @bytes.index("\0", (@bytes.index("\0", offset) || raise(ArgumentError, 'invalid BSON regex')) + 1)
            (last || raise(ArgumentError, 'invalid BSON regex')) + 1 - offset
          when 12 then 4 + @bytes.byteslice(offset, 4).unpack1('l<') + 12
          else raise ArgumentError, "unsupported BSON field tag: #{type}"
          end
        end

        def scalar(type, value)
          case type
          when 1 then [value].pack('E')
          when 2 then "#{[value.bytesize + 1].pack('l<')}#{value.b}\0"
          when 8 then value ? "\1" : "\0"
          when 10 then ''
          when 16, 18
            bits = type == 16 ? 32 : 64
            raise ArgumentError, "integer exceeds BSON int#{bits} range" unless value.between?(-(2**(bits - 1)),
                                                                                               (2**(bits - 1)) - 1)

            [value].pack(type == 16 ? 'l<' : 'q<')
          else raise ArgumentError, "BSON field type #{type} is not editable"
          end
        end
      end
      private_constant :NativePatch
    end
  end
end
# rubocop:enable Metrics
