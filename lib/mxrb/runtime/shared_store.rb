# frozen_string_literal: true

require 'fileutils'
require 'digest'
require 'json'
require 'sqlite3'

module Mxrb
  module Runtime
    # rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength
    # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists
    SessionRecord = Data.define(:token, :identity, :expires_at)

    # Injectable session persistence protocol.
    module SessionStore
      def write_session(token:, identity:, expires_at:) = raise NotImplementedError
      def read_session(token, now: Time.now.utc) = raise NotImplementedError
      def delete_session(token) = raise NotImplementedError
    end

    # Injectable scheduled-event claim/lease protocol. Renewal is optional for
    # local coordinators and required for distributed lease implementations.
    module SchedulerCoordinator
      def claim_scheduled_event(event:, slot:, owner:, now:, lease_until:, skip_overlap:)
        raise NotImplementedError
      end

      def complete_scheduled_event(event:, slot:, owner:, now: Time.now.utc) = raise NotImplementedError
      def renew_scheduled_event(event:, slot:, owner:, lease_until:) = raise NotImplementedError
    end

    # Process-local implementation of the shared runtime contracts. It keeps
    # the standalone runtime dependency-free while exposing the same API as
    # SQLiteSharedStore for injection in SessionManager and Scheduler.
    class MemorySharedStore
      include SessionStore
      include SchedulerCoordinator

      def initialize
        @sessions = {}
        @claims = {}
        @leases = {}
        @mutex = Mutex.new
      end

      def write_session(token:, identity:, expires_at:)
        @mutex.synchronize do
          @sessions[token.to_s] = SessionRecord.new(
            token.to_s, copy(identity), expires_at.utc
          )
        end
        token
      end

      def read_session(token, now: Time.now.utc)
        @mutex.synchronize do
          prune_sessions(now)
          record = @sessions[token.to_s]
          record && SessionRecord.new(record.token, copy(record.identity), record.expires_at)
        end
      end

      def delete_session(token)
        @mutex.synchronize { !!@sessions.delete(token.to_s) }
      end

      def claim_scheduled_event(event:, slot:, owner:, now:, lease_until:, skip_overlap:)
        key = [event.to_s, slot.to_s]
        @mutex.synchronize do
          claim = @claims[key]
          return false if claim && (claim[:completed_at] || claim.fetch(:lease_expires_at) > now)

          lease = @leases[event.to_s]
          return false if skip_overlap && lease && lease.fetch(:expires_at) > now

          @claims[key] = {
            owner: owner.to_s, claimed_at: now, lease_expires_at: lease_until,
            completed_at: nil
          }
          if skip_overlap
            @leases[event.to_s] = {
              slot: slot.to_s, owner: owner.to_s, expires_at: lease_until
            }
          end
          true
        end
      end

      def complete_scheduled_event(event:, slot:, owner:, now: Time.now.utc)
        key = [event.to_s, slot.to_s]
        @mutex.synchronize do
          claim = @claims[key]
          claim[:completed_at] = now if claim && claim.fetch(:owner) == owner.to_s
          lease = @leases[event.to_s]
          @leases.delete(event.to_s) \
            if lease && lease.fetch(:owner) == owner.to_s && lease.fetch(:slot) == slot.to_s
        end
        true
      end

      def renew_scheduled_event(event:, slot:, owner:, lease_until:)
        key = [event.to_s, slot.to_s]
        @mutex.synchronize do
          claim = @claims[key]
          return false unless claim && claim.fetch(:owner) == owner.to_s && !claim[:completed_at]

          claim[:lease_expires_at] = lease_until
          lease = @leases[event.to_s]
          lease[:expires_at] = lease_until \
            if lease && lease.fetch(:owner) == owner.to_s && lease.fetch(:slot) == slot.to_s
          true
        end
      end

      def close = nil

      private

      def prune_sessions(now)
        @sessions.delete_if { |_token, record| record.expires_at <= now }
      end

      def copy(value) = JSON.parse(JSON.generate(value))
    end

    # SQLite implementation safe for multiple Ruby processes sharing a file.
    # BEGIN IMMEDIATE serializes claim decisions; primary keys make a schedule
    # slot idempotent even after a process restart.
    class SQLiteSharedStore
      include SessionStore
      include SchedulerCoordinator

      attr_reader :database

      def initialize(path, busy_timeout: 5_000)
        raw_path = path.to_s
        raise ArgumentError, 'shared store path must not be empty' if raw_path.empty?

        expanded = raw_path == ':memory:' ? raw_path : File.expand_path(raw_path)

        FileUtils.mkdir_p(File.dirname(expanded)) unless expanded == ':memory:'
        @database = SQLite3::Database.new(expanded)
        @database.results_as_hash = true
        @database.busy_timeout = Integer(busy_timeout)
        @mutex = Mutex.new
        configure!
        migrate!
      end

      def write_session(token:, identity:, expires_at:)
        synchronize do
          database.execute(
            <<~SQL, [session_key(token), JSON.generate(identity), timestamp(expires_at)]
              INSERT INTO mxrb_runtime_sessions (token, identity_json, expires_at)
              VALUES (?, ?, ?)
              ON CONFLICT(token) DO UPDATE SET
                identity_json = excluded.identity_json,
                expires_at = excluded.expires_at
            SQL
          )
        end
        token
      end

      def read_session(token, now: Time.now.utc)
        row = synchronize do
          database.execute('DELETE FROM mxrb_runtime_sessions WHERE expires_at <= ?', [timestamp(now)])
          database.get_first_row(
            'SELECT token, identity_json, expires_at FROM mxrb_runtime_sessions WHERE token = ?',
            [session_key(token)]
          )
        end
        return unless row

        SessionRecord.new(
          token.to_s, JSON.parse(row.fetch('identity_json')),
          Time.at(row.fetch('expires_at').to_f).utc
        )
      end

      def delete_session(token)
        synchronize do
          database.execute('DELETE FROM mxrb_runtime_sessions WHERE token = ?', [session_key(token)])
          database.changes.positive?
        end
      end

      def claim_scheduled_event(event:, slot:, owner:, now:, lease_until:, skip_overlap:)
        transaction do
          claim = database.get_first_row(
            <<~SQL, [event.to_s, slot.to_s]
              SELECT completed_at, lease_expires_at
              FROM mxrb_runtime_scheduled_claims
              WHERE event_key = ? AND slot = ?
            SQL
          )
          next false if claim && (claim['completed_at'] || claim.fetch('lease_expires_at').to_f > timestamp(now))

          if skip_overlap
            active = database.get_first_value(
              'SELECT 1 FROM mxrb_runtime_scheduler_leases WHERE event_key = ? AND expires_at > ?',
              [event.to_s, timestamp(now)]
            )
            next false if active
          end

          database.execute(
            <<~SQL, [event.to_s, slot.to_s, owner.to_s, timestamp(now), timestamp(lease_until)]
              INSERT INTO mxrb_runtime_scheduled_claims
                (event_key, slot, owner, claimed_at, lease_expires_at, completed_at)
              VALUES (?, ?, ?, ?, ?, NULL)
              ON CONFLICT(event_key, slot) DO UPDATE SET
                owner = excluded.owner,
                claimed_at = excluded.claimed_at,
                lease_expires_at = excluded.lease_expires_at,
                completed_at = NULL
            SQL
          )
          if skip_overlap
            database.execute(
              <<~SQL, [event.to_s, slot.to_s, owner.to_s, timestamp(lease_until)]
                INSERT INTO mxrb_runtime_scheduler_leases (event_key, slot, owner, expires_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(event_key) DO UPDATE SET
                  slot = excluded.slot,
                  owner = excluded.owner,
                  expires_at = excluded.expires_at
              SQL
            )
          end
          true
        end
      end

      def complete_scheduled_event(event:, slot:, owner:, now: Time.now.utc)
        transaction do
          database.execute(
            <<~SQL, [timestamp(now), event.to_s, slot.to_s, owner.to_s]
              UPDATE mxrb_runtime_scheduled_claims
              SET completed_at = ?
              WHERE event_key = ? AND slot = ? AND owner = ?
            SQL
          )
          database.execute(
            <<~SQL, [event.to_s, slot.to_s, owner.to_s]
              DELETE FROM mxrb_runtime_scheduler_leases
              WHERE event_key = ? AND slot = ? AND owner = ?
            SQL
          )
        end
        true
      end

      def renew_scheduled_event(event:, slot:, owner:, lease_until:)
        transaction do
          database.execute(
            <<~SQL, [timestamp(lease_until), event.to_s, slot.to_s, owner.to_s]
              UPDATE mxrb_runtime_scheduled_claims
              SET lease_expires_at = ?
              WHERE event_key = ? AND slot = ? AND owner = ? AND completed_at IS NULL
            SQL
          )
          next false unless database.changes.positive?

          database.execute(
            <<~SQL, [timestamp(lease_until), event.to_s, slot.to_s, owner.to_s]
              UPDATE mxrb_runtime_scheduler_leases
              SET expires_at = ?
              WHERE event_key = ? AND slot = ? AND owner = ?
            SQL
          )
          true
        end
      end

      def close
        @mutex.synchronize { database.close unless database.closed? }
      end

      private

      def configure!
        database.execute('PRAGMA journal_mode = WAL')
        database.execute('PRAGMA synchronous = NORMAL')
      end

      def migrate!
        synchronize do
          database.execute_batch(<<~SQL)
            CREATE TABLE IF NOT EXISTS mxrb_runtime_sessions (
              token TEXT PRIMARY KEY,
              identity_json TEXT NOT NULL,
              expires_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS mxrb_runtime_sessions_expiration
              ON mxrb_runtime_sessions (expires_at);
            CREATE TABLE IF NOT EXISTS mxrb_runtime_scheduled_claims (
              event_key TEXT NOT NULL,
              slot TEXT NOT NULL,
              owner TEXT NOT NULL,
              claimed_at REAL NOT NULL,
              lease_expires_at REAL NOT NULL,
              completed_at REAL,
              PRIMARY KEY (event_key, slot)
            );
            CREATE TABLE IF NOT EXISTS mxrb_runtime_scheduler_leases (
              event_key TEXT PRIMARY KEY,
              slot TEXT NOT NULL,
              owner TEXT NOT NULL,
              expires_at REAL NOT NULL
            );
          SQL
        end
      end

      def transaction
        synchronize do
          database.execute('BEGIN IMMEDIATE')
          result = yield
          database.execute('COMMIT')
          result
        rescue Exception # rubocop:disable Lint/RescueException
          database.execute('ROLLBACK') if database.transaction_active?
          raise
        end
      end

      def synchronize(&block) = @mutex.synchronize(&block)
      def timestamp(value) = value.to_f
      def session_key(token) = Digest::SHA256.hexdigest(token.to_s)
    end
    # rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/ClassLength
    # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/ParameterLists
  end
end
