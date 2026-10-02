# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby file widgets API' do
  it 'persists binary content, streams safe downloads and removes content with its record' do
    Dir.mktmpdir('mxrb-file-api-') do |directory|
      source = File.join(directory, 'Files.mpr')
      target = File.join(directory, 'ruby')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module(:Files) { entity(:Document) { string :Name } }
      end
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      server = Mxrb::RubyApp::Server.new(target, port: 0)
      record = server.application.create_record('Files.Document', { 'Name' => 'Document' })
      path = "/api/files/Files.Document/#{record.fetch(:id)}"
      request_type = Struct.new(:path, :request_method, :body, :query) { def [](_name) = nil }
      dispatch = lambda do |method, body = '', query = {}|
        response = Mxrb::Http::Response.new
        server.send(:dispatch, request_type.new(path, method, body, query), response)
        response
      end
      expect(dispatch.call('GET').status).to eq(404)
      bytes = "\x89PNG\r\n\x1a\n\x00\xff".b
      upload = dispatch.call('PUT', JSON.generate(name: "../example\r\n.png", content: Base64.strict_encode64(bytes)))
      expect(upload.status).to eq(200)
      expect(JSON.parse(upload.body)).to include('name' => 'example.png', 'media_type' => 'image/png')
      download = dispatch.call('GET')
      expect(download.body).to eq(bytes)
      expect(download['Content-Disposition']).to start_with('inline;')
      expect(download['X-Content-Type-Options']).to eq('nosniff')
      expect(dispatch.call('GET', '', 'download' => '1')['Content-Disposition']).to start_with('attachment;')
      server.application.close
      server = Mxrb::RubyApp::Server.new(target, port: 0)
      expect(dispatch.call('GET').body).to eq(bytes)
      upload = dispatch.call('PUT',
                             JSON.generate(name: 'fake.png',
                                           content: Base64.strict_encode64('<script>alert(1)</script>')))
      expect(upload.status).to eq(200)
      expect(dispatch.call('GET')['Content-Type']).to eq('application/octet-stream')
      expect(dispatch.call('GET')['Content-Disposition']).to start_with('attachment;')
      context = server.application.session_manager.authenticate(nil)
      policy = server.application.send(:access_control)
      allow(policy).to receive(:authorize!).and_raise(Mxrb::Runtime::AuthorizationError, 'denied')
      expect { server.application.file_content('Files.Document', record.fetch(:id), context:) }
        .to raise_error(Mxrb::Runtime::AuthorizationError)
      expect(dispatch.call('PUT', JSON.generate(name: 'denied.txt', content: 'YQ==')).status).to eq(403)
      allow(policy).to receive(:authorize!).and_call_original
      server.application.delete_record('Files.Document', record.fetch(:id))
      expect(dispatch.call('GET').status).to eq(404)
      database = server.application.send(:bridge).store.database
      expect(database.get_first_value('SELECT COUNT(*) FROM mxrb_file_contents')).to eq(0)
    ensure
      server&.application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  it 'rejects malformed encoding, empty names and oversized uploads before storing them' do
    database = SQLite3::Database.new(':memory:')
    store = Mxrb::RubyApp::FileContent.new(database)
    expect { store.write('Files.Document', '1', 'file', '!') }.to raise_error(ArgumentError)
    expect { store.write('Files.Document', '1', '', 'YQ==') }.to raise_error(ArgumentError)
    oversized = 'x' * (((Mxrb::RubyApp::FileContent::MAX_BYTES + 2) / 3) * 4 + 1)
    expect { store.write('Files.Document', '1', 'file', oversized) }.to raise_error(ArgumentError, /20 MiB/)
    expect(database.get_first_value('SELECT COUNT(*) FROM mxrb_file_contents')).to eq(0)
  ensure
    database&.close
  end
end
# rubocop:enable Metrics/BlockLength
