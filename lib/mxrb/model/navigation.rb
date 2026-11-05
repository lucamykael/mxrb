# frozen_string_literal: true

module Mxrb
  module Model
    # Typed reader for modern and legacy native Mendix navigation documents.
    class Navigation
      LEGACY_PROFILES = {
        'DesktopProfile' => 'Desktop',
        'TabletProfile' => 'Tablet',
        'PhoneProfile' => 'Phone',
        'OfflinePhoneProfile' => 'OfflinePhone',
        'HybridPhoneProfile6' => 'HybridPhone',
        'HybridTabletProfile6' => 'HybridTablet'
      }.freeze

      attr_reader :raw_document

      def initialize(raw_document)
        @raw_document = raw_document || {}
      end

      def profiles
        @profiles ||= begin
          modern = items(@raw_document['Profiles'])
          documents = modern.empty? ? legacy_profile_documents : modern
          documents.map do |document|
            next NativeNavigationProfile.new(document) if document['$Type'] == NativeNavigationProfile::TYPE

            NavigationProfile.new(document)
          end.freeze
        end
      end

      def empty? = @raw_document.empty?
      def to_h = { profiles: profiles.map(&:to_h) }

      private

      def items(value) = IO::BsonCodec.parse_array(value).fetch(:items)

      def legacy_profile_documents
        LEGACY_PROFILES.filter_map do |key, name|
          value = @raw_document[key]
          value.merge('Name' => value['Name'] || name) if value.is_a?(Hash)
        end
      end
    end

    # The entities a profile synchronizes to the device, as Studio Pro stores
    # them: the entity, its sync mode (None, NoneAndPreserveData or All), an
    # optional XPath constraint and the compatibility flag.
    module OfflineEntityConfigs
      SYNC_MODES = %w[None NoneAndPreserveData All].freeze

      # The stored sync mode for a DSL value such as :none_and_preserve_data.
      def self.sync_mode(value)
        mode = value.to_s.split('_').map(&:capitalize).join
        return mode if SYNC_MODES.include?(mode)

        raise ArgumentError, "unknown offline sync mode #{value.inspect}; use :none, :none_and_preserve_data or :all"
      end

      def offline_entities
        IO::BsonCodec.parse_array(@raw_document['OfflineEntityConfigs']).fetch(:items).grep(Hash)
                     .map { offline_entity(_1) }
      end

      private

      def offline_entity(config)
        entry = { entity: config['Entity'].to_s, sync_mode: config.fetch('SyncMode', 'None').to_s }
        entry[:constraint] = config['Constraint'].to_s unless config['Constraint'].to_s.empty?
        entry[:compatibility_mode] = true if config['CompatibilityMode'] == true
        entry
      end
    end

    # A navigation icon as Studio Pro stores it: a glyph code, an icon of a
    # collection or an image.
    module NavigationIcon
      private

      def icon(value)
        return unless value.is_a?(Hash)
        return { collection: value['Image'].to_s } if value['$Type'] == 'Forms$IconCollectionIcon'
        return { image: value['Image'].to_s } if value['$Type'] == 'Forms$ImageIcon'

        value['Code']
      end
    end

    # The settings of a menu item's action, leaving out what Studio Pro stores by default.
    module NavigationItemAction
      MICROFLOW_OPTIONS = {
        form_validations: %w[FormValidations All], progress_bar: %w[ProgressBar None],
        asynchronous: ['Asynchronous', false], use_all_pages: ['UseAllPages', false]
      }.freeze

      private

      def action_target(action)
        { page: reference(action.dig('FormSettings', 'Form')),
          microflow: reference(action.dig('MicroflowSettings', 'Microflow')) }
      end

      def action_options(action)
        options = action['DisabledDuringExecution'] == true ? { disabled_during_execution: true } : {}
        options.merge(page_options(action['FormSettings'])).merge(microflow_options(action['MicroflowSettings']))
      end

      def page_options(settings)
        return {} unless settings.is_a?(Hash)

        title = settings['TitleOverride'] || settings['FormTitle']
        { location: settings['Location'], title: (text_translations(title['Text'] || title) if title) }.compact
      end

      def microflow_options(settings)
        return {} unless settings.is_a?(Hash)

        MICROFLOW_OPTIONS.each_with_object(microflow_text_options(settings)) do |(key, (field, default)), values|
          values[key] = settings[field] unless settings[field].nil? || settings[field] == default
        end
      end

      def microflow_text_options(settings)
        message, confirmation = settings.values_at('ProgressMessage', 'ConfirmationInfo')
        { progress_message: (text_translations(message) if message),
          confirmation: (confirmation_options(confirmation) if confirmation) }.compact
      end

      def confirmation_options(confirmation)
        { question: 'Question', proceed: 'ProceedButtonCaption', cancel: 'CancelButtonCaption' }
          .transform_values { text_translations(confirmation[_1]) }
      end
    end

    # Typed view of one navigation profile, including recursive menu items.
    class NavigationProfile
      include OfflineEntityConfigs
      include NavigationIcon
      include NavigationItemAction

      attr_reader :raw_document

      def initialize(raw_document)
        @raw_document = raw_document
      end

      def name = @raw_document['Name'].to_s
      def kind = @raw_document['Kind'].to_s

      def enabled = optional_field('Enabled')
      def enabled? = enabled.nil? || enabled == true

      def offline? = kind.match?(/offline/i) || @raw_document['OfflineEnabled6'] == true ||
        name.match?(/offline/i)

      def offline_enabled = optional_field('OfflineEnabled6')
      def throw_partial_sync_error = optional_field('ThrowPartialSyncError')

      def app_icon = @raw_document['AppIcon']

      def app_title
        translations = text_translations(@raw_document['AppTitle'])
        legacy = @raw_document['ApplicationTitle'].to_s
        translations.empty? && !legacy.empty? ? { 'en_US' => legacy } : translations
      end

      def home_page = reference(@raw_document.dig('HomePage', 'Page'))
      def home_microflow = reference(@raw_document.dig('HomePage', 'Microflow'))
      def sign_in_page = reference(@raw_document.dig('LoginPageSettings', 'Form'))
      def sign_in_location = @raw_document.dig('LoginPageSettings', 'Location')

      def sign_in_title
        settings = @raw_document['LoginPageSettings'] || {}
        text_template_translations(settings['TitleOverride'] || settings['FormTitle'])
      end

      def not_found_page = reference(@raw_document.dig('NotFoundHomepage', 'Page'))
      def not_found_microflow = reference(@raw_document.dig('NotFoundHomepage', 'Microflow'))

      def role_homes
        items(@raw_document['HomeItems'] || @raw_document['RoleBasedHomePages']).map do |home|
          {
            role: reference(home['UserRole']),
            page: reference(home['Page']),
            microflow: reference(home['Microflow'])
          }.compact
        end
      end

      def menu_items
        collection = @raw_document['Menu'] || @raw_document['MenuItemCollection']
        items(collection&.fetch('Items', nil)).map { navigation_item(_1) }
      end

      def to_h
        base_profile.merge(
          offline: offline?,
          app_icon:,
          app_title:,
          items: menu_items,
          offline_entities:
        )
      end

      private

      def base_profile
        {
          name:,
          kind:,
          home_page:,
          home_microflow:,
          sign_in_page:,
          role_homes:
        }.merge(profile_settings)
      end

      def profile_settings
        {
          sign_in_title:,
          sign_in_location:,
          not_found_page:,
          not_found_microflow:,
          enabled:,
          offline_enabled:,
          throw_partial_sync_error:
        }
      end

      def items(value) = IO::BsonCodec.parse_array(value).fetch(:items)

      def reference(value)
        result = IO::BsonCodec.extract_id(value)
        result.to_s.empty? ? nil : result
      end

      def optional_field(name) = @raw_document.key?(name) ? @raw_document[name] : nil

      def text_translations(text)
        return {} unless text.is_a?(Hash)

        translations = items(text['Translations'] || text['Items']).to_h do |translation|
          [translation['LanguageCode'].to_s, translation['Text'].to_s]
        end
        translations.reject { |_locale, value| value.empty? }
      end

      def text_template_translations(template)
        return {} unless template.is_a?(Hash)

        text_translations(template['Text'])
      end

      def navigation_item(item)
        action = item['Action'].is_a?(Hash) ? item['Action'] : {}
        {
          caption: text_translations(item['Caption']), **action_target(action), icon: icon(item['Icon']),
          items: items(item['Items']).map { navigation_item(_1) }
        }.compact.merge(action_options(action))
      end
    end

    # Typed view of a native mobile profile: a native home page, role-based
    # home pages and bottom bar items instead of a web menu.
    class NativeNavigationProfile
      include OfflineEntityConfigs
      include NavigationIcon

      TYPE = 'Navigation$NativeNavigationProfile'
      SETTINGS = {
        ota_enabled: 'OtaEnabled', logging_enabled: 'LoggingEnabled',
        encryption_db_enabled: 'EncryptionDbEnabled',
        local_file_encryption_enabled: 'LocalFileEncryptionEnabled',
        session_cookie_encryption_enabled: 'SessionCookieEncryptionEnabled',
        screen_navigation_transition: 'ScreenNavigationTransition',
        popup_navigation_transition: 'PopupNavigationTransition',
        apply_screen_transition: 'ApplyScreenTransition', network_timeout_ms: 'NetworkTimeoutMs',
        native_navigation_enabled: 'NativeNavigationEnabled'
      }.freeze
      SETTING_DEFAULTS = {
        ota_enabled: false, logging_enabled: false, encryption_db_enabled: false,
        local_file_encryption_enabled: false, session_cookie_encryption_enabled: false,
        screen_navigation_transition: 'SystemDefault', popup_navigation_transition: 'SystemDefault',
        apply_screen_transition: false, network_timeout_ms: 60_000, native_navigation_enabled: false
      }.freeze

      attr_reader :raw_document

      def initialize(raw_document)
        @raw_document = raw_document
      end

      def name = @raw_document['Name'].to_s
      def kind = 'Native'
      def home_page = reference(@raw_document.dig('NativeHomePage', 'HomePagePage'))
      def home_nanoflow = reference(@raw_document.dig('NativeHomePage', 'HomePageNanoflow'))
      def menu_items = []

      def role_homes
        items(@raw_document['RoleBasedNativeHomePages']).map do |home|
          {
            role: reference(home['UserRole']), page: reference(home['HomePagePage']),
            nanoflow: reference(home['HomePageNanoflow'])
          }.compact
        end
      end

      def bottom_bar_items
        items(@raw_document['BottomBarItems']).map do |item|
          {
            caption: caption_translations(item['Caption']), page: reference(item['Page']),
            icon: icon(item['Icon'])
          }.compact
        end
      end

      def settings
        SETTINGS.each_with_object({}) do |(key, field), values|
          values[key] = @raw_document[field] if @raw_document.key?(field)
        end
      end

      def to_h
        {
          name:, kind:, home_page:, home_nanoflow:, role_homes:,
          throw_partial_sync_error: @raw_document['ThrowPartialSyncError'],
          bottom_bar: bottom_bar_items, settings:, offline_entities:
        }
      end

      private

      def items(value) = IO::BsonCodec.parse_array(value).fetch(:items)

      def reference(value)
        result = IO::BsonCodec.extract_id(value)
        result.to_s.empty? ? nil : result
      end

      def caption_translations(text)
        return {} unless text.is_a?(Hash)

        items(text['Items']).to_h { [_1['LanguageCode'].to_s, _1['Text'].to_s] }
      end
    end
  end
end
