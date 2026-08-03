# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'official MPR native web compatibility' do
  it 'preflights and compiles the pinned Mendix acceptance project' do
    paths = ENV.fetch('MXRB_ACCEPTANCE_MPRS', '').split(File::PATH_SEPARATOR).select { File.file?(_1) }
    skip 'pinned acceptance fixtures not present in this environment' if paths.empty?

    paths.each do |path|
      source = Mxrb::Compiler::SourceModel.read(path)
      report = Mxrb::Compiler::CompatibilityAnalyzer.new(path, source:).analyze
      expect(report).to be_compatible

      Dir.mktmpdir do |root|
        target = File.join(root, 'operations.json')
        operations = Mxrb::Compiler::WebOperationCompiler.new(source).write(target)
        expect(operations).not_to be_empty
        expect(JSON.parse(File.read(target))).to eq(operations)
      end
    end
  end
end
