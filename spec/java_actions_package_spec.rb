# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::JavaActionsPackage do
  around do |example|
    Dir.mktmpdir do |directory|
      @directory = directory
      @source = File.join(directory, 'project', 'Runtime.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = @source
      load 'spec/fixtures/java_action_sidecar/project.rb'
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
    end
  end

  it 'packages the sidecar, the project sources with their proxies and its libraries' do
    library = File.join(@directory, 'project', 'userlib', 'vendor', 'lib.jar')
    FileUtils.mkdir_p(File.dirname(library))
    File.binwrite(library, 'jar')
    File.write(File.join(@directory, 'project', 'userlib', 'lib.jar.Module.RequiredLib'), '')
    FileUtils.mkdir_p(File.join(@directory, 'project', 'vendorlib'))
    File.binwrite(File.join(@directory, 'project', 'vendorlib', 'module.jar'), 'vendor')
    application = File.join(@directory, 'app')
    FileUtils.mkdir_p(File.join(application, 'java-actions', 'stale'))

    result = described_class.new(@source, application).write!
    package = File.join(application, 'java-actions')
    expect(result.to_h).to eq(directory: package, sources: 26, proxies: 4, libraries: 2)
    expect(File).not_to exist(File.join(package, 'stale'))
    expect(File.binread(File.join(package, 'userlib', 'vendor', 'lib.jar'))).to eq('jar')
    expect(File.binread(File.join(package, 'userlib', 'vendorlib', 'module.jar'))).to eq('vendor')
    expect(File).to exist(File.join(package, 'src', 'mxrb', 'sidecar', 'Server.java'))
    expect(File).to exist(File.join(package, 'javasource', 'views', 'proxies', 'Order.java'))
    expect(File).not_to exist(File.join(package, 'javasource', 'system', 'UserActionsRegistrar.java'))
    expect(File.read(File.join(package, 'javasource', 'views', 'Words.java'), encoding: 'UTF-8')).to include('ação')
    compose = File.read(File.join(application, 'docker-compose.yml'))
    expect(compose).to include("build: java-actions\n", '127.0.0.1:${MXRB_JAVA_ACTIONS_PORT:-7911}:7911')
    expect(Mxrb::RubyApp::SOURCE_EXCLUSIONS).to include('java-actions/')

    File.write(File.join(application, 'docker-compose.yml'), "# edited\n")
    described_class.new(@source, application).write!
    expect(File.read(File.join(application, 'docker-compose.yml'))).to eq("# edited\n")
  end

  it 'needs an application directory' do
    expect { described_class.new(@source, File.join(@directory, 'missing')).write! }
      .to raise_error(ArgumentError, /missing is not a directory/)
  end
end
# rubocop:enable Metrics/BlockLength
