# frozen_string_literal: true

require 'json'
require 'webrick'

module Mxrb
  module Uml
    # Loopback-only unified viewer for class, activity, and sequence diagrams.
    # rubocop:disable Metrics
    class Server
      LOOPBACK_HOSTS = %w[127.0.0.1 ::1 localhost].freeze

      attr_reader :source, :host, :port

      def initialize(source, host: '127.0.0.1', port: 4569)
        @source = File.expand_path(source)
        raise ArgumentError, "MPR not found: #{@source}" unless File.file?(@source)

        @host = host.to_s
        raise ArgumentError, 'UML server must bind to loopback' unless LOOPBACK_HOSTS.include?(@host)

        @port = Integer(port)
      end

      def start
        @server = WEBrick::HTTPServer.new(
          BindAddress: host, Port: port, Logger: WEBrick::Log.new(File::NULL), AccessLog: []
        )
        @server.mount_proc('/') { dispatch(_1, _2) }
        yield(@server) if block_given?
        @server.start
      end

      def shutdown = @server&.shutdown

      private

      def dispatch(request, response)
        return render(response, 200, File.binread(asset_path), 'text/html; charset=utf-8') \
          if request.request_method == 'GET' && request.path == '/'
        return json(response, 405, ok: false, error: 'method_not_allowed') unless request.request_method == 'GET'

        payload = case request.path
                  when '/api/class' then class_payload(request.query)
                  when '/api/activity' then activity_payload(request.query)
                  when '/api/sequence' then sequence_payload(request.query)
                  when '/api/catalog' then catalog_payload
                  end
        return json(response, 404, ok: false, error: 'not_found') unless payload

        json(response, 200, payload)
      rescue ArgumentError, KeyError, Mxrb::Error => e
        json(response, 422, ok: false, error: e.message)
      end

      def class_payload(query)
        selected = query.fetch('modules', '').split(',').map(&:strip).reject(&:empty?)
        with_project do |project|
          modules = project.modules
          unless selected.empty?
            unknown = selected - modules.map(&:name)
            raise ArgumentError, "unknown modules: #{unknown.join(', ')}" unless unknown.empty?

            modules = modules.select { selected.include?(_1.name) }
          end
          formats(ClassDiagram.new(modules))
        end
      end

      def activity_payload(query)
        qualified = query.fetch('microflow') { raise ArgumentError, 'microflow is required' }
        with_project do |project|
          flow = find_microflow(project, qualified)
          raise ArgumentError, "microflow not found: #{qualified}" unless flow

          formats(ActivityDiagram.new(flow))
        end
      end

      def sequence_payload(query)
        root = query['root']
        module_name = query['module']
        raise ArgumentError, 'root or module is required' if root.to_s.empty? && module_name.to_s.empty?

        with_project do |project|
          diagram = SequenceDiagram.new(
            project.semantic_index,
            root: root.to_s.empty? ? nil : root,
            module_name: module_name.to_s.empty? ? nil : module_name,
            depth: query.fetch('depth', 2)
          )
          formats(diagram)
        end
      end

      def catalog_payload
        with_project do |project|
          {
            modules: project.modules.map(&:name).sort,
            microflows: project.modules.flat_map do |mod|
              mod.microflows.map { "#{mod.name}.#{_1.name}" }
            end.sort
          }
        end
      end

      def find_microflow(project, qualified)
        module_name, flow_name = qualified.to_s.split('.', 2)
        return unless flow_name

        project.modules.find { _1.name == module_name }&.microflows&.find { _1.name == flow_name }
      end

      def with_project
        project = Model::Project.open(source)
        yield project
      ensure
        project&.close
      end

      def formats(diagram) = { mermaid: diagram.to_mermaid, plantuml: diagram.to_plantuml }
      def asset_path = File.join(__dir__, 'index.html')

      def json(response, status, payload)
        render(response, status, JSON.generate(payload), 'application/json; charset=utf-8')
      end

      def render(response, status, body, type)
        response.status = status
        response['Content-Type'] = type
        response['Cache-Control'] = 'no-store'
        response['X-Content-Type-Options'] = 'nosniff'
        response.body = body
      end
    end
    # rubocop:enable Metrics
  end
end
