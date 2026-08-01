# frozen_string_literal: true

require 'json'

module Mxrb
  module Model
    DesignToken = Data.define(:name, :value, :kind, :theme, :path, :line)

    # Read-only inventory and quality metrics for Mendix theme assets.
    class DesignSystem
      ASSET_DIRECTORIES = %w[
        theme theme-cache themesource resources widgets javasource javascriptsource
        userlib vendorlib
      ].freeze
      CSS_TOKEN = /(?<name>--[A-Za-z0-9_-]+)\s*:\s*(?<value>[^;{}]+);/
      SCSS_TOKEN = /(?<name>\$[A-Za-z0-9_-]+)\s*:\s*(?<value>[^;{}]+);/

      attr_reader :root

      def initialize(root)
        @root = File.expand_path(root)
      end

      def tokens
        @tokens ||= stylesheet_paths.flat_map { scan_stylesheet(_1) }.freeze
      end

      def themes
        tokens.map(&:theme).compact.uniq.sort.freeze
      end

      def catalogs
        Dir.glob(File.join(@root, 'themesource', '**', 'design-properties.json')).sort.to_h do |path|
          [relative(path), JSON.parse(File.read(path))]
        rescue JSON::ParserError
          [relative(path), nil]
        end.freeze
      end

      def unresolved_references
        names = tokens.map(&:name).to_h { [_1, true] }
        tokens.flat_map do |token|
          token.value.scan(/var\((--[A-Za-z0-9_-]+)/).flatten.reject { names.key?(_1) }
                                                             .map do
            {
              token:, reference: _1
            }.freeze
          end
        end.freeze
      end

      def literal_colors
        tokens.select { _1.value.match?(/#[0-9a-f]{3,8}\b/i) }.freeze
      end

      def contrast_ratio(foreground, background)
        light, dark = [relative_luminance(foreground), relative_luminance(background)].sort.reverse
        ((light + 0.05) / (dark + 0.05)).round(2)
      end

      def plan_literal_migration(replacements)
        DesignMigrationPlan.build(@root, replacements)
      end

      private

      def stylesheet_paths
        paths = ASSET_DIRECTORIES.flat_map do |directory|
          Dir.glob(File.join(@root, directory, '**', '*.{css,scss}'))
        end
        paths.select { File.file?(_1) }.sort
      end

      def scan_stylesheet(path)
        theme = File.basename(path)[/\A_theme-([^.]+)/, 1]
        File.readlines(path).each_with_index.flat_map do |line, index|
          next [] if line.lstrip.start_with?('//')

          line.scan(CSS_TOKEN).map { token(_1, :css_custom_property, theme, path, index) } +
            line.scan(SCSS_TOKEN).map { token(_1, :scss_variable, theme, path, index) }
        end
      end

      def token(match, kind, theme, path, index)
        DesignToken.new(match[0], match[1].strip, kind, theme, relative(path), index + 1)
      end

      def relative(path) = Pathname.new(path).relative_path_from(Pathname.new(@root)).to_s

      def relative_luminance(color)
        hex = normalized_hex(color)
        channels = hex.scan(/../).map { linear_channel(_1.to_i(16) / 255.0) }
        (0.2126 * channels[0]) + (0.7152 * channels[1]) + (0.0722 * channels[2])
      end

      def normalized_hex(color)
        hex = color.to_s.delete_prefix('#')
        hex = hex.chars.flat_map { [_1, _1] }.join if hex.length == 3
        raise ArgumentError, 'expected a three- or six-digit hex color' unless hex.match?(/\A[0-9a-f]{6}\z/i)

        hex
      end

      def linear_channel(channel)
        return channel / 12.92 if channel <= 0.04045

        ((channel + 0.055) / 1.055)**2.4
      end
    end
  end
end
