# frozen_string_literal: true

require 'spec_helper'
require 'digest'
require 'stringio'
require 'tmpdir'
load File.expand_path('../script/pluggable_schema_round_trip_gate', __dir__)

RSpec.describe MxrbPluggableSchemaRoundTripGate do # rubocop:disable Metrics/BlockLength
  def widget_document
    registry = Mxrb::Pluggable::Catalog.new
    Mxrb::Pluggable.widget_type('com.example.private.Widget', catalog: registry) do
      properties { property :caption, :string }
    end
    node = Mxrb::Pluggable.widget('com.example.private.Widget', catalog: registry)
    node.identifier 'private_widget'
    node.object.set(:caption, 'private caption')
    Mxrb::Forms::MprCodec.new(pluggable_catalog: registry).encode(node)
  end

  def make_mpr(path, document)
    db = SQLite3::Database.new(path)
    db.execute('CREATE TABLE _MetaData (_ProductVersion TEXT)')
    db.execute("INSERT INTO _MetaData VALUES ('11.12.1')")
    db.execute('CREATE TABLE Unit (UnitID BLOB, ContainerID BLOB, ' \
               'ContainmentName TEXT, ContentsHash TEXT, Contents BLOB)')
    id = Mxrb::IO::BsonCodec.uuid_to_blob(SecureRandom.uuid)
    db.execute('INSERT INTO Unit VALUES (?, ?, ?, ?, ?)',
               [id, id, 'Pages', '', SQLite3::Blob.new(Mxrb::IO::BsonCodec.serialize(document))])
  ensure
    db&.close
  end

  it 'checks every nested widget, writes sanitized evidence, and leaves the MPR unchanged' do
    Dir.mktmpdir('mxrb-schema-gate-') do |directory|
      path = File.join(directory, 'PrivateProject.mpr')
      destination = File.join(directory, 'report.json')
      make_mpr(path, { 'First' => widget_document, 'Nested' => [2, widget_document] })
      digest = Digest::SHA256.file(path).hexdigest

      expect(described_class.cli([path, '--output', destination])).to eq(0)
      evidence = File.read(destination)
      expect(JSON.parse(evidence)).to include('passed' => true, 'widgets' => 2, 'schemas_byte_equal' => 2)
      expect(evidence).not_to include('PrivateProject', 'private_widget', 'private caption', 'com.example.private')
      expect(Digest::SHA256.file(path).hexdigest).to eq(digest)
    end
  end

  it 'continues after an invalid widget and reports only its ordinal and error class' do
    Dir.mktmpdir('mxrb-schema-gate-') do |directory|
      path = File.join(directory, 'PrivateProject.mpr')
      invalid = widget_document.merge('PrivateUnsupportedField' => 'private data')
      make_mpr(path, { 'Children' => [2, invalid, widget_document] })
      output = StringIO.new

      expect(described_class.cli([path], output:)).to eq(1)
      evidence = JSON.parse(output.string)
      expect(evidence).to include('passed' => false, 'widgets' => 2, 'schemas_equal' => 1)
      expect(evidence.fetch('failures').first).to include('unit' => 1, 'widget' => 1)
      expect(output.string).not_to include('PrivateUnsupportedField', 'private data', 'private_widget')
    end
  end

  it 'rejects a report destination that aliases the input MPR' do
    Dir.mktmpdir('mxrb-schema-gate-') do |directory|
      path = File.join(directory, 'PrivateProject.mpr')
      alias_path = File.join(directory, 'report.json')
      make_mpr(path, widget_document)
      File.symlink(path, alias_path)
      digest = Digest::SHA256.file(path).hexdigest

      expect(described_class.cli([path, '--output', alias_path], errors: StringIO.new)).to eq(1)
      expect(Digest::SHA256.file(path).hexdigest).to eq(digest)
    end
  end

  it 'fails empty corpora instead of claiming schema coverage' do
    Dir.mktmpdir('mxrb-schema-gate-') do |directory|
      path = File.join(directory, 'Empty.mpr')
      make_mpr(path, { '$Type' => 'Projects$Project' })

      expect(described_class.run(path)).to include(passed: false, widgets: 0, failures: [{ reason: 'no_widgets' }])
    end
  end

  it 'returns distinct nonzero statuses for missing input and invalid arguments' do
    output = StringIO.new
    expect(described_class.cli(['/missing/private/Project.mpr'], output:)).to eq(1)
    expect(output.string).not_to include('/missing/private')
    expect(described_class.cli([], errors: StringIO.new)).to eq(64)
  end
end
