# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Edits the translation projected into Ruby, retaining other languages and template parameters.
    module PageEditTexts
      TYPES = %w[text_box number_input text_area].freeze
      FIELDS = { 'placeholder' => %w[PlaceholderTemplate Placeholder],
                 'aria_label' => %w[ScreenReaderLabel] }.freeze

      module_function

      def supported?(type, key) = TYPES.include?(type) && FIELDS.key?(key)

      def apply(owner, type, key, before, after, language:) # rubocop:disable Metrics/ParameterLists
        raise ArgumentError, 'text edits require string values' unless before.is_a?(String) && after.is_a?(String)

        text = text_node(owner.fetch(native_field(owner, type, key)), before, after)
        replace_translation(text, before, after, language)
      end

      def native_field(owner, type, key)
        field = FIELDS.fetch(key).find { owner.key?(_1) }
        native_types = PageEditProperties::CONTRACTS.fetch(type, [[], {}]).first
        unless supported?(type, key) && native_types.include?(owner['$Type']) && field
          raise ArgumentError, "#{key} has no supported native field on #{owner['$Type']}"
        end

        field
      end

      def text_node(value, before, after)
        if value.is_a?(Hash) && value['$Type'] == 'Forms$ClientTemplate'
          unless before.scan(/\{\d+\}/).uniq.sort == after.scan(/\{\d+\}/).uniq.sort
            raise ArgumentError, 'text edits must preserve template parameter references'
          end

          value = value['Template']
        end
        return value if value.is_a?(Hash) && value['$Type'] == 'Texts$Text'

        raise ArgumentError, 'unsupported native text representation'
      end

      def replace_translation(text, before, after, language)
        items = translation_items(text)
        entry = items[1]
        return add_translation(items, before, after, language) unless entry

        unless entry.is_a?(Hash) && entry['$Type'] == 'Texts$Translation' && entry['Text'] == before
          raise ArgumentError, 'text no longer matches the exported Ruby baseline'
        end

        entry['Text'] = after
      end

      def translation_items(text)
        items = text['Items']
        unless items.is_a?(Array) && items.first.is_a?(Integer)
          raise ArgumentError, 'native translation list is missing'
        end

        items
      end

      def add_translation(items, before, after, language)
        raise ArgumentError, 'text no longer matches the exported Ruby baseline' unless before.empty?
        raise ArgumentError, 'the project default language is required for an empty text' if language.to_s.empty?

        items << { '$ID' => SecureRandom.uuid, '$Type' => 'Texts$Translation',
                   'LanguageCode' => language, 'Text' => after }
      end
    end
  end
end
