# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe 'Ruby domain identity removal regressions' do
  after { Mxrb::RubyApp::Registry.reset! }

  {
    associations: [:remove_association, [:Item_Owner], :associations],
    indexes: [:remove_index, [:Name], :indexes],
    access_rules: [:remove_access_rule, ['App.User'], :access_rules],
    lifecycle: [:remove_native_lifecycle, [:before_commit], :native_lifecycle_definitions],
    validation_rules: [:remove_validation_rule, [:Name], :validation_rules]
  }.each do |collection, (method, arguments, reader)|
    it "rejects #{collection} removal without a complete collection declaration" do
      record = Class.new(Mxrb::RubyApp::Record)
      record.mendix_name('App.Item', id: '00000000-0000-4000-8000-000000000001')
      previous = record.public_send(reader)
      options = collection == :validation_rules ? { kind: :required } : {}
      record.public_send(method, *arguments, **options)
      baseline = { 'id' => record.mendix_id, 'associations' => [], collection.to_s => [] }
      manifest = Mxrb::RubyApp::Manifest.new('/tmp/record-removal-review', 'mode' => 'ruby', 'modules' => [
                                               { 'models' => [baseline], 'dtos' => [] }
                                             ])

      expect { record.resolve_record_identities!(Mxrb::RubyApp::RecordIdentity.new(manifest)) }
        .to raise_error(Mxrb::ValidationError, /declar|complete|clear/i)
      expect(record.public_send(reader)).to eq(previous)
    end
  end

  [[:Name], %i[Name Code]].each do |names|
    it "rejects a standalone removal against #{names.size} indexes without changing the model" do
      Dir.mktmpdir('mxrb-record-removal-') do |directory|
        source = File.join(directory, 'Source.mpr')
        output = File.join(directory, 'ruby')
        rebuilt = File.join(directory, 'Rebuilt.mpr')
        Mxrb.define(source) do
          mendix_version '11.12.1'
          self.module(:App) do
            entity(:Item) do
              string :Name
              string :Code
            end
          end
        end
        mpr = Mxrb::IO::MprFile.open(source)
        begin
          indexes = names.map { { members: [{ name: _1.to_s, ascending: true }] } }
          Mxrb::Writer.new(source, version: '11.12.1', modules: [])
                      .synchronize_ruby_entity_structures!(mpr, module_name: 'App',
                                                                entities: [{ name: 'Item', indexes: }])
        ensure
          mpr.close
        end
        Mxrb::Exporter.new(source, output, mode: :ruby).export!
        baseline = Mxrb::RubyApp::Manifest.load(output).modules.first.fetch('models').first
        expect(baseline.fetch('indexes').size).to eq(names.size)
        path = File.join(output, 'app', 'models', 'app', 'item.rb')
        original = File.read(path)
        modified = original.gsub(/    index[^\n]* do\n.*?    end\n/m, '')
                           .sub('    clear_access_rules!', "    clear_access_rules!\n    remove_index :Name")
        expect(modified).not_to eq(original)
        File.write(path, modified)

        source_bytes = File.binread(source)
        expect { Mxrb::RubyApp.compile(output, rebuilt) }
          .to raise_error(Mxrb::ValidationError, /declar|complete|clear/i)
        expect(File.binread(source)).to eq(source_bytes)

        # Explicit complete declarations remove only the intended index. For
        # the last member, clearing the collection is the unambiguous contract.
        complete = original.sub(/    index[^\n]* do\n.*?    end\n/m, "    remove_index :Name\n")
        complete = complete.sub('    remove_index :Name', "    clear_indexes!\n    remove_index :Name") if names.one?
        File.write(path, complete)
        Mxrb::RubyApp.compile(output, rebuilt)
        restored = File.join(directory, 'restored')
        Mxrb::Exporter.new(rebuilt, restored, mode: :ruby).export!
        actual = Mxrb::RubyApp::Manifest.load(restored).modules.first.fetch('models').first
        expect(actual.fetch('indexes')).to eq(baseline.fetch('indexes').drop(1))
        expect(actual.fetch('id')).to eq(baseline.fetch('id'))
      end
    end
  end
end
# rubocop:enable Metrics/BlockLength
