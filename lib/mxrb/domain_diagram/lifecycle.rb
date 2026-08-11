# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'rbconfig'
require 'securerandom'
require 'time'

module Mxrb
  module DomainDiagram
    # Background lifecycle for the ER editor. Control happens through a
    # token-authenticated loopback endpoint rather than a potentially stale PID.
    # rubocop:disable Metrics
    class Lifecycle
      STATE_ROOT_ENV = 'MXRB_DIAGRAM_STATE_ROOT'
      START_TIMEOUT = 8
      STOP_TIMEOUT = 8

      Status = Data.define(:state, :source, :output, :url, :pid, :log) do
        def running? = state == 'running'
        def to_h = { state:, source:, output:, url:, pid:, log: }.compact
      end

      attr_reader :source, :state_root, :executable

      def initialize(source, state_root: self.class.default_state_root, executable: $PROGRAM_NAME)
        @source = File.expand_path(source)
        @state_root = File.expand_path(state_root)
        @executable = File.expand_path(executable)
      end

      def self.default_state_root
        configured = ENV[STATE_ROOT_ENV]
        return configured unless configured.to_s.empty?

        File.join(Dir.home, '.local', 'state', 'mxrb', 'diagram-er')
      end

      def up(output: nil, modules: nil, port: nil, force: false)
        previous = read_state
        raise ArgumentError, "diagram already running at #{url_for(previous)}" if running?(previous)
        raise ArgumentError, 'managed diagram is already starting' if starting?(previous)

        settings = settings_for(previous, output:, modules:, port:)
        managed_paths = prepare_output(previous, settings, force:)
        token = SecureRandom.hex(24)
        state = settings.merge(
          'version' => 1, 'source' => source, 'token' => token, 'state' => 'starting',
          'pid' => nil, 'log' => log_path, 'managed_paths' => managed_paths,
          'created_at' => Time.now.utc.iso8601
        )
        write_state(state)
        pid = spawn_worker(state)
        Process.detach(pid)
        write_state(read_state.merge('pid' => pid))
        wait_until(START_TIMEOUT) { running?(read_state, token:) }
        status
      rescue StandardError
        mark_stopped(token) if defined?(token) && token
        raise
      end

      def status
        state = read_state
        return Status.new('absent', source, nil, nil, nil, nil) unless state

        lifecycle_state = if running?(state)
                            'running'
                          elsif starting?(state)
                            'starting'
                          else
                            'stopped'
                          end
        Status.new(
          lifecycle_state, source, state['output'], url_for(state), state['pid'], state['log']
        )
      end

      def down
        state = read_state or raise ArgumentError, "no managed diagram for #{source}"
        unless running?(state)
          raise ArgumentError, 'managed diagram is still starting; retry in a moment' if starting?(state)

          mark_stopped(state.fetch('token'))
          return status
        end

        response = request(state, Net::HTTP::Post, '/api/admin/shutdown')
        raise ArgumentError, 'managed diagram refused the shutdown request' unless response.is_a?(Net::HTTPSuccess)

        wait_until(STOP_TIMEOUT) { !running?(read_state) }
        mark_stopped(state.fetch('token'))
        status
      end

      def destroy(confirm: false)
        raise ArgumentError, 'destroy requires --yes' unless confirm

        state = read_state or raise ArgumentError, "no managed diagram for #{source}"
        current = status
        down if %w[running starting].include?(current.state)
        Array(state['managed_paths']).reverse_each do |path|
          remove_managed_path(path, state.fetch('output'))
        end
        FileUtils.remove_entry_secure(instance_dir) if File.exist?(instance_dir)
        Status.new('absent', source, nil, nil, nil, nil)
      end

      # Internal worker entrypoint used by `mxrb diagram-er __serve`.
      def run_worker(output:, modules:, port:, token:)
        state = read_state or raise ArgumentError, 'diagram lifecycle state is missing'
        raise ArgumentError, 'diagram lifecycle token does not match' unless state['token'] == token

        server = Server.new(
          source, output:, modules:, port:, reuse: true, lifecycle_token: token
        )
        trap('INT') { Thread.new { server.shutdown } }
        trap('TERM') { Thread.new { server.shutdown } }
        server.start do
          write_state(state.merge(
                        'pid' => Process.pid, 'state' => 'running',
                        'started_at' => Time.now.utc.iso8601
                      ))
        end
      ensure
        mark_stopped(token) if defined?(token) && token
      end

      private

      def settings_for(previous, output:, modules:, port:)
        selected_output = File.expand_path(output || previous&.fetch('output', nil) || default_output)
        if previous && output && selected_output != File.expand_path(previous.fetch('output'))
          raise ArgumentError, 'destroy the existing managed diagram before changing --output'
        end

        {
          'output' => selected_output,
          'modules' => modules.nil? ? Array(previous&.fetch('modules', [])) : Array(modules),
          'port' => Integer(port || previous&.fetch('port', nil) || 4568),
          'host' => '127.0.0.1'
        }
      end

      def prepare_output(previous, settings, force:)
        output = settings.fetch('output')
        if previous && File.file?(output) && !force
          Server.new(source, output:, port: settings.fetch('port'), reuse: true)
          return Array(previous['managed_paths'])
        end

        server = Server.new(source, output:, port: settings.fetch('port'), force:)
        (Array(previous&.fetch('managed_paths', [])) + server.managed_paths).uniq
      end

      def spawn_worker(state)
        arguments = [
          RbConfig.ruby, executable, 'diagram-er', '__serve', source,
          '--output', state.fetch('output'), '--port', state.fetch('port').to_s,
          '--token', state.fetch('token'), '--state-root', state_root
        ]
        Array(state['modules']).each { arguments.concat(['--module', _1.to_s]) }
        prepare_instance_dir
        FileUtils.touch(state.fetch('log'))
        File.chmod(0o600, state.fetch('log'))
        Process.spawn(*arguments, out: state.fetch('log'), err: %i[child out])
      end

      def starting?(state)
        return false unless state&.fetch('state', nil) == 'starting'

        created_at = Time.iso8601(state.fetch('created_at'))
        Time.now.utc - created_at <= START_TIMEOUT
      rescue ArgumentError, KeyError
        false
      end

      def running?(state, token: state&.fetch('token', nil))
        return false unless state && token

        response = request(state, Net::HTTP::Get, '/api/admin/status', token:)
        response&.is_a?(Net::HTTPSuccess) == true
      end

      def request(state, request_class, path, token: state.fetch('token'))
        request = request_class.new(path)
        request['X-MXRB-Lifecycle-Token'] = token
        Net::HTTP.start(
          state.fetch('host'), Integer(state.fetch('port')),
          open_timeout: 0.25, read_timeout: 0.5
        ) { _1.request(request) }
      rescue IOError, SystemCallError, Timeout::Error, SocketError
        nil
      end

      def wait_until(timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        loop do
          return true if yield
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
            raise ArgumentError, "diagram lifecycle timed out; see #{log_path}"
          end

          sleep 0.05
        end
      end

      def mark_stopped(token)
        state = read_state
        return unless state && state['token'] == token

        write_state(state.merge(
                      'pid' => nil, 'state' => 'stopped',
                      'stopped_at' => Time.now.utc.iso8601
                    ))
      end

      def remove_managed_path(path, output)
        expanded = File.expand_path(path)
        output = File.expand_path(output)
        external = File.join(File.dirname(output), 'mprcontents')
        raise ArgumentError, 'refusing to remove the source MPR' if expanded == source

        unless expanded == output || expanded == external
          raise ArgumentError, "refusing to remove unmanaged path #{expanded}"
        end
        return unless File.exist?(expanded) || File.symlink?(expanded)

        if File.directory?(expanded) && !File.symlink?(expanded)
          FileUtils.remove_entry_secure(expanded)
        else
          FileUtils.rm_f(expanded)
        end
      end

      def read_state
        JSON.parse(File.binread(state_path))
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid diagram lifecycle state: #{e.message}"
      end

      def write_state(payload)
        prepare_instance_dir
        temporary = "#{state_path}.#{Process.pid}.tmp"
        File.binwrite(temporary, JSON.pretty_generate(payload))
        File.chmod(0o600, temporary)
        File.rename(temporary, state_path)
      ensure
        FileUtils.rm_f(temporary) if defined?(temporary) && temporary
      end

      def default_output
        File.join(File.dirname(source), "#{File.basename(source, '.mpr')}.domain-layout.mpr")
      end

      def prepare_instance_dir
        FileUtils.mkdir_p(instance_dir)
        File.chmod(0o700, instance_dir)
      end

      def url_for(state) = "http://#{state.fetch('host')}:#{state.fetch('port')}"
      def instance_dir = File.join(state_root, Digest::SHA256.hexdigest(source)[0, 24])
      def state_path = File.join(instance_dir, 'state.json')
      def log_path = File.join(instance_dir, 'server.log')
    end
    # rubocop:enable Metrics
  end
end
