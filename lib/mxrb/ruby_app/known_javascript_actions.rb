# frozen_string_literal: true

require 'digest'

module Mxrb
  module RubyApp
    # Selects TypeScript adapters only for verified web action implementations.
    module KnownJavaScriptActions
      SOURCES = {
        'JS_GetSingleStringLocalStorageObjectItem' =>
          'b7a2183846a918ace84441b0e8788567b8b7acc030ecad888ed50996772a7888',
        'JS_GetShowEmailBooleanLocalStorageObjectItem' =>
          '0a88d00d8cc90e6256c51ab9dcb5189aa1ad13f6f532d19974866abbab9c7fab',
        'JS_SetSingleLocalStorageObjectItem' =>
          'c87cccec1fb9063dfdf2eff5d4427944672b710ef47d64f4eaf83d0a574c1053'
      }.freeze

      module_function

      def matching(directory)
        SOURCES.filter_map do |name, digest|
          path = File.join(directory, 'javascriptsource', 'feedbackmodule', 'actions', "#{name}.js")
          next unless File.file?(path)
          next unless Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n")) == digest

          name
        end
      end
    end
  end
end
