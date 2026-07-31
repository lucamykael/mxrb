# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Initializer do
  it 'creates the four-file scaffold and generates a valid MPR' do
    Dir.mktmpdir do |dir|
      result = described_class.new('vet_clinic').scaffold(into: dir)
      expected = [
        'Gemfile', 'project.rb', 'modules/VetClinic/module.rb',
        'modules/VetClinic/domain/model.rb'
      ].map { File.join(result.root, _1) }
      expect(result.root).to eq(File.join(dir, 'vet_clinic'))
      expect(result.files).to eq(expected)
      expect(result.files).to all(satisfy { File.file?(_1) })
      expect(File.read(expected[1])).to include(
        'Mxrb.define', 'mendix_version "11.12.1"',
        'modules", "VetClinic", "module.rb"'
      )
      expect(File.read(expected[2])).to include(
        'self.module :VetClinic', 'domain", "model.rb"'
      )
      expect(File.read(expected[3])).to include('# entity :Example')

      load expected[1]
      mpr = File.join(result.root, 'VetClinic.mpr')
      expect(Mxrb.validate(mpr)).to be_valid
      expect(Mxrb.open(mpr) { _1.modules.map(&:name) }).to eq(['VetClinic'])
    end
  end

  it 'normalizes snake case and common lowercase compounds while preserving PascalCase' do
    Dir.mktmpdir do |dir|
      values = {
        'my_app' => 'MyApp', 'vetclinic' => 'VetClinic',
        'ConnectorKitDemo' => 'ConnectorKitDemo'
      }
      values.each do |name, module_name|
        result = described_class.new(name).scaffold(into: dir)
        expect(result.files).to include(
          File.join(result.root, 'modules', module_name, 'module.rb')
        )
      end
    end
  end

  it 'rejects unsafe names and aborts without touching an existing directory' do
    ['', '../escape', 'with/slash', '1project', "nul\0name"].each do |name|
      expect { described_class.new(name) }.to raise_error(ArgumentError, /project name/)
    end
    Dir.mktmpdir do |dir|
      existing = File.join(dir, 'existing')
      FileUtils.mkdir_p(existing)
      File.write(File.join(existing, 'keep.txt'), 'keep')
      expect { described_class.new('existing').scaffold(into: dir) }
        .to raise_error(SystemExit)
      expect(File.read(File.join(existing, 'keep.txt'))).to eq('keep')
    end
  end

  it 'removes its private staging directory when a write fails' do
    Dir.mktmpdir do |dir|
      allow(File).to receive(:binwrite).and_raise(IOError, 'disk full')
      expect { described_class.new('failed_app').scaffold(into: dir) }
        .to raise_error(IOError, /disk full/)
      expect(Dir.children(dir)).to be_empty
    end
  end

  it 'exposes init through the CLI and prints every created file' do
    command = [RbConfig.ruby, File.expand_path('../bin/mxrb', __dir__), 'init', 'my_app']
    Dir.mktmpdir do |dir|
      stdout, stderr, status = Open3.capture3(*command, chdir: dir)
      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to include(
        'create', 'my_app/Gemfile', 'my_app/project.rb',
        'my_app/modules/MyApp/module.rb', 'cd ', 'bundle exec mxrb generate project.rb'
      )
      expect(File).to exist(File.join(dir, 'my_app', 'modules', 'MyApp', 'domain', 'model.rb'))
    end
  end
end
# rubocop:enable Metrics/BlockLength
