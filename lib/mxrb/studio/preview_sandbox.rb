# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'

module Mxrb
  module Studio
    class PreviewIsolationUnavailable < StandardError; end

    # A separate mount/PID/network namespace is mandatory. Isolated.run's
    # process separation alone cannot keep arbitrary Ruby from writing files.
    class PreviewSandbox # rubocop:disable Metrics/ClassLength
      TIMEOUT = 120
      MAXIMUM_OUTPUT = 128 * 1024

      def initialize(context:, model_name:)
        @context = context
        @model_name = model_name
      end

      def generate(workspace) # rubocop:disable Metrics/AbcSize
        %w[home tmp generated].each { FileUtils.mkdir_p(File.join(workspace, _1)) }
        output, status = execute(command(workspace))
        result = worker_result(workspace, output, status)
        unless result['ok'] == true && status.success?
          raise RubySourceError.new(result.fetch('message', 'sandboxed Ruby generation failed'),
                                    locations: Array(result['locations']).map { _1.transform_keys(&:to_sym) })
        end

        generated_file(workspace)
      rescue Errno::ENOENT => e
        raise PreviewIsolationUnavailable, "Ruby preview isolation is unavailable: #{e.message}"
      end

      private

      def worker_result(workspace, output, status)
        if File.file?(File.join(workspace, 'result.json'))
          return JSON.parse(Files.new(workspace).read('result.json').fetch(:text))
        end
        if File.file?(File.join(workspace, 'worker-started'))
          raise RubySourceError, "sandboxed Ruby worker ended without a result (status #{status.exitstatus})"
        end

        raise PreviewIsolationUnavailable, "Ruby preview isolation could not start: #{output.strip}"
      end

      def generated_file(workspace)
        entry = Files.new(workspace).list('generated').find { _1[:name] == @model_name && !_1[:directory] }
        raise RubySourceError, 'generated model must be a regular file' unless entry

        File.join(workspace, 'generated', @model_name)
      end

      def command(workspace)
        arguments = ['/usr/bin/bwrap', '--unshare-all', '--die-with-parent', '--new-session', '--cap-drop', 'ALL',
                     '--ro-bind', '/usr', '/usr', '--proc', '/proc', '--dev', '/dev', '--tmpfs', '/tmp']
        arguments.concat(system_links)
        readonly_paths.each { arguments.concat(['--ro-bind', _1, _1]) }
        library = File.expand_path('../..', __dir__)
        arguments.concat(['--ro-bind', library, '/opt/mxrb/lib', '--bind', workspace, '/work',
                          '--chdir', '/work/ruby', '--', RbConfig.ruby, '-I/opt/mxrb/lib',
                          '/opt/mxrb/lib/mxrb/studio/preview_worker.rb'])
      end

      def system_links
        %w[bin sbin lib lib64].flat_map do |name|
          path = "/#{name}"
          next [] unless File.exist?(path)

          File.symlink?(path) ? ['--symlink', File.readlink(path), path] : ['--ro-bind', path, path]
        end
      end

      def readonly_paths
        prefix = RbConfig::CONFIG.fetch('prefix')
        runtime = %w[bin lib share].map { File.join(prefix, _1) }
        gems = Gem.path.flat_map { |root| %w[gems extensions specifications plugins].map { File.join(root, _1) } }
        (runtime + gems + ['/etc/ld.so.cache']).select { File.exist?(_1) && !_1.start_with?('/usr/') }.uniq
      end

      def environment
        { 'HOME' => '/work/home', 'TMPDIR' => '/work/tmp', 'XDG_CACHE_HOME' => '/work/home/.cache',
          'XDG_STATE_HOME' => '/work/home/.state', 'LANG' => 'C.UTF-8', 'LC_ALL' => 'C.UTF-8', 'TZ' => 'UTC',
          'PATH' => "#{File.dirname(RbConfig.ruby)}:/usr/bin", 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR),
          'GEM_HOME' => Gem.dir, 'MXRB_OUTPUT_PATH' => File.join('/work/generated', @model_name), 'NO_COLOR' => '1' }
      end

      def execute(arguments) # rubocop:disable Metrics/MethodLength
        @context.check!
        Open3.popen3(environment, *arguments, unsetenv_others: true, pgroup: true) do |input, output, errors, process|
          input.close
          hook = @context.on_cancel { terminate(process.pid) }
          begin
            text = read_output([output, errors], process)
            @context.check!
            [text, process.value]
          ensure
            @context.remove_cancel_hook(hook)
            terminate(process.pid) if process.alive?
          end
        end
      end

      def read_output(streams, process)
        result = +''
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT
        until streams.empty? && !process.alive?
          @context.check!
          check_deadline(deadline)
          ready = ::IO.select(streams, nil, nil, 0.1)&.first || []
          ready.each { drain(_1, streams, result) }
        end
        result
      end

      def check_deadline(deadline)
        return if Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

        raise RubySourceError, 'Ruby preview generation timed out'
      end

      def drain(stream, streams, result)
        chunk = stream.read_nonblock(4096, exception: false)
        return streams.delete(stream) if chunk.nil?
        return if chunk == :wait_readable

        result << chunk
        raise RubySourceError, 'Ruby preview exceeded its output limit' if result.bytesize > MAXIMUM_OUTPUT
      end

      def terminate(pid)
        Process.kill('KILL', -pid)
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
