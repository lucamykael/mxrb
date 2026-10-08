# frozen_string_literal: true

require 'digest'
require 'zip'

module Mxrb
  module RubyApp
    # Reads verified, project-owned widget code; no vendor bundle is distributed by MXRB.
    module KnownFeedbackWidget
      ENTRY = 'SprintrFeedbackWidget/SprintrFeedback.mjs'
      HASHES = %w[
        4ab4d672dccdbe8336ee55071f37aab1bd7689c890fa0f56f9a1ffbb60e06619
        f8a1af46b2e7da3b43d93a45e82338b835bdd9ab1dfc2a0d3fb2e485af7f6c89
        a1821880941bbabfb4a626484ebacd813d7dbe3e63c91a9518db528d9706e8e8
      ].freeze

      module_function

      def source(directory)
        Dir.glob(File.join(directory, 'widgets', '*.mpk')).sort.each do |path|
          contents = read(path)
          return contents if contents
        end
        nil
      end

      def read(path)
        Zip::File.open(path) do |archive|
          entry = archive.find_entry(ENTRY)
          license = archive.find_entry('LICENSE')
          next unless entry && license

          bundle = entry.get_input_stream.read
          next unless HASHES.include?(Digest::SHA256.hexdigest(bundle))

          { bundle:, license: license.get_input_stream.read }
        end
      rescue Zip::Error
        nil
      end
    end
  end
end
