# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# The sidecar of docker/java-actions, built and started as its image does, runs the
# fixture's Java actions for an exported Ruby application.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'Java action sidecar' do
  let(:fixture) { 'spec/fixtures/java_action_sidecar' }

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

  # As the image does: the sidecar's sources, then the packaged javasource with its proxies.
  def build_sidecar(package)
    api = File.join(@directory, 'api')
    run!('javac', '-d', api, *Dir.glob(File.join(package, 'src', '**', '*.java')))
    classes = File.join(@directory, 'classes')
    report = File.join(@directory, 'build-report.tsv')
    output = run!('java', '-cp', api, 'mxrb.sidecar.Build', File.join(package, 'javasource'),
                  File.join(package, 'userlib'), classes, report)
    [api, classes, report, output]
  end

  def start_sidecar(api, classes, report, captions)
    environment = { 'MXRB_JAVA_ACTIONS_PORT' => '0', 'MXRB_JAVA_ACTIONS_REPORT' => report,
                    'MXRB_JAVA_ACTIONS_CAPTIONS' => captions }
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

  def export
    @target = File.join(@directory, 'ruby')
    Mxrb::Exporter.new(@source, @target, mode: :ruby).export!
  end

  def open_application(process = {})
    process = process.merge('MXRB_DATABASE_PATH' => File.join(@directory, 'runtime.sqlite3'))
    @application = Mxrb::RubyApp::Application.new(@target, process:)
  end

  # The application's server, as it answers a request.
  def dispatch(method, path, query: {}, cookie: nil, headers: {})
    server = Mxrb::RubyApp::Server.allocate
    server.instance_variable_set(:@application, @application)
    headers = Mxrb::Http::Headers.new(cookie ? headers.merge('Cookie' => cookie) : headers)
    request = Mxrb::Http::Request.new(path:, request_method: method, body: '', query:, headers:)
    Mxrb::Http::Response.new.tap { server.send(:dispatch, request, _1) }
  end

  it 'hands the Java actions without a Ruby adapter to the configured sidecar' do
    sidecar = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def invoke(name, parameters, context:, http: nil)
        @calls << [name, parameters, http]
        context.retrieve('//Views.Order[Name = $name]', { 'name' => parameters.to_h['text'] }).size.to_s
      end

      def request(handler, request, session:, context:)
        @calls << [handler, request.slice('method', 'path', 'query', 'cookies', 'root_url'), session, context.session]
        { 'status' => 201, 'content_type' => nil, 'headers' => [%w[X-Handled yes]], 'body' => 'done',
          'cookies' => [{ 'name' => 'c', 'value' => 'v', 'path' => nil, 'max_age' => 60, 'http_only' => false }] }
      end
    end.new
    allow(Mxrb::Runtime::JavaSidecar).to receive(:configured).and_return(sidecar)
    export
    open_application
    expect(@application.call_service('Views.Upper', { 'Value' => 'none' })).to eq('0')
    expect(sidecar.calls).to eq([['Views.Shout', [%w[text none]], nil]])

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

    @application.send(:bridge).sidecar_services.register_request_handler('/fake/')
    previous = ENV.fetch('MXRB_SECURE_COOKIES', nil)
    ENV['MXRB_SECURE_COOKIES'] = 'true'
    response = dispatch('POST', '/fake/x', query: { 'a' => '1' }, cookie: 'other=1; flag')
    expect([response.status, response.body, response['X-Handled'], response['Content-Type']])
      .to eq([201, 'done', 'yes', nil])
    expect(response['Set-Cookie']).to eq(['c=v; Path=/; SameSite=Lax; Max-Age=60; Secure'])
    handler, request, session, java = sidecar.calls.last
    expect([handler, session, java['id']]).to eq(['fake', nil, nil])
    expect(request.except('root_url')).to eq('method' => 'POST', 'path' => '/fake/x', 'query' => 'a=1',
                                             'cookies' => { 'other' => '1', 'flag' => '' })
    expect(request['root_url']).to start_with('http')
  ensure
    ENV['MXRB_SECURE_COOKIES'] = previous
  end

  it 'serves background work through the configured sidecar while the runtime runs' do
    sidecar = Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def listen(running:)
        yield 'ticket'
        sleep 0.01 while running.call
      end

      def attach(ticket, context:)
        @calls << [ticket, context.class]
        raise 'background failure' if ticket == 'broken'
      end
    end.new
    allow(Mxrb::Runtime::JavaSidecar).to receive(:configured).and_return(sidecar)
    export
    open_application
    @application.start_runtime
    @application.start_java_listener
    deadline = Time.now + 5
    sleep 0.01 until sidecar.calls.any? || Time.now > deadline
    expect(sidecar.calls).to eq([['ticket', Mxrb::Runtime::JavaActionContext]])
    expect { @application.send(:attach_java_work, 'broken') }.to output(/background failure/).to_stderr
    @application.stop_java_listener
    @application.stop_java_listener
  end

  it 'needs the sidecar for request handlers and background work' do
    Mxrb.open(@source) do |project|
      interpreter = Mxrb::Runtime::Native::Interpreter.new(project)
      expect { interpreter.java_request('x', {}) }
        .to raise_error(Mxrb::NativeRuntimeError, 'request handlers need the Java actions sidecar')
      expect { interpreter.java_attach('x') }
        .to raise_error(Mxrb::NativeRuntimeError, 'background work needs the Java actions sidecar')
    end
  end

  it 'runs the project Java actions against the Ruby application' do
    skip 'javac is unavailable' unless system('javac', '-version', out: File::NULL, err: File::NULL)

    export
    File.write(File.join(@target, 'docker-compose.yml'), "# kept\n")
    result = Mxrb::RubyApp::JavaActionsPackage.new(@source, @target).write!
    package = File.join(@target, 'java-actions')
    expect(result.to_h).to eq(directory: package, sources: 27, proxies: 4, libraries: 0)
    expect(File.read(File.join(@target, 'docker-compose.yml'))).to eq("# kept\n")
    expect(File.read(File.join(package, 'javasource', 'views', 'Words.java'))).to include('"ação"')
    expect(File).to exist(File.join(package, 'Dockerfile'))

    api, classes, report, output = build_sidecar(package)
    expect(output).to include('compiled 30 sources, left out 1')
    expect(File.read(report))
      .to match(/\Aviews\.actions\.Unsupported\tline \d+: cannot find symbol symbol: method notInTheRuntimeApi\(/)
    port = start_sidecar(api, classes, report, File.join(package, 'captions.tsv'))
    open_application('MXRB_JAVA_ACTIONS_URL' => "tcp://127.0.0.1:#{port}", 'MXRB_ADMIN_PASSWORD' => 'Adm1n!pass')
    @application.start_runtime
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
      'unsupported_type' => 'com.mendix.core.CoreRuntimeException',
      'rename' => 'second->renamed Views.Order',
      'renamed_quantity' => '6',
      'accent' => 'ação',
      'inspect' => 'Views.Order Views true Name:String Quantity:Integer Status:Enum ' \
                   'Views.Order_Customer>Views.Customer:REFERENCE Views.Order_Tag>Views.Tag:REFERENCESET | ' \
                   'Name=MendixString Quantity=MendixInteger Status=MendixEnum ' \
                   'Views.Order_Customer=MendixObjectReference Views.Order_Tag=MendixObjectReferenceSet | ' \
                   'NORMAL false Views.Order System.FileDocument true true true',
      'track' => 'filled->tracked CHANGED UNCHANGED NORMAL INSTANTIATED true changed=1',
      'captions' => 'Aberto|Open|Closed|Fechado||11|[2, 4]',
      'microflows' => 'true [Value] String String Integer true null',
      'store' => 'hello note.txt 5 3 10 4',
      'oql' => '1 Id Ada Views.Customer Ada rush=1 Integer',
      'json' => '{"name":"Ada","count":4,"sum":3.5,"missing":null,"ok":true,"list":["a",1]}|fallback|true|false|true',
      'gaps' => '1 5.0 MxAdmin Administrator true false en_US mxrb true false',
      'nonce_outside' => 'none false'
    )
    expect(@application.send(:bridge).interpreter.effects)
      .to include(type: 'show_message', level: 'warning', blocking: true, message: 'stored hello')
    remembered = lambda do
      labels = @application.send(:bridge).store.retrieve('Views.Tag').map { _1.members['Label'] }
      (['from a finished invocation', 'from the background'] - labels).empty?
    end
    deadline = Time.now + 10
    sleep 0.05 until remembered.call || Time.now > deadline
    expect(remembered.call).to be(true)

    first = dispatch('GET', '/hello/world', query: { 'q' => '1' })
    expect(first.status).to eq(200)
    cookie = first['Set-Cookie'].first
    token = cookie[/\Amxrb_session=([^;]+)/, 1]
    expect(cookie).to include('Path=/', 'HttpOnly')
    expect(cookie).not_to include('Max-Age')
    expect(first['Content-Type']).to eq('text/plain')
    expect(first['X-Path-Info']).to eq('/world')
    expect(first.body).to eq('world q=1 fresh=true anonymous=true true Ada true guests=true /hello')
    second = dispatch('POST', '/hello', cookie: "mxrb_session=#{token}")
    expect(second.body).to start_with(' q=null fresh=false anonymous=true true Ada')
    expect(second['Set-Cookie']).to be_nil
    expect(dispatch('GET', '/api/session', cookie: "mxrb_session=#{token}").body).to include('"csrf":"')
    expect(dispatch('GET', '/helloworld').status).to eq(404)

    nonce = dispatch('GET', '/rest/nonce/v1/nonce/read', cookie: 'nonce=abc', headers: { 'X-Probe' => 'one' })
    expect([nonce.status, nonce.body]).to eq([200, 'abc one /rest/nonce/v1/nonce/read'])
    expect(nonce['Set-Cookie']).to eq(['nonce=next; Path=/; HttpOnly', 'seen=1; Path=/; SameSite=Lax; Max-Age=60'])
    expect(dispatch('GET', '/rest/nonce/v1/nonce/read').body).to eq('no cookies null /rest/nonce/v1/nonce/read')
  end
end
# rubocop:enable Metrics/BlockLength
