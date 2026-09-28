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
          documents.map { NavigationProfile.new(_1) }.freeze
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

    # Typed view of one navigation profile, including recursive menu items.
    class NavigationProfile
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
          items: menu_items
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
          caption: text_translations(item['Caption']),
          page: reference(action.dig('FormSettings', 'Form')),
          microflow: reference(action.dig('MicroflowSettings', 'Microflow')),
          icon: item.dig('Icon', 'Code'),
          items: items(item['Items']).map { navigation_item(_1) }
        }.compact
      end
    end
  end
end
