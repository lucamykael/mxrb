# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Loopback HTTP server for the generated backend and browser frontend.
    class Server
      MAX_BODY_BYTES = 1_048_576
      LOOPBACK_HOSTS = %w[127.0.0.1 ::1 localhost].freeze

      attr_reader :host, :port, :application

      def initialize(root, host: '127.0.0.1', port: 9292, logger: nil, environment: nil,
                     reload: nil)
        @host = host.to_s
        raise ArgumentError, 'the Ruby application server must bind to loopback' unless LOOPBACK_HOSTS.include?(@host)

        @port = Integer(port)
        @application = Application.new(root, environment:, reload:)
        @logger = logger
      end

      def start
        @server = Http::Server.new(host:, port:, logger: @logger) { dispatch(_1, _2) }
        application.start_runtime
        @server.start { yield(_1) if block_given? }
      ensure
        application.close
      end

      def shutdown = @server&.shutdown

      private

      def sessions
        return @sessions if defined?(@sessions) && @sessions

        application.session_manager
      end

      def dispatch(request, response)
        application.reload_if_changed! if application.respond_to?(:reload_if_changed!)
        path = request.path
        method = request.request_method
        if method == 'GET' && path == '/api/health'
          return render_json(
            response, 200, ok: true, project: application.schema[:project],
                           environment: application.environment.name,
                           reload: application.reload_status
          )
        end

        if method == 'POST' && path == '/api/login'
          credentials = request_json(request)
          session = sessions.login(credentials['username'], credentials['password'])
          set_session_cookie(response, session.fetch(:token))
          public_session = session.reject { |key, _value| key == :token }
          return render_json(response, 200, { ok: true }.merge(public_session))
        end

        authorization = request_authorization(request)
        handler = application.java_request_handler(path)
        validate_csrf!(request, authorization) if !handler && unsafe_request?(method) && cookie_authenticated?(request)
        context = sessions.authenticate(authorization, client_time_zone: request['X-Mxrb-Time-Zone'])
        return forward_java_request(handler, request, response, context) if handler

        if method == 'GET' && path == '/api/session'
          return render_json(
            response, 200,
            user: context.user, roles: context.user_roles, module_roles: context.module_roles,
            language: application.user_language(context), csrf: sessions.csrf_token(authorization),
            time_zone: context.attributes['time_zone']
          )
        end
        if method == 'POST' && path == '/api/session/language'
          code = application.change_language(request_json(request)['code'], context:)
          return render_json(response, 200, language: code)
        end
        if method == 'POST' && path == '/api/logout'
          logged_out = sessions.logout(authorization)
          clear_session_cookie(response)
          return render_json(response, 200, ok: logged_out)
        end
        return render_json(response, 200, application.schema(context:)) if method == 'GET' && path == '/api/schema'
        return render_json(response, 200, application.schema(context:)[:navigation]) \
          if method == 'GET' && path == '/api/navigation'
        if method == 'GET' && path == '/api/pages'
          return render_json(
            response, 200,
            pages: application.schema(context:)[:modules].flat_map { _1.fetch('pages') }
          )
        end

        if (name = route_name(path, '/api/pages/')) && method == 'GET'
          page = application.page(name, context:)
          return render_json(response, page ? 200 : 404, page || error('not_found', "page #{name} not found"))
        end
        if method == 'POST' && path == '/api/microflow-jobs'
          values = request_json(request)
          job = application.async_invocations.submit(values['name'], values.fetch('arguments', {}),
                                                     owner: authorization, context:)
          return render_json(response, 202, job)
        end
        if (id = route_name(path, '/api/microflow-jobs/')) && method == 'GET'
          job = application.async_invocations.fetch(id, owner: authorization)
          return render_json(response, job ? 200 : 404, job || error('not_found', 'invocation not found'))
        end

        if (name = route_name(path, '/api/microflows/')) && method == 'POST'
          invocation = application.invoke_service(name, request_json(request), context:)
          return render_json(response, 200, { ok: true }.merge(invocation))
        end

        if method == 'POST' && path == '/api/records/draft'
          return render_json(response, 200, application.draft_record(request_json(request)['type'], context:))
        end

        if method == 'POST' && path == '/api/records/restore'
          values = request_json(request)
          return render_json(response, 200, application.restore_record(values['type'], values['attributes'], context:))
        end

        if method == 'POST' && path == '/api/records/delete'
          application.delete_records(request_json(request)['records'], context:)
          return render_json(response, 200, ok: true)
        end

        if method == 'POST' && path == '/api/records/commit'
          records = application.commit_records(request_json(request)['records'], context:)
          return render_json(response, 200, records:)
        end

        if (tail = route_name(path, '/api/files/')) && %w[GET PUT].include?(method)
          name, id = tail.split('/', 2)
          raise ArgumentError, 'file record id is required' if id.to_s.empty?

          upload = method == 'PUT' ? request_json(request, max_bytes: 28 * 1024 * 1024) : nil
          thumbnail = if request.query.key?('thumbnail_width') || request.query.key?('thumbnail_height')
                        [request.query['thumbnail_width'], request.query['thumbnail_height']]
                      end
          content = application.file_content(name, id, context:, upload:, thumbnail:)
          return render_json(response, 404, error('not_found', 'file not found')) unless content
          return render_json(response, 200, content) if upload

          response.status = 200
          response['Content-Type'] = content.fetch('media_type')
          inline = content.fetch('media_type').start_with?('image/') && request.query['download'] != '1'
          disposition = inline ? 'inline' : 'attachment'
          response['Content-Disposition'] =
            "#{disposition}; filename*=UTF-8''#{URI.encode_www_form_component(content.fetch('name'))}"
          response['X-Content-Type-Options'] = 'nosniff'
          response['Content-Security-Policy'] = "default-src 'none'; sandbox"
          response['Cache-Control'] = 'private, no-store'
          response.body = content.fetch('content')
          return
        end

        if (tail = route_name(path, '/api/entities/'))
          name, id = tail.split('/', 2)
          if method == 'GET' && id.nil?
            query = request.query.to_h
            scope = {
              context:, association: query['association'], context_type: query['context_type'],
              context_id: query['context_id']
            }
            if query.key?('xpath')
              scope.merge!(xpath: query['xpath'], xpath_context_type: query['xpath_context_type'],
                           xpath_context_id: query['xpath_context_id'])
              scope[:xpath_variables] = JSON.parse(query['xpath_variables']) if query.key?('xpath_variables')
            end
            page = if %w[filters sort offset limit].any? { query.key?(_1) }
                     application.record_page(
                       name, **scope, filters: query_json_array(query['filters'], 'filters'),
                                      sort: query_json_array(query['sort'], 'sort'),
                                      offset: query.fetch('offset', 0), limit: query['limit']
                     )
                   else
                     records = application.records(name, **scope)
                     { records:, total: records.length }
                   end
            return render_json(response, 200, page)
          end

          if method == 'GET' && id
            record = application.record(name, id, context:)
            return render_json(
              response, record ? 200 : 404,
              record || error('not_found', "#{name} #{id} not found")
            )
          end
          return render_json(response, 201, application.create_record(name, request_json(request), context:)) \
            if method == 'POST' && id.nil?

          if %w[PUT PATCH].include?(method) && id
            record = application.update_record(name, id, request_json(request), context:)
            return render_json(
              response, record ? 200 : 404,
              record || error('not_found', "#{name} #{id} not found")
            )
          end

          if method == 'DELETE' && id
            deleted = application.delete_record(name, id, context:)
            return render_json(response, deleted ? 200 : 404, ok: deleted)
          end
        end

        if (match = rest_route(method, path))
          route, path_parameters = match
          return render_json(response, 401, error('unauthorized', 'Authenticated session required')) \
            if route['requires_authentication'] && authorization.to_s.empty?

          body = request.body.to_s.empty? ? nil : request_json(request)
          route_context = if !route['requires_authentication'] && authorization.to_s.empty?
                            nil
                          else
                            context
                          end
          result = application.invoke_rest(
            route, path_parameters:, query: request.query.to_h, body:, context: route_context
          )
          cors(response) if route['enable_cors']
          status = Integer(route.fetch('success_status', 200))
          if status == 204
            response.status = status
            response.body = ''
            return
          end
          return render_json(response, status, result)
        end

        if method == 'OPTIONS' && application.rest_routes.any? { path_match(_1.fetch('path'), path) }
          cors(response)
          response.status = 204
          return
        end

        return render_static(request, response) if method == 'GET' && !path.start_with?('/api/')

        render_json(response, 404, error('not_found', "route #{method} #{path} not found"))
      rescue JSON::ParserError, ArgumentError => e
        render_json(response, 400, error('invalid_request', e.message))
      rescue AuthenticationError => e
        render_json(response, 401, error('unauthorized', e.message))
      rescue Runtime::AuthorizationError => e
        render_json(response, 403, error('forbidden', e.message))
      rescue NotFoundError => e
        render_json(response, 404, error('not_found', e.message))
      rescue RecordValidationError => e
        render_json(response, 422, error('validation_failed', e.message).merge(validation: e.errors))
      rescue NativeRuntimeError => e
        render_json(response, 422, error('runtime_error', e.message))
      end

      # A request handler of a Java action answers as it sets status, headers,
      # cookies and body; it guards its own requests, so no CSRF token applies.
      def forward_java_request(handler, request, response, context)
        cookies = request['Cookie'].to_s.split(';').to_h do |pair|
          name, value = pair.strip.split('=', 2)
          [name, value.to_s]
        end
        result = application.handle_java_request(handler, {
                                                   'method' => request.request_method, 'path' => request.path,
                                                   'query' => URI.encode_www_form(request.query),
                                                   'headers' => request.headers.to_h, 'cookies' => cookies,
                                                   'body' => request.body.to_s, 'remote_addr' => '127.0.0.1'
                                                 }, context:)
        response.status = Integer(result.fetch('status'))
        response['Content-Type'] = result['content_type'] if result['content_type']
        result.fetch('headers').each { |name, value| response[name] = value }
        set_cookies = result.fetch('cookies').map { java_cookie(_1) }
        response['Set-Cookie'] = set_cookies unless set_cookies.empty?
        response.body = result.fetch('body')
      end

      def java_cookie(cookie)
        attributes = ["#{cookie.fetch('name')}=#{cookie.fetch('value')}", "Path=#{cookie.fetch('path') || '/'}",
                      'SameSite=Lax']
        attributes << "Max-Age=#{cookie['max_age']}" if cookie['max_age'].to_i >= 0
        attributes << 'HttpOnly' if cookie['http_only']
        attributes << 'Secure' if ENV['MXRB_SECURE_COOKIES'] == 'true'
        attributes.join('; ')
      end

      def rest_route(method, path)
        application.rest_routes.each do |route|
          next unless route.fetch('method') == method

          match = path_match(route.fetch('path'), path)
          return [route, match.named_captures] if match
        end
        nil
      end

      def path_match(template, path)
        names = []
        pattern = Regexp.escape(template).gsub(/\\\{([A-Za-z_]\w*)\\\}/) do
          names << Regexp.last_match(1)
          '([^/]+)'
        end
        match = %r{\A#{pattern}/?\z}.match(path)
        return unless match

        values = names.zip(match.captures.map { URI.decode_www_form_component(_1) }).to_h
        Struct.new(:named_captures).new(values)
      end

      def cors(response)
        response['Access-Control-Allow-Origin'] = '*'
        response['Access-Control-Allow-Headers'] = 'Authorization, Content-Type'
        response['Access-Control-Allow-Methods'] = 'GET, POST, PUT, PATCH, DELETE, OPTIONS'
      end

      def request_authorization(request)
        header = request['Authorization'].to_s
        return header unless header.empty?

        token = request['Cookie'].to_s.split(';').filter_map do |part|
          name, value = part.strip.split('=', 2)
          value if name == 'mxrb_session'
        end.first
        token && "Bearer #{token}"
      end

      def cookie_authenticated?(request)
        request['Authorization'].to_s.empty? && request['Cookie'].to_s.match?(/(?:\A|;\s*)mxrb_session=/)
      end

      def unsafe_request?(method) = !%w[GET HEAD OPTIONS].include?(method)

      def validate_csrf!(request, authorization)
        return if sessions.valid_csrf?(authorization, request['X-CSRF-Token'])

        raise AuthenticationError, 'invalid or missing CSRF token'
      end

      def set_session_cookie(response, token)
        attributes = ["mxrb_session=#{token}", 'Path=/', 'HttpOnly', 'SameSite=Strict',
                      "Max-Age=#{sessions.ttl}"]
        attributes << 'Secure' if ENV['MXRB_SECURE_COOKIES'] == 'true'
        response['Set-Cookie'] = attributes.join('; ')
      end

      def clear_session_cookie(response)
        response['Set-Cookie'] = 'mxrb_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0'
      end

      def route_name(path, prefix)
        return unless path.start_with?(prefix)

        URI.decode_www_form_component(path.delete_prefix(prefix))
      end

      def request_json(request, max_bytes: MAX_BODY_BYTES)
        body = request.body.to_s
        if body.bytesize > max_bytes
          raise ArgumentError,
                max_bytes == MAX_BODY_BYTES ? 'request body exceeds 1 MiB' : 'request body exceeds allowed limit'
        end
        return {} if body.empty?

        JSON.parse(body).tap do |payload|
          raise ArgumentError, 'JSON body must be an object' unless payload.is_a?(Hash)
        end
      end

      def query_json_array(value, name)
        return [] if value.to_s.empty?

        JSON.parse(value).tap do |payload|
          raise ArgumentError, "#{name} must be a JSON array" unless payload.is_a?(Array)
        end
      end

      def render_static(request, response)
        relative = request.path == '/' ? 'index.html' : request.path.delete_prefix('/')
        clean = Pathname.new(relative).cleanpath
        return render_json(response, 404, error('not_found', 'asset not found')) \
          if clean.absolute? || clean.to_s.start_with?('../')

        public_root = File.join(application.root, 'frontend', 'dist')
        path = File.join(public_root, clean.to_s)
        path = File.join(public_root, 'index.html') unless File.file?(path)
        response.status = File.file?(path) ? 200 : 404
        response['Content-Type'] = content_type(path)
        response.body = File.file?(path) ? File.binread(path) : 'Not found'
      end

      def content_type(path)
        case File.extname(path)
        when '.html' then 'text/html; charset=utf-8'
        when '.js' then 'text/javascript; charset=utf-8'
        when '.css' then 'text/css; charset=utf-8'
        when '.json' then 'application/json; charset=utf-8'
        else 'application/octet-stream'
        end
      end

      def error(code, message) = { ok: false, error: { code:, message: } }

      def render_json(response, status, payload)
        response.status = status
        response['Content-Type'] = 'application/json; charset=utf-8'
        response.body = JSON.generate(payload)
      end
    end
    # rubocop:enable Metrics
  end
end
