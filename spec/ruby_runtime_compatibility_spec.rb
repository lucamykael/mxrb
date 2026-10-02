# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zlib'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Standalone runtime compatibility' do
  around do |example|
    Dir.mktmpdir do |directory|
      @root = File.join(directory, 'app')
      source = File.join(directory, 'Files.mpr')
      Mxrb.define(source) do
        mendix_version '11.12.1'
        self.module :Files do
          entity(:Tag) { string :Name }
          entity :Document do
            generalizes 'System.FileDocument'
            string :Label
            association 'Files.Tag', type: :ReferenceSet, name: :Tags
          end
          entity(:Report) { generalizes 'Files.Document' }
          entity(:Photo) { generalizes 'System.Image' }
          entity(:Album) { association 'System.FileDocument', name: :Cover }
        end
      end
      Mxrb::Exporter.new(source, @root, mode: :ruby).export!
      @application = Mxrb::RubyApp::Application.new(@root)
      example.run
    ensure
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  before { allow(Mxrb::IO::MprFile).to receive(:open).and_raise('MPR is forbidden at runtime') }

  def png_chunk(type, data)
    [[data.bytesize].pack('N'), type, data, [Zlib.crc32(type + data)].pack('N')].join
  end

  def png
    header = [8, 4, 8, 2, 0, 0, 0].pack('NNCCCCC')
    pixels = Zlib.deflate(["\0", "\xff\0\0".b * 8].join * 4)
    ["\x89PNG\r\n\x1a\n".b, png_chunk('IHDR', header), png_chunk('IDAT', pixels), png_chunk('IEND', '')].join
  end

  it 'persists inherited members, associations and blobs and retrieves concrete subtypes through their bases' do
    app = @application
    tag = app.create_record('Files.Tag', 'Name' => 'Visible')
    report = app.create_record('Files.Report', 'Name' => 'Original', 'Label' => 'Report', 'Tags' => [])
    app.update_record('Files.Document', report.fetch(:id), { 'Tags' => [tag] })
    photo = app.create_record('Files.Photo')
    album = app.create_record('Files.Album')
    app.update_record('Files.Album', album.fetch(:id), { 'Cover' => photo })
    upload = { 'name' => 'test.png', 'content' => Base64.strict_encode64(png) }
    app.file_content('System.FileDocument', photo.fetch(:id), upload:)
    expect(app.record('System.Image', photo.fetch(:id)).fetch(:attributes))
      .to include('Name' => 'test.png', 'FileSize' => png.bytesize, 'HasContents' => true)
    expect(app.records('Files.Document').map { _1.fetch(:type) }).to eq(['Files.Report'])
    expect(app.records('System.FileDocument').map { _1.fetch(:id) }).to contain_exactly(report[:id], photo[:id])
    store = app.send(:bridge).store
    expect(store.count('System.FileDocument')).to eq(2)
    model = Mxrb::RubyApp::Registry.fetch(:record, 'Files.Report').from_native(store.find('Files.Report', report[:id]))
    expect(model.name).to eq('Original')
    model.name = 'Edited in Ruby'
    model.sync_to_native!
    expect(model.to_h.dig(:attributes, :name)).to eq('Edited in Ruby')
    store.commit(store.find('Files.Report', report[:id]))
    metadata = app.schema[:modules].flat_map { _1['models'] }.find { _1['name'] == 'Files.Report' }
    expect(metadata['attributes'].map { _1['name'] }).to include('Name', 'FileSize', 'Label')
    expect(store.retrieve_association('Files.Cover', store.find('System.Image', photo[:id])).map(&:id))
      .to eq([album[:id]])
    snapshot = store.snapshot
    store.restore(snapshot)
    expect(store.count('System.FileDocument')).to eq(2)
    legacy_snapshot = snapshot.except('__mxrb_files__')
    store.restore(legacy_snapshot)
    app.file_content('System.FileDocument', photo[:id], upload:)
    app.close
    @application = Mxrb::RubyApp::Application.new(@root)
    expect(@application.record('Files.Document', report[:id]).dig(:attributes, 'Tags', 0, :id)).to eq(tag[:id])
    expect(@application.record('Files.Report', report[:id]).dig(:attributes, 'Name')).to eq('Edited in Ruby')
    expect(@application.record('Files.Album', album[:id]).dig(:attributes, 'Cover', :type)).to eq('Files.Photo')
    expect(@application.file_content('System.FileDocument', photo[:id]).fetch('content')).to eq(png)
    @application.delete_record('System.FileDocument', photo[:id])
    expect(@application.record('System.Image', photo[:id])).to be_nil
  end

  it 'filters nested and reverse association XPath on the server before pagination' do
    app = @application
    tag = app.create_record('Files.Tag', 'Name' => "A]B's")
    other = app.create_record('Files.Tag', 'Name' => 'Other')
    report = app.create_record('Files.Report', 'Label' => 'Keep')
    app.update_record('Files.Report', report[:id], { 'Tags' => [tag] })
    app.create_record('Files.Document', 'Label' => 'Drop')
    xpath = "[Files.Tags/Files.Tag[Name = 'A]B''s']]"
    result = app.record_page('Files.Document', xpath:, limit: 1)
    expect(result.fetch(:total)).to eq(1)
    expect(result.fetch(:records).first[:id]).to eq(report[:id])
    reverse = '[Files.Tags/Files.Report = $currentObject]'
    expect(app.records('Files.Tag', xpath: reverse, xpath_context_type: 'Files.Document',
                                    xpath_context_id: report[:id]).map { _1[:id] }).to eq([tag[:id]])
    expect(app.records('Files.Tag', xpath: '[Files.Tags/Files.Document/Label = \'Keep\']').map { _1[:id] })
      .to eq([tag[:id]])
    expect(app.send(:bridge).interpreter.count('Files.Document', xpath)).to eq(1)
    expect(app.records('Files.Tag', xpath: "[Name = 'Other']").map { _1[:id] }).to eq([other[:id]])
    expect { app.records('Files.Tag', xpath: '[Name', xpath_context_type: 'Files.Report') }
      .to raise_error(ArgumentError, /type and id/)
    expect { app.records('Files.Tag', xpath: '', xpath_context_type: 'Files.Report', xpath_context_id: 'missing') }
      .to raise_error(ArgumentError, /not found/)
  end

  it 'generates a real bounded PNG thumbnail, caches it and invalidates it on replacement or deletion' do
    app = @application
    photo = app.create_record('Files.Photo')
    upload = { 'name' => 'test.png', 'content' => Base64.strict_encode64(png) }
    expect { app.file_content('System.Image', photo[:id], upload: upload.merge('content' => 'dGV4dA==')) }
      .to raise_error(ArgumentError, /requires an image/)
    app.file_content('System.Image', photo[:id], upload:)
    thumbnail = app.file_content('System.Image', photo[:id], thumbnail: [4, 4])
    expect(thumbnail.fetch('content').byteslice(16, 8).unpack('NN')).to eq([4, 2])
    expect(thumbnail.fetch('content')).not_to eq(png)
    expect(app.file_content('Files.Photo', photo[:id], thumbnail: [4, 4])).to eq(thumbnail)
    database = app.send(:bridge).store.database
    expect(database.get_first_value('SELECT COUNT(*) FROM mxrb_file_thumbnails')).to eq(1)
    app.file_content('Files.Photo', photo[:id], upload:)
    expect(database.get_first_value('SELECT COUNT(*) FROM mxrb_file_thumbnails')).to eq(0)
    app.file_content('Files.Photo', photo[:id], thumbnail: [4, 4])
    store = app.send(:bridge).store
    snapshot = store.snapshot
    app.delete_record('System.Image', photo[:id])
    store.restore(snapshot)
    expect(app.file_content('Files.Photo', photo[:id], thumbnail: [4, 4])).to eq(thumbnail)
    app.delete_record('System.Image', photo[:id])
    expect(database.get_first_value('SELECT COUNT(*) FROM mxrb_file_thumbnails')).to eq(0)
  end

  it 'serves constrained queries and thumbnails over HTTP without bypassing concrete entity permissions' do
    @application.close
    server = Mxrb::RubyApp::Server.new(@root, port: 0)
    @application = app = server.application
    photo = app.create_record('Files.Photo')
    app.file_content('Files.Photo', photo[:id],
                     upload: { 'name' => 'test.png', 'content' => Base64.strict_encode64(png) })
    dispatch = lambda do |path, query|
      request = Struct.new(:path, :query) do
        def request_method = 'GET'
        def body = ''
        def [](_key) = nil
      end.new(path, query)
      Mxrb::Http::Response.new.tap { server.send(:dispatch, request, _1) }
    end
    query = { 'xpath' => '[Name = $currentObject/Name]', 'xpath_context_type' => 'System.Image',
              'xpath_context_id' => photo[:id], 'limit' => '1' }
    response = dispatch.call('/api/entities/System.FileDocument', query)
    expect(response.status).to eq(200)
    expect(JSON.parse(response.body).fetch('total')).to eq(1)
    response = dispatch.call('/api/entities/System.FileDocument', query.except('limit'))
    expect(JSON.parse(response.body).fetch('records').first.fetch('type')).to eq('Files.Photo')
    path = "/api/files/System.Image/#{photo[:id]}"
    response = dispatch.call(path, 'thumbnail_width' => '4', 'thumbnail_height' => '4')
    expect(response.status).to eq(200)
    expect(response.body.byteslice(16, 8).unpack('NN')).to eq([4, 2])
    expect(dispatch.call(path, 'thumbnail_height' => '4').status).to eq(400)
    expect(dispatch.call(path, 'thumbnail_width' => '0', 'thumbnail_height' => '4').status).to eq(400)
    policy = app.access_control
    context = app.session_manager.authenticate(nil)
    allow(policy).to receive(:entity_allowed?).with('Files.Photo', anything).and_return(false)
    expect(app.records('System.Image', context:)).to eq([])
    expect(app.record('System.Image', photo[:id], context:)).to be_nil
    allow(policy).to receive(:authorize!).with('Files.Photo', anything).and_raise(Mxrb::Runtime::AuthorizationError)
    expect { app.file_content('System.Image', photo[:id], context:, thumbnail: [4, 4]) }
      .to raise_error(Mxrb::Runtime::AuthorizationError)
  end

  it 'inherits upload policy, detects cycles and handles unavailable images and workers explicitly' do
    base = Mxrb::RubyApp::Registry.fetch(:record, 'Files.Document')
    report = Mxrb::RubyApp::Registry.fetch(:record, 'Files.Report')
    base.file_policy(max_bytes: 16, extensions: ['png'])
    expect(report.runtime_file_policy).to include(max_bytes: 16, extensions: ['png'])
    base.generalizes('Files.Report')
    expect { report.runtime_ancestors }.to raise_error(ArgumentError, /cyclic/)
    base.generalizes('Files.Document')
    expect { base.runtime_ancestors }.to raise_error(ArgumentError, /cyclic/)
    base.generalizes('System.FileDocument')
    report.generalizes('Files.Tag')
    expect(report.runtime_attributes.map { _1[:mendix_name] }).to eq(['Name'])
    report.generalizes('Files.Document')
    files = Mxrb::RubyApp::FileContent.new(@application.send(:bridge).store.database)
    expect(files.thumbnail('Files.Photo', 'missing', 4, 4)).to be_nil
    thumbnail = Mxrb::RubyApp::Thumbnail
    content = { 'media_type' => 'text/plain', 'content' => 'no image' }
    expect { thumbnail.render(content, 4, 4) }.to raise_error(ArgumentError, /raster/)
    content['media_type'] = 'image/png'
    expect { thumbnail.render(content, 4, 4) }.to raise_error(ArgumentError, /invalid image/)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('MXRB_IMAGEMAGICK', 'magick').and_return('/missing/mxrb-imagemagick')
    expect { thumbnail.render(content, 4, 4) }.to raise_error(ArgumentError, /requires ImageMagick/)
    allow(Process).to receive(:spawn).and_return(1234)
    allow(Timeout).to receive(:timeout).with(15).and_raise(Timeout::Error)
    expect(Process).to receive(:kill).with('KILL', 1234)
    expect(Process).to receive(:wait).with(1234)
    expect { thumbnail.send(:run, 'worker', []) }.to raise_error(ArgumentError, /timed out/)
  end

  it 'builds standalone authorization metadata when exported demo passwords are redacted' do
    security = Class.new(Mxrb::RubyApp::ProjectSecurity) do
      project_security
      security_level 'CheckEverything'
      user_role 'Administrator', module_roles: ['Files.Administrator']
      user_role 'Reader', module_roles: ['Files.Reader']
      demo_user 'reader', entity: 'Files.Document', roles: ['Reader'], password: nil
    end
    policy = @application.access_control
    expect(policy.context(roles: ['Reader']).module_roles).to include('Files.Reader')
    expect(security.demo_user_definitions.first[:password]).to be_nil
    context = policy.context(roles: ['Reader'])
    expect(policy.entity_allowed?('Files.Document', action: :read, context:)).to be(false)
  end
end
# rubocop:enable Metrics/BlockLength
