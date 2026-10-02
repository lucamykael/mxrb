# frozen_string_literal: true

require 'tmpdir'
require 'timeout'

module Mxrb
  module RubyApp
    # Explicit raster decoder and bounded worker; upload names never enter argv.
    class Thumbnail
      FORMATS = { 'image/png' => 'PNG', 'image/jpeg' => 'JPEG', 'image/gif' => 'GIF', 'image/webp' => 'WEBP' }.freeze

      def self.dimensions(width, height)
        [width, height].map do |value|
          number = Integer(value.to_s, 10)
          raise ArgumentError, 'thumbnail dimensions must be between 1 and 1024' unless (1..1024).cover?(number)

          number
        end
      end

      def self.render(content, width, height)
        width, height = dimensions(width, height)
        format = FORMATS.fetch(content.fetch('media_type')) { raise ArgumentError, 'thumbnail requires a raster image' }
        Dir.mktmpdir('mxrb-thumbnail-') do |directory|
          render_file(directory, content.fetch('content'), format, width, height)
        end
      rescue Errno::ENOENT
        raise ArgumentError, 'thumbnail generation requires ImageMagick; configure MXRB_IMAGEMAGICK'
      end

      def self.render_file(directory, bytes, format, width, height)
        input = File.join(directory, 'source')
        output = File.join(directory, 'thumbnail.png')
        File.binwrite(input, bytes)
        arguments = ['-limit', 'memory', '128MiB', '-limit', 'map', '0', '-limit', 'disk', '0',
                     '-limit', 'thread', '1', '-limit', 'time', '10', "#{format}:#{input}[0]",
                     '-auto-orient', '-thumbnail', "#{width}x#{height}>", '-strip', "PNG:#{output}"]
        run(ENV.fetch('MXRB_IMAGEMAGICK', 'magick'), arguments)
        File.binread(output)
      end

      def self.run(command, arguments)
        pid = Process.spawn(command, *arguments, out: File::NULL, err: File::NULL)
        _, status = Timeout.timeout(15) { Process.wait2(pid) }
        raise ArgumentError, 'invalid image or thumbnail resource limit exceeded' unless status.success?
      rescue Timeout::Error
        Process.kill('KILL', pid)
        Process.wait(pid)
        raise ArgumentError, 'thumbnail generation timed out'
      end
      private_class_method :run, :render_file
    end
  end
end
