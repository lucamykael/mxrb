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

      COMMONS_SOURCES = {
        'Base64Encode' =>
          '591cb49897e8c7501553fcef17c6281eea4f3824e9d86d241fa78c079dd60c51',
        'Base64Decode' =>
          'c6388aa9b715a4897ac79f25a1b4ba446d3b5e8548582b7deb6cfdd9b215c42d',
        'GetGuid' =>
          '2f9abccdfa7d3290a78c1828d7d8cfbf56db9238631dd64b2ba9c6d6d7803e9b',
        'GetPlatform' =>
          '99f9043fe12c66c228971c213fbb520f9ecb7b4f89515cc46b27e93acd622780',
        'FindObjectWithGUID' =>
          '8bdf42c7f08e7997d7ff59083eae638b271b662b6c1b9a8ff290c35d9ff10350'
      }.freeze

      module_function

      def matching(directory, sources: SOURCES, module_name: 'feedbackmodule')
        sources.filter_map do |name, digest|
          path = File.join(directory, 'javascriptsource', module_name, 'actions', "#{name}.js")
          next unless File.file?(path)
          next unless Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n")) == digest

          name
        end
      end
    end
  end
end
