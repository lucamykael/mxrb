# frozen_string_literal: true

require 'digest'

module Mxrb
  module RubyApp
    # Selects TypeScript adapters only for verified web action implementations.
    module KnownJavaScriptActions
      SOURCES = {
        'JS_isStrictMode' =>
          '87da5aef414593bd793d95a0139efa8257f922fff8f92255a934771d2767d104',
        'JS_PopulateFeedbackMetadata' =>
          '9a6c9fd171c55282508a22638996ac9b6461093592b1815c470f76cd889e4654',
        'JS_GetFeedbackStorageObject' =>
          'a93f11149c06faff956cf6d7540193e0a307f20bc93d697af409542eab3defa3',
        'GetStorageItemObject' =>
          '5a4d423f7e867940bf74d5bdbf8dda617c3eb1f475000d44afba383ae56c219c',
        'JS_SetFeedbackStorageObject' =>
          '698ec24426711a1733bc9cb6984683011db137d808c2642a88b1c07119f2798c',
        'SetStorageItemObject' =>
          '8b1d18178290f7325e8acc20d44db26497c94bf98d39f898569fc95541cbaa50',
        'JS_GetSingleLocalStorageObjectItem' =>
          '73f3fba8544c003aedca4f34c1fbdce337facffa2e332f416e78ef038e93af77',
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
          '8bdf42c7f08e7997d7ff59083eae638b271b662b6c1b9a8ff290c35d9ff10350',
        'GetStorageItemString' =>
          '36a583f85a4f31d92dab90fc95a710f3862d0bb56ca96daaa4fa6a4f871e53e0',
        'SetStorageItemString' =>
          'fba61d01cec648eb96fd90d45792d2aa81deaee24a201ca4830d03e36fa44ff4',
        'RemoveStorageItem' =>
          '815e0e72c30c383855cae5f48504962e889df5efebd87c63bdc37ba0419c5f3b',
        'StorageItemExists' =>
          'f87e5b1da5009611020462b1652c1add271334c7d864e2a492079552dfba58e7',
        'ClearLocalStorage' =>
          '6d40ff267ad85c52173500c81fd49fabd0a1413d024e2bcc7ebc8d843f424bca'
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
