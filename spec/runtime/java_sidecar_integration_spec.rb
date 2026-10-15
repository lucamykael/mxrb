# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# The sidecar of docker/java-actions, built and started as its image does, runs the
# fixture's Java actions for an exported Ruby application.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'Java action sidecar' do
  let(:fixture) { 'spec/fixtures/java_action_sidecar' }
  let(:sidecar) { File.expand_path('../../docker/java-actions/src', __dir__) }

  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'project', 'Runtime.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = @source
      load File.join(fixture, 'project.rb')
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @application&.close
      stop_sidecar
      Mxrb::RubyApp::Registry.reset!
    end
  end

  def build_sidecar
    api = File.join(@directory, 'api')
    sources = Dir.glob(File.join(sidecar, '**', '*.java'))
    run!('javac', '-d', api, *sources)
    classes = File.join(@directory, 'classes')
    report = File.join(@directory, 'build-report.tsv')
    javasource = File.join(File.dirname(@source), 'javasource')
    output = run!('java', '-cp', api, 'mxrb.sidecar.Build', javasource, File.join(@directory, 'userlib'), classes,
                  report)
    [api, classes, report, output]
  end

  def start_sidecar(api, classes, report)
    environment = { 'MXRB_JAVA_ACTIONS_PORT' => '0', 'MXRB_JAVA_ACTIONS_REPORT' => report }
    stdin, stdout, @sidecar_process = Open3.popen2(environment, 'java', '-cp', [api, classes].join(':'),
                                                   'mxrb.sidecar.Server')
    stdin.close
    Integer(stdout.gets.to_s[/port (\d+)/, 1])
  end

  def stop_sidecar
    return unless @sidecar_process

    Process.kill('TERM', @sidecar_process.pid)
    @sidecar_process.join
  rescue Errno::ESRCH
    nil
  end

  def run!(*command)
    output, status = Open3.capture2e(*command)
    raise "#{command.first} failed:\n#{output}" unless status.success?

    output
  end

  def export(process = {})
    target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, target, mode: :ruby).export!
    process = process.merge('MXRB_DATABASE_PATH' => File.join(@directory, 'runtime.sqlite3'))
    @application = Mxrb::RubyApp::Application.new(target, process:)
  end

  it 'hands the Java actions without a Ruby adapter to the configured sidecar' do
    sidecar = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def invoke(name, parameters, context:)
        @calls << [name, parameters]
        context.retrieve('//Views.Order[Name = $name]', { 'name' => parameters.to_h['text'] }).size.to_s
      end
    end.new
    allow(Mxrb::Runtime::JavaSidecar).to receive(:configured).and_return(sidecar)
    export
    expect(@application.call_service('Views.Upper', { 'Value' => 'none' })).to eq('0')
    expect(sidecar.calls).to eq([['Views.Shout', [%w[text none]]]])

    interpreter = @application.send(:bridge).interpreter
    store = interpreter.store
    orders = [%w[a 2], %w[b 9], %w[a 5]].map do |name, quantity|
      store.create('Views.Order').tap { _1.members.merge!('Name' => name, 'Quantity' => Integer(quantity)) }
    end
    names = ->(values) { values.map { _1.members.values_at('Name', 'Quantity').join } }
    expect(names.call(interpreter.retrieve_xpath('Views.Order', '', sort: [['Quantity', true]])))
      .to eq(%w[b9 a5 a2])
    expect(names.call(interpreter.retrieve_xpath('Views.Order', '[Name = $name]', { 'name' => 'a' },
                                                 offset: 1, amount: 1, sort: [['Quantity', false]])))
      .to eq(%w[a5])
    expect(interpreter.retrieve_xpath('Views.Order', '', amount: 0).size).to eq(orders.size)
  end

  it 'runs the project Java actions against the Ruby application' do
    skip 'javac is unavailable' unless system('javac', '-version', out: File::NULL, err: File::NULL)

    api, classes, report, output = build_sidecar
    expect(output).to include('compiled 11 sources, left out 1')
    expect(File.read(report))
      .to start_with("views.actions.Unsupported\tline 24: cannot find symbol symbol: method getXASId()")
    port = start_sidecar(api, classes, report)

    export('MXRB_JAVA_ACTIONS_URL' => "tcp://127.0.0.1:#{port}")
    expect(@application.call_service('Views.RunAll')).to be(true)

    log = @application.send(:bridge).interpreter.log
    expect(log).to include('SidecarNode Info: hello from Java')
    expect(log.grep(/\AORACLE /).to_h { _1.delete_prefix('ORACLE ').split('=', 2) }).to eq(
      'echo' => 'hi|7|2.5|true|1767323045000',
      'describe_before' => 'first 3 Integer tags=0 customer=none changed=false',
      'describe_after' => 'filled 4 Integer tags=1 customer=Views.Customer changed=false',
      'customer' => 'Ada',
      'count_filled' => '1',
      'largest' => 'second',
      'total' => '9',
      'call_flow' => 'NESTED!',
      'greeting' => 'hello from a constant',
      'fail_message' => 'checked failure',
      'fail_type' => 'java.lang.IllegalStateException',
      'unsupported_type' => 'com.mendix.core.CoreRuntimeException'
    )
  end
end
# rubocop:enable Metrics/BlockLength
