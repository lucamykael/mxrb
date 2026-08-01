# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Compiler::ProjectMaterializer do
  around do |example|
    Dir.mktmpdir do |root|
      @mpr = File.join(root, 'App.mpr')
      @deployment = File.join(root, 'deployment')
      define_project
      prepare_model
      example.run
    end
  end

  def define_project
    Mxrb.define(@mpr) do
      mendix_version '11.12.1'
      self.module(:App) do
        entity(:Item) { string :Name }
        microflow(:Run) { return_value 'true' }
      end
    end
  end

  def prepare_model
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    project = source.units_of('Projects$Project').first.document
    @app = source.units_of('Projects$ModuleImpl').first.document
    @domain = source.units_of('DomainModels$DomainModel').first.document
    @flow = source.units_of('Microflows$Microflow').first.document
    system = {
      '$ID' => '11111111-1111-4111-8111-111111111111', '$Type' => 'Projects$ModuleImpl',
      'DomainModel' => nil, 'AllDocuments' => []
    }
    runtime_project = {
      '$ID' => project['$ID'], '$Type' => project['$Type'],
      'ProjectDocuments' => [], 'Modules' => [system]
    }
    write_model(runtime_project, @domain, @flow)
  end

  def write_model(*documents)
    path = File.join(@deployment, 'model', 'model.mdp')
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, documents.map { Mxrb::IO::BsonCodec.serialize(_1) }.join)
  end

  it 'rebuilds source modules and preserves Runtime-provided modules' do
    result = described_class.new(@mpr, deployment: @deployment).materialize
    package = Mxrb::Compiler::ModelPackage.read(result.model_path)
    project = package.documents.find { _1['$Type'] == 'Projects$Project' }
    module_document = package.find(Mxrb::IO::BsonCodec.extract_id(@app['$ID'])).document

    expect(result).to have_attributes(modules: 2, documents: 1)
    expect(project.keys).to eq(%w[$ID $Type ProjectDocuments Modules])
    expect(Mxrb::IO::BsonCodec.extract_id(project['Modules'].first['$ID']))
      .to eq('11111111-1111-4111-8111-111111111111')
    expect(project['Modules'].last['DomainModel']).to include('$ID' => @domain['$ID'])
    expect(project['Modules'].last['AllDocuments']).to eq(
      [{ '$ID' => @flow['$ID'], '$Type' => 'Microflows$Microflow' }]
    )
    expect(module_document).to include('Name' => 'App')
  end

  it 'creates a project root when compiling a fresh model package' do
    write_model(@domain)
    result = described_class.new(@mpr, deployment: @deployment).materialize
    package = Mxrb::Compiler::ModelPackage.read(result.model_path)
    expect(package.documents.first).to include('$Type' => 'Projects$Project')
    expect(result.modules).to eq(1)
  end

  it 'returns no reference for an absent source unit' do
    materializer = described_class.new(@mpr, deployment: @deployment)
    package = Mxrb::Compiler::ModelPackage.read(File.join(@deployment, 'model', 'model.mdp'))
    expect(materializer.send(:reference, nil, package)).to be_nil
  end

  it 'preserves unmatched project documents, reuses a header, and includes the System seed' do
    materializer = described_class.new(@mpr, deployment: @deployment)
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    project = source.units_of('Projects$Project').first.document
    preserved = { '$ID' => '22222222-2222-4222-8222-222222222222', '$Type' => 'Test$Document' }
    existing = { 'ProjectDocuments' => [preserved] }
    package = Mxrb::Compiler::SystemModelSeed.for('11.12.1').package
    header = project.merge('DeploymentID' => 'already-present')
    package = package.with_appended(header)

    expect(materializer.send(:project_documents, source, package, existing)).to eq([preserved])
    expect(materializer.send(:seeded_modules, source, package).first)
      .to include('$Type' => 'Projects$ModuleImpl')
    expect(materializer.send(:ensure_deployment_header, package, source)).to equal(package)
  end
end
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
