# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Application
      # rubocop:disable Metrics
      # The synchronization an offline profile runs against /api/sync: the
      # client uploads the objects it created, changed and deleted while
      # offline, then downloads the entities the profile synchronizes, each
      # under its XPath constraint. Uploads apply in one transaction, so a
      # validation failure keeps every change pending on the client; an object
      # the server no longer has is reported as a conflict and skipped.
      module OfflineSynchronization
        SYNC_MODES = %w[All None NoneAndPreserveData].freeze

        def offline_configuration(profile: nil, context: nil)
          selected = offline_profile(profile)
          raise NotFoundError, "no offline profile#{" #{profile}" if profile}" unless selected

          {
            profile: selected.fetch('name').to_s,
            entities: offline_entities(selected).select { |config| readable_entity?(config.fetch(:entity), context) },
            synchronized_at: Time.now.utc.iso8601
          }
        end

        def synchronize_offline(payload, context: nil)
          raise ArgumentError, 'synchronization payload must be an object' unless payload.is_a?(Hash)

          configuration = offline_configuration(profile: payload['profile'], context:)
          changes = Array(payload['changes'])
          valid = changes.all? { |entry| offline_change?(entry) }
          raise ArgumentError, 'changes must be objects with type and id' unless valid

          runtime_synchronize do
            bridge.interpreter.store.transaction do
              uploaded = upload_offline_changes(changes, context:)
              configuration.except(:entities).merge(uploaded)
                           .merge(download_offline_data(configuration, payload, context:))
            end
          ensure
            release_runtime_cache
          end
        end

        private

        # A native profile always works on the device; a web profile does when
        # Studio Pro marks it offline or gives it entities to synchronize.
        def offline_profiles
          profiles = manifest.data.dig('navigation', 'profiles')
          Array(profiles).select do |profile|
            profile.is_a?(Hash) &&
              (profile['offline'] == true || profile['kind'].to_s == 'Native' ||
               !Array(profile['offline_entities']).empty?)
          end
        end

        def offline_profile(name)
          return offline_profiles.first if name.to_s.empty?

          offline_profiles.find { |profile| profile['name'].to_s == name.to_s }
        end

        def offline_entities(profile)
          Array(profile['offline_entities']).map do |config|
            mode = config.fetch('sync_mode', 'None').to_s
            raise ArgumentError, "unknown offline sync mode #{mode.inspect}" unless SYNC_MODES.include?(mode)

            { entity: config['entity'].to_s, sync_mode: mode, constraint: config['constraint'].to_s }
          end
        end

        def readable_entity?(entity, context)
          !context || access_control.entity_allowed?(entity, action: :read, context:)
        rescue Runtime::AuthorizationError
          false
        end

        def offline_change?(entry)
          entry.is_a?(Hash) && %w[type id].all? { entry[_1].is_a?(String) && !entry[_1].empty? } &&
            (entry['deleted'] == true || entry['attributes'].is_a?(Hash))
        end

        # Deletions of objects the server no longer has are already done; a change
        # to such an object is a conflict the client resolves by dropping it.
        def upload_offline_changes(changes, context:)
          store = bridge.interpreter.store
          deletions, upserts = changes.partition { |entry| entry['deleted'] == true }
          conflicts = []
          upserts = upserts.select do |entry|
            next true if entry['new_record'] == true || store.find(entry['type'], entry['id'])

            conflicts << { type: entry['type'], id: entry['id'], reason: 'deleted' }
            false
          end
          committed = upserts.empty? ? [] : commit_records(upserts, context:)
          existing = deletions.select { |entry| store.find(entry['type'], entry['id']) }
          existing = existing.map { |entry| entry.slice('type', 'id') }
          delete_records(existing, context:) unless existing.empty?
          guid_map = committed.filter_map { |saved| [saved[:draft_id], saved[:id]] if saved[:draft_id] }.to_h
          { ok: true, guid_map:, conflicts:, uploaded: committed.map { |saved| saved.except(:draft_id) } }
        end

        def download_offline_data(configuration, payload, context:)
          objects = Array(payload['objects'])
          unless objects.empty?
            raise ArgumentError, 'objects must have type and id' unless objects.all? do |entry|
              offline_reference?(entry)
            end

            return { objects: objects.map { |entry| record(entry['type'], entry['id'], context:) } }
          end

          requested = payload['entities']
          raise ArgumentError, 'entities must be a list of names' unless requested.nil? || requested.is_a?(Array)

          entities = configuration.fetch(:entities).select do |config|
            requested.nil? || requested.include?(config.fetch(:entity))
          end
          {
            entities: entities.map do |config|
              next config unless config.fetch(:sync_mode) == 'All'

              xpath = config.fetch(:constraint).empty? ? nil : config.fetch(:constraint)
              config.merge(records: records(config.fetch(:entity), context:, xpath:))
            end
          }
        end

        def offline_reference?(entry)
          entry.is_a?(Hash) && %w[type id].all? { entry[_1].is_a?(String) && !entry[_1].empty? }
        end
      end
      # rubocop:enable Metrics
    end
  end
end
