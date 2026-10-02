# frozen_string_literal: true

require 'spec_helper'
require 'socket'
require 'timeout'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Modbus do
  # A loopback peer with literal wire messages, independent of client encoding.
  def with_peer(expected, response, **options) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    server = TCPServer.new('127.0.0.1', 0)
    peer = Thread.new do
      Timeout.timeout(3) do
        socket = server.accept
        begin
          request = socket.read(expected.bytesize)
          raise "unexpected request: #{request.unpack1('H*')}" unless request == expected

          response.each_byte { |byte| socket.write([byte].pack('C')) }
        ensure
          socket.close
        end
      end
    end
    peer.report_on_exception = false
    client = described_class::Client.new(host: '127.0.0.1', port: server.addr[1], **options)
    yield client
    peer.value
  ensure
    server&.close
    peer&.kill
    peer&.join
  end

  def hex(value) = [value.delete(' ')].pack('H*')

  def stub_client(response)
    transport = instance_double(described_class::TcpTransport)
    allow(described_class::TcpTransport).to receive(:new).and_return(transport)
    allow(transport).to receive(:call).and_return(hex(response))
    [described_class::Client.new(host: 'device.test'), transport]
  end

  it 'reads coils across bytes through TCP with LSB-first packing' do
    with_peer(hex('0001 0000 0006 01 01 0013 000a'), hex('0001 0000 0005 01 01 02 cd01')) do |client|
      expect(client.read_coils(19, 10)).to eq([true, false, true, true, false, false, true, true, true, false])
    end
  end

  it 'reads discrete inputs and unsigned big-endian registers through TCP' do
    with_peer(hex('0001 0000 0006 01 02 0000 0008'), hex('0001 0000 0004 01 02 01 80')) do |client|
      expect(client.read_discrete_inputs(0, 8)).to eq([false] * 7 + [true])
    end
    with_peer(hex('0001 0000 0006 ff 03 0000 0002'), hex('0001 0000 0007 ff 03 04 1234 ffff'), unit_id: 255) do |client|
      expect(client.read_holding_registers(0, 2)).to eq([0x1234, 65_535])
    end
    with_peer(hex('0001 0000 0006 01 04 ffff 0001'), hex('0001 0000 0005 01 04 02 0000')) do |client|
      expect(client.read_input_registers(65_535)).to eq([0])
    end
  end

  it 'writes single coils and registers and validates the echo through TCP' do
    [[true, 'ff00'], [false, '0000']].each do |value, wire|
      frame = hex("0001 0000 0006 01 05 0007 #{wire}")
      with_peer(frame, frame) { |client| expect(client.write_single_coil(7, value)).to eq(value) }
    end
    frame = hex('0001 0000 0006 01 06 0003 abcd')
    with_peer(frame, frame) { |client| expect(client.write_single_register(3, 0xabcd)).to eq(0xabcd) }
  end

  it 'writes multiple coils and registers through TCP with correct quantities and byte counts' do
    with_peer(hex('0001 0000 0009 01 0f 0013 000a 02 cd01'), hex('0001 0000 0006 01 0f 0013 000a')) do |client|
      expect(client.write_multiple_coils(19,
                                         [true, false, true, true, false, false, true, true, true, false])).to eq(10)
    end
    with_peer(hex('0001 0000 000b 01 10 0000 0002 04 0000 ffff'), hex('0001 0000 0006 01 10 0000 0002')) do |client|
      expect(client.write_multiple_registers(0, [0, 65_535])).to eq(2)
    end
  end

  it 'surfaces device exceptions without retrying a write' do
    with_peer(hex('0001 0000 0006 01 06 0000 0001'), hex('0001 0000 0003 01 86 02')) do |client|
      expect { client.write_single_register(0, 1) }.to raise_error(described_class::ExceptionResponse) { |error|
        expect(error.function).to eq(6)
        expect(error.code).to eq(2)
        expect(error.message).to include('exception 2')
      }
    end
  end

  it 'rejects invalid configuration before opening a socket' do
    expect(Socket).not_to receive(:tcp)
    [nil, 1, '', '  '].each do |host|
      expect { described_class::Client.new(host:) }.to raise_error(ArgumentError)
    end
    [{ port: 0 }, { port: 65_536 }, { port: '502' }, { unit_id: -1 }, { unit_id: 256 },
     { timeout: nil }, { timeout: 0 }, { timeout: -1 }, { timeout: Float::NAN },
     { timeout: Float::INFINITY }, { timeout: Complex(1, 1) }, { timeout: 10**1000 },
     { timeout: Rational(1, 10**1000) }].each do |options|
      expect { described_class::Client.new(host: 'localhost', **options) }.to raise_error(ArgumentError)
    end
  end

  it 'rejects invalid addresses, quantities and values before sending' do
    client = described_class::Client.new(host: 'localhost')
    expect(Socket).not_to receive(:tcp)
    [[:read_coils, -1], [:read_coils, 65_536], [:read_coils, 0.5], [:read_coils, 0, 0],
     [:read_coils, 0, 2001], [:read_holding_registers, 0, 126], [:read_coils, 65_535, 2],
     [:write_single_coil, 0, 1], [:write_single_register, 0, -1], [:write_single_register, 0, 65_536],
     [:write_multiple_coils, 0, nil], [:write_multiple_coils, 0, []],
     [:write_multiple_coils, 0, [nil]], [:write_multiple_coils, 0, [false] * 1969],
     [:write_multiple_registers, 0, [0] * 124], [:write_multiple_registers, 0, ['1']]].each do |method, *args|
      expect { client.public_send(method, *args) }.to raise_error(ArgumentError)
    end
  end

  it 'accepts maximum read quantities and rejects inconsistent response payloads' do
    client, transport = stub_client('')
    allow(transport).to receive(:call).with(hex('01 0000 07d0')).and_return(hex('01 fa') + "\x00".b * 250)
    expect(client.read_coils(0, 2000)).to eq([false] * 2000)
    allow(transport).to receive(:call).with(hex('03 0000 007d')).and_return(hex('03 fa') + "\x00".b * 250)
    expect(client.read_holding_registers(0, 125)).to eq([0] * 125)
    ['830201', '04 02 0000', '03 01 00', '03 02 00', '03 02 000000', '03', ''].each do |response|
      allow(transport).to receive(:call).and_return(hex(response))
      expect { client.read_holding_registers(0) }.to raise_error(described_class::ProtocolError)
    end
    allow(transport).to receive(:call).and_return(hex('01 01 80'))
    expect { client.read_coils(0) }.to raise_error(described_class::ProtocolError, /padding/)
  end

  it 'rejects incorrect write echoes' do
    client, = stub_client('06 0000 0000')
    expect { client.write_single_register(0, 1) }.to raise_error(described_class::ProtocolError, /echo/)
    client, = stub_client('10 0000 0002')
    expect { client.write_multiple_registers(0, [1]) }.to raise_error(described_class::ProtocolError, /echo/)
  end

  it 'rejects invalid MBAP identifiers and lengths over TCP' do
    ['0002 0000 0005 01', '0001 0001 0005 01', '0001 0000 0005 02',
     '0001 0000 0002 01', '0001 0000 00ff 01'].each do |header|
      with_peer(hex('0001 0000 0006 01 03 0000 0001'), hex(header)) do |client|
        expect { client.read_holding_registers(0) }.to raise_error(described_class::ProtocolError)
      end
    end
  end

  it 'rejects truncated responses rather than returning partial data' do
    with_peer(hex('0001 0000 0006 01 03 0000 0001'), hex('0001 0000 0005 01 03 02 12')) do |client|
      expect { client.read_holding_registers(0) }.to raise_error(described_class::TransportError, /closed/)
    end
  end

  it 'keeps custom Modbus separate from certified Marketplace packages' do
    expect(Mxrb::Protocols.find_by_protocol(:modbus)).to be_empty
    expect { Mxrb::Protocols.plan(:modbus, mendix_version: '11.12.1') }
      .to raise_error(Mxrb::MarketplaceError, /no verified Marketplace connector/)
  end

  it 'returns a TCP register value through a generated microflow and its Ruby adapter' do
    with_peer(hex('0001 0000 0006 01 03 0000 0001'), hex('0001 0000 0005 01 03 02 1234')) do |client|
      Dir.mktmpdir('mxrb-modbus-runtime-') do |root|
        path = File.join(root, 'Modbus.mpr')
        Mxrb.define(path) do
          mendix_version '11.12.1'
          self.module :Industrial do
            java_action :ReadRegister, parameters: [], return_type: { kind: :integer }
            microflow :ReadValue do
              return_type :Integer
              call_java 'Industrial.ReadRegister', as: :value
              return_value '$value'
            end
          end
        end
        expect(Mxrb.validate(path)).to be_valid
        Mxrb.open(path) do |project|
          adapter = ->(_arguments) { client.read_holding_registers(0).first }
          runtime = Mxrb::Runtime::Native::Interpreter.new(
            project, java_custom_actions: { 'Industrial.ReadRegister' => adapter }
          )
          expect(runtime.call('Industrial.ReadValue')).to eq(0x1234)
        end
      end
    end
  end

  it 'times out on a silent TCP peer and closes the connection without retrying' do
    server = TCPServer.new('127.0.0.1', 0)
    peer = Thread.new do
      Timeout.timeout(3) do
        socket = server.accept
        begin
          expect(socket.read(12)).to eq(hex('0001 0000 0006 01 06 0000 0001'))
          expect(socket.read).to eq('')
        ensure
          socket.close
        end
      end
    end
    peer.report_on_exception = false
    client = described_class::Client.new(host: '127.0.0.1', port: server.addr[1], timeout: 0.1)
    expect do
      client.write_single_register(0, 1)
    end.to raise_error(described_class::TimeoutError, /outcome may be unknown/)
    peer.value
    expect(server.accept_nonblock(exception: false)).to eq(:wait_readable)
  ensure
    server&.close
    peer&.kill
    peer&.join
  end
