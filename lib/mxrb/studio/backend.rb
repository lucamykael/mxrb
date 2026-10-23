# frozen_string_literal: true

require 'rbconfig'
require_relative 'service'

module Mxrb
  module Studio
    # Single-shot entry point: one request object with an `action` (the
    # version 1 names) per process. Long-lived clients use Server instead;
    # both reach the same Service methods.
    class Backend
      PROTOCOL_VERSION = Protocol::VERSION

      def initialize(service: Service.new)
        @service = service
      end

      def call(request)
        action = request.fetch('action')
        method = Service::LEGACY.fetch(action) { raise ArgumentError, "unknown Studio action: #{action}" }
        @service.dispatch(method, request.except('action'))
      end

      def arguments(request) = @service.tasks_prepare(Service::Params.new(request), nil)

      # Replaces the process with the MXRB command; for terminal-style clients.
      def execute(request)
        root = File.expand_path('../../..', __dir__)
        directory = File.realpath(request.fetch('directory'))
        argv = arguments(request)
        exec({ 'NO_COLOR' => '1', 'TERM' => 'dumb', 'PAGER' => 'cat', 'GIT_PAGER' => 'cat', 'PSQL_PAGER' => 'cat' },
             RbConfig.ruby, File.join(root, 'bin', 'mxrb'), '--no-progress', *argv, chdir: directory)
      end
    end
  end
end
