# frozen_string_literal: true

require_relative "unit"

module Mxrb
  module Model
    class Menu < Unit
      attr_reader :name, :items, :raw_document

      def decode(doc)
        @raw_document = doc
        @name = doc["Name"]
        collection = doc["ItemCollection"] || {}
        @items = parse_array(collection["Items"]).map { menu_item(_1) }
      end

      private

      def menu_item(doc)
        {
          name: doc["Name"],
          caption: extract_text(doc["Caption"]),
          page: doc.dig("Action", "FormSettings", "Form"),
          items: parse_array(doc["Items"]).map { menu_item(_1) }
        }.compact
      end

      def extract_text(obj)
        return "" unless obj.is_a?(Hash)

        translation = parse_array(obj["Items"] || obj["Translations"]).find { _1.is_a?(Hash) }
        return "" unless translation

        translation["Text"] || translation["Translation"] || ""
      end
    end
  end
end
