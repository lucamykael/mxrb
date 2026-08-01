# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::ModelPackage do
  def bson(document) = Mxrb::IO::BsonCodec.serialize(document)

  around do |example|
    Dir.mktmpdir do |root|
      @path = File.join(root, 'model.mdp')
      @first_id = '11111111-1111-4111-8111-111111111111'
      @second_id = '22222222-2222-4222-8222-222222222222'
      File.binwrite(@path, bson('$ID' => @first_id, '$Type' => 'Projects$Project', 'Name' => 'App') +
                           bson('$ID' => @second_id, '$Type' => 'Security$ProjectSecurity'))
      example.run
    end
  end

  it 'reads, inventories, locates, replaces, and deterministically writes BSON streams' do
    package = described_class.read(@path)
    expect(package.entries.map(&:offset)).to eq([0, package.entries.first.size])
    expect(package.types).to eq('Projects$Project' => 1, 'Security$ProjectSecurity' => 1)
    expect(package.find(@first_id).document['Name']).to eq('App')
    expect(package.find('missing')).to be_nil

    replacement = { '$ID' => @second_id, '$Type' => 'Security$ProjectSecurity', 'SecurityLevel' => 'CheckEverything' }
    updated = package.replace(@second_id, replacement)
    output = File.join(File.dirname(@path), 'nested', 'updated.mdp')
    expect(updated.write(output)).to eq(output)
    reread = described_class.read(output)
    expect(reread.documents.last).to include('SecurityLevel' => 'CheckEverything')
    expect(reread.entries.last.offset).to eq(reread.entries.first.size)
  end

  it 'upserts documents by GUID and rejects documents without IDs' do
    package = described_class.read(@path)
    replacement = package.documents.first.merge('Name' => 'Updated')
    replaced = package.upsert(replacement)
    expect(replaced.entries.length).to eq(2)
    expect(replaced.find(@first_id).document['Name']).to eq('Updated')

    appended = replacement.merge('$ID' => '33333333-3333-4333-8333-333333333333')
    inserted = replaced.upsert(appended)
    expect(inserted.entries.length).to eq(3)
    expect(inserted.entries.last.offset).to be_positive
    expect { package.upsert('$Type' => 'MissingId') }
      .to raise_error(Mxrb::CompilationError, /has no \$ID/)
  end

  it 'rejects missing documents and malformed or truncated BSON streams' do
    package = described_class.read(@path)
    expect { package.replace('missing', {}) }.to raise_error(Mxrb::CompilationError, /not found/)

    File.binwrite(@path, "\x01\x00\x00")
    expect { described_class.read(@path) }.to raise_error(Mxrb::CompilationError, /truncated BSON length/)
    File.binwrite(@path, [100].pack('l<').concat('short'))
    expect { described_class.read(@path) }.to raise_error(Mxrb::CompilationError, /invalid BSON size/)
    File.binwrite(@path, [5].pack('l<').concat('x'))
    expect { described_class.read(@path) }.to raise_error(Mxrb::CompilationError, /BSON parse error/)
  end
end
# rubocop:enable Metrics/BlockLength
