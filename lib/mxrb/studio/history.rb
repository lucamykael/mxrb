# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'
require_relative '../io/mpr_file'
require_relative 'files'
require_relative 'write_lock'

# rubocop:disable Metrics
module Mxrb
  module Studio
    # Undo/redo journal for writes MXRB makes to a model. Each entry stores the
    # exact native bytes of every unit the write added, removed or changed, so
    # undoing restores IDs, references and layout byte for byte. An entry is
    # only undone (or redone) while the affected units still hold the state the
    # entry left them in; a later edit by anyone else makes it a conflict.
    class History
      LIMIT = 100
      attr_reader :model_path, :directory

      def initialize(model_path, state_root:)
        @model_path = File.realpath(model_path)
        @directory = File.join(File.expand_path(state_root), 'history', Digest::SHA256.hexdigest(@model_path))
      end

      # Runs a write and journals the units it changed. Returns the block's
      # result and the entry summary (nil when the write changed nothing).
      def record(label)
        WriteLock.synchronize(model_path) do
          before = unit_states
          result = yield
          entry = store(label, before, unit_states)
          [result, entry]
        end
      end

      def entries
        state = read_state
        { undo: state.fetch('undo').reverse.map { summary(_1) }, redo: state.fetch('redo').reverse.map { summary(_1) } }
      end

      def undo = move(from: 'undo', to: 'redo', restore: 'before', expect: 'after')
      def redo = move(from: 'redo', to: 'undo', restore: 'after', expect: 'before')

      private

      def unit_states
        mpr = IO::MprFile.open(model_path, readonly: true, apply_studio_compatibility: false)
        mpr.all_units.to_h do |unit|
          [unit.fetch('UnitID'), { container: unit.fetch('ContainerID'), containment: unit.fetch('ContainmentName'),
                                   bytes: mpr.content_bytes(unit).to_s.b }]
        end
      ensure
        mpr&.close
      end

      def store(label, before, after)
        changes = (before.keys | after.keys).sort.filter_map do |unit_id|
          old = before[unit_id]
          new = after[unit_id]
          next if old && new && old[:bytes] == new[:bytes] && old.except(:bytes) == new.except(:bytes)

          { unit_id:, kind: if old.nil?
                              'added'
                            else
                              new.nil? ? 'removed' : 'changed'
                            end,
            before: old, after: new }
        end
        return if changes.empty?

        id = "#{Time.now.utc.strftime('%Y%m%dT%H%M%S%6N')}-#{SecureRandom.hex(4)}"
        write_entry(id, label, changes)
        state = read_state
        state['undo'] << id
        state['redo'].each { FileUtils.rm_rf(entry_path(_1)) }
        state['redo'] = []
        state['undo'].shift([state['undo'].length - LIMIT, 0].max).each { FileUtils.rm_rf(entry_path(_1)) }
        write_state(state)
        summary(id)
      end

      def write_entry(id, label, changes)
        path = entry_path(id)
        FileUtils.mkdir_p(path, mode: 0o700)
        manifest = changes.map do |change|
          %i[before after].each do |side|
            File.binwrite(File.join(path, "#{change[:unit_id]}.#{side}.bson"), change[side][:bytes]) if change[side]
          end
          { unit_id: change[:unit_id], kind: change[:kind],
            before: change[:before] && describe(change[:before]), after: change[:after] && describe(change[:after]) }
        end
        File.write(File.join(path, 'manifest.json'),
                   JSON.generate({ id:, label:, created_at: Time.now.utc.iso8601, changes: manifest }))
      end

      def describe(state)
        { container: state[:container], containment: state[:containment],
          sha256: Digest::SHA256.hexdigest(state[:bytes]) }
      end

      def move(from:, to:, restore:, expect:)
        WriteLock.synchronize(model_path) do
          state = read_state
          id = state.fetch(from).last
          raise ArgumentError, "nothing to #{from}" unless id

          manifest = read_manifest(id)
          apply(id, manifest, restore:, expect:)
          state[from].pop
          state[to] << id
          write_state(state)
          summary(id).merge(direction: from)
        end
      end

      def apply(id, manifest, restore:, expect:)
        current = unit_states
        manifest.fetch('changes').each do |change|
          expected = change[expect]
          actual = current[change['unit_id']]
          matches = if expected.nil? then actual.nil?
                    else actual && Digest::SHA256.hexdigest(actual[:bytes]) == expected['sha256']
                    end
          next if matches

          raise Conflict, "#{change['unit_id']} changed after this edit; undo would overwrite newer work"
        end
        mpr = IO::MprFile.open(model_path, readonly: false, apply_studio_compatibility: false)
        mpr.transaction do
          manifest.fetch('changes').each do |change|
            target = change[restore]
            unit_id = change['unit_id']
            if target.nil?
              mpr.delete_unit(unit_id)
            else
              bytes = File.binread(File.join(entry_path(id), "#{unit_id}.#{restore}.bson"))
              if current.key?(unit_id)
                mpr.relocate_unit(unit_id, container_uuid: target['container'], containment_name: target['containment'])
                mpr.update_unit_bytes(unit_id, bytes)
              else
                mpr.insert_unit_bytes(unit_uuid: unit_id, container_uuid: target['container'],
                                      containment_name: target['containment'], bson_bytes: bytes)
              end
            end
          end
        end
      ensure
        mpr&.close
      end

      def summary(id)
        manifest = read_manifest(id)
        { id:, label: manifest.fetch('label'), created_at: manifest.fetch('created_at'),
          units: manifest.fetch('changes').map { _1.slice('unit_id', 'kind') } }
      end

      def entry_path(id) = File.join(directory, 'entries', id)
      def state_path = File.join(directory, 'state.json')

      def read_manifest(id) = JSON.parse(File.read(File.join(entry_path(id), 'manifest.json')))

      def read_state
        return { 'undo' => [], 'redo' => [] } unless File.file?(state_path)

        JSON.parse(File.read(state_path))
      end

      def write_state(state)
        FileUtils.mkdir_p(directory, mode: 0o700)
        temporary = "#{state_path}.#{SecureRandom.hex(6)}.tmp"
        File.write(temporary, JSON.generate(state))
        File.rename(temporary, state_path)
      end
    end
  end
end
# rubocop:enable Metrics
