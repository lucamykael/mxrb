# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Starts the Ruby API and Vite dev server as one supervised command.
    class Supervisor
      attr_reader :root, :host, :api_port, :frontend_port

      def initialize(root, host: '127.0.0.1', api_port: 9292, frontend_port: 5173,
                     npm: ENV.fetch('MXRB_NPM', 'npm'), frontend: true, environment: nil,
                     reload: true)
        @root = File.expand_path(root)
        @host = host.to_s
        @api_port = Integer(api_port)
        @frontend_port = Integer(frontend_port)
        @npm = npm.to_s
        @frontend = frontend
        @reload = reload == true
        @environment = if environment.is_a?(Environment)
                         environment
                       else
                         Environment.load(
                           environment, root: @root
                         )
                       end
      end

      def start
        if external_backend?
          @backend_pid = spawn_backend
        else
          @server = Server.new(root, host:, port: api_port, environment: @environment, reload: @reload)
          @backend = Thread.new { @server.start }
        end
        @frontend_pid = spawn_frontend if @frontend
        yield(self) if block_given?
        if @frontend_pid
          wait_for_process(@frontend_pid, 'frontend')
        elsif @backend_pid
          wait_for_process(@backend_pid, 'backend')
        else
          @backend.join
        end
      rescue Interrupt, Errno::ECHILD
        nil
      ensure
        shutdown
      end

      def shutdown
        @shutting_down = true
        @server&.shutdown
        terminate(@frontend_pid)
        terminate(@backend_pid)
        @backend&.join(2)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      private

      def external_backend?
        %w[flymetothemoon onrails].include?(
          Manifest.load(root).data.dig('ruby_stack', 'preset')
        )
      end

      def spawn_backend
        Process.spawn(
          profile_environment.merge(
            'HOST' => host, 'MXRB_SERVER_PORT' => api_port.to_s,
            'MXRB_RELOAD' => @reload ? '1' : '0'
          ),
          'bundle', 'exec', 'puma', '-C', 'config/puma.rb', chdir: root
        )
      end

      def terminate(pid)
        return unless pid

        Process.kill('TERM', pid)
        Process.wait(pid)
      end

      def wait_for_process(pid, label)
        _waited, status = Process.wait2(pid)
        return if status.success? || @shutting_down

        reason = status.exitstatus ? "status #{status.exitstatus}" : "signal #{status.termsig}"
        raise Error, "#{label} process exited with #{reason}"
      end

      def spawn_frontend
        directory = File.join(root, 'frontend')
        package = File.join(directory, 'package.json')
        raise ArgumentError, "frontend package not found: #{directory}" unless File.file?(package)
        unless File.directory?(File.join(directory, 'node_modules'))
          raise ArgumentError, "frontend dependencies missing; run `#{@npm} install --prefix frontend`"
        end

        frontend_environment = profile_environment.select { _1.start_with?('VITE_') }
        frontend_environment['MXRB_ENV'] = @environment.name
        frontend_environment['MXRB_API_PORT'] = api_port.to_s
        Process.spawn(
          frontend_environment, @npm, 'run', 'dev', '--',
          '--host', host, '--port', frontend_port.to_s, '--strictPort', chdir: directory
        )
      end

      def profile_environment
        @environment.to_h.reject { |key, value| ENV[key] == value }
                    .merge('MXRB_ENV' => @environment.name)
      end
    end
    # rubocop:enable Metrics
  end
end
