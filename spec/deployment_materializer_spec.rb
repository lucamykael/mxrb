# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

RSpec.describe Mxrb::Compiler::DeploymentMaterializer do
  it 'runs every native stage in dependency order and returns their results' do
    Dir.mktmpdir do |root|
      mpr = File.join(root, 'App.mpr')
      deployment = File.join(root, 'deployment')
      source = instance_double(Mxrb::Compiler::SourceModel, version: '11.12.1')
      adapter = instance_double(Mxrb::Compiler::Adapter)
      allow(Mxrb::Compiler::SourceModel).to receive(:read).with(mpr).and_return(source)
      bootstrapper = instance_double(Mxrb::Compiler::DeploymentBootstrapper, prepare: true)
      allow(Mxrb::Compiler::DeploymentBootstrapper).to receive(:new)
        .with(mpr, deployment:, mendix_home: nil).and_return(bootstrapper)
      allow(Mxrb::Compiler::Adapter).to receive(:for).with('11.12.1').and_return(adapter)
      allow(adapter).to receive(:validate_deployment!).with(deployment)
      described_class::STAGES.each do |stage|
        instance = instance_double(stage)
        allow(stage).to receive(:new).with(mpr, deployment:).and_return(instance)
        allow(instance).to receive(:materialize).and_return(stage.name)
      end

      result = described_class.new(mpr, deployment:).materialize
      expect(result).to have_attributes(deployment:, mendix_version: '11.12.1')
      expect(result.stages.keys).to eq(described_class::STAGES.map { _1.name.split('::').last })
      expect(result.stages.values).to eq(described_class::STAGES.map(&:name))
    end
  end
end
