# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Application
      # The paths Java actions registered with Core.addRequestHandler, whose
      # requests the server forwards to the Java actions sidecar.
      module RequestHandlers
        def java_request_handler(path) = bridge.sidecar_services.request_handler(path.to_s)

        def handle_java_request(handler, request, context:)
          runtime_synchronize { bridge.interpreter.java_request(handler, request, context:) }
        end

        # Serves the callbacks of work Java actions leave running, such as MQTT
        # listeners, each in a transaction of its own, while the runtime runs.
        def start_java_listener
          sidecar = bridge.interpreter.java_sidecar
          return if sidecar.nil? || @java_listener&.alive?

          @java_listening = true
          @java_listener = Thread.new do
            sidecar.listen(running: -> { @java_listening }) do |ticket|
              Thread.new { attach_java_work(ticket) }
            end
          end
        end

        def stop_java_listener
          @java_listening = false
          @java_listener&.join(2)
          @java_listener = nil
        end

        private

        def attach_java_work(ticket)
          runtime_synchronize { bridge.interpreter.java_attach(ticket) }
        rescue StandardError => e
          warn "mxrb: background Java action work failed: #{e.message}"
        end
      end
    end
  end
end
