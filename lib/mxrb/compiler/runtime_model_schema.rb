# frozen_string_literal: true

require 'json'

module Mxrb
  module Compiler
    # Learns ordered Runtime BSON fields and existing compiled values from model.mdp.
    class RuntimeModelSchema
      DEFAULT_FIELDS = JSON.parse(
        File.read(File.join(__dir__, 'schemas', 'runtime-11.json'))
      ).transform_values(&:freeze).freeze
      AUDITED_FIELDS = Dir[File.join(__dir__, 'schemas', 'runtime-*.json')].sort.reduce(DEFAULT_FIELDS) do |all, path|
        all.merge(JSON.parse(File.read(path)).transform_values(&:freeze))
      end.freeze
      def self.builtin_fields(version)
        return DEFAULT_FIELDS unless version

        seed_version = SystemModelSeed.seed_version_for(version)
        path = schema_path(seed_version)
        return DEFAULT_FIELDS unless path

        versioned = JSON.parse(File.read(path)).transform_values(&:freeze)
        AUDITED_FIELDS.merge(versioned).freeze
      end

      def self.schema_path(version)
        exact = File.join(__dir__, 'schemas', "runtime-#{version}.json")
        major = File.join(__dir__, 'schemas', "runtime-#{version.to_s.split('.').first}.json")
        [exact, major].find { File.file?(_1) }
      end

      def initialize(package, version: nil)
        @by_id = {}
        @by_qualified_name = {}
        @fields = Hash.new { |hash, key| hash[key] = [] }
        @builtin_fields = self.class.builtin_fields(version)
        @versioned_fields = versioned_fields(version)
        package.documents.each { index(_1) }
      end

      def counterpart(source)
        @by_id[IO::BsonCodec.extract_id(source['$ID'])]
      end

      def counterpart_id(id) = @by_id[IO::BsonCodec.extract_id(id)]
      def named(qualified_name) = @by_qualified_name[qualified_name]

      def fields_for(source) # rubocop:disable Metrics/AbcSize
        return @versioned_fields.fetch(source['$Type']) if @versioned_fields.key?(source['$Type'])

        existing = counterpart(source)
        return existing.keys if existing && existing['$Type'] == source['$Type']
        return @builtin_fields.fetch(source['$Type']) if @builtin_fields.key?(source['$Type'])

        candidates = @fields.fetch(source['$Type'], [])
        raise CompilationError, "no Runtime schema for #{source['$Type']}" if candidates.empty?

        candidates.max_by(&:length)
      end # rubocop:enable Metrics/AbcSize

      private

      def versioned_fields(version)
        return {} unless version

        seed_version = SystemModelSeed.seed_version_for(version)
        path = self.class.schema_path(seed_version)
        path ? JSON.parse(File.read(path)) : {}
      end

      def index(value)
        case value
        when Hash then index_document(value)
        when Array then value.each { index(_1) }
        end
      end

      def index_document(document)
        type = document['$Type']
        if type
          @fields[type] << document.keys unless @fields[type].include?(document.keys)
          id = IO::BsonCodec.extract_id(document['$ID'])
          @by_id[id] = document if id
          @by_qualified_name[document['QualifiedName']] = document if document['QualifiedName']
        end
        document.each_value { index(_1) }
      end
    end
  end
end
