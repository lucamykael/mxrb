# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::KnownOqlActions do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'selects only source-matched actions, accepting CRLF and rejecting modified or missing sources' do
    Dir.mktmpdir do |root|
      directory = File.join(root, 'javasource', 'hr', 'actions')
      FileUtils.mkdir_p(directory)
      source = "// selected query action\n"
      stub_const('Mxrb::RubyApp::KnownOqlActions::SOURCES',
                 'RetrieveDatasetOql' => [Digest::SHA256.hexdigest(source)], 'RetrieveAdvancedOql' => [])
      expect(described_class.registrations(root)).to eq('')
      File.binwrite(File.join(directory, 'RetrieveDatasetOql.java'), source.gsub("\n", "\r\n"))
      File.write(File.join(directory, 'RetrieveAdvancedOql.java'), '// custom')
      expect(described_class.registrations(root))
        .to eq('Mxrb::RubyApp::KnownOqlActions.register("RetrieveDatasetOql")')
      File.write(File.join(directory, 'RetrieveDatasetOql.java'), '// custom')
      expect(described_class.registrations(root)).to eq('')
    end
  end

  it 'binds each adapter to its own runtime store and rejects unknown action registrations' do
    described_class.register('RetrieveDatasetOql')
    described_class.register('RetrieveAdvancedOql')
    actions = Mxrb::RubyApp::Registry.java_custom_actions
    first = double('first store')
    second = double('second store')
    expect(first).to receive(:dataset_objects).with('Hr.Query', 'Hr.Result').and_return(['first'])
    expect(second).to receive(:dataset_objects).with('Hr.Query', 'Hr.Result').and_return(['second'])
    expect(first).to receive(:oql_objects).with('SELECT query', 'Hr.Result').and_return(['text'])
    dataset = actions.fetch('Hr.RetrieveDatasetOql')
    arguments = { 'DataSetName' => 'Hr.Query', 'ResultEntity' => 'Hr.Result' }
    expect(dataset.bind(first).call(arguments)).to eq(['first'])
    expect(dataset.bind(second).call(arguments)).to eq(['second'])
    expect(actions.fetch('Hr.RetrieveAdvancedOql').bind(first)
                  .call('OqlQuery' => 'SELECT query', 'ResultEntity' => 'Hr.Result')).to eq(['text'])
    expect { described_class.register('Other') }.to raise_error(KeyError)
  end
end
# rubocop:enable Metrics/BlockLength
