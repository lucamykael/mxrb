# frozen_string_literal: true

require 'base64'
require 'bigdecimal'
require 'json'
require 'socket'
require 'uri'

module Mxrb
  module Runtime
    # Runs the project's own Java actions, which have no Ruby adapter, in an
    # opt-in sidecar container. The Ruby application stays the Runtime: the
    # sidecar gets handles to the calling microflow's objects and reads, changes,
    # commits and retrieves them through callbacks, so the transaction, the
    # events and the security context stay in Ruby.
    #
    # Each invocation is one TCP connection carrying JSON messages, one per line:
    #   -> {"id":0,"method":"invoke","params":{"action":..,"arguments":[..]}}
    #   <- {"id":n,"method":<callback>,"params":{..}}  -> {"id":n,"result":..}
    #   <- {"id":0,"result":..} or {"id":0,"error":{"type":..,"message":..}}
    class JavaSidecar
      URL = 'MXRB_JAVA_ACTIONS_URL'
      TOKEN = 'MXRB_JAVA_ACTIONS_TOKEN'
      TIMEOUT = 'MXRB_JAVA_ACTIONS_TIMEOUT'
      DEFAULT_TIMEOUT = 300

      # The sidecar an environment enables; nil keeps Java actions without a
      # Ruby adapter failing closed. The services answer what the Runtime API
      # asks of the application: its metamodel, captions and file contents.
      def self.configured(environment = ENV, services: nil)
        url = environment[URL].to_s
        return nil if url.empty?

        new(url, token: environment[TOKEN], timeout: Float(environment.fetch(TIMEOUT, DEFAULT_TIMEOUT)), services:)
      end

      attr_reader :host, :port

      def initialize(url, token: nil, timeout: DEFAULT_TIMEOUT, services: nil)
        uri = URI.parse(url.include?('://') ? url : "tcp://#{url}")
        raise ArgumentError, "#{URL} must be tcp://host:port, got #{url.inspect}" unless valid?(uri)

        @host = uri.host
        @port = uri.port
        @token = token.to_s.empty? ? nil : token.to_s
        @timeout = timeout
        @services = services
      end

      # Runs a Java action with its parameters in model order and returns its result.
      def invoke(name, parameters, context:)
        session = Session.new(context, @services)
        exchange('invoke', session,
                 'action' => name.to_s, 'arguments' => parameters.map { [_1.to_s, session.encode(_2)] })
      end

      # Forwards an HTTP request to the handler Core.addRequestHandler registered for
      # its path: method, path, query, headers, cookies, body, remote_addr and
      # root_url, with the session of its cookie (nil without one). The handler's
      # response comes back as status, content_type, headers, cookies and body.
      def request(handler, http, session:, context:)
        codec = Session.new(context, @services)
        http = http.merge('body' => Codec::Binary.new(http.fetch('body', '').to_s.b))
        exchange('request', codec,
                 'handler' => handler.to_s, 'request' => codec.encode(http), 'session' => codec.encode(session))
      end

      # Keeps a connection on which the sidecar asks for a connection of its own
      # for each callback of work a Java action left running (an MQTT listener,
      # say), and yields each ticket. It reconnects while running holds.
      def listen(running:, retry_after: 1)
        while running.call
          begin
            listening(running) { yield _1 }
          rescue NativeRuntimeError, JSON::ParserError
            sleep(retry_after)
          end
        end
      end

      # Serves one callback of background work on the connection asked for.
      def attach(ticket, context:)
        exchange('attach', Session.new(context, @services), 'ticket' => ticket.to_s)
      end

      private

      def listening(running)
        connect do |socket|
          params = @token ? { 'token' => @token } : {}
          write(socket, 'id' => 0, 'method' => 'listen', 'params' => params)
          while running.call
            next unless socket.wait_readable(0.5)

            line = socket.gets or raise NativeRuntimeError, 'the Java action sidecar closed the listen connection'
            message = JSON.parse(line)
            yield message.dig('params', 'ticket').to_s if message['method'] == 'attach'
          end
        end
      end

      def exchange(method, session, params)
        connect do |socket|
          params['token'] = @token if @token
          write(socket, 'id' => 0, 'method' => method, 'params' => params)
          serve(socket, session)
        end
      end

      def valid?(uri) = uri.scheme == 'tcp' && !uri.host.to_s.empty? && uri.port

      def connect
        socket = Socket.tcp(@host, @port, connect_timeout: @timeout)
        yield socket
      rescue SystemCallError, SocketError, IOError => e
        raise NativeRuntimeError, "Java action sidecar at #{@host}:#{@port} is unavailable: #{e.message}"
      ensure
        socket&.close
      end

      def serve(socket, session)
        loop do
          message = read(socket)
          return finish(message, session) if message['id'].zero? && !message.key?('method')

          write(socket, session.answer(message))
        end
      end

      def finish(message, session)
        return session.decode(message['result']) unless message.key?('error')

        error = message['error'] || {}
        raise JavaActionError.new(error['type'].to_s, error['message'].to_s)
      end

      def read(socket)
        line = socket.wait_readable(@timeout) && socket.gets
        raise NativeRuntimeError, "Java action sidecar at #{@host}:#{@port} did not answer" if line.nil?

        message = JSON.parse(line)
        raise NativeRuntimeError, 'Java action sidecar sent a malformed message' unless valid_message?(message)

        message
      rescue JSON::ParserError
        raise NativeRuntimeError, 'Java action sidecar sent a malformed message'
      end

      def valid_message?(message) = message.is_a?(Hash) && message['id'].is_a?(Integer)

      def write(socket, message)
        socket.write("#{JSON.generate(message)}\n")
      end

      # The objects one invocation has seen, by handle, and the callbacks the
      # Java side may make while it runs.
      class Session # rubocop:disable Metrics/ClassLength
        CALLBACKS = %w[
          log get set member related instantiate commit delete rollback retrieve microflow
          constant end_transaction changed original session application_root_url runtime_version model_version
          metamodel caption file store_file message oql request_handler guest_session guest_login_enabled
          long_id object_for_long default_language
        ].freeze
        LOG_LEVELS = {
          'TRACE' => 'Trace', 'DEBUG' => 'Debug', 'INFO' => 'Info',
          'WARNING' => 'Warning', 'ERROR' => 'Error', 'CRITICAL' => 'Critical'
        }.freeze

        def initialize(context, services = nil)
          @context = context
          @services = services
          @codec = Codec.new
        end

        def answer(message)
          method = message['method'].to_s
          raise NativeRuntimeError, "unknown Java action callback #{method.inspect}" unless CALLBACKS.include?(method)

          params = decode(message['params'] || {})
          { 'id' => message['id'], 'result' => encode(public_send("callback_#{method}", params)) }
        rescue StandardError => e
          type = e.respond_to?(:java_class) ? e.java_class : 'com.mendix.core.CoreException'
          { 'id' => message['id'], 'error' => { 'type' => type, 'message' => e.message } }
        end

        def callback_log(params)
          level = LOG_LEVELS.fetch(params['level'].to_s) { raise ArgumentError, "unknown log level #{params['level']}" }
          @context.log(params['node'], level, params['message'])
        end

        # IMendixObject.getValue: an Integer attribute is a java.lang.Integer and
        # an empty reference set an empty list, as the generated proxies expect.
        def callback_get(params)
          object, name = member!(params)
          typed(object, name, object.members[name])
        end

        def callback_set(params)
          object, name = member!(params)
          object.members[name] = params['value']
          @context.store.touch(object) if @context.store.respond_to?(:touch)
          nil
        end

        def callback_member(params)
          @context.member_kind(object!(params['object']).entity, member(params['member']))&.to_s
        end

        # Core.retrieveByPath: the objects an association relates the object to.
        def callback_related(params)
          @context.store.retrieve_association(member(params['association']), object!(params['object']))
        end

        def callback_instantiate(params) = @context.store.create(params['entity'].to_s, events: events?(params))

        def callback_commit(params)
          @context.store.commit(objects!(params['objects']), events: events?(params))
          nil
        end

        def callback_delete(params)
          @context.store.delete(objects!(params['objects']), events: events?(params))
          nil
        end

        def callback_rollback(params)
          @context.store.rollback(objects!(params['objects']))
          nil
        end

        # Core.retrieveXPathQuery: "//Module.Entity[constraint]..." with variables,
        # an offset, an amount (0 or less for all) and sortings as [path, descending].
        def callback_retrieve(params)
          @context.retrieve(params['xpath'].to_s, params['variables'].to_h,
                            offset: Integer(params.fetch('offset', 0)), amount: Integer(params.fetch('amount', -1)),
                            sort: Array(params['sort']).map { [_1.fetch(0).to_s, _1.fetch(1) == true] })
        end

        # Core.microflowCall: as the user of the context's session, when it has another one.
        def callback_microflow(params)
          @context.call_flow(params['name'].to_s, params['arguments'].to_h, username: params['user'],
                                                                            sudo: params['sudo'] == true)
        end

        def callback_constant(params) = @context.constant(params['name'].to_s)
        def callback_end_transaction(_params) = @context.end_transaction
        def callback_changed(params) = @context.changed?(object!(params['object']))

        # The members at the last commit, nil for an object never committed.
        def callback_original(params)
          object = object!(params['object'])
          @context.store.original(object)&.to_h { |name, value| [name, typed(object, name, value)] }
        end

        def callback_session(_params) = @context.session
        def callback_default_language(_params) = @context.default_language

        # Core.addRequestHandler: the application's server forwards the path's requests.
        def callback_request_handler(params) = services.register_request_handler(params['path'].to_s) && nil

        # Core.initializeGuestSession: a guest's session, which the handler's cookie carries.
        def callback_guest_session(_params) = services.guest_session
        def callback_guest_login_enabled(_params) = services.guest_login_enabled?

        # IMendixIdentifier.toLong and Core.createMendixIdentifier: a number kept for an object.
        def callback_long_id(params) = numbered_store.long_id(object!(params['object']))
        def callback_object_for_long(params) = numbered_store.object_for_long(Integer(params['id']))
        def callback_application_root_url(_params) = @context.application_root_url
        def callback_runtime_version(_params) = @context.runtime_version
        def callback_model_version(_params) = @context.model_version
        def callback_metamodel(_params) = services.metamodel

        # Core.getInternationalizedString of an enumeration value's caption.
        def callback_caption(params)
          services.caption(params['enumeration'].to_s, params['value'].to_s, params['language'])
        end

        # FeedbackHelper.addTextMessageFeedback: the calling microflow shows the message.
        def callback_message(params)
          @context.show_message(params['type'].to_s, params['message'].to_s, blocking: params['blocking'] == true)
        end

        # Core.retrieveOQLDataTable: OQL text or a dataset's name, with parameters,
        # an offset and an amount (0 or less for all); an ID column holds the object.
        def callback_oql(params) # rubocop:disable Metrics/AbcSize
          store = @context.store
          raise NativeRuntimeError, 'OQL needs the application database' unless store.respond_to?(:oql_table)

          table = store.oql_table(params['query'].to_s, parameters: params['parameters'].to_h)
          columns = table.definition.columns
          { 'columns' => columns.map { [_1.name, _1.type.to_s] },
            'rows' => page(table.rows, params).map { |row| columns.map { oql_value(_1.type, row[_1.name]) } } }
        end

        def callback_file(params) = Codec::Binary.new(@context.file_content(object!(params['object'])))

        def callback_store_file(params)
          services.store_file(@context.store, object!(params['object']), params['name'].to_s, params['content'].to_s)
          nil
        end

        def encode(value) = @codec.encode(value)
        def decode(value) = @codec.decode(value)

        private

        def object!(value)
          raise ArgumentError, "expected an object, got #{value.inspect}" unless value.is_a?(Native::ObjectValue)

          value
        end

        def objects!(values) = Array(values).map { object!(_1) }

        def member!(params)
          object = object!(params['object'])
          name = member(params['member'])
          raise ArgumentError, "#{object.entity} has no member #{name}" unless @context.member_kind(object.entity, name)

          [object, name]
        end

        def page(rows, params)
          rows = rows.drop(Integer(params.fetch('offset', 0)))
          amount = Integer(params.fetch('amount', -1))
          amount.positive? ? rows.first(amount) : rows
        end

        def oql_value(type, value)
          case type
          when :integer then value.nil? ? nil : Codec::JavaInteger.new(value)
          when :identifier then value.nil? ? nil : @context.store.locate(value)
          else value
          end
        end

        def typed(object, name, value)
          case @context.member_kind(object.entity, name)
          when :integer then value.nil? ? nil : Codec::JavaInteger.new(value)
          when :reference_set then Array(value)
          else value
          end
        end

        # Members are stored by their short name: "Name", or "Assoc" for "Module.Assoc".
        def member(name) = name.to_s.split(%r{[./]}).last.to_s

        def events?(params) = params['events'] != false

        def services = @services || raise(NativeRuntimeError, 'the application offers no Runtime services')

        def numbered_store
          store = @context.store
          return store if store.respond_to?(:long_id)

          raise NativeRuntimeError, 'numeric object ids need the application database'
        end
      end

      # The values of the protocol: JSON scalars and lists, decimals, dates and
      # objects tagged by a "$" key, objects by their handle in the invocation.
      class Codec
        # A java.lang.Integer, which an Integer attribute's value is in Java.
        JavaInteger = Data.define(:value)
        # Bytes, such as a file document's contents.
        Binary = Data.define(:bytes)

        def initialize
          @objects = []
          @handles = {}.compare_by_identity
        end

        def encode(value) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
          case value
          when nil, true, false, String, Integer then value
          when JavaInteger then { '$integer' => value.value }
          when Binary then { '$binary' => Base64.strict_encode64(value.bytes) }
          when Hash then value.to_h { [_1.to_s, encode(_2)] }
          when BigDecimal then { '$decimal' => value.to_s('F') }
          when Float then { '$decimal' => BigDecimal(value.to_s).to_s('F') }
          when Time then { '$datetime' => (value.to_r * 1000).floor }
          when Native::ObjectValue then { '$object' => handle(value), 'entity' => value.entity, 'id' => value.id }
          when Array then value.map { encode(_1) }
          when Symbol then value.to_s
          else raise NativeRuntimeError, "cannot pass #{value.class} to a Java action"
          end
        end

        # Values the Java side sends: tagged decimals, dates and object handles,
        # lists, and maps of names to values (variables, arguments, parameters).
        def decode(value)
          case value
          when Array then value.map { decode(_1) }
          when Hash then tagged?(value) ? decode_tagged(value) : value.transform_values { decode(_1) }
          else value
          end
        end

        private

        def tagged?(value) = value.keys.first.to_s.start_with?('$')

        def decode_tagged(value) # rubocop:disable Metrics/AbcSize
          if value.key?('$decimal') then BigDecimal(value['$decimal'].to_s)
          elsif value.key?('$datetime') then Time.at(Rational(Integer(value['$datetime']), 1000)).utc
          elsif value.key?('$object') then object(value['$object'])
          elsif value.key?('$binary') then Base64.strict_decode64(value['$binary'].to_s)
          else raise NativeRuntimeError, "Java action sent an unknown value #{value.keys.inspect}"
          end
        end

        def handle(object)
          @handles[object] ||= begin
            @objects << object
            @objects.size - 1
          end
        end

        def object(handle)
          object = handle.is_a?(Integer) && !handle.negative? ? @objects[handle] : nil
          raise NativeRuntimeError, "unknown object handle #{handle.inspect}" unless object

          object
        end
      end
    end
  end
end
