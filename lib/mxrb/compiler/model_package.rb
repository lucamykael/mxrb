# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module Mxrb
  module Compiler
    # Mendix model.mdp is an ordered stream of BSON documents without a
    # container header. Each document carries its own int32 BSON length.
    class ModelPackage
      Entry = Data.define(:offset, :size, :document) do
        def id = IO::BsonCodec.extract_id(document['$ID'])
        def type = document['$Type'].to_s
      end

      attr_reader :entries

      def self.read(path)
        bytes = File.binread(path)
        new(parse(bytes, path))
      end

      def self.empty = new([].freeze)
      def self.decode(bytes, label = 'model.mdp') = new(parse(bytes, label))

      def self.from_documents(documents)
        new([].freeze).then do |package|
          documents.reduce(package) { |result, document| result.with_appended(document) }
        end
      end

      def self.parse(bytes, label = 'model.mdp')
        entries = []
        offset = 0
        while offset < bytes.bytesize
          entry = parse_entry(bytes, offset, label)
          entries << entry
          offset += entry.size
        end
        entries.freeze
      rescue SerializationError => e
        raise CompilationError, "#{label}: #{e.message}"
      end
      private_class_method :parse

      def self.parse_entry(bytes, offset, label)
        size = document_size(bytes, offset, label)
        document = IO::BsonCodec.parse(bytes.byteslice(offset, size))
        Entry.new(offset:, size:, document:)
      end
      private_class_method :parse_entry

      def self.document_size(bytes, offset, label)
        remaining = bytes.bytesize - offset
        raise CompilationError, "#{label}: truncated BSON length at byte #{offset}" if remaining < 4

        size = bytes.byteslice(offset, 4).unpack1('l<')
        return size if size.between?(5, remaining)

        raise CompilationError, "#{label}: invalid BSON size #{size} at byte #{offset}"
      end
      private_class_method :document_size

      def initialize(entries)
        @entries = entries
      end

      def documents = entries.map(&:document)
      def types = entries.map(&:type).tally.freeze
      def find(id) = entries.find { _1.id == id }

      def replace(id, document)
        index = entries.index { _1.id == id }
        raise CompilationError, "model document #{id} not found" unless index

        updated = entries.map.with_index do |entry, position|
          position == index ? Entry.new(offset: 0, size: 0, document:) : entry
        end
        self.class.new(reindex(updated))
      end

      def upsert(document)
        id = IO::BsonCodec.extract_id(document['$ID'])
        raise CompilationError, 'model document has no $ID' unless id
        return replace(id, document) if find(id)

        self.class.new(reindex(entries + [Entry.new(offset: 0, size: 0, document:)]))
      end

      def with_appended(document)
        self.class.new(reindex(entries + [Entry.new(offset: 0, size: 0, document:)]))
      end

      def write(path)
        output = File.expand_path(path)
        FileUtils.mkdir_p(File.dirname(output))
        Dir.mktmpdir('mxrb-model-', File.dirname(output)) do |directory|
          temporary = File.join(directory, 'model.mdp')
          File.binwrite(temporary, entries.map { IO::BsonCodec.serialize(_1.document) }.join)
          FileUtils.mv(temporary, output, force: true)
        end
        output
      end

      private

      def reindex(source)
        offset = 0
        source.map do |entry|
          size = IO::BsonCodec.serialize(entry.document).bytesize
          Entry.new(offset:, size:, document: entry.document).tap { offset += size }
        end.freeze
      end
    end
  end
end
