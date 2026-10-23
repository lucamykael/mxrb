# frozen_string_literal: true

require 'spec_helper'
require 'mxrb/studio/documents'
require 'tmpdir'

# rubocop:disable Metrics
RSpec.describe Mxrb::Studio::Documents do
  around do |example|
    Dir.mktmpdir('mxrb-studio-documents-') do |directory|
      @directory = directory
      previous = ENV.fetch('XDG_STATE_HOME', nil)
      ENV['XDG_STATE_HOME'] = File.join(directory, 'state')
      example.run
    ensure
      ENV['XDG_STATE_HOME'] = previous
    end
  end

  def open_model(path, readonly: true)
    model = Mxrb::IO::MprFile.open(path, readonly:, apply_studio_compatibility: false)
    yield model
  ensure
    model&.close
  end

  def make_project(format)
    path = File.join(@directory, "#{format}.mpr")
    Mxrb.define(path) { mendix_version '11.12.1' }
    identifier = SecureRandom.uuid
    nested_id = SecureRandom.uuid
    bytes = BSON::Document.new(
      '$Type' => 'Tests$Document', 'Name' => 'Original', '$ID' => identifier,
      'Documentation' => 'Olá 🐧', 'Flag' => true, 'Count' => 7, 'Wide' => BSON::Int64.new(12),
      'Ratio' => 1.5, 'Empty' => nil,
      'Blob' => BSON::Binary.new("\0\xFFpayload".b, :user),
      'Children' => [3, { '$ID' => nested_id, '$Type' => 'Tests$Child', 'Text' => 'Caption',
                          'Location' => { 'X' => 10, 'Y' => 20 } }],
      'References' => [1, 'App.Entity'], 'Entity' => 'App.Entity', 'DestinationPointer' => SecureRandom.uuid,
      'a/b~c' => 'escaped'
    ).to_bson.to_s
    open_model(path, readonly: false) do |mpr|
      @unit_id = mpr.insert_unit(container_uuid: mpr.root_unit.fetch('UnitID'),
                                 containment_name: 'Documents',
                                 unit_uuid: identifier,
                                 contents_doc: { '$ID' => identifier, '$Type' => 'Tests$Document' })
      mpr.transaction { mpr.update_unit_bytes(@unit_id, bytes) }
      mpr.migrate_storage_format!(:v2) if format == :v2
    end
    @original_bytes = bytes
    path
  end

  def snapshot(path)
    open_model(path) do |mpr|
      { database: File.binread(path),
        units: mpr.all_units.to_h { |unit| [unit.fetch('UnitID'), [unit, mpr.content_bytes(unit)]] },
        files: mpr.content_files.to_h { [_1, File.binread(_1)] } }
    end
  end

  %i[v1 v2].each do |format|
    context "with #{format} native storage" do
      let(:path) { make_project(format) }
      let(:documents) { described_class.new(path) }

      it 'lists and projects native BSON without changing any files' do
        before = snapshot(path)
        entry = documents.list.find { _1[:unit_id] == @unit_id }
        expect(entry).to include(name: 'Original', type: 'Tests$Document', containment_name: 'Documents')
        result = documents.read(@unit_id)
        expect(result[:revision]).to eq(Digest::SHA256.hexdigest(@original_bytes))
        expect(result.dig(:document,
                          'Blob')).to eq('$binary' => { 'base64' => Base64.strict_encode64("\0\xFFpayload".b),
                                                        'subType' => '80' })
        expect(JSON.parse(JSON.generate(result)).dig('document', 'Name')).to eq('Original')
        editable = result[:properties].select { _1[:editable] }.map { _1[:path] }
        expect(editable).to include('/Name', '/Children/1/Text', '/Children/1/Location/X')
        expect(editable).not_to include('/$ID', '/$Type', '/Children/0', '/Children/1/$ID', '/References/1', '/Entity',
                                        '/DestinationPointer', '/Blob')
        expect(snapshot(path)).to eq(before)
      end

      it 'patches only the selected scalar bytes preserving every other native field and unit' do
        before = snapshot(path)
        revision = documents.read(@unit_id)[:revision]
        result = documents.patch(@unit_id, revision:, changes: [
                                   { path: '/Name', value: 'Novo 🐧' },
                                   { path: ['Children', 1, 'Text'], value: 'Nova legenda' }
                                 ])
        # Build the exact expected native document directly, preserving scalar widths and key order.
        native = BSON::Document.from_bson(BSON::ByteBuffer.new(@original_bytes))
        native['Name'] = 'Novo 🐧'
        native['Children'][1]['Text'] = 'Nova legenda'
        # BSON parsing forgets Int64 width; restore the untouched width in this independent expected encoding.
        native['Wide'] = BSON::Int64.new(native['Wide'])
        expected = native.to_bson.to_s
        after = snapshot(path)
        expect(after[:units].fetch(@unit_id).last).to eq(expected)
        before[:units].each do |id, value|
          expect(after[:units].fetch(id)).to eq(value) unless id == @unit_id
        end
        expect(result.dig(:document, 'Children', 1, 'Location')).to eq('X' => 10, 'Y' => 20)
        expect(result.dig(:document, '$ID')).to eq(@unit_id)
        expect(result.dig(:document, 'Children', 1, '$ID')).to eq(native['Children'][1]['$ID'])
        expect(result[:revision]).to eq(Digest::SHA256.hexdigest(expected))
        expect(result.dig(:document, 'Name')).to eq('Novo 🐧')
        expect(open_model(path, &:format_version)).to eq(format)
      end

      it 'keeps int32 and int64 widths while editing booleans, numbers and escaped JSON pointer keys' do
        revision = documents.read(@unit_id)[:revision]
        result = documents.patch(@unit_id, revision:, changes: { '/Count' => 8, '/Wide' => (2**40), '/Flag' => false,
                                                                 '/Ratio' => 2.75, '/a~1b~0c' => 'updated' })
        bytes = snapshot(path)[:units].fetch(@unit_id).last
        expect(bytes).to include("\x10Count\0#{[8].pack('l<')}")
        expect(bytes).to include("\x12Wide\0#{[2**40].pack('q<')}")
        expect(result.dig(:document, 'Flag')).to be(false)
        expect(result.dig(:document, 'a/b~c')).to eq('updated')
      end

      it 'serializes two clients editing the same revision without losing a newer edit' do
        revision = documents.read(@unit_id)[:revision]
        model_path = path
        identifier = @unit_id
        results = Queue.new
        threads = %w[first second].map do |name|
          Thread.new do
            described_class.new(model_path).patch(identifier, revision:, changes: { '/Name' => name })
            results << :saved
          rescue Mxrb::Studio::Conflict
            results << :conflict
          end
        end
        threads.each(&:join)
        expect(2.times.map { results.pop }).to contain_exactly(:saved, :conflict)
        expect(%w[first second]).to include(documents.read(identifier).dig(:document, 'Name'))
      end

      it 'uses the actual native payload revision even when stored ContentsHash metadata is stale' do
        open_model(path, readonly: false) do |mpr|
          mpr.query('UPDATE Unit SET ContentsHash = ? WHERE UnitID = ?',
                    ['stale', Mxrb::IO::BsonCodec.uuid_to_blob(@unit_id)])
        end
        result = documents.read(@unit_id)
        expect(result[:revision]).to eq(Digest::SHA256.hexdigest(@original_bytes))
        expect(documents.patch(@unit_id, revision: result[:revision], changes: { '/Name' => 'Fixed' })
          .dig(:document, 'Name')).to eq('Fixed')
      end

      it 'rejects stale revisions and preserves a newer document exactly' do
        revision = documents.read(@unit_id)[:revision]
        documents.patch(@unit_id, revision:, changes: { '/Name' => 'External' })
        before = snapshot(path)
        expect { documents.patch(@unit_id, revision:, changes: { '/Name' => 'Editor' }) }
          .to raise_error(Mxrb::Studio::Conflict)
        expect(snapshot(path)).to eq(before)
      end

      it 'validates every change before opening a writable transaction and preserves all units on errors' do
        revision = documents.read(@unit_id)[:revision]
        invalid = [
          { '/Missing' => 'value' }, { '/Name/child' => 'value' }, { '/Children/1/Text' => 1 },
          { '/Name' => nil }, { '/Count' => 1.5 }, { '/Count' => 2**40 }, { '/Wide' => 2**70 },
          { '/Ratio' => Float::INFINITY }, { '/$ID' => SecureRandom.uuid }, { '/$Type' => 'Tests$Other' },
          { '/Children/1/$ID' => SecureRandom.uuid }, { '/Children/0' => 2 },
          { '/Children' => [] }, { '/References/1' => 'App.Other' }, { '/Entity' => 'App.Other' },
          { '/DestinationPointer' => SecureRandom.uuid }, { '/Blob' => 'text' }, { '/bad~escape' => 'x' }
        ]
        before = snapshot(path)
        allow(Mxrb::IO::MprFile).to receive(:open).and_call_original
        invalid.each do |change|
          expect(Mxrb::IO::MprFile).not_to receive(:open).with(path, readonly: false, apply_studio_compatibility: false)
          expect { documents.patch(@unit_id, revision:, changes: { '/Name' => 'Must roll back' }.merge(change)) }
            .to raise_error(ArgumentError)
          expect(snapshot(path)).to eq(before)
        end
      end

      it 'rolls back a database write and split unit file when an exception occurs inside the transaction' do
        revision = documents.read(@unit_id)[:revision]
        before = snapshot(path)
        allow_any_instance_of(Mxrb::IO::MprFile).to receive(:update_unit_bytes).and_wrap_original do |original, *args|
          original.call(*args)
          raise 'planned write failure'
        end
        expect { documents.patch(@unit_id, revision:, changes: { '/Name' => 'Rejected' }) }
          .to raise_error(RuntimeError, 'planned write failure')
        expect(snapshot(path)).to eq(before)
      end
    end
  end

  it 'rejects missing models, unknown units and malformed unit IDs' do
    expect { described_class.new(File.join(@directory, 'missing.mpr')) }.to raise_error(Errno::ENOENT)
    documents = described_class.new(make_project(:v1))
    expect { documents.read('invalid') }.to raise_error(ArgumentError, /UUID/)
    expect { documents.read(SecureRandom.uuid) }.to raise_error(ArgumentError, /unknown unit/)
  end
end
# rubocop:enable Metrics
