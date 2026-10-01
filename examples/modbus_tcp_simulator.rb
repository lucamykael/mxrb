# frozen_string_literal: true

require 'timeout'
require_relative '../lib/mxrb/modbus'

module Mxrb
  module Modbus
    # Development-only, loopback-only device: 256 values in each data area.
    # Values persist across connections until this process exits.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    class TcpSimulator
      Fault = Class.new(StandardError)

      def initialize(port: 1502)
        @server = TCPServer.new('127.0.0.1', port)
        @coils = Array.new(256, false)
        @inputs = Array.new(256, false)
        @holding = Array.new(256, 0)
        @registers = Array.new(256, 0)
        @inputs[0] = true
        @registers[0] = 1234
      end

      def port = @server.addr[1]
      def close = @server.close

      def serve_next
        socket = @server.accept
        Timeout.timeout(2) do
          transaction, protocol, length, unit = read_exact(socket, 7).unpack('nnnC')
          return unless protocol.zero? && (2..254).cover?(length) && unit == 1

          response = process(read_exact(socket, length - 1))
          socket.write([transaction, 0, response.bytesize + 1, unit].pack('nnnC') + response)
        end
      rescue IOError, SystemCallError, Timeout::Error
        nil
      ensure
        socket&.close
      end

      def run
        puts "Modbus TCP simulator: 127.0.0.1:#{port}, unit_id=1, addresses=0..255 (Ctrl+C to stop)"
        $stdout.flush
        loop { serve_next }
      rescue Interrupt
        nil
      ensure
        close
      end

      private

      def read_exact(socket, size)
        bytes = socket.read(size)
        raise EOFError unless bytes && bytes.bytesize == size

        bytes
      end

      def process(pdu) # rubocop:disable Metrics/CyclomaticComplexity
        function = pdu.getbyte(0)
        case function
        when 1, 2 then read_bits(pdu, function == 1 ? @coils : @inputs)
        when 3, 4 then read_registers(pdu, function == 3 ? @holding : @registers)
        when 5, 6 then write_single(pdu)
        when 15, 16 then write_multiple(pdu)
        else raise Fault, '1'
        end
      rescue Fault => e
        [function | 0x80, e.message.to_i].pack('CC')
      end

      def range!(address, count, maximum)
        raise Fault, '3' unless (1..maximum).cover?(count)
        raise Fault, '2' unless address + count <= 256
      end

      def read_request(pdu, maximum)
        raise Fault, '3' unless pdu.bytesize == 5

        function, address, count = pdu.unpack('Cnn')
        range!(address, count, maximum)
        [function, address, count]
      end

      def read_bits(pdu, area)
        function, address, count = read_request(pdu, 2000)
        data = area.slice(address, count).each_slice(8).map do |bits|
          bits.each_with_index.sum { |bit, index| bit ? 1 << index : 0 }
        end.pack('C*')
        [function, data.bytesize].pack('CC') + data
      end

      def read_registers(pdu, area)
        function, address, count = read_request(pdu, 125)
        data = area.slice(address, count).pack('n*')
        [function, data.bytesize].pack('CC') + data
      end

      def write_single(pdu)
        raise Fault, '3' unless pdu.bytesize == 5

        function, address, value = pdu.unpack('Cnn')
        range!(address, 1, 1)
        if function == 5
          raise Fault, '3' unless [0, 0xff00].include?(value)

          @coils[address] = value == 0xff00
        else
          @holding[address] = value
        end
        pdu
      end

      def write_multiple(pdu)
        raise Fault, '3' if pdu.bytesize < 6

        function, address, count, bytes = pdu.unpack('CnnC')
        range!(address, count, function == 15 ? 1968 : 123)
        expected = function == 15 ? (count + 7) / 8 : count * 2
        raise Fault, '3' unless bytes == expected && pdu.bytesize == bytes + 6

        data = pdu.byteslice(6..)
        if function == 15
          @coils[address, count] = Array.new(count) { |i| (data.getbyte(i / 8) & (1 << (i % 8))).positive? }
        else
          @holding[address, count] = data.unpack('n*')
        end
        [function, address, count].pack('Cnn')
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
  end
end

Mxrb::Modbus::TcpSimulator.new(port: Integer(ARGV.fetch(0, '1502'))).run if $PROGRAM_NAME == __FILE__
