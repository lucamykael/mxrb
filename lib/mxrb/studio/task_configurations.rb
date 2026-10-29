# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'shellwords'
require 'time'
require_relative 'catalog'
require_relative 'files'
require_relative 'write_lock'

module Mxrb
  module Studio
    # Named MXRB task configurations saved per project, like run
    # configurations in other IDEs. They store a catalog command, its field
    # values and extra arguments; workspace placeholders such as {mpr} stay
    # unresolved so a configuration keeps working after the project moves.
    class TaskConfigurations
      MAXIMUM = 200
      MAXIMUM_NAME = 120

      def initialize(project, state_root:, catalog: Catalog.new)
        raise ArgumentError, 'project must be a path' unless project.is_a?(String) && !project.empty?

        @project = File.realpath(project)
        @state_root = File.expand_path(state_root)
        @catalog = catalog
      end

      def list = { project: @project, configurations: read.fetch('configurations') }

      def save(configuration) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        entry = validate(configuration)
        synchronize do
          document = read
          items = document.fetch('configurations')
          existing = items.index { _1['id'] == entry['id'] }
          if items.any? { _1['name'].casecmp?(entry['name']) && _1['id'] != entry['id'] }
            raise Conflict, "a task named #{entry['name']} already exists"
          end

          now = Time.now.utc.iso8601
          if existing
            entry['created_at'] = items[existing]['created_at']
            items[existing] = entry.merge('updated_at' => now)
          else
            raise ArgumentError, "at most #{MAXIMUM} saved tasks per project" if items.size >= MAXIMUM

            items << entry.merge('created_at' => now, 'updated_at' => now)
          end
          write(document)
          items.find { _1['id'] == entry['id'] }
        end
      end

      def delete(id)
        synchronize do
          document = read
          before = document.fetch('configurations').size
          document['configurations'].reject! { _1['id'] == id }
          raise ArgumentError, 'unknown saved task' if document['configurations'].size == before

          write(document)
          { id:, deleted: true }
        end
      end

      def path = File.join(@state_root, 'task-configurations', "#{Digest::SHA256.hexdigest(@project)}.json")

      private

      def validate(configuration) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        raise ArgumentError, 'configuration must be an object' unless configuration.is_a?(Hash)

        name = configuration['name'].to_s.strip
        raise ArgumentError, 'name the saved task' if name.empty?
        raise ArgumentError, "task name exceeds #{MAXIMUM_NAME} characters" if name.length > MAXIMUM_NAME

        command = configuration['command_id']
        values = configuration.fetch('values', {})
        extra = configuration.fetch('extra', '')
        raise ArgumentError, 'values must be an object' unless values.is_a?(Hash)
        unless values.values.all? { [String, TrueClass, FalseClass].include?(_1.class) }
          raise ArgumentError, 'values must be text or booleans'
        end
        raise ArgumentError, 'extra arguments must be text' unless extra.is_a?(String)

        # Validates the command, field names, choices and extra quoting now
        # rather than when the saved task is run.
        @catalog.arguments(command, values.reject { _2 == '' }, extra: Shellwords.split(extra))
        id = configuration['id']
        id = SecureRandom.uuid unless id.is_a?(String) && id.match?(/\A[0-9a-f-]{36}\z/)
        { 'id' => id, 'name' => name, 'command_id' => command, 'values' => values, 'extra' => extra }
      end

      def read
        value = File.file?(path) ? JSON.parse(File.read(path)) : nil
        return value if value.is_a?(Hash) && value['configurations'].is_a?(Array)

        { 'version' => 1, 'project' => @project, 'configurations' => [] }
      rescue JSON::ParserError
        raise Conflict, "saved tasks file is corrupt: #{path}"
      end

      def write(document)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        temporary = "#{path}.#{SecureRandom.hex(8)}.tmp"
        File.write(temporary, "#{JSON.pretty_generate(document)}\n", perm: 0o600)
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary) if temporary
      end

      def synchronize(&) = WriteLock.synchronize(path, &)
    end
  end
end
