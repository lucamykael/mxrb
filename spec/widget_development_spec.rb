# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Mxrb::WidgetDevelopment do # rubocop:disable Metrics/BlockLength
  it 'runs the pinned official generator with argv-safe arguments' do
    calls = []
    runner = lambda do |environment, command, directory|
      calls << [environment, command, directory]
      true
    end
    Dir.mktmpdir do |root|
      result = described_class.new(runner:).create('OrderSummary', directory: root)

      expect(result).to eq(File.join(root, 'OrderSummary'))
      expect(calls).to eq([[{}, %w[npx --yes @mendix/generator-widget@11.11.0 OrderSummary], root]])
    end
  end

  it 'builds through the official release task and returns MPK packages' do
    calls = []
    runner = lambda do |environment, command, directory|
      calls << [environment, command, directory]
      if command == %w[npm run release]
        FileUtils.mkdir_p(File.join(directory, 'dist'))
        File.write(File.join(directory, 'dist', 'OrderSummary.mpk'), 'package')
      end
      true
    end
    Dir.mktmpdir do |root|
      File.write(File.join(root, 'package.json'), '{}')
      packages = described_class.new(runner:).build(root, project: '/tmp/Mendix App')

      expect(packages).to eq([File.join(root, 'dist', 'OrderSummary.mpk')])
      expect(calls.map { _1[1] }).to eq([%w[npm ci], %w[npm run release]])
      expect(calls.last.first).to eq('MX_PROJECT_PATH' => '/tmp/Mendix App')
    end
  end

  it 'rejects unsafe names, missing projects, failed commands, and empty builds' do
    expect { described_class.new.create('../escape') }.to raise_error(ArgumentError, /widget name/)
    expect { described_class.new.build('/missing') }.to raise_error(ArgumentError, /not found/)
    expect do
      Dir.mktmpdir { described_class.new(runner: ->(*) { false }).create('Safe', directory: _1) }
    end.to raise_error(Mxrb::CompilationError, /command failed/)
    expect do
      Dir.mktmpdir do |root|
        File.write(File.join(root, 'package.json'), '{}')
        described_class.new(runner: ->(*) { true }).build(root)
      end
    end.to raise_error(Mxrb::CompilationError, /no MPK/)
  end
end
