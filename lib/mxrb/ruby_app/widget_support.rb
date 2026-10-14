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

      # Widgets rendered by an adapter the export registers only for a verified package.
      ADAPTERS = {
        'SprintrFeedbackWidget.SprintrFeedback' => ['frontend/src/generated/feedbackWidget.ts',
                                                    'registerFeedbackWidget(']
      }.freeze

      # The registrations of the project's own widget builds run by the pluggable host.
      PROJECT_WIDGETS = 'frontend/src/generated/projectWidgets.ts'

      def initialize(root = nil) = @root = root

      def self.family(widget_id)
        FAMILIES.find { Regexp.new(_1.fetch('pattern')).match?(widget_id.downcase) }
      end

      def report
        uses.sort.filter_map do |widget_id, documents|
          next if adapter_registered?(widget_id)

          family = self.class.family(widget_id)
          support = family ? family.fetch('support') : 'unsupported'
          next if support == 'full'

          { widget_id:, support:, note: family&.fetch('note', nil), documents: documents.uniq.sort }.compact
        end
      end

      private

      def adapter_registered?(widget_id)
        path, marker = ADAPTERS.fetch(widget_id) { [PROJECT_WIDGETS, "registerProjectWidget(#{widget_id.inspect}"] }
        return false unless @root

        file = File.join(@root, path)
        File.file?(file) && File.read(file).include?(marker)
      end

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
