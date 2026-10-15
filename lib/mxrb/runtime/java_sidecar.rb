# frozen_string_literal: true

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
      # Ruby adapter failing closed.
      def self.configured(environment = ENV)
        url = environment[URL].to_s
        return nil if url.empty?

        new(url, token: environment[TOKEN], timeout: Float(environment.fetch(TIMEOUT, DEFAULT_TIMEOUT)))
      end

      attr_reader :host, :port

      def initialize(url, token: nil, timeout: DEFAULT_TIMEOUT)
        uri = URI.parse(url.include?('://') ? url : "tcp://#{url}")
        raise ArgumentError, "#{URL} must be tcp://host:port, got #{url.inspect}" unless valid?(uri)

        @host = uri.host
        @port = uri.port
        @token = token.to_s.empty? ? nil : token.to_s
        @timeout = timeout
      end

      # Runs a Java action with its parameters in model order and returns its result.
      def invoke(name, parameters, context:)
        session = Session.new(context)
        connect do |socket|
          params = { 'action' => name.to_s, 'arguments' => parameters.map { [_1.to_s, session.encode(_2)] } }
          params['token'] = @token if @token
          write(socket, 'id' => 0, 'method' => 'invoke', 'params' => params)
          serve(socket, session)
        end
      end

      private

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
      class Session
        CALLBACKS = %w[
          log get set member related instantiate commit delete rollback retrieve microflow
          constant end_transaction changed user application_root_url runtime_version model_version
        ].freeze
        LOG_LEVELS = {
          'TRACE' => 'Trace', 'DEBUG' => 'Debug', 'INFO' => 'Info',
          'WARNING' => 'Warning', 'ERROR' => 'Error', 'CRITICAL' => 'Critical'
        }.freeze

        def initialize(context)
          @context = context
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
          value = object.members[name]
          case @context.member_kind(object.entity, name)
          when :integer then value.nil? ? nil : Codec::JavaInteger.new(value)
          when :reference_set then Array(value)
          else value
          end
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

        def callback_microflow(params) = @context.call_flow(params['name'].to_s, params['arguments'].to_h)
        def callback_constant(params) = @context.constant(params['name'].to_s)
        def callback_end_transaction(_params) = @context.end_transaction
        def callback_changed(params) = @context.changed?(object!(params['object']))
        def callback_user(_params) = @context.user
        def callback_application_root_url(_params) = @context.application_root_url
        def callback_runtime_version(_params) = @context.runtime_version
        def callback_model_version(_params) = @context.model_version

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

        # Members are stored by their short name: "Name", or "Assoc" for "Module.Assoc".
        def member(name) = name.to_s.split(%r{[./]}).last.to_s

        def events?(params) = params['events'] != false
      end

      # The values of the protocol: JSON scalars and lists, decimals, dates and
      # objects tagged by a "$" key, objects by their handle in the invocation.
      class Codec
        # A java.lang.Integer, which an Integer attribute's value is in Java.
        JavaInteger = Data.define(:value)

        def initialize
          @objects = []
          @handles = {}.compare_by_identity
        end

        def encode(value) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
          case value
          when nil, true, false, String, Integer then value
          when JavaInteger then { '$integer' => value.value }
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

        def decode_tagged(value)
          if value.key?('$decimal') then BigDecimal(value['$decimal'].to_s)
          elsif value.key?('$datetime') then Time.at(Rational(Integer(value['$datetime']), 1000)).utc
          elsif value.key?('$object') then object(value['$object'])
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
