# frozen_string_literal: true

require 'spec_helper'
load File.expand_path('../script/prepare_oracle_dependencies', __dir__)

RSpec.describe OracleDependencies do # rubocop:disable Metrics/BlockLength
  let(:entry) do
    { 'file' => 'dependency-1.jar', 'url' => 'https://repo.maven.apache.org/maven2/example/dependency-1.jar',
      'sha256' => Digest::SHA256.hexdigest('verified') }
  end
  let(:manifest) { { 'schema_version' => 1, 'artifacts' => [entry] } }

  it 'rejects invalid paths and duplicate filenames before creating the output' do
    Dir.mktmpdir do |root|
      directory = File.join(root, 'userlib')
      entry['file'] = '../outside.jar'
      expect { described_class.install(manifest, directory) }.to raise_error(ArgumentError, /invalid/)
      expect(File).not_to exist(directory)
      entry['file'] = 'lib.jar'
      manifest['artifacts'] << entry.merge('file' => 'LIB.jar')
      expect { described_class.install(manifest, directory) }.to raise_error(ArgumentError, /duplicate/)
    end
  end

  it 'installs verified bytes and checks cached files instead of trusting their names' do
    Dir.mktmpdir do |root|
      allow(described_class).to receive(:download) { |_url, path| File.write(path, 'verified') }
      expect(described_class.install(manifest, root)).to eq(1)
      expect(described_class.install(manifest, root)).to eq(1)
      expect(described_class).to have_received(:download).once
      File.write(File.join(root, entry['file']), 'tampered')
      expect { described_class.install(manifest, root) }.to raise_error(ArgumentError, /checksum/)
    end
  end

  it 'does not install a corrupt download or leave its temporary file' do
    Dir.mktmpdir do |root|
      allow(described_class).to receive(:download) { |_url, path| File.write(path, 'corrupt') }
      expect { described_class.install(manifest, root) }.to raise_error(ArgumentError, /checksum/)
      expect(Dir.children(root)).to be_empty
    end
  end
end
