# frozen_string_literal: true

module Mxrb
  module Modbus
    # One connection per transaction: no stale responses, shared socket or
    # automatic retries. A write timeout means the remote outcome is unknown.
    class TcpTransport
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

      def remaining(deadline)
        seconds = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise TimeoutError, 'Modbus transaction timed out; remote write outcome may be unknown' unless seconds.positive?

        seconds
      end

      def response_length(header)
        transaction, protocol, length, unit = header.unpack('nnnC')
        raise ProtocolError, 'unexpected Modbus transaction' unless transaction == 1
        raise ProtocolError, 'unexpected Modbus protocol identifier' unless protocol.zero?
        raise ProtocolError, 'unexpected Modbus unit identifier' unless unit == @unit_id
        raise ProtocolError, 'invalid Modbus response length' unless (3..254).cover?(length)

        length
      end

      def read(socket, size, deadline)
        bytes = +''.b
        while bytes.bytesize < size
          wait(socket, :wait_readable, deadline)
          chunk = socket.read_nonblock(size - bytes.bytesize, exception: false)
          raise TransportError, 'connection closed before complete Modbus response' if chunk.nil?

          bytes << chunk unless chunk == :wait_readable
        end
        bytes
      end

      def write(socket, bytes, deadline)
        until bytes.empty?
          wait(socket, :wait_writable, deadline)
          count = socket.write_nonblock(bytes, exception: false)
          bytes = bytes.byteslice(count..) unless count == :wait_writable
        end
      end

      def wait(socket, method, deadline)
        return if socket.public_send(method, remaining(deadline))

        raise TimeoutError, 'Modbus transaction timed out; remote write outcome may be unknown'
      end
    end
  end
end
