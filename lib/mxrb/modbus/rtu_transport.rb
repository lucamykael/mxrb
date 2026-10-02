# frozen_string_literal: true

module Mxrb
  module Modbus
    # Unicast RTU on a caller-owned, raw, configured serial IO (8E1/8O1/8N2).
    # A single client must own the bus. Errors poison the session, because late
    # RTU responses have no transaction identifier and cannot be retried safely.
    class RtuTransport # rubocop:disable Metrics/ClassLength
      include StreamIO

      def initialize(io:, unit_id:, timeout:, baud_rate: 9600)
        validate!(io, unit_id, baud_rate)
        @io = io
        @unit_id = unit_id
        @timeout = timeout
        @gap = baud_rate > 19_200 ? 0.00175 : 38.5 / baud_rate
        @inter_byte = baud_rate > 19_200 ? 0.00075 : 16.5 / baud_rate
        @lock = Mutex.new
        @failed = false
      end

      def call(pdu)
        return transaction(pdu) if @lock.owned?

        synchronize { transaction(pdu) }
      end

      # Keep the bus reserved through the client's semantic response decoding.
      def synchronize
        raise TransportError, 'RTU bus already has a transaction in progress' unless @lock.try_lock

        begin
          yield
        ensure
          @lock.unlock
        end
      end

      def self.crc(bytes)
        bytes.each_byte.reduce(0xffff) do |crc, byte|
          crc ^= byte
          8.times { crc = crc.odd? ? (crc >> 1) ^ 0xa001 : crc >> 1 }
          crc
        end
      end

      def invalidate! = @failed = true

      private

      def validate!(io, unit_id, baud_rate)
        unless %i[read_nonblock write_nonblock wait_readable wait_writable].all? { io.respond_to?(_1) }
          raise ArgumentError, 'io must be a configured serial IO with nonblocking reads/writes and readiness waits'
        end
        unless unit_id.is_a?(Integer) && (1..247).cover?(unit_id)
          raise ArgumentError, 'RTU unit_id must be an Integer in 1..247; broadcast is unsupported'
        end
        return if baud_rate.is_a?(Integer) && (300..115_200).cover?(baud_rate)

        raise ArgumentError, 'baud_rate must be an Integer in 300..115200 matching the configured serial port'
      end

      def transaction(pdu)
        raise TransportError, 'RTU session failed; reopen and resynchronize before reuse' if @failed

        transfer(pdu, Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout)
      rescue Error
        @failed = true
        raise
      rescue IOError, SystemCallError => e
        @failed = true
        raise TransportError, e.message
      end

      def transfer(pdu, deadline)
        quiet!(deadline)
        frame = [@unit_id].pack('C') + pdu
        write(@io, frame + [self.class.crc(frame)].pack('v'), deadline)
        response = receive_frame(pdu.getbyte(0), deadline)
        quiet!(deadline)
        decode(response)
      end

      def quiet!(deadline)
        raise TimeoutError, 'insufficient time for RTU frame separation' if remaining(deadline) < @gap
        raise ProtocolError, 'unexpected data on RTU bus during frame separation' if @io.wait_readable(@gap)
      end

      def receive_frame(function, deadline) # rubocop:disable Metrics/MethodLength
        bytes = +''.b
        read_deadline = deadline
        loop do
          chunk = receive_chunk(read_deadline)
          next if chunk == :wait_readable

          bytes << chunk
          read_deadline = [deadline, Process.clock_gettime(Process::CLOCK_MONOTONIC) + @inter_byte].min
          length = frame_length(bytes, function)
          next unless length && bytes.bytesize >= length

          raise ProtocolError, 'extra bytes in RTU response' unless bytes.bytesize == length

          return bytes
        end
      end

      def receive_chunk(deadline)
        unless @io.wait_readable(remaining(deadline))
          raise TimeoutError,
                'RTU response timeout or inter-character gap; remote write outcome may be unknown'
        end

        chunk = @io.read_nonblock(256, exception: false)
        raise TransportError, 'serial port closed before complete RTU response' if chunk.nil?

        chunk
      end

      def frame_length(bytes, function)
        return if bytes.bytesize < 2

        raise ProtocolError, 'unexpected RTU unit identifier' unless bytes.getbyte(0) == @unit_id

        received = bytes.getbyte(1)
        return 5 if received == (function | 0x80)

        raise ProtocolError, 'unexpected RTU function' unless received == function
        return 8 unless (1..4).cover?(function)

        read_frame_length(bytes)
      end

      def read_frame_length(bytes)
        return if bytes.bytesize < 3

        count = bytes.getbyte(2)
        raise ProtocolError, 'invalid RTU byte count' if count > 250

        count + 5
      end

      def decode(frame)
        body = frame.byteslice(0...-2)
        raise ProtocolError, 'invalid RTU CRC' unless frame.byteslice(-2, 2).unpack1('v') == self.class.crc(body)

        body.byteslice(1..)
      end
    end
  end
end
