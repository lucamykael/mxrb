# frozen_string_literal: true

require 'digest'

module Mxrb
  module Settings
    # Lossless BSON codec for the typed Studio Pro 11 project-settings model.
    class MprCodec # rubocop:disable Metrics/ClassLength
      def decode(document)
        node = decode_value(document)
        unless node.is_a?(Node) && node.storage_type == 'Settings$ProjectSettings'
          raise Error, 'project settings root must be Settings$ProjectSettings'
        end

        node
      end

      def encode(model, baseline: nil)
        unless model.is_a?(Node) && model.storage_type == 'Settings$ProjectSettings'
          raise Error, 'project settings model must be a Settings::Node root'
        end

        encode_node(model, baseline, ['project_settings'])
      end

      private

      def decode_value(value) # rubocop:disable Metrics/MethodLength
        case value
        when BSON::Binary
          BinaryAsset.from_bytes(value.data, subtype: value.type)
        when Array
          decode_collection(value)
        when Hash
          decode_node(value)
        else
          value
        end
      rescue ArgumentError => e
        raise Error, "invalid project-settings collection: #{e.message}"
      end

      def decode_collection(value)
        parsed = IO::BsonCodec.parse_array(value)
        Collection.new(items: parsed.fetch(:items).map { decode_value(_1) },
                       marker: parsed.fetch(:marker))
      end

      def decode_node(document)
        type = document['$Type']
        raise Error, 'untyped maps are not valid project-settings values' unless type

        Node.new(type).tap do |node|
          document.each do |field, value|
            next if %w[$ID $Type].include?(field)

            node.set(field, decode_value(value))
          end
        end
      end

      def encode_value(value, baseline, path)
        case value
        when Node then encode_node(value, baseline, path)
        when Collection then encode_collection(value, baseline, path)
        when BinaryAsset then BSON::Binary.new(value.bytes, value.subtype)
        else value
        end
      end

      def encode_node(node, baseline, path)
        previous = baseline if baseline.is_a?(Hash) && baseline['$Type'] == node.storage_type
        document = {
          '$ID' => encoded_identity(previous, path, node.storage_type),
          '$Type' => node.storage_type
        }
        node.fields.each do |field, value|
          document[field] = encode_value(value, previous&.fetch(field, nil), [*path, field])
        end
        document
      end

      def encoded_identity(previous, path, type)
        identity = previous && IO::BsonCodec.extract_id(previous['$ID']).to_s
        identity.to_s.empty? ? stable_id(*path, type) : identity
      end

      def encode_collection(collection, baseline, path)
        previous_items = bson_items(baseline)
        consumed = {}
        items = collection.items.each_with_index.map do |item, index|
          previous_index = matching_index(item, previous_items, consumed, index)
          consumed[previous_index] = true if previous_index
          encode_value(item, previous_index && previous_items[previous_index], [*path, index])
        end
        IO::BsonCodec.build_array(items, marker: collection.marker)
      end

      def matching_index(item, previous, consumed, index)
        return index if !item.is_a?(Node) && index < previous.length
        return unless item.is_a?(Node)

        key_field = %w[Name Code ActionActivityType ModuleName].find { item.fields.key?(_1) }
        matching_node_index(item, previous, consumed, key_field) ||
          positional_node_index(item, previous, index)
      end

      def matching_node_index(item, previous, consumed, key_field)
        previous.each_index.find do |candidate|
          value = previous[candidate]
          !consumed[candidate] && value.is_a?(Hash) &&
            value['$Type'] == item.storage_type &&
            (!key_field || value[key_field] == item.fields[key_field])
        end
      end

      def positional_node_index(item, previous, index)
        value = previous[index]
        index if value.is_a?(Hash) && value['$Type'] == item.storage_type
      end

      def bson_items(value)
        return [] unless value.is_a?(Array)

        IO::BsonCodec.parse_array(value).fetch(:items)
      rescue ArgumentError
        []
      end

      def stable_id(*parts)
        hex = Digest::SHA256.hexdigest(parts.join("\0"))[0, 32]
        hex[12] = '5'
        hex[16] = ((hex[16].to_i(16) & 0x3) | 0x8).to_s(16)
        [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join('-')
      end
    end
  end
end
