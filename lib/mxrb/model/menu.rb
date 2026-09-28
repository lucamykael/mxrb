# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    class Menu < Unit
      SUPPORTED_ACTIONS = %w[Forms$NoAction Forms$FormAction Forms$MicroflowAction].freeze

      attr_reader :name, :items, :raw_document, :documentation, :export_level

      def decode(doc)
        @raw_document = doc
        @name = doc["Name"]
        @documentation = doc['Documentation'].to_s
        @excluded = doc['Excluded'] == true
        @export_level = doc.fetch('ExportLevel', 'Hidden').to_s
        collection = doc["ItemCollection"] || {}
        @items = parse_array(collection["Items"]).map { menu_item(_1) }
      end

      def excluded? = @excluded

      def semantic?
        collection = raw_document['ItemCollection']
        collection.is_a?(Hash) && collection['$Type'] == 'Menus$MenuItemCollection' &&
          menu_items_semantic?(parse_array(collection['Items']))
      end

      private

      def menu_item(doc)
        caption, translations, locale = extract_text(doc["Caption"])
        action = doc['Action'].is_a?(Hash) ? doc['Action'] : {}
        {
          name: doc["Name"],
          caption:, caption_translations: translations, caption_locale: locale,
          page: action.dig("FormSettings", "Form"),
          microflow: action.dig('MicroflowSettings', 'Microflow'),
          icon: doc.dig('Icon', 'Code'),
          items: parse_array(doc["Items"]).map { menu_item(_1) }
        }.compact
      end

      def extract_text(obj)
        return ['', {}, nil] unless obj.is_a?(Hash)

        translations = parse_array(obj["Items"] || obj["Translations"])
                       .select { _1.is_a?(Hash) }
                       .to_h { [_1['LanguageCode'].to_s, (_1['Text'] || _1['Translation']).to_s] }
        locale = translations.key?('en_US') ? 'en_US' : translations.keys.first
        [locale ? translations.fetch(locale) : '', translations, locale]
      end

      def menu_items_semantic?(items)
        items.all? do |item|
          item.is_a?(Hash) && item['$Type'] == 'Menus$MenuItem' &&
            supported_action?(item['Action']) && supported_icon?(item['Icon']) &&
            menu_items_semantic?(parse_array(item['Items']))
        end
      end

      def supported_action?(action)
        action.nil? || (action.is_a?(Hash) && SUPPORTED_ACTIONS.include?(action['$Type']))
      end

      def supported_icon?(icon)
        icon.nil? || (icon.is_a?(Hash) && icon['$Type'] == 'Forms$GlyphIcon')
      end
    end
  end
end
