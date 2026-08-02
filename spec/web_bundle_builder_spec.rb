# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::WebBundleBuilder do
  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @mpr = File.join(root, 'Web.mpr')
      @deployment = File.join(root, 'deployment')
      @version = File.join(root, '11.12.1')
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module(:Demo)
      end
      FileUtils.mkdir_p(File.join(@deployment, 'web', 'dist', 'chunks'))
      FileUtils.mkdir_p(File.join(@deployment, 'log'))
      File.write(File.join(@deployment, 'web', 'dist', 'index.js'), 'bundle')
      File.write(File.join(@deployment, 'web', 'dist', 'chunks', 'one.js'), 'chunk')
      example.run
    end
  end

  before do
    allow(Mxrb::Compiler::WidgetPackageExtractor).to receive(:new).and_return(
      instance_double(Mxrb::Compiler::WidgetPackageExtractor, extract: 0)
    )
    allow(Mxrb::Compiler::PageBundleBuilder).to receive(:new).and_return(
      instance_double(Mxrb::Compiler::PageBundleBuilder, build: [])
    )
    allow(Mxrb::Compiler::WebOperationCompiler).to receive(:new).and_return(
      instance_double(Mxrb::Compiler::WebOperationCompiler, write: [])
    )
  end

  it 'writes localized startup data and reports the Rspack output inventory' do
    client = File.join(@deployment, 'web', 'dist', 'chunks', 'one.js')
    File.write(
      client,
      'let t=(0,A.g)().getConfig("isDevModeEnabled")?"":' \
      '`?${(0,A.g)().getConfig("cachebust")}`'
    )
    status = instance_double(Process::Status, success?: true)
    expect(Open3).to receive(:capture2e) do |environment, node, runner, chdir:|
      expect(environment).to include('NODE_ENV' => 'production', 'MX_DEPLOYMENT_WEB_DIRECTORY' => chdir)
      expect(node).to end_with('modeler/tools/node/linux-x64/node')
      expect(runner).to end_with('modeler/tools/node/rspack-runner.mjs')
      ['', status]
    end
    result = described_class.new(
      @mpr, deployment: @deployment, mendix_home: File.join(@version, 'runtime')
    ).build
    expect(result.files).to eq(2)
    expect(File.read(client)).to match(
      /let t=`\?\d+\$\{\(0,A\.g\)\(\)\.getConfig\("cachebust"\)\}`/
    )
    entry = File.read(File.join(@deployment, 'web', 'index.js'))
    expect(entry).to include('startApp', '"languages"', '"systemTexts"')
  end

  it 'uses English defaults without system texts and surfaces bundler failures' do
    source = instance_double(Mxrb::Compiler::SourceModel)
    allow(Mxrb::Compiler::SourceModel).to receive(:read).with(@mpr).and_return(source)
    allow(source).to receive(:version).and_return('11.12.1')
    allow(source).to receive(:documents).with('Texts$SystemTextCollection').and_return([])
    builder = described_class.new(@mpr, deployment: @deployment, mendix_home: @version)
    expect(builder.send(:languages)).to eq(['en_US'])
    expect(builder.send(:rendered_system_texts)).to eq({})

    allow(Open3).to receive(:capture2e)
      .and_return(['syntax error', instance_double(Process::Status, success?: false)])
    expect { builder.build }.to raise_error(Mxrb::CompilationError, /syntax error/)
  end
end
# rubocop:enable Metrics/BlockLength
