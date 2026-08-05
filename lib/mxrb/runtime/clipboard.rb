# frozen_string_literal: true

require 'tempfile'

module Mxrb
  module Runtime
    # Copies secrets through stdin so they never appear in the process list.
    class Clipboard
      COMMANDS = [
        ['wl-copy'], ['pbcopy'], ['xclip', '-selection', 'clipboard'],
        ['xsel', '--clipboard', '--input'], ['clip.exe']
      ].freeze

      def initialize(path: ENV.fetch('PATH', ''), runner: nil)
        @path = path
        @runner = runner || method(:capture)
      end

      def copy(text)
        command = available_command
        unless command
          raise ToolchainError,
                'no clipboard command found; install wl-copy, pbcopy, xclip, xsel, or clip.exe'
        end

        _stdout, stderr, status = @runner.call(command, text.to_s)
        raise ToolchainError, "clipboard command failed: #{stderr}" unless status.success?

        command.first
      end

      private

      def available_command
        COMMANDS.find { executable?(_1.first) }
      end

      def executable?(name)
        @path.split(File::PATH_SEPARATOR).any? do |directory|
          file = File.join(directory, name)
          File.file?(file) && File.executable?(file)
        end
      end

      def capture(command, input)
        Tempfile.create('mxrb-clipboard') { capture_process(command, input, _1) }
      end

      def capture_process(command, input, stderr)
        ::IO.pipe do |reader, writer|
          pid = Process.spawn({ 'PATH' => @path }, *command, in: reader, out: File::NULL, err: stderr)
          reader.close
          writer.write(input)
          writer.close
          _child, status = Process.wait2(pid)
          stderr.rewind
          ['', stderr.read, status]
        end
      end
    end
  end
end
