# frozen_string_literal: true

require 'spec_helper'
require 'pty'
require 'io/console'
require 'timeout'
require_relative '../examples/modbus_tcp_simulator'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'Modbus transport selection and local simulation' do
  def hex(value) = [value.delete(' ')].pack('H*')

  def with_serial_peer(expected, response) # rubocop:disable Metrics/AbcSize
    master, slave = PTY.open
    slave.raw!
    release = Queue.new
    peer = Thread.new do
      Timeout.timeout(3) do
        expect(master.read(expected.bytesize)).to eq(expected)
        master.write(response)
        release.pop
      end
    end
    peer.report_on_exception = false
    yield Mxrb::Modbus::Client.new(transport: :rtu, io: slave, baud_rate: 9600)
    release << true
    peer.value
  ensure
    peer&.kill
    peer&.join
    master&.close
    slave&.close
  end

  it 'reads and writes a persistent local TCP simulation through the public client' do
    server = Mxrb::Modbus::TcpSimulator.new(port: 0)
    peer = Thread.new { 10.times { server.serve_next } }
    client = Mxrb::Modbus::Client.new(transport: :tcp, host: '127.0.0.1', port: server.port)
    expect(client.read_holding_registers(0, 2)).to eq([0, 0])
    expect(client.write_single_register(0, 42)).to eq(42)
    expect(client.write_multiple_registers(1, [123, 456])).to eq(2)
    expect(client.read_holding_registers(0, 3)).to eq([42, 123, 456])
    expect(client.write_single_coil(0, true)).to be(true)
    expect(client.write_multiple_coils(1, [true, false, true])).to eq(3)
    expect(client.read_coils(0, 4)).to eq([true, true, false, true])
    expect(client.read_discrete_inputs(0, 2)).to eq([true, false])
    expect(client.read_input_registers(0)).to eq([1234])
    expect { client.read_holding_registers(256) }.to raise_error(Mxrb::Modbus::ExceptionResponse) { |e| expect(e.code).to eq(2) }
    peer.value
  ensure
    peer&.kill
    peer&.join
    server&.close
  end

  it 'uses literal RTU CRC vectors over an actual pseudo-terminal' do
    with_serial_peer(hex('01 03 0000 000a c5cd'), hex('01 03 14') + "\x00".b * 20 + hex('a367')) do |client|
      expect(client.read_holding_registers(0, 10)).to eq([0] * 10)
    end
    with_serial_peer(hex('01 06 0001 0003 980b'), hex('01 06 0001 0003 980b')) do |client|
      expect(client.write_single_register(1, 3)).to eq(3)
    end
  end

  it 'verifies the published CRC check value independently of frame encoding' do
    expect(Mxrb::Modbus::RtuTransport.crc('123456789')).to eq(0x4b37)
  end

  it 'rejects unsupported transports, serial options and broadcast before IO' do
    expect { Mxrb::Modbus::Client.new(transport: :udp) }.to raise_error(ArgumentError, /transport/)
    expect { Mxrb::Modbus::Client.new(transport: :rtu, io: nil) }.to raise_error(ArgumentError, /serial IO/)
    io = instance_double(File, read_nonblock: '', write_nonblock: 1, wait_readable: nil, wait_writable: true)
    [0, 248, '1'].each do |unit_id|
      expect { Mxrb::Modbus::Client.new(transport: :rtu, io:, unit_id:) }.to raise_error(ArgumentError, /unit_id/)
    end
    [0, 115_201, '9600'].each do |baud_rate|
      expect { Mxrb::Modbus::Client.new(transport: :rtu, io:, baud_rate:) }.to raise_error(ArgumentError, /baud_rate/)
    end
    expect { Mxrb::Modbus::Client.new(transport: :rtu, io:, host: 'localhost') }.to raise_error(ArgumentError)
  end
end

