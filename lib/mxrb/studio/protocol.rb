# frozen_string_literal: true

require 'json'
require_relative 'files'
require_relative 'write_lock'

module Mxrb
  module Studio
    class Cancelled < StandardError; end

    # Raised for Ruby sources that do not parse or evaluate; carries locations.
    class RubySourceError < StandardError
      attr_reader :locations

      def initialize(message, locations: [])
        super(message)
        @locations = locations
      end
    end

    # JSON-RPC 2.0 vocabulary of the Studio protocol. Standard codes keep their
    # JSON-RPC meaning; the -320xx range carries MXRB conditions a client can
    # act on (retry when busy, show a compare view on conflict, ...).
    module Protocol
      NAME = 'mxrb-studio'
      VERSION = 2
      MINIMUM_VERSION = 2

      PARSE_ERROR = -32_700
      INVALID_REQUEST = -32_600
      METHOD_NOT_FOUND = -32_601
      INVALID_PARAMS = -32_602
      INTERNAL_ERROR = -32_603
      NOT_INITIALIZED = -32_002
      REQUEST_CANCELLED = -32_800
      CONFLICT = -32_010
      BUSY = -32_011
      VALIDATION = -32_012
      TOOLCHAIN = -32_013
      RUBY_SOURCE = -32_014
      UNSUPPORTED_PROTOCOL = -32_015

      KINDS = {
        PARSE_ERROR => 'parse_error', INVALID_REQUEST => 'invalid_request',
        METHOD_NOT_FOUND => 'method_not_found', INVALID_PARAMS => 'invalid_params',
        INTERNAL_ERROR => 'internal_error', NOT_INITIALIZED => 'not_initialized',
        REQUEST_CANCELLED => 'cancelled', CONFLICT => 'conflict', BUSY => 'busy',
        VALIDATION => 'validation', TOOLCHAIN => 'toolchain', RUBY_SOURCE => 'ruby_source',
        UNSUPPORTED_PROTOCOL => 'unsupported_protocol'
      }.freeze

      # A request failure that already knows its protocol code.
      class Failure < StandardError
        attr_reader :code, :data

        def initialize(code, message, data = {})
          super(message)
          @code = code
          @data = data
        end
      end

      module_function

      def code_for(error)
        case error
        when Failure then error.code
        when Cancelled then REQUEST_CANCELLED
        when Conflict then CONFLICT
        when Busy then BUSY
        when NotImplementedError, Mxrb::ToolchainError, SystemCallError then TOOLCHAIN
        when RubySourceError, ScriptError then RUBY_SOURCE
        when ArgumentError, TypeError, JSON::ParserError then INVALID_PARAMS
        when Mxrb::Error then VALIDATION
        else INTERNAL_ERROR
        end
      end

      def error_object(error, roots: [])
        code = code_for(error)
        data = { kind: KINDS.fetch(code), type: error.class.name }
        data.merge!(error.data) if error.is_a?(Failure)
        locations = locations_for(error, roots)
        data[:locations] = locations unless locations.empty?
        { code:, message: error.message, data: }
      end

      # File/line locations that belong to the client's workspace. Ruby syntax
      # errors name their file in the message; evaluation errors in backtraces.
      def locations_for(error, roots)
        return error.locations if error.respond_to?(:locations) && error.locations.is_a?(Array)

        prefixes = roots.compact.map { File.expand_path(_1) }
        found = message_locations(error.message)
        found += backtrace_locations(error).select do |item|
          prefixes.any? { item[:file].start_with?("#{_1}/") }
        end
        found.uniq.first(20)
      end

      def message_locations(message)
        message.to_s.scan(%r{^((?:/|\.{1,2}/)?[^\s:]+\.rb):(\d+):}).map do |file, line|
          { file: File.expand_path(file), line: line.to_i }
        end
      end

      def backtrace_locations(error)
        Array(error.backtrace_locations).filter_map do |location|
          path = location.absolute_path || location.path
          { file: path, line: location.lineno } if path&.end_with?('.rb')
        end
      end
    end
  end
end
