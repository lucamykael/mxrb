# frozen_string_literal: true

require 'fileutils'
require 'json'

module Mxrb
  module Compiler
    # Writes one page entry module per source page and an auditable support manifest.
    class PageBundleBuilder
      def initialize(source, web_root)
        @source = source
        @web_root = web_root
      end

      def build
        destination = File.join(@web_root, 'pages')
        FileUtils.mkdir_p(destination)
        Dir.glob(File.join(destination, '**', '*.js')).each { FileUtils.rm_f(_1) }
        bundles = @source.units_of('Forms$Page').map { PageBundleCompiler.new(@source).compile(_1) }
        bundles.each { write_bundle(destination, _1) }
        write_manifest(bundles)
        bundles
      end

      private

      def write_bundle(destination, bundle)
        path = File.join(destination, "#{bundle.qualified_name}.js")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, bundle.source)
      end

      def write_manifest(bundles)
        manifest = bundles.to_h { [_1.qualified_name, _1.unsupported_widgets] }
        File.write(File.join(@web_root, 'mxrb-pages.json'), JSON.pretty_generate(manifest))
      end
    end
  end
end
