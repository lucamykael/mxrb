# frozen_string_literal: true

module Mxrb
  module Compiler
    # The custom widgets the web documents of a project use: pluggable ones by
    # id and legacy ones by module, in the order they are first met.
    class WebWidgetInventory
      include ModelValues

      def initialize(source)
        @source = source
      end

      def ids(plugin:)
        widget_types.select { (_1['WidgetPluginWidget'] == true) == plugin }.map { _1['WidgetId'].to_s }.uniq
      end

      # The web documents in the order of the MPR units.
      def documents
        return [] unless @source.respond_to?(:units)

        @documents ||= @source.units.select { web_document?(_1) }.map(&:document)
      end

      private

      def widget_types
        @widget_types ||= documents.flat_map { custom_widget_types(_1) }
      end

      def web_document?(unit)
        case unit.document['$Type']
        when 'Forms$Page' then @source.web_page?(unit)
        when 'Forms$Layout' then @source.web_layout?(unit)
        when 'Forms$Snippet' then unit.document.fetch('Type', 'Web') == 'Web'
        else false
        end
      end

      def custom_widget_types(value, found = [])
        case value
        when Hash
          found << value['Type'] if value['$Type'] == 'CustomWidgets$CustomWidget' && value['Type'].is_a?(Hash)
          value.each_value { custom_widget_types(_1, found) }
        when Array then value.each { custom_widget_types(_1, found) }
        end
        found
      end
    end
  end
end
