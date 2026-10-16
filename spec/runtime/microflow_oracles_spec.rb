# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# Microflows whose "ORACLE <case>=<value>" log lines were recorded on the native
# Mendix 11.12.1 Runtime by script/oql_native_oracle.
RSpec.describe 'microflows recorded on the native Runtime' do
  {
    'getCaption and getKey' => 'native_enum_captions',
    'Find and Filter by attribute or association' => 'native_list_member_operations',
    'retrieves over references changed in memory' => 'native_uncommitted_references'
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
end
