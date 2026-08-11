# frozen_string_literal: true

require 'uri'

module Mxrb
  # Reads the compiled browser interfaces embedded in the gem.
  module WebUi
    ROOT = File.expand_path('web_ui', __dir__)
    CONTENT_TYPES = {
      '.css' => 'text/css; charset=utf-8',
      '.gif' => 'image/gif',
      '.html' => 'text/html; charset=utf-8',
      '.ico' => 'image/x-icon',
      '.jpeg' => 'image/jpeg',
      '.jpg' => 'image/jpeg',
      '.js' => 'application/javascript; charset=utf-8',
      '.json' => 'application/json; charset=utf-8',
      '.map' => 'application/json; charset=utf-8',
      '.mjs' => 'application/javascript; charset=utf-8',
      '.png' => 'image/png',
      '.svg' => 'image/svg+xml; charset=utf-8',
      '.ttf' => 'font/ttf',
      '.wasm' => 'application/wasm',
      '.webp' => 'image/webp',
      '.woff' => 'font/woff',
      '.woff2' => 'font/woff2'
    }.freeze

    module_function

    def page(name)
      File.binread(File.join(root, "#{name}.html"))
    end

    def asset(request_path)
      relative = decoded_asset_path(request_path)
      return unless relative

      assets = File.realpath(File.join(root, 'assets'))
      candidate = File.realpath(File.join(assets, relative))
      return unless inside?(candidate, assets) && File.file?(candidate)

      [File.binread(candidate), content_type(candidate)]
    rescue Errno::ENOENT, Errno::ENOTDIR, Errno::EACCES
      nil
    end

    def root = ROOT

    def content_type(path)
      CONTENT_TYPES.fetch(File.extname(path).downcase, 'application/octet-stream')
    end

    def decoded_asset_path(request_path)
      prefix = '/assets/'
      return unless request_path.start_with?(prefix)

      relative = repeatedly_unescape(request_path.delete_prefix(prefix))
      return unless valid_relative_path?(relative)

      relative
    end
    private_class_method :decoded_asset_path

    def valid_relative_path?(relative)
      return false if relative.nil? || relative.empty?
      return false if relative.include?("\0") || relative.include?('\\')

      relative.split('/').none? { _1.empty? || %w[. ..].include?(_1) }
    end
    private_class_method :valid_relative_path?

    def repeatedly_unescape(value)
      8.times do
        decoded = URI::RFC2396_PARSER.unescape(value)
        return value if decoded == value

        value = decoded
      end
      nil
    end
    private_class_method :repeatedly_unescape

    def inside?(path, directory)
      path.start_with?("#{directory}#{File::SEPARATOR}")
    end
    private_class_method :inside?
  end
end
