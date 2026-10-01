# frozen_string_literal: true

require 'socket'
require 'io/wait'
require_relative 'errors'

module Mxrb
  # MXRB's own runtime connector, independent of Marketplace package identity.
  # Addresses are zero-based; registers are unsigned 16-bit integers.
  module Modbus
    Error = Class.new(Mxrb::Error)
    ProtocolError = Class.new(Error)
    TransportError = Class.new(Error)
    TimeoutError = Class.new(TransportError)

    # The device rejected a valid request. Preserve its exact exception code.
    class ExceptionResponse < Error
      attr_reader :function, :code

      def initialize(function, code)
        @function = function
        @code = code
        super("Modbus function #{function} returned exception #{code}")
      end
    end
  end
end

require_relative 'modbus/tcp_transport'
require_relative 'modbus/client'
