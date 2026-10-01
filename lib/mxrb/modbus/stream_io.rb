# frozen_string_literal: true

module Mxrb
  module Modbus
    # Deadline-bound IO shared by sockets and already configured serial ports.
    module StreamIO
      private

      def remaining(deadline)
        seconds = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise TimeoutError, 'Modbus transaction timed out; remote write outcome may be unknown' unless seconds.positive?

        seconds
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
