# frozen_string_literal: true

module Mxrb
  module Runtime
    # The project languages the Runtime offers as System.Language objects. The
    # Runtime describes a language as "<language>, <country>" in English, as
    # Java's locale display names do (en_US is "English, United States").
    module Languages
      LANGUAGE_NAMES = {
        'ar' => 'Arabic', 'bg' => 'Bulgarian', 'ca' => 'Catalan', 'cs' => 'Czech', 'da' => 'Danish',
        'de' => 'German', 'el' => 'Greek', 'en' => 'English', 'es' => 'Spanish', 'et' => 'Estonian',
        'fi' => 'Finnish', 'fr' => 'French', 'he' => 'Hebrew', 'hi' => 'Hindi', 'hr' => 'Croatian',
        'hu' => 'Hungarian', 'id' => 'Indonesian', 'it' => 'Italian', 'ja' => 'Japanese', 'ko' => 'Korean',
        'lt' => 'Lithuanian', 'lv' => 'Latvian', 'ms' => 'Malay', 'nb' => 'Norwegian Bokmål', 'nl' => 'Dutch',
        'no' => 'Norwegian', 'pl' => 'Polish', 'pt' => 'Portuguese', 'ro' => 'Romanian', 'ru' => 'Russian',
        'sk' => 'Slovak', 'sl' => 'Slovenian', 'sr' => 'Serbian', 'sv' => 'Swedish', 'th' => 'Thai',
        'tr' => 'Turkish', 'uk' => 'Ukrainian', 'vi' => 'Vietnamese', 'zh' => 'Chinese'
      }.freeze
      COUNTRY_NAMES = {
        'AE' => 'United Arab Emirates', 'AR' => 'Argentina', 'AT' => 'Austria', 'AU' => 'Australia',
        'BE' => 'Belgium', 'BG' => 'Bulgaria', 'BR' => 'Brazil', 'CA' => 'Canada', 'CH' => 'Switzerland',
        'CL' => 'Chile', 'CN' => 'China', 'CO' => 'Colombia', 'CZ' => 'Czechia', 'DE' => 'Germany',
        'DK' => 'Denmark', 'EE' => 'Estonia', 'EG' => 'Egypt', 'ES' => 'Spain', 'FI' => 'Finland',
        'FR' => 'France', 'GB' => 'United Kingdom', 'GR' => 'Greece', 'HK' => 'Hong Kong SAR China',
        'HR' => 'Croatia', 'HU' => 'Hungary', 'ID' => 'Indonesia', 'IE' => 'Ireland', 'IL' => 'Israel',
        'IN' => 'India', 'IT' => 'Italy', 'JP' => 'Japan', 'KR' => 'South Korea', 'LT' => 'Lithuania',
        'LU' => 'Luxembourg', 'LV' => 'Latvia', 'MX' => 'Mexico', 'MY' => 'Malaysia', 'NL' => 'Netherlands',
        'NO' => 'Norway', 'NZ' => 'New Zealand', 'PE' => 'Peru', 'PH' => 'Philippines', 'PL' => 'Poland',
        'PT' => 'Portugal', 'RO' => 'Romania', 'RS' => 'Serbia', 'RU' => 'Russia', 'SA' => 'Saudi Arabia',
        'SE' => 'Sweden', 'SG' => 'Singapore', 'SI' => 'Slovenia', 'SK' => 'Slovakia', 'TH' => 'Thailand',
        'TR' => 'Türkiye', 'TW' => 'Taiwan', 'UA' => 'Ukraine', 'US' => 'United States', 'VN' => 'Vietnam',
        'ZA' => 'South Africa'
      }.freeze
      LANGUAGE = 'System.Language'

      module_function

      # { 'default' => code, 'codes' => [...] } from the project settings.
      def settings(project)
        return project.language_settings if project.respond_to?(:language_settings)

        languages = language_settings_document(project)
        return {} unless languages

        codes = IO::BsonCodec.parse_array(languages['Languages'])[:items].map { _1['Code'].to_s }
        { 'default' => languages['DefaultLanguageCode'].to_s, 'codes' => codes }
      end

      def language_settings_document(project)
        return unless project.respond_to?(:all_units)

        root = project.all_units.map { project.parse_bson(_1) }.find { _1['$Type'] == 'Settings$ProjectSettings' }
        parts = root ? IO::BsonCodec.parse_array(root['Settings'])[:items] : []
        parts.find { _1['$Type'] == 'Settings$LanguageSettings' }
      end

      def description(code)
        language, country = code.to_s.split('_', 2)
        name = LANGUAGE_NAMES.fetch(language.to_s, language.to_s)
        country ? "#{name}, #{COUNTRY_NAMES.fetch(country, country)}" : name
      end

      # Creates the System.Language object of every project language at startup
      # and keeps its description current; Code identifies the language.
      def synchronize(store, settings)
        codes = Array(settings['codes'])
        return if codes.empty?

        existing = store.retrieve(LANGUAGE)
        codes.each do |code|
          object = existing.find { _1.members['Code'] == code } || store.create(LANGUAGE)
          updates = { 'Code' => code, 'Description' => description(code) }
          update_language(store, object, updates)
        end
      end

      def update_language(store, object, updates)
        return if updates.all? { |key, value| object.members[key] == value }

        object.members.merge!(updates)
        store.commit(object)
      end
    end
  end
end
