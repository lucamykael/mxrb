# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Exact embedded schemas, without widget values or an executable MPR.
    module PluggableSchemas
      def self.path(root, identifier)
        File.join(root, '.mxrb', 'widget_schemas', "#{Digest::SHA256.hexdigest(identifier)}.bson")
      end

      def self.write(root, documents)
        documents.each do |identifier, widgets|
          destination = path(root, identifier)
          FileUtils.mkdir_p(File.dirname(destination))
          schemas = widgets.map { _1.slice('Name', 'Type') }
          File.binwrite(destination, IO::BsonCodec.serialize('Widgets' => schemas))
        end
      end

      def self.read(root, identifier)
        source = path(root, identifier)
        raise ValidationError, 'private widget schema snapshot is unavailable' unless File.file?(source)

        IO::BsonCodec.parse(File.binread(source)).fetch('Widgets')
      end
    end
  end
end
