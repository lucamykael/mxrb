# frozen_string_literal: true

require 'json'
require 'securerandom'
require 'date'
require 'time'

module Mxrb
  module Runtime
    # Server-owned snapshots of uncommitted page objects. Tokens are capabilities,
    # additionally bound to the authenticated principal, and expire after an hour.
    # Keeping these rows in the model database makes commit/invalidation atomic
    # and allows another application process to resume the same draft.
    class ClientDrafts
      TTL = 3600

      def initialize(store)
        @store = store
        @database = store.database
        @database.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS mxrb_client_drafts (
            token TEXT PRIMARY KEY, owner TEXT NOT NULL, entity TEXT NOT NULL,
            object_id TEXT NOT NULL, expires_at REAL NOT NULL, payload TEXT,
            UNIQUE(owner, entity, object_id)
          )
        SQL
      end

      def capture(value, owner:, seen: {})
        return seen[value.id] if seen.key?(value.id)

        token = register(value, owner)
        seen[value.id] = token
        payload = JSON.generate(codec.encode(value.members, owner, seen))
        @database.execute('UPDATE mxrb_client_drafts SET payload = ?, expires_at = ? WHERE token = ?',
                          [payload, Time.now.to_f + TTL, token])
        token
      end

      def resume(token, entity:, id:, owner:)
        row = authorized_row(token, entity, id, owner)
        existing = @store.find(entity, id)
        return existing if existing

        detached = @store.detached_draft(entity, id)
        return @store.resume_draft(detached) if detached

        materialize(row, owner)
      end

      def delete(value)
        @database.execute('DELETE FROM mxrb_client_drafts WHERE entity = ? AND object_id = ?',
                          [value.entity, value.id])
      end

      private

      def authorized_row(token, entity, id, owner)
        row = @database.get_first_row(
          'SELECT * FROM mxrb_client_drafts WHERE token = ? AND owner = ? ' \
          'AND entity = ? AND object_id = ? AND expires_at > ?',
          [token, owner, entity, id, Time.now.to_f]
        )
        raise NativeRuntimeError, 'page draft is missing, expired or belongs to another user' unless row

        row
      end

      def register(value, owner)
        @database.execute('DELETE FROM mxrb_client_drafts WHERE expires_at <= ?', [Time.now.to_f])
        @database.execute(
          'INSERT OR IGNORE INTO mxrb_client_drafts (token, owner, entity, object_id, expires_at) ' \
          'VALUES (?, ?, ?, ?, ?)',
          [SecureRandom.hex(32), owner, value.entity, value.id, Time.now.to_f + TTL]
        )
        @database.get_first_value(
          'SELECT token FROM mxrb_client_drafts WHERE owner = ? AND entity = ? AND object_id = ?',
          [owner, value.entity, value.id]
        )
      end

      def codec = ClientDraftCodec.new(self, @store)

      def materialize(row, owner)
        object = Native::ObjectValue.new(entity: row.fetch('entity'), id: row.fetch('object_id'), members: {})
        @store.resume_draft(object)
        object.members.replace(codec.decode(JSON.parse(row.fetch('payload')), owner))
        object
      end
    end

    # Tagged values preserve dates and object identity without evaluating client input.
    class ClientDraftCodec
      def initialize(drafts, store)
        @drafts = drafts
        @store = store
      end

      def encode(value, owner, seen)
        case value
        when Native::ObjectValue then encode_reference(value, owner, seen)
        when Hash then { 'hash' => value.map { [encode(_1, owner, seen), encode(_2, owner, seen)] } }
        when Array then value.map { encode(_1, owner, seen) }
        else encode_scalar(value)
        end
      end

      def decode(value, owner)
        return value.map { decode(_1, owner) } if value.is_a?(Array)
        return value unless value.is_a?(Hash)

        decode_tagged(value, owner)
      end

      private

      def encode_scalar(value)
        case value
        when BigDecimal then { 'decimal' => DecimalValues.text(value) }
        when Time then { 'time' => value.iso8601(9) }
        when DateTime then { 'datetime' => value.iso8601(9) }
        when Date then { 'date' => value.iso8601 }
        else value
        end
      end

      def decode_tagged(value, owner)
        case value.keys.first
        when 'hash' then value.fetch('hash').to_h { [decode(_1, owner), decode(_2, owner)] }
        when 'decimal' then DecimalValues.parse(value.fetch('decimal'))
        when 'time' then Time.iso8601(value.fetch('time'))
        when 'datetime' then DateTime.iso8601(value.fetch('datetime'))
        when 'date' then Date.iso8601(value.fetch('date'))
        else decode_reference(value, owner)
        end
      end

      def encode_reference(value, owner, seen)
        reference = { 'record' => [value.entity, value.id] }
        reference['draft'] = @drafts.capture(value, owner:, seen:) if @store.draft?(value)
        reference
      end

      def decode_reference(value, owner)
        entity, id = value.fetch('record')
        return @store.find(entity, id) unless value.key?('draft')

        @store.find(entity, id) || @drafts.resume(value.fetch('draft'), entity:, id:, owner:)
      end
    end
  end
end
