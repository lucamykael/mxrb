# frozen_string_literal: true

module Mxrb
  module Modbus
    # One connection per transaction: no stale responses, shared socket or
    # automatic retries. A write timeout means the remote outcome is unknown.
    class TcpTransport
      include StreamIO

      def initialize(host:, port:, unit_id:, timeout:)
        @host = host
        @port = port
        @unit_id = unit_id
        @timeout = timeout
      end

      def call(pdu)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
        Socket.tcp(@host, @port, open_timeout: remaining(deadline)) do |socket|
          transfer(socket, pdu, deadline)
        end
      rescue Errno::ETIMEDOUT, ::IO::TimeoutError => e
        raise TimeoutError, e.message
      rescue IOError, SystemCallError, SocketError => e
        raise TransportError, e.message
      end

      private

      def transfer(socket, pdu, deadline)
        write(socket, [1, 0, pdu.bytesize + 1, @unit_id].pack('nnnC') + pdu, deadline)
        length = response_length(read(socket, 7, deadline))
        read(socket, length - 1, deadline)
      end

      def response_length(header)
        transaction, protocol, length, unit = header.unpack('nnnC')
        raise ProtocolError, 'unexpected Modbus transaction' unless transaction == 1
        raise ProtocolError, 'unexpected Modbus protocol identifier' unless protocol.zero?
        raise ProtocolError, 'unexpected Modbus unit identifier' unless unit == @unit_id
        raise ProtocolError, 'invalid Modbus response length' unless (3..254).cover?(length)

        length
      end
    end
  end
end