RSpec.describe Mxrb::Modbus::RtuTransport do
  let(:io) { instance_double(File) }
  let(:transport) { described_class.new(io:, unit_id: 1, timeout: 1) }

  before do
    allow(io).to receive(:wait_readable).and_return(nil, true, nil)
    allow(io).to receive(:wait_writable).and_return(true)
    allow(io).to receive(:write_nonblock) { |bytes, **| bytes.bytesize }
    allow(io).to receive(:read_nonblock).and_return(frame([1, 3, 2, 0, 42].pack('C*')))
  end

  def frame(body) = body + [described_class.crc(body)].pack('v')

  it 'supports fragmented RTU frames and nonblocking readiness races' do
    allow(Process).to receive(:clock_gettime).and_return(0)
    response = frame([1, 3, 2, 0, 42].pack('C*'))
    allow(io).to receive(:wait_readable).and_return(nil, true, true, true, true, true, nil)
    allow(io).to receive(:read_nonblock).and_return(:wait_readable, response.byteslice(0, 1), response.byteslice(1, 1),
                                                    response.byteslice(2, 1), response.byteslice(3..))
    expect(transport.call("\x03\x00\x00\x00\x01".b)).to eq("\x03\x02\x00\x2a".b)
  end

  it 'preserves exception responses for the shared client decoder' do
    allow(io).to receive(:wait_readable).and_return(nil, true, nil, nil, true, nil)
    allow(io).to receive(:read_nonblock).and_return(frame("\x01\x83\x02".b), frame("\x01\x03\x02\x00\x2a".b))
    client = Mxrb::Modbus::Client.new(transport: :rtu, io:)
    expect { client.read_holding_registers(0) }.to raise_error(Mxrb::Modbus::ExceptionResponse) { |e| expect(e.code).to eq(2) }
    expect(client.read_holding_registers(0)).to eq([42])
  end

  it 'fails closed for invalid frames and refuses subsequent calls on that serial session' do
    ["\x02\x03\x00".b, "\x01\x04\x00".b, "\x01\x03\xfb".b,
     "\x01\x03\x00\x00\x00".b, "#{frame("\x01\x03\x00".b)}x"].each do |response|
      session = described_class.new(io:, unit_id: 1, timeout: 1, baud_rate: 115_200)
      allow(io).to receive(:wait_readable).and_return(nil, true, nil)
      allow(io).to receive(:read_nonblock).and_return(response)
      expect { session.call("\x03".b) }.to raise_error(Mxrb::Modbus::ProtocolError)
      expect { session.call("\x03".b) }.to raise_error(Mxrb::Modbus::TransportError, /session failed/)
    end
  end

  it 'rejects traffic during frame separation, EOF and timed out responses' do
    allow(io).to receive(:wait_readable).and_return(true)
    expect { transport.call("\x03".b) }.to raise_error(Mxrb::Modbus::ProtocolError, /frame separation/)
    session = described_class.new(io:, unit_id: 1, timeout: 1)
    allow(io).to receive(:wait_readable).and_return(nil, true)
    allow(io).to receive(:read_nonblock).and_return(nil)
    expect { session.call("\x03".b) }.to raise_error(Mxrb::Modbus::TransportError, /closed/)
    session = described_class.new(io:, unit_id: 1, timeout: 1)
    allow(io).to receive(:wait_readable).and_return(nil)
    expect { session.call("\x03".b) }.to raise_error(Mxrb::Modbus::TimeoutError)
    allow(Process).to receive(:clock_gettime).and_return(0)
    short = described_class.new(io:, unit_id: 1, timeout: 0.00001)
    expect { short.call("\x03".b) }.to raise_error(Mxrb::Modbus::TimeoutError)
  end

  it 'normalizes serial IO failures and refuses simultaneous transactions' do
    allow(io).to receive(:wait_readable).and_raise(IOError, 'disconnected')
    expect { transport.call("\x03".b) }.to raise_error(Mxrb::Modbus::TransportError, /disconnected/)
    lock = transport.instance_variable_get(:@lock)
    lock.lock
    expect { transport.call("\x03".b) }.to raise_error(Mxrb::Modbus::TransportError, /in progress/)
    expect(lock).to be_locked
    lock.unlock
  end

  it 'invalidates RTU when the shared decoder rejects a CRC-valid response with the wrong quantity' do
    allow(io).to receive(:read_nonblock).and_return(frame("\x01\x03\x00".b))
    client = Mxrb::Modbus::Client.new(transport: :rtu, io:)
    expect { client.read_holding_registers(0) }.to raise_error(Mxrb::Modbus::ProtocolError, /byte count/)
    expect { client.read_holding_registers(0) }.to raise_error(Mxrb::Modbus::TransportError, /session failed/)
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
