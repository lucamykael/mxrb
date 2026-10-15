# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe 'Empty values in microflows' do
  let(:fixture) { 'spec/fixtures/native_empty_objects' }
  let(:expected) { JSON.parse(File.read(File.join(fixture, 'expected.json'))).fetch('results') }

  around do |example|
    Dir.mktmpdir('mxrb-empty-objects-') do |root|
      @path = File.join(root, 'Empty.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = @path
      load File.join(fixture, 'project.rb')
      @project = Mxrb::Model::Project.open(@path)
      example.run
    ensure
      ENV['MXRB_OUTPUT_PATH'] = previous
      @project&.close
    end
  end

  it 'matches Mendix 11.12.1 with the memory and the SQLite store' do
    [nil, Mxrb::Runtime::SQLiteStore.new(@project)].each do |store|
      runtime = Mxrb::Runtime::Native::Interpreter.new(@project, store:)
      expect(runtime.call('Views.RunAll')).to be(true)
      expect(runtime.log.to_h { _1.delete_prefix('ORACLE ').split('=', 2) }).to eq(expected)
    ensure
      store&.close
    end
  end
end

RSpec.describe 'Non-persistent objects in the SQLite store' do
  it 'starts non-persistent objects with their modeled defaults in the SQLite store' do
    root = Dir.mktmpdir('mxrb-draft-')
    path = File.join(root, 'Draft.mpr')
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :Views do
        entity :Draft do
          non_persistent!
          boolean :Done
          integer :Count, default: '3'
        end
      end
    end
    project = Mxrb::Model::Project.open(path)
    store = Mxrb::Runtime::SQLiteStore.new(project)
    expect(store.create('Views.Draft').members).to eq('Done' => false, 'Count' => 3)
    explicit = Mxrb::Runtime::SQLiteStore.new(project, defaults: { 'Views.Draft' => { 'Done' => true } })
    expect(explicit.create('Views.Draft').members).to eq('Done' => true)
  ensure
    explicit&.close
    store&.close
    project&.close
    FileUtils.rm_rf(root)
  end
end
