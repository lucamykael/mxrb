# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Decides whether an exporter-owned page projection can be safely upgraded
    # from the deprecated native-widget syntax to the current typed widget DSL.
    # The embedded original remains recoverable from the copied runtime MPR.
    class LegacyWidgetSourceMigration
      WIDGET_METHODS = {
        'Forms$FileManager' => 'file_manager',
        'Forms$ReferenceSetSelector' => 'reference_set_selector',
        'Forms$NavigationList' => 'navigation_list',
        'Forms$ScrollContainer' => 'scroll_container',
        'Forms$ImageViewer' => 'image_viewer',
        'Forms$ImageUploader' => 'image_uploader',
        'Forms$MenuBar' => 'menu_bar',
        'Forms$NavigationTree' => 'navigation_tree'
      }.freeze

      def initialize(path:, embedded_source:, generated_source:)
        @path = path.to_s
        @embedded_source = embedded_source.to_s
        @generated_source = generated_source.to_s
      end

      def regenerate?
        page_source? && supported_legacy_projection? && complete_typed_projection?
      end

      private

      def page_source?
        @path.match?(%r{\Aapp/pages/.+_page\.rb\z})
      end

      def supported_legacy_projection?
        legacy_widget_count.positive? && legacy_widget_count == legacy_type_counts.values.sum
      end

      def complete_typed_projection?
        return false if @generated_source.match?(/\bnative_widget\b/)

        legacy_type_counts.all? do |native_type, count|
          typed_method_count(WIDGET_METHODS.fetch(native_type)) >= count
        end
      end

      def legacy_widget_count
        @legacy_widget_count ||= @embedded_source.scan(/\bnative_widget\b/).size
      end

      def legacy_type_counts
        counts = WIDGET_METHODS.keys.to_h do |native_type|
          [native_type, @embedded_source.scan(native_type).size]
        end
        @legacy_type_counts ||= counts.reject { |_type, count| count.zero? }
      end

      def typed_method_count(method_name)
        @generated_source.scan(/\b#{Regexp.escape(method_name)}(?:\s|\()/).size
      end
    end
  end
end
