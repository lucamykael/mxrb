# frozen_string_literal: true

require 'base64'

module Mxrb
  module RubyApp
    # Blob storage shares the entity database and transaction. Client MIME and
    # filenames never determine executable content or filesystem destinations.
    class FileContent
      MAX_BYTES = 20 * 1024 * 1024

      def initialize(database)
        @database = database
        @database.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS mxrb_file_contents (
            entity TEXT NOT NULL, object_id TEXT NOT NULL, name TEXT NOT NULL,
            media_type TEXT NOT NULL, content BLOB NOT NULL,
            PRIMARY KEY (entity, object_id)
          )
        SQL
      end

      def write(entity, id, filename, encoded, **policy)
        bytes = decode(encoded)
        name = normalized_name(filename)
        type = media_type(bytes)
        validate_policy(name, type, bytes.bytesize, policy)
        @database.execute(
          'INSERT OR REPLACE INTO mxrb_file_contents (entity, object_id, name, media_type, content) ' \
          'VALUES (?, ?, ?, ?, ?)',
          [entity, id, name, type, SQLite3::Blob.new(bytes)]
        )
        { name:, media_type: type, size: bytes.bytesize }
      end

      def read(entity, id)
        @database.get_first_row(
          'SELECT name, media_type, content FROM mxrb_file_contents WHERE entity = ? AND object_id = ?', [entity, id]
        )
      end

      def delete(entity, id)
        @database.execute('DELETE FROM mxrb_file_contents WHERE entity = ? AND object_id = ?', [entity, id])
      end

      # A database trigger covers microflows, events:false, and transactional
      # deletes as well as HTTP CRUD. Rollback restores the blob with its row.
      def attach(entity)
        trigger = "mxrb_file_delete_#{Digest::SHA256.hexdigest(entity.name)[0, 24]}"
        table = entity.table.gsub('"', '""')
        name = entity.name.gsub("'", "''")
        @database.execute(<<~SQL)
          CREATE TRIGGER IF NOT EXISTS "#{trigger}" AFTER DELETE ON "#{table}"
          BEGIN
            DELETE FROM mxrb_file_contents WHERE entity = '#{name}' AND object_id = OLD.id;
          END
        SQL
      end

      private

      def validate_policy(name, type, size, policy)
        raise ArgumentError, 'file exceeds the entity upload policy' if size > policy.fetch(:max_bytes, MAX_BYTES)

        extensions = policy.fetch(:extensions, [])
        unless extensions.empty? || extensions.include?(File.extname(name).delete_prefix('.').downcase)
          raise ArgumentError, 'file extension is not allowed by the entity upload policy'
        end
        return unless policy[:images_only] && !type.start_with?('image/')

        raise ArgumentError, 'entity upload policy requires an image'
      end

      def decode(encoded)
        raise ArgumentError, 'file exceeds 20 MiB' if encoded.to_s.bytesize > ((MAX_BYTES + 2) / 3) * 4

        Base64.strict_decode64(encoded.to_s).tap do |bytes|
          raise ArgumentError, 'file exceeds 20 MiB' if bytes.bytesize > MAX_BYTES
        end
      end

      def normalized_name(filename)
        name = filename.to_s.tr('\\', '/').split('/').last.to_s.gsub(/[\x00-\x1f\x7f]/, '')[0, 200]
        raise ArgumentError, 'file name is required' if name.empty?

        name
      end

      def media_type(bytes)
        return 'image/png' if bytes.start_with?("\x89PNG\r\n\x1a\n".b)
        return 'image/jpeg' if bytes.start_with?("\xff\xd8\xff".b)
        return 'image/gif' if bytes.start_with?('GIF87a', 'GIF89a')
        return 'image/webp' if bytes.start_with?('RIFF') && bytes.byteslice(8, 4) == 'WEBP'

        'application/octet-stream'
      end
    end
  end
end
