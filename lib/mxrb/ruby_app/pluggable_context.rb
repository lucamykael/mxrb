# frozen_string_literal: true

require_relative '../io/mpr_file'
require_relative '../pluggable/mpr_codec'

module Mxrb
  module RubyApp
    # Resolves the exact embedded schema of one existing page widget. It does
    # not union package revisions or execute private schema source files.
    class PluggableContext
      THREAD_KEY = :mxrb_ruby_app_pluggable_context

      def self.current = Thread.current[THREAD_KEY]

      def self.with(manifest: nil, mpr: nil)
        previous = current
        context = new(manifest:, mpr:)
        Thread.current[THREAD_KEY] = context
        yield context
      ensure
        begin
          context&.close
        ensure
          Thread.current[THREAD_KEY] = previous
        end
      end

      def initialize(manifest: nil, mpr: nil)
        @manifest = manifest
        @mpr = mpr
        @owns_mpr = false
        @pages = {}
        @catalogs = {}
      end

      def with_page(identifier)
        previous = @page_id
        @page_id = identifier.to_s.dup.freeze
        yield
      ensure
        @page_id = previous
      end

      def for_widget(name, widget_id:)
        raise ValidationError, 'typed pluggable properties require their private page identity' if @page_id.to_s.empty?

        key = [@page_id, name.to_s.dup.freeze, widget_id.to_s.dup.freeze].freeze
        catalog = @catalogs[key] ||= exact_catalog(key[1], key[2])
        PluggableProperties.new(key[2], catalog:)
      end

      def close
        @mpr.close if @owns_mpr && @mpr
      ensure
        @mpr = nil
      end

      private

      def mpr
        return @mpr if @mpr

        raise ValidationError, 'typed pluggable properties require their private runtime baseline' unless @manifest

        path = @manifest.absolute_path('runtime_mpr')
        raise ValidationError, 'private pluggable runtime baseline is unavailable' unless File.file?(path)

        @mpr = IO::MprFile.open(path, readonly: true)
        @owns_mpr = true
        @mpr
      rescue KeyError, ArgumentError
        raise ValidationError, 'private pluggable runtime baseline path is unavailable or invalid'
      end

      def page_widgets
        @pages[@page_id] ||= begin
          unit = mpr.unit(@page_id)
          raise ValidationError, 'private pluggable page baseline is unavailable' unless unit

          document = mpr.parse_contents(unit)
          raise ValidationError, 'private pluggable identity is not a page' unless document['$Type'] == 'Forms$Page'

          collect_widgets(document)
        end
      end

      def collect_widgets(value, found = [])
        case value
        when Hash
          found << value if value['$Type'] == 'CustomWidgets$CustomWidget'
          value.each_value { collect_widgets(_1, found) }
        when Array then value.each { collect_widgets(_1, found) }
        end
        found
      end

      def exact_catalog(name, widget_id)
        document = widget_type(name, widget_id)
        catalog = Pluggable::Catalog.new
        Pluggable::MprCodec.new(forms_codec: nil, catalog:).register_type(document)
        catalog
      rescue Pluggable::CodecError, KeyError
        raise ValidationError, 'private pluggable widget schema is unsupported'
      end

      def widget_type(name, widget_id)
        matches = page_widgets.select do |widget|
          widget['Name'].to_s == name && widget.dig('Type', 'WidgetId').to_s == widget_id
        end
        raise ValidationError, 'private pluggable widget identity is missing or ambiguous' unless matches.one?

        # The codec freezes schema strings. Never freeze data owned by the
        # caller's MPR/parser while constructing this private catalog.
        Marshal.load(Marshal.dump(matches.first.fetch('Type')))
      end
    end
  end
end
