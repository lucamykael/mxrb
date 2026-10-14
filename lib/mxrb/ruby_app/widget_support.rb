# frozen_string_literal: true

require 'json'

module Mxrb
  module RubyApp
    # Pluggable widgets of the loaded pages, snippets and layouts that the generated
    # frontend renders only approximately or not at all (see marketplaceWidgets.json).
    class WidgetSupport
      FAMILIES = JSON.parse(File.read(File.expand_path(
                                        'frontend_template/src/generated/bridge/marketplaceWidgets.json', __dir__
                                      ))).fetch('widgets').freeze

      def self.family(widget_id)
        FAMILIES.find { Regexp.new(_1.fetch('pattern')).match?(widget_id.downcase) }
      end

      def report
        uses.sort.filter_map do |widget_id, documents|
          family = self.class.family(widget_id)
          support = family ? family.fetch('support') : 'unsupported'
          next if support == 'full'

          { widget_id:, support:, note: family&.fetch('note', nil), documents: documents.uniq.sort }.compact
        end
      end

      private

      def uses
        Registry.all(:page).merge(Registry.all(:presentation)).each_with_object(Hash.new { _1[_2] = [] }) do
          |(name, document), result|
          # Page classes expose their widget tree; snippets and layouts are registered as hashes.
          widget_ids(document.respond_to?(:widgets) ? document.widgets : document).each { result[_1] << name.to_s }
        end
      end

      def widget_ids(value)
        case value
        when Hash
          own = value['type'] == 'pluggable_widget' ? [value.dig('options', 'widget_id')].compact : []
          own + value.values.flat_map { widget_ids(_1) }
        when Array then value.flat_map { widget_ids(_1) }
        else []
        end
      end
    end
  end
end
