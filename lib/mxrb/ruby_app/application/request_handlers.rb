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
      end
    end
  end
end
