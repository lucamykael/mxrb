# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio'
require 'open3'
require 'stringio'
require 'tmpdir'

# rubocop:disable Metrics
module StudioServerSpec
  # Minimal service with controllable methods.
  class FakeStudioService
    attr_reader :closed, :release

    def initialize(root = nil)
      @root = root
      @release = Queue.new
      @closed = false
    end

    def methods_list = %w[echo]

    def dispatch(method, params, context)
      case method
      when 'echo' then params
      when 'wait'
        context.on_cancel { @release << :cancelled }
        @release.pop
      when 'progress'
        context.with_progress('Working', total: 2) { |task| task.advance(detail: 'half') && :done }
      when 'cancel_self'
        context.cancel!
        :ignored
      when 'ruby_error' then Kernel.load(File.join(@root, 'broken.rb'))
      when 'syntax_error' then raise SyntaxError, 'unexpected end'
      when 'binary' then "\xFF".b
      else raise Mxrb::Studio::Protocol::Failure.new(Mxrb::Studio::Protocol::METHOD_NOT_FOUND, 'unknown')
      end
    end

    def close = @closed = true
  end

  # Drives a server over pipes, like an IDE over stdio.
  class Harness
    attr_reader :thread

    def initialize(server_class, service)
      @input, @writer = IO.pipe
      @reader, @output = IO.pipe
      @thread = Thread.new { server_class.new(input: @input, output: @output, service:).run }
    end

    def send_line(text) = @writer.write("#{text}\n")
    def send_message(message) = send_line(JSON.generate({ jsonrpc: '2.0' }.merge(message)))

    def read
      line = @reader.gets
      raise 'server closed its output' unless line

      JSON.parse(line, symbolize_names: true)
    end

    def read_until(&)
      loop do
        message = read
        return message if yield(message)
      end
    end

    def close
      @writer.close unless @writer.closed?
      @thread.join(5)
    end
  end
end

