# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Compiler::ArtifactMaterializer do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'App.mpr')
      @deployment = File.join(root, 'deployment')
      define_project
      prepare_deployment
      example.run
    end
  end

  def define_project
    Mxrb.define(@mpr) do
      mendix_version '11.12.1'
      self.module(:App) do
        microflow :Run
        enumeration(:State) { value :Open, caption: 'Open item' }
        scheduled_event :Tick, microflow: 'App.Run', interval: 5, unit: :minutes do
          documentation 'Periodic work'
        end
        layout :Shell
        native_document :Pattern, type: 'RegularExpressions$RegularExpression',
                                  deep_structure: { 'Expression' => '^ok$' }
        native_document :Assets, type: 'Images$ImageCollection', deep_structure: {
          'Images' => Mxrb::IO::BsonCodec.build_array([
                                                        {
                                                          '$ID' => '11111111-1111-4111-8111-111111111111',
                                                          '$Type' => 'Images$Image', 'Name' => 'Logo',
                                                          'Image' => 'bytes', 'ImageFormat' => 'Svg'
                                                        }
                                                      ])
        }
      end
    end
  end

  def prepare_deployment
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    project = source.units_of('Projects$Project').first.document
    FileUtils.mkdir_p(File.join(@deployment, 'model'))
    File.binwrite(
      File.join(@deployment, 'model', 'model.mdp'),
      Mxrb::IO::BsonCodec.serialize('$ID' => project['$ID'], '$Type' => project['$Type'])
    )
    File.write(
      File.join(@deployment, 'model', 'metadata.json'),
      JSON.generate('RuntimeVersion' => '11.12.1', 'ScheduledEvents' => [])
    )
  end

  it 'materializes named, enumeration, image, regex, and scheduled-event artifacts' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    package = Mxrb::Compiler::ModelPackage.read(result.model_path)
    documents = package.documents.to_h { [_1['$Type'], _1] }

    expect(result).to have_attributes(documents: 5, scheduled_events: 1)
    expect(documents.fetch('Forms$Layout')).to include('QualifiedName' => 'App.Shell')
    expect(documents.fetch('RegularExpressions$RegularExpression')).to include(
      'QualifiedName' => 'App.Pattern', 'Expression' => '^ok$'
    )
    expect(documents.dig('Enumerations$Enumeration', 'Values', 0)).to include(
      'Name' => 'Open', 'RemoteValue' => nil, 'Image' => ''
    )
    expect(documents.dig('Images$ImageCollection', 'Images', 0)).to include(
      'Name' => 'Logo', 'Format' => 'svg', 'QualifiedName' => 'App.Assets.Logo'
    )
    expect(documents.fetch('ScheduledEvents$ScheduledEvent').keys).to eq(
      %w[$ID $Type Schedule Name QualifiedName StartDateTime TimeZone OnOverlap Interval
         IntervalType Microflow Documentation]
    )
    metadata = JSON.parse(File.read(result.metadata_path))
    expect(metadata['ScheduledEvents']).to eq(
      [{ 'Name' => 'App.Tick', 'Description' => 'Periodic work' }]
    )
  end

  it 'rejects unsupported and module-less artifacts explicitly' do
    compiler = Mxrb::Compiler::ArtifactDocumentCompiler.new
    expect(compiler.send(:text_reference, nil)).to be_nil
    unit = Mxrb::Compiler::SourceModel::Unit.new(
      id: 'unsupported', container_id: 'unsupported', containment: 'Documents', module_name: 'App',
      document: { '$ID' => 'unsupported', '$Type' => 'Test$Artifact', 'Name' => 'Unknown' }
    )
    expect { compiler.compile(unit) }.to raise_error(Mxrb::CompilationError, /unsupported Runtime artifact/)
    layout = unit.with(module_name: nil,
                       document: unit.document.merge('$Type' => 'Forms$Layout', 'Name' => 'Orphan'))
    expect { compiler.compile(layout) }.to raise_error(Mxrb::CompilationError, /outside a module/)
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
