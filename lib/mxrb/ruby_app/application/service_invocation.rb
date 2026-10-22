# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Application
      # rubocop:disable Metrics
      # Calls microflow services, REST operations and native actions.
      module ServiceInvocation
        # What a published REST operation answers: its returned value, and the status,
        # headers and content it set on its System.HttpResponse.
        RestResponse = Data.define(:result, :status, :headers, :content)

        def call_service(name, arguments = {}, synchronized_context: nil, context: nil)
          runtime_synchronize do
            implementation = Registry.fetch(:service, name.to_s)
            raise NativeRuntimeError, "microflow #{name} not found" unless implementation || microflow_exists?(name)

            authorize_document!(:microflow, name, :execute, context)
            normalized = arguments.to_h.transform_values { deserialize(_1, context:) }
            synchronize_context(synchronized_context, context:) if synchronized_context
            next native_call(name, normalized, context:) unless implementation

            keyword_arguments = normalized.transform_keys(&:to_sym)
            implementation.new(self, context:).call(**keyword_arguments)
          end
        end

        def invoke_service(name, arguments = nil, context: nil, **keyword_arguments)
          runtime_synchronize do
            arguments = keyword_arguments if arguments.nil?
            bridge.interpreter.clear_effects!
            invocation_arguments = arguments.to_h.dup
            synchronized_context = invocation_arguments.delete('__mxrb_context')
            staged = invocation_arguments.delete('__mxrb_changes') || []
            raise ArgumentError, 'staged changes must be a list of objects' unless
              staged.is_a?(Array) && staged.all?(Hash)

            bridge.interpreter.store.transaction do
              active_context = synchronize_context(synchronized_context, context:) if synchronized_context
              staged.each { synchronize_context(_1, context:) }
              implicit_context_argument(name, invocation_arguments, active_context, synchronized_context)
              result = call_service(name, invocation_arguments, context:)
              {
                result: serialize(result, context:), effects: serialize(bridge.interpreter.effects, context:),
                context: serialize(active_context, context:)
              }
            end
          ensure
            release_runtime_cache
          end
        end

        def rest_routes
          @rest_routes ||= manifest.modules.flat_map do |mod|
            mod.fetch('endpoints', []).flat_map do |endpoint|
              endpoint.fetch('operations', []).map do |operation|
                operation.merge(
                  'service' => endpoint.fetch('name'),
                  'enable_cors' => endpoint.fetch('enable_cors', false),
                  'requires_authentication' => endpoint.fetch('requires_authentication', false)
                )
              end
            end
          end
        end

        # With http: (the request's uri:, content: and headers:, and as java: the request
        # its Java actions get), the operation gets the
        # System.HttpRequest and System.HttpResponse its microflow asks for and answers
        # with a RestResponse, as Mendix 11.12.1 does: the response starts with the
        # operation's success status, and a returned value is the body before its content.
        def invoke_rest(route, path_parameters: {}, query: {}, body: nil, context: nil, http: nil)
          service = service_manifest(route.fetch('microflow'))
          arguments = request_arguments(service, path_parameters, query, body, context:)
          return invoke_service(route.fetch('microflow'), arguments, context:).fetch(:result) unless http

          runtime_synchronize do
            messages = {}
            messages = http_messages(service, http, Integer(route.fetch('success_status', 200)))
            messages.select! { |name, _message| accepts_argument?(route.fetch('microflow'), name) }
            arguments.merge!(messages.transform_values(&:last))
            exchange = Runtime::JavaSidecar::HttpExchange.new(http.fetch(:java))
            result = bridge.interpreter.with_http_exchange(exchange) do
              invoke_service(route.fetch('microflow'), arguments, context:).fetch(:result)
            end
            rest_response(result, messages.values.find { _1.first == 'System.HttpResponse' }&.last, exchange)
          ensure
            discard_http_messages(messages.values.map(&:last))
          end
        end

        def application_root_url = bridge.interpreter.application_root_url.delete_suffix('/')

        def native_call(name, arguments = {}, context: nil)
          runtime_synchronize do
            service = Registry.fetch(:service, name.to_s)
            kind = service&.native_kind == :nanoflow ? :nanoflow : :microflow
            authorize_document!(kind, name, :execute, context)
            serialize(
              bridge.interpreter.call(name.to_s, arguments.to_h.transform_keys(&:to_s), context:), context:
            )
          end
        end

        private

        # Uncommitted objects the context reaches (through non-persistent objects)
        # are the instances the call works on: a staged change to one of them
        # resumes that instance, not a copy from its draft snapshot.
        def stage_reachable_drafts(root, context:)
          store = bridge.interpreter.store
          return unless store.respond_to?(:resume_draft)

          owner = draft_owner(context)
          pending = [root]
          seen = {}
          until pending.empty?
            value = pending.pop
            next unless value.is_a?(Runtime::Native::ObjectValue) && !seen[[value.entity, value.id]]

            seen[[value.entity, value.id]] = true
            if store.find(value.entity, value.id).nil? && store.client_drafts.registered?(value, owner:)
              store.resume_draft(value)
            elsif !value.equal?(root) && !store.transient_entity?(value.entity)
              next
            end
            value.members.each_value { pending.concat(Array(_1)) }
          end
        end

        # A page action without parameter mappings passes the object of its data
        # view to the one unmapped parameter of a compatible entity.
        def implicit_context_argument(name, arguments, object, reference)
          return unless object.is_a?(Runtime::Native::ObjectValue)

          service = manifest.modules.flat_map { _1.fetch('services', []) }.find { _1['name'] == name.to_s }
          schema = bridge.interpreter.store.schema
          candidates = Array(service&.fetch('parameters', nil)).select do |parameter|
            entity = parameter['entity'].to_s
            !arguments.key?(parameter['name']) && !entity.empty? && schema.assignable?(object.entity, entity)
          end
          arguments[candidates.first.fetch('name')] = reference if candidates.one?
        end

        def microflow_exists?(name)
          bridge.project.modules.any? do |mod|
            mod.microflows.any? { "#{mod.name}.#{_1.name}" == name.to_s }
          end
        end

        def service_manifest(name)
          manifest.modules.flat_map { _1.fetch('services', []) }.find { _1.fetch('name') == name } ||
            raise(NativeRuntimeError, "REST microflow #{name} not found")
        end

        def request_arguments(service, path_parameters, query, body, context: nil)
          supplied = path_parameters.to_h.merge(query.to_h).transform_keys(&:to_s)
          supplied.merge!(body.transform_keys(&:to_s)) if body.is_a?(Hash)
          parameters = service.fetch('parameters', []).reject { rest_context_parameter?(_1) }
          unresolved = parameters.reject { |parameter| request_value(supplied, parameter.fetch('name')).first }
          if body && unresolved.one? && !body_matches_parameters?(body, parameters)
            supplied[unresolved.first.fetch('name')] = body
          end
          parameters.to_h do |parameter|
            found, value = request_value(supplied, parameter.fetch('name'))
            # The Runtime hands a query or header parameter left out of the request
            # as empty, whatever IsRequired says; only a missing body object fails.
            if !found && parameter['required'] && parameter['entity']
              raise NativeRuntimeError, "missing REST argument #{parameter.fetch('name')}"
            end

            [parameter.fetch('name'), deserialize_rest_value(value, parameter, context:)]
          end
        end

        def request_value(values, name)
          key = values.keys.find { _1.casecmp?(name.to_s) }
          [!key.nil?, key && values[key]]
        end

        # The HTTP messages of the operation's microflow parameters, by parameter name.
        def http_messages(service, http, status)
          store = bridge.interpreter.store
          service.fetch('parameters', []).select { rest_context_parameter?(_1) }.to_h do |parameter|
            entity = parameter.fetch('entity')
            message = store.create(entity)
            message.members.merge!('HttpVersion' => 'HTTP/1.1')
            if entity == 'System.HttpRequest'
              message.members.merge!('Uri' => http.fetch(:uri), 'Content' => http.fetch(:content))
              http.fetch(:headers).each do |key, value|
                store.create('System.HttpHeader').members.merge!('Key' => key, 'Value' => value,
                                                                 'HttpHeaders' => message)
              end
            else
              message.members['StatusCode'] = status
            end
            [parameter.fetch('name'), [entity, message]]
          end
        end

        # The response the microflow set, with the headers and cookies its Java actions added.
        def rest_response(result, response, exchange)
          return RestResponse.new(result:, status: nil, headers: exchange.headers, content: nil) unless response

          headers = bridge.interpreter.store.retrieve_association('HttpHeaders', response).map do |header|
            [header.members['Key'].to_s, header.members['Value'].to_s]
          end
          RestResponse.new(result:, status: response.members['StatusCode'], headers: headers + exchange.headers,
                           content: response.members['Content'])
        end

        # A controller action gets only the HTTP messages it declares; a microflow all.
        def accepts_argument?(name, argument)
          definition = Registry.fetch(:service, name.to_s)&.controller_definition
          return true unless definition

          controller = definition.fetch(:controller)
          controller = Registry.fetch(:controller, controller.to_s) unless controller.is_a?(Class)
          return true unless controller

          controller.instance_method(definition.fetch(:action)).parameters.any? do |kind, parameter|
            kind == :keyrest || (%i[key keyreq].include?(kind) && parameter.to_s == argument)
          end
        end

        # The messages live as long as the request, as the Runtime's do.
        def discard_http_messages(messages)
          store = bridge.interpreter.store
          Array(messages).each do |message|
            store.delete(store.retrieve_association('HttpHeaders', message) + [message], events: false)
          end
        end

        def rest_context_parameter?(parameter)
          %w[System.HttpRequest System.HttpResponse].include?(parameter['entity'].to_s)
        end

        def body_matches_parameters?(body, parameters)
          body.is_a?(Hash) && body.keys.any? do |key|
            parameters.any? { _1.fetch('name').casecmp?(key.to_s) }
          end
        end

        def deserialize_rest_value(value, parameter, context: nil)
          entity = parameter['entity']
          return deserialize(value) unless entity && value.is_a?(Hash) && !(value['id'] && value['type'])

          authorize_entity!(entity, :create, context)
          # The Runtime instantiates the entity, so the microflow or a Java action can commit it.
          object = bridge.interpreter.store.create(entity)
          value.each do |member, member_value|
            authorize_entity!(entity, :write, context, member:, record: object)
            object.members[member.to_s] = deserialize(member_value, context:)
          end
          object
        end
      end
      # rubocop:enable Metrics
    end
  end
end
