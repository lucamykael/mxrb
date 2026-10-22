# frozen_string_literal: true

require 'digest'

module Mxrb
  module RubyApp
    # Selects TypeScript adapters only for verified web action implementations.
    module KnownJavaScriptActions # rubocop:disable Metrics/ModuleLength
      METADATA_VARIANTS = {
        '9a6c9fd171c55282508a22638996ac9b6461093592b1815c470f76cd889e4654' => 'legacy',
        '70b119c394b738ac372d63bd8acee372a9892fc863ab47ee6791c7db869f0daa' => 'screen',
        '84a491512704e2cc2911f5e066cd6ecb9c54a3d946ebe2d32bf91c1e78d74db0' => 'viewport'
      }.freeze

      SOURCES = {
        'JS_ToggleFeedbackScreenshotWidget' =>
          'e9540c12c5b114d110d8f3637955690bb70c98d93b25809194c2e3aa5dd732db',
        'JS_ToggleFeedbackAnnotateWidget' =>
          '76b3ca00c5967e95640f5951e87bcf3c3e04211eb2a141fad645646504803524',
        'JS_isStrictMode' =>
          '87da5aef414593bd793d95a0139efa8257f922fff8f92255a934771d2767d104',
        'JS_PopulateFeedbackMetadata' => METADATA_VARIANTS.keys.freeze,
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
          'c87cccec1fb9063dfdf2eff5d4427944672b710ef47d64f4eaf83d0a574c1053',
        'JS_UploadAndConvertToFileBlobURL' =>
          'd8f245699ae0f2e2ad443c43bb9038ba82f0c9f2ce480f384c9a8c4df43d51f8',
        'JS_RevokeUploadedFileFromMemory' =>
          '99a113e34c9803c059762d6533bc0516c26bc960612ee002bf47e0ddd80ac294',
        'JS_Recalculate_MendixModal_Error_PopUp_Zindex' =>
          '9b447afb3344dcc200b342ed7d0c22b0772008bced983054650a622ea0996514'
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
          '6d40ff267ad85c52173500c81fd49fabd0a1413d024e2bcc7ebc8d843f424bca',
        'SignIn' => %w[
          1d4098cc6c5084632b16d56c7b35a33bd36b2931e3aa6cd0fd6cb609ee7e3808
          43f283dc9452e421b24b1081a3930cbfa1ba2c715046955ee736e17d0f19895b
          2c4128b496b918feaf8b374e9d343378d24d2558f5da2fd4beaa810d50ec31a9
        ].freeze
      }.freeze

      # Native Mobile Resources actions, whose React Native implementation the
      # generated frontend replaces with a browser adapter.
      NATIVE_SOURCES = {
        'BiometricAuthentication' =>
          '21586c26c6168a990f091214d3337ced8a20262aeb91eec2721769627aa71dbf',
        'CancelAllScheduledNotifications' =>
          '859909eba24ced38efd9735f8e5a57f759ca8846555a39cd8bf02f8bb5fe6ab2',
        'CancelScheduledNotification' =>
          '34f100c7d9908621ac3587b1a1cfe3c3eaa4dad2adbf8c304bfd2f92c03061d7',
        'ChangeStatusBar' =>
          '5b5ea466b220d49d541600e9e35df811440ed475ade205a139d4821eeb529b41',
        'CheckGenericPermission' =>
          'b2c85b5ab202b0344b75795517d79fbc85244f2188ac5cf0b9cfc917df10ad5e',
        'ClearAllDeliveredNotifications' =>
          '51fb267032d3f29ac7cf1c9d523a1b060cbf8cfe44822af41d7f06e6bd1ee45b',
        'DisplayNotification' =>
          '2ca399395d5f1f0bf6f497d4d83510cba537a2a42c09ab85b46e2f5c944d7b77',
        'DownloadFile' =>
          'c70d5f4d461306b60cfe112c7956b16732c89f2b68c874ae135257c2b6b9b23b',
        'GetClipboardContent' =>
          '60bf28f58cc349a61484ac5460ee4b7a3be5fda85af5d9ca09d88fb2eef8b05a',
        'GetDeviceInfo' =>
          'aae537e7333159bd8605f23aef76dd1ee5d00267020fa5d950b7b2b6a4b9f129',
        'GetPushNotificationToken' =>
          'b21cdd7bd70e929cc8500564b1da20913598de0d787344c2d6386427002974bd',
        'HasNotificationPermission' =>
          '4d93050530cf290706ef1c7c21a88f290d5ece35911784f12569a6a24c6dd06d',
        'HideKeyboard' =>
          '29ef7062e7ccb001e3e79770c52568b7e328710ad9423e03f5e3b967dd8c5a1b',
        'IsBiometricAuthenticationSupported' =>
          '1b2b5560098f20ddb24e2f312c119f636accc3fa7c5082842948bdf05ce0d402',
        'IsCellularConnection' =>
          '1901f0f57c8cca420fdd31d3eaa67ea6105e81da54e376b5e64df278d7d205ee',
        'IsConnected' =>
          '5190f1b3d4d14dcb725534b94f125620636a169cf9c7cbcaa9c680934210c17e',
        'IsWifiConnection' =>
          '517d392900e2e3983f20ac342e997cac839967a0d767d6413cb2313aff552bc4',
        'OpenInAppBrowser' =>
          '4f711d4f9fc2b6d91298ecb532fd05b92bf6edf45bd91f1065a2a64fbc016467',
        'ParseUrlToObject' =>
          '4ee55af595b8576d006eff6a78d2393b16db5e9418544b9994a3a2fbc0df0514',
        'PlaySound' =>
          '9f06519208578a8009513b6b16cbcbd350f0205adc1c8c2007cf054acce7c8e4',
        'RegisterDeepLink' =>
          'ddd1f7bf5ea29866ca87563b7a4a29464c4f3ae5257435fc9a9df6ad50f4a2a3',
        'RequestGenericPermission' =>
          'cb8fca6509fd279abc924564ae4c2878f7ee805da3caaf5ad3787005e631f87f',
        'RequestNotificationPermission' =>
          '1cd2d7abd01ddab1492aede1b209b7771e10ab00ec71bc0f2b6a71f94c030c70',
        'SaveToPictureLibrary' =>
          '08130539173d978d0ddc5618236584c2388674513a74ee4d8adc3624f3966dfb',
        'ScheduleNotification' =>
          '99012b95f49fdf9ad22c53153f5cf868f69987eba193c71e42216ef733d5ad8a',
        'SetBadgeNumber' =>
          'b68e3b1d71c802cfdeb345b357833e79cfff63e2d3cf805855e7f0bec9b79b42',
        'SetClipboardContent' =>
          '94ee27778e18efa20b9c49cdbf9c6b28906bcde9af9a12414fb664571bd29cbf',
        'TakePicture' =>
          '0f523f9a00149021a26475a0f9aa167566bd3330105c31e0ba7a434d5ad73ca2',
        'TakePictureAdvanced' =>
          'b123a7d8568199442d8afbcadf8297a191cad5c60f1d44ade907fe2d1ab89854',
        'Vibrate' =>
          '7470650092e7eae855d84500fe087fe64bd47406455ef65e985ddddc0355adc9'
      }.freeze

      MODULES = {
        'FeedbackModule' => [SOURCES, 'feedbackmodule'],
        'NanoflowCommons' => [COMMONS_SOURCES, 'nanoflowcommons'],
        'NativeMobileResources' => [NATIVE_SOURCES, 'nativemobileresources']
      }.freeze

      module_function

      def matching(directory, sources: SOURCES, module_name: 'feedbackmodule')
        sources.filter_map do |name, digest|
          path = File.join(directory, 'javascriptsource', module_name, 'actions', "#{name}.js")
          next unless File.file?(path)
          next unless Array(digest).include?(Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n")))

          name
        end
      end

      # The verified actions of every adapted module, qualified as nanoflows call them.
      def adapted(directory)
        MODULES.flat_map do |namespace, (sources, module_name)|
          matching(directory, sources:, module_name:).map { "#{namespace}.#{_1}" }
        end
      end

      def metadata_variant(directory)
        path = File.join(directory, 'javascriptsource/feedbackmodule/actions/JS_PopulateFeedbackMetadata.js')
        return unless File.file?(path)

        METADATA_VARIANTS[Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n"))]
      end
    end
  end
end
