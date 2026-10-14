# frozen_string_literal: true

require 'fileutils'
require 'json'

module Mxrb
  module Compiler
    # Writes one page entry module per source page and an auditable support manifest.
    # rubocop:disable Metrics
    class PageBundleBuilder
      def initialize(source, web_root, strict: ENV['MXRB_STRICT_PAGES'] == '1')
        @source = source
        @web_root = web_root
        @strict = strict
      end

      def build
        destination = File.join(@web_root, 'pages')
        FileUtils.mkdir_p(destination)
        Dir.glob(File.join(destination, '**', '*.js')).each { FileUtils.rm_f(_1) }
        bundles = @source.units_of('Forms$Page').select { web_page?(_1) }
                         .map { PageBundleCompiler.new(@source).compile(_1) }
        bundles.each { write_bundle(destination, _1) }
        layout_bundles = build_layouts
        write_manifest(bundles)
        report_unsupported(bundles + layout_bundles)
        bundles + layout_bundles
      end

      private

      def web_page?(unit) = !@source.is_a?(SourceModel) || @source.web_page?(unit)
      def web_layout?(unit) = !@source.is_a?(SourceModel) || @source.web_layout?(unit)

      def write_bundle(destination, bundle)
        path = File.join(destination, "#{bundle.qualified_name}.js")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, bundle.source)
      end

      def build_layouts
        destination = File.join(@web_root, 'layouts')
        FileUtils.mkdir_p(destination)
        Dir.glob(File.join(destination, '**', '*.js')).each { FileUtils.rm_f(_1) }
        bundles = @source.units_of('Forms$Layout').select { web_layout?(_1) }
                         .map { PageBundleCompiler.new(@source).compile_layout(_1) }
        bundles.each { write_bundle(destination, _1) }
        bundles
      end

      # A page or layout that renders a widget or action inert is a hole in the
      # client: warn on every build, and fail it in strict mode.
      def report_unsupported(bundles)
        gaps = bundles.reject { _1.unsupported_widgets.empty? }
        return if gaps.empty?

        detail = gaps.map { "  #{_1.qualified_name}: #{_1.unsupported_widgets.join(', ')}" }.join("\n")
        message = "#{gaps.sum { _1.unsupported_widgets.length }} unsupported widget(s)/action(s) " \
                  "rendered inert:\n#{detail}"
        raise CompilationError, message if @strict

        warn "[mxrb] WARNING: #{message}"
      end

      def write_manifest(bundles)
        manifest = bundles.to_h { [_1.qualified_name, _1.unsupported_widgets] }
        File.write(File.join(@web_root, 'mxrb-pages.json'), JSON.pretty_generate(manifest))
      end
    end
    # rubocop:enable Metrics
  end
end
