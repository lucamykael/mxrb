# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::Dataset do
  after { Mxrb::RubyApp::Registry.reset! }

  def declare(name = 'Hr.Query')
    Class.new(described_class).tap do |dataset|
      dataset.mendix_name(name, id: 'dataset-id')
      dataset.oql('SELECT e.Name AS Name FROM Hr.Employee e')
    end
  end

  def synchronizer(dataset, documents: [])
    definition = dataset.definition
    entry = { 'name' => definition.name, 'id' => dataset.mendix_id,
              'parameters' => definition.parameters, 'excluded' => definition.excluded }
    manifest = double(modules: [{ 'datasets' => [entry] }])
    project = double(modules: [double(application_documents: documents)])
    Mxrb::RubyApp::DatasetSynchronizer.new(project, manifest)
  end

  it 'preserves native metadata while exposing query text and validating its declaration' do
    dataset = declare
    expect(dataset.mendix_name).to eq('Hr.Query')
    expect(dataset.definition.parameters).to eq([])
    expect(dataset.definition.excluded).to be(false)
    dataset.native_metadata(parameters: [:Filter], excluded: true)
    expect(dataset.definition.parameters).to eq(['Filter'])
    expect(dataset.definition.excluded).to be(true)
    expect { dataset.mendix_name('Unqualified') }.to raise_error(ArgumentError, /qualified/)
    expect { dataset.oql(42) }.to raise_error(TypeError, /String/)
  end

  it 'keeps domain-only modules compatible and leaves non-OQL datasets native' do
    expect(Mxrb::Runtime::OqlDatasets.module_definitions(Object.new)).to eq([])
    exporter = Mxrb::RubyApp::Exporter.allocate
    document = { doc: { 'Source' => { '$Type' => 'DataSets$MicroflowSource' } } }
    expect(exporter.send(:export_dataset, Object.new, document, 'Hr', 'hr')).to be_nil
  end

  it 'rejects structural changes before writing a native dataset' do
    dataset = declare
    removal = synchronizer(dataset)
    Mxrb::RubyApp::Registry.reset!
    expect { removal.synchronize! }.to raise_error(Mxrb::ValidationError, %r{creation/removal})
    dataset = declare
    rename = synchronizer(dataset)
    Mxrb::RubyApp::Registry.reset!
    declare('Hr.Renamed')
    expect { rename.synchronize! }.to raise_error(Mxrb::ValidationError, /rename/)
    Mxrb::RubyApp::Registry.reset!
    dataset = declare
    parameter = synchronizer(dataset)
    dataset.native_metadata(parameters: ['Filter'])
    expect { parameter.synchronize! }.to raise_error(Mxrb::ValidationError, /parameter/)
    dataset = declare
    exclusion = synchronizer(dataset)
    dataset.native_metadata(excluded: true)
    expect { exclusion.synchronize! }.to raise_error(Mxrb::ValidationError, /metadata/)
  end

  it 'rejects a missing native source instead of silently losing the query edit' do
    expect { synchronizer(declare).synchronize! }
      .to raise_error(Mxrb::ValidationError, /source is missing/)
  end
end
# rubocop:enable Metrics/BlockLength
