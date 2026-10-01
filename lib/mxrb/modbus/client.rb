# frozen_string_literal: true

module Mxrb
  module Modbus
    # The same synchronous operations over TCP or a caller-owned RTU serial IO.
    class Client # rubocop:disable Metrics/ClassLength
      def initialize(transport: :tcp, unit_id: 1, timeout: 5.0, **options)
        timeout!(timeout)
        @transport = case transport
                     when :tcp then tcp_transport(unit_id, timeout.to_f, **options)
                     when :rtu then RtuTransport.new(unit_id:, timeout: timeout.to_f, **options)
                     else raise ArgumentError, 'transport must be :tcp or :rtu'
                     end
      end

      def read_coils(address, quantity = 1) = operation { read_bits(1, address, quantity) }
      def read_discrete_inputs(address, quantity = 1) = operation { read_bits(2, address, quantity) }
      def read_holding_registers(address, quantity = 1) = operation { read_registers(3, address, quantity) }
      def read_input_registers(address, quantity = 1) = operation { read_registers(4, address, quantity) }

      def write_single_coil(address, value)
        operation do
          boolean!(value)
          write_single(5, address, value ? 0xff00 : 0)
          value
        end
      end

      def write_single_register(address, value)
        operation do
          integer!(value, 0..65_535, 'register')
          write_single(6, address, value)
          value
        end
      end

      def write_multiple_coils(address, values)
        operation do
          values!(values)
          range!(address, values.size, 1968)
          values.each { boolean!(_1) }
          write_multiple(15, address, values.size, packed_bits(values))
        end
      end

      def write_multiple_registers(address, values)
        operation do
          values!(values)
          range!(address, values.size, 123)
          values.each { integer!(_1, 0..65_535, 'register') }
          write_multiple(16, address, values.size, values.pack('n*'))
        end
      end

      private

      def operation(&block)
        return @transport.synchronize(&block) if @transport.respond_to?(:synchronize)

        yield
      end

      def packed_bits(values)
        values.each_slice(8).map do |bits|
          bits.each_with_index.sum { |bit, index| bit ? 1 << index : 0 }
        end.pack('C*')
      end

      def tcp_transport(unit_id, timeout, host:, port: 502)
        raise ArgumentError, 'host must be a nonempty String' unless host.is_a?(String) && !host.strip.empty?

        integer!(port, 1..65_535, 'port')
        integer!(unit_id, 0..255, 'unit_id')
        TcpTransport.new(host: host.dup.freeze, port:, unit_id:, timeout:)
      end

      def timeout!(value)
        return if value.is_a?(Numeric) && value.real? && value <= Float::MAX && value.to_f.positive?

        raise ArgumentError, 'timeout must be finite and positive'
      end

      def integer!(value, range, name)
        return if value.is_a?(Integer) && range.cover?(value)

        raise ArgumentError, "#{name} must be an Integer in #{range}"
      end

      def boolean!(value)
        raise ArgumentError, 'coil must be true or false' unless [true, false].include?(value)
      end

      def values!(values)
        raise ArgumentError, 'values must be an Array' unless values.is_a?(Array)
      end

      def range!(address, quantity, maximum)
        integer!(address, 0..65_535, 'address')
        integer!(quantity, 1..maximum, 'quantity')
        raise ArgumentError, 'address range exceeds 65535' if address + quantity > 65_536
      end

      def exchange(function, payload)
        response = @transport.call([function].pack('C') + payload)
        if response.getbyte(0) == (function | 0x80)
          protocol_error!('invalid Modbus exception response') unless response.bytesize == 2

          raise ExceptionResponse.new(function, response.getbyte(1))
        end
        protocol_error!('unexpected Modbus function') unless response.getbyte(0) == function

        response.byteslice(1..)
      end

      def read_data(function, address, quantity, bytes)
        data = exchange(function, [address, quantity].pack('nn'))
        protocol_error!('invalid Modbus byte count') unless data.getbyte(0) == bytes && data.bytesize == bytes + 1

        data.byteslice(1..)
      end

      def read_bits(function, address, quantity)
        range!(address, quantity, 2000)
        data = read_data(function, address, quantity, (quantity + 7) / 8)
        padding!(data, quantity)

        Array.new(quantity) { |index| (data.getbyte(index / 8) & (1 << (index % 8))).positive? }
      end

      def padding!(data, quantity)
        unused = quantity % 8
        return unless unused.positive? && (data.getbyte(-1) >> unused).positive?

        protocol_error!('nonzero Modbus coil padding')
      end

      def read_registers(function, address, quantity)
        range!(address, quantity, 125)
        read_data(function, address, quantity, quantity * 2).unpack('n*')
      end

      def write_single(function, address, value)
        range!(address, 1, 1)
        payload = [address, value].pack('nn')
        protocol_error!('invalid Modbus write echo') unless exchange(function, payload) == payload
      end

      def write_multiple(function, address, quantity, data)
        expected = [address, quantity].pack('nn')
        payload = expected + [data.bytesize].pack('C') + data
        protocol_error!('invalid Modbus write echo') unless exchange(function, payload) == expected

        quantity
      end

      def protocol_error!(message)
        @transport.invalidate! if @transport.respond_to?(:invalidate!)
        raise ProtocolError, message
      end
    end
  end
end
