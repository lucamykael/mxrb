# frozen_string_literal: true

require 'socket'

# The HTTP server the REST calls of this fixture reach, both on the native
# Runtime (script/oql_native_oracle) and in the spec: /ok answers 200 with a JSON
# object and an X-Probe header, /echo answers with the body it got, and any other
# path 400 with a JSON error.
module LatestHttpResponseStub
  PORT = 9395

  def self.start(port: PORT)
    server = TCPServer.new('127.0.0.1', port)
    Thread.new do
      loop do
        client = server.accept
        Thread.new(client) { answer(_1) }
      end
    rescue IOError
      nil
    end
    server
  end

  def self.answer(client) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    path = client.gets.to_s.split[1].to_s
    length = 0
    while (line = client.gets) && line != "\r\n"
      length = line.split(':', 2).last.to_i if line.downcase.start_with?('content-length:')
    end
    received = length.positive? ? client.read(length) : ''
    status, body = case path
                   when '/ok' then ['200 OK', '{"name":"remote"}']
                   when '/echo' then ['200 OK', received]
                   else ['400 Bad Request', '{"error":"nope"}']
                   end
    client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nX-Probe: yes\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  ensure
    client.close
  end
end

if $PROGRAM_NAME == __FILE__
  LatestHttpResponseStub.start
  sleep
end