end

RSpec.describe Mxrb::Modbus::TcpTransport do
  subject(:transport) { described_class.new(host: 'localhost', port: 502, unit_id: 1, timeout: 1) }

  def socket_stub
    socket = instance_double(Socket)
    allow(Socket).to receive(:tcp).and_yield(socket)
    allow(socket).to receive(:wait_readable).and_return(true)
    allow(socket).to receive(:wait_writable).and_return(true)
    socket
  end

  it 'handles partial writes, partial reads and readiness races under one deadline' do
    socket = socket_stub
    frame = [1, 0, 3, 1, 3, 0].pack('nnnCCC')
    expect(socket).to receive(:write_nonblock).with(frame, exception: false).and_return(:wait_writable, 2)
    expect(socket).to receive(:write_nonblock).with(frame.byteslice(2..),
                                                    exception: false).and_return(frame.bytesize - 2)
    allow(socket).to receive(:read_nonblock).and_return(:wait_readable, frame.byteslice(0, 3), frame.byteslice(3, 4),
                                                        frame.byteslice(7..))
    expect(transport.call("\x03\x00".b)).to eq("\x03\x00".b)
  end

  it 'bounds socket readiness waits and checks the absolute deadline' do
    socket = socket_stub
    allow(socket).to receive(:wait_writable).and_return(nil)
    expect { transport.call('x') }.to raise_error(Mxrb::Modbus::TimeoutError, /timed out/)
    allow(Process).to receive(:clock_gettime).and_return(0, 2)
    expect { transport.call('x') }.to raise_error(Mxrb::Modbus::TimeoutError, /timed out/)
  end

  it 'normalizes connection, DNS and IO failures without retrying' do
    [Errno::ETIMEDOUT.new, IO::TimeoutError.new].each do |error|
      expect(Socket).to receive(:tcp).once.and_raise(error)
      expect { transport.call('x') }.to raise_error(Mxrb::Modbus::TimeoutError)
    end
    [Errno::ECONNREFUSED.new, SocketError.new, IOError.new].each do |error|
      expect(Socket).to receive(:tcp).once.and_raise(error)
      expect { transport.call('x') }.to raise_error(Mxrb::Modbus::TransportError)
    end
  end
end
# rubocop:enable Metrics/BlockLength
