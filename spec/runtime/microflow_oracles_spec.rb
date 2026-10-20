# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require_relative '../fixtures/native_latest_http_response/stub'

# Microflows whose "ORACLE <case>=<value>" log lines were recorded on the native
# Mendix 11.12.1 Runtime by script/oql_native_oracle.
# rubocop:disable Metrics/BlockLength
RSpec.describe 'microflows recorded on the native Runtime' do
  before(:all) { @stub = LatestHttpResponseStub.start }
  after(:all) { @stub.close }

  {
    'getCaption and getKey' => 'native_enum_captions',
    'Find and Filter by attribute or association' => 'native_list_member_operations',
    'retrieves over references changed in memory' => 'native_uncommitted_references',
    'a JSON import mapping' => 'native_import_mapping',
    'changes that add to and remove from a reference set' => 'native_reference_set_changes',
    '$latestHttpResponse after REST calls' => 'native_latest_http_response',
    'object type decisions and casts' => 'native_inheritance_split'
  }.each do |subject, fixture|
    it "runs #{subject} as Mendix 11.12.1 does, in memory and on SQLite" do
      directory = File.join('spec/fixtures', fixture)
      expected = JSON.parse(File.read(File.join(directory, 'expected.json'))).fetch('results')
      Dir.mktmpdir do |work|
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(File.join(work, 'Oracle.mpr'))
        load File.join(directory, 'project.rb')
        Mxrb.open(File.join(work, 'Oracle.mpr')) do |project|
          sqlite = Mxrb::Runtime::SQLiteStore.new(project, path: File.join(work, 'oracle.sqlite3'))
          [nil, sqlite].each do |store|
            interpreter = Mxrb::Runtime::Native::Interpreter.new(project, store:)
            expect(interpreter.call('Views.RunAll')).to be(true)
            logged = interpreter.log.to_h { |line| line.delete_prefix('ORACLE ').split('=', 2).then { [_1, [_2]] } }
            expect(logged).to eq(expected), "with #{store.class}"
          end
        ensure
          sqlite&.close
        end
      end
    end
  end

  %w[native_import_mapping native_uncommitted_references native_reference_set_changes
     native_latest_http_response native_inheritance_split].each do |fixture|
    it "runs #{fixture} from the exported Ruby application as Mendix 11.12.1 does" do
      expected = JSON.parse(File.read(File.join('spec/fixtures', fixture, 'expected.json'))).fetch('results')
      Dir.mktmpdir do |work|
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(File.join(work, 'Oracle.mpr'))
        load File.join('spec/fixtures', fixture, 'project.rb')
        target = File.join(work, 'ruby')
        Mxrb::Exporter.new(File.join(work, 'Oracle.mpr'), target, mode: :ruby).export!(parallel: false)
        application = Mxrb::RubyApp::Application.new(target)
        bridge = application.send(:bridge)
        bridge.scheduler.instance_variable_get(:@executor).call('Views.RunAll')
        logged = bridge.interpreter.log.grep(/\AORACLE /)
                       .to_h { |line| line.delete_prefix('ORACLE ').split('=', 2).then { [_1, [_2]] } }
        expect(logged).to eq(expected)
      ensure
        application&.close
        Mxrb::RubyApp::Registry.reset!
      end
    end
  end

  it 'keeps the member of Find and Filter in the exported Ruby' do
    Dir.mktmpdir do |work|
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('MXRB_OUTPUT_PATH').and_return(File.join(work, 'Oracle.mpr'))
      load 'spec/fixtures/native_list_member_operations/project.rb'
      Mxrb::Exporter.new(File.join(work, 'Oracle.mpr'), File.join(work, 'ruby'), mode: :ruby).export!(parallel: false)
      source = File.read(Dir.glob(File.join(work, 'ruby', 'app', 'services', '**', 'run_all.rb')).first)
      expect(source).to include('attribute: "Views.Item.Code"', 'association: "Views.Item_Group"')
    end
  end
end
# rubocop:enable Metrics/BlockLength