RSpec.describe Mxrb::Studio::Server do
  around do |example|
    previous = Mxrb::Studio::ProgressTask.instance_variable_get(:@interval)
    Mxrb::Studio::ProgressTask.interval = 0
    Dir.mktmpdir('mxrb-studio-server-') do |directory|
      @directory = directory
      example.run
    end
  ensure
    Mxrb::Studio::ProgressTask.interval = previous
  end

  let(:service) { StudioServerSpec::FakeStudioService.new(@directory) }
  let(:harness) { StudioServerSpec::Harness.new(described_class, service) }

  def initialize_session(roots: [])
    harness.send_message(id: 0, method: 'initialize', params: { protocol_versions: [2], roots: })
    harness.read
  end

  def run_lines(*lines, output: StringIO.new)
    described_class.new(input: StringIO.new(lines.map { "#{_1}\n" }.join), output:, service:).run
    output.string.lines.map { JSON.parse(_1, symbolize_names: true) }
  end

  it 'negotiates the protocol version and describes the server' do
    reply = initialize_session[:result]
    expect(reply[:protocol]).to eq(name: 'mxrb-studio', version: 2)
    expect(reply[:server]).to include(name: 'mxrb', version: Mxrb::VERSION, pid: Process.pid)
    expect(reply).to include(methods: ['echo'], notifications: described_class::NOTIFICATIONS)
    expect(reply[:capabilities]).to include(cancellation: true, framing: 'ndjson')
    replies = run_lines('{"jsonrpc":"2.0","id":1,"method":"initialize"}',
                        '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocol_version":2}}',
                        '{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocol_version":1}}')
    expect(replies[0..1].map { _1.dig(:result, :protocol, :version) }).to eq([2, 2])
    expect(replies[2][:error]).to include(code: -32_015, data: { supported: [2] })
    harness.close
  end

  it 'rejects malformed messages with JSON-RPC errors and ignores blank lines and notifications' do
    output = Class.new do
      attr_reader :string

      def initialize = @string = +''
      def write(text) = @string << text
    end.new
    replies = run_lines('not json', '[1]', '', '{"jsonrpc":"1.0","id":4,"method":"echo"}',
                        '{"jsonrpc":"2.0","id":1.5,"method":"echo"}', '{"jsonrpc":"2.0","id":5}',
                        '{"jsonrpc":"2.0","method":"unknown/notification"}',
                        '{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":99}}',
                        '{"jsonrpc":"2.0","id":6,"method":"echo"}', output:)
    expect(replies.map { _1.dig(:error, :code) }).to eq([-32_700, -32_600, -32_600, -32_600, -32_600, -32_002])
    expect(replies.map { _1[:id] }).to eq([nil, nil, 4, 1.5, 5, 6])
    expect(replies.last[:error][:data]).to eq(kind: 'not_initialized')
    expect(service.closed).to be(true)
  end

  it 'answers requests concurrently and shuts down after in-flight requests finish' do
    initialize_session
    harness.send_message(id: 1, method: 'wait')
    harness.send_message(id: 'two', method: 'echo', params: { value: 'ação' })
    expect(harness.read).to eq(jsonrpc: '2.0', id: 'two', result: { value: 'ação' })
    harness.send_message(id: 2, method: 'shutdown')
    sleep 0.1
    service.release << :released
    expect(harness.read).to eq(jsonrpc: '2.0', id: 1, result: 'released')
    expect(harness.read).to eq(jsonrpc: '2.0', id: 2, result: nil)
    harness.send_message(id: 3, method: 'echo')
    expect(harness.read[:error]).to include(code: -32_600, message: 'the server is shutting down')
    harness.send_message(method: 'exit')
    expect(harness.thread.join(5)).to be_truthy
    expect(service.closed).to be(true)
  end

  it 'cancels requests on $/cancelRequest and when the client goes away' do
    initialize_session
    harness.send_message(id: 7, method: 'wait')
    Thread.pass until service.release.num_waiting.positive?
    harness.send_message(method: '$/cancelRequest', params: { id: 7 })
    expect(harness.read).to include(id: 7, error: include(code: -32_800, message: 'request cancelled'))
    harness.send_message(id: 8, method: 'cancel_self')
    expect(harness.read[:error]).to include(code: -32_800, data: { kind: 'cancelled', type: 'Mxrb::Studio::Cancelled' })
    harness.send_message(id: 9, method: 'wait')
    Thread.pass until service.release.num_waiting.positive?
    harness.close
    expect(service.closed).to be(true)
  end

  it 'reports progress notifications and structured errors with workspace locations' do
    File.write(File.join(@directory, 'broken.rb'), "\nraise ArgumentError, 'invalid entity'\n")
    initialize_session(roots: [@directory])
    harness.send_message(id: 1, method: 'progress')
    messages = []
    messages << harness.read until messages.last&.key?(:id)
    expect(messages[0..-2].map { _1.dig(:params, :kind) }).to eq(%w[begin report end])
    expect(messages[1]).to include(method: '$/progress', params: include(token: 1, detail: 'half', current: 1))
    expect(messages.last).to include(id: 1, result: 'done')
    harness.send_message(id: 2, method: 'ruby_error', params: [1])
    error = harness.read[:error]
    expect(error).to include(code: -32_602, message: 'invalid entity')
    expect(error[:data]).to include(kind: 'invalid_params', type: 'ArgumentError',
                                    locations: [{ file: File.join(@directory, 'broken.rb'), line: 2 }])
    harness.send_message(id: 3, method: 'syntax_error', params: { root: @directory })
    expect(harness.read[:error]).to include(code: -32_014, data: include(kind: 'ruby_source'))
    harness.send_message(id: 4, method: 'missing')
    expect(harness.read[:error]).to eq(code: -32_601, message: 'unknown', data: { kind: 'method_not_found' })
    harness.send_message(id: 5, method: 'binary')
    expect(harness.read[:error]).to include(code: -32_603)
    harness.close
  end

  it 'serves the real backend from the command line' do
    requests = [
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocol_version: 2 } },
      { jsonrpc: '2.0', id: 2, method: 'ruby/syntax', params: { text: "entity :A do\nend\n" } },
      { jsonrpc: '2.0', id: 3, method: 'shutdown' },
      { jsonrpc: '2.0', method: 'exit' }
    ].map { JSON.generate(_1) }.join("\n")
    cli = File.expand_path('../bin/mxrb', __dir__)
    output, errors, status = Open3.capture3(RbConfig.ruby, cli, 'studio', 'serve', '--state-root',
                                            File.join(@directory, 'state'), stdin_data: "#{requests}\n")
    expect(status).to be_success, errors
    replies = output.lines.map { JSON.parse(_1, symbolize_names: true) }
    expect(replies.map { _1[:id] }).to eq([1, 2, 3])
    expect(replies[1][:result]).to eq(valid: true, diagnostics: [])
    _output, errors, status = Open3.capture3(RbConfig.ruby, cli, 'studio', 'other')
    expect(status).not_to be_success
    expect(errors).to include('Usage: mxrb studio serve')
    _output, _errors, status = Open3.capture3(RbConfig.ruby, cli, 'studio', 'serve', '--state-root')
    expect(status).not_to be_success
  end
end
# rubocop:enable Metrics
