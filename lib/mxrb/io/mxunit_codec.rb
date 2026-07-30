# frozen_string_literal: true

require "fileutils"
require_relative "bson_codec"

module Mxrb
  module IO
    # Storage adapter for MPR v2 unit files.
    #
    # Mendix currently stores the serialized unit payload outside SQLite.  The
    # payload is kept opaque here: known BSON payloads can be decoded, while
    # unknown/newer encodings fail explicitly instead of being overwritten.
    module MxunitCodec
      class UnsupportedFormat < SerializationError; end

      def self.path_for(contents_dir, uuid)
        hex = uuid.delete("-").downcase
        File.join(contents_dir, hex[0, 2], hex[2, 2], "#{uuid.downcase}.mxunit")
      end

      def self.read(path)
        bytes = File.binread(path)
        BsonCodec.parse(bytes)
      rescue SerializationError => e
        raise UnsupportedFormat, "#{path}: unsupported .mxunit encoding (#{e.message})"
      end

      def self.serialize(doc)
        BsonCodec.serialize(doc)
      end

      def self.write_atomic(path, bytes)
        FileUtils.mkdir_p(File.dirname(path))
        temporary = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
        File.binwrite(temporary, bytes)
        File.rename(temporary, path)
      ensure
        FileUtils.rm_f(temporary) if temporary
      end
    end
  end
end
