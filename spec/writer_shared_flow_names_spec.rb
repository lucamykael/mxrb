# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Writer do
  def collections(path)
    Mxrb.open(path) do |project|
      project.modules.flat_map do |mod|
        (mod.microflows + mod.nanoflows).map do |flow|
          ["#{mod.name}.#{flow.name}",
           Mxrb::IO::BsonCodec.extract_id(project.parse_bson(project.raw_unit(flow.id)).dig('ObjectCollection', '$ID'))]
        end
      end.to_h
    end
  end

  def define(path, second_module: :Beta, flow: :RunAll)
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module(:Alpha) { microflow(:RunAll) { log_message 'alpha' } }
      self.module(second_module) { microflow(flow) { log_message 'beta' } }
    end
  end

  it 'gives flows that share a name across modules distinct object collections' do
    Dir.mktmpdir do |directory|
      shared = File.join(directory, 'Shared.mpr')
      define(shared)
      ids = collections(shared)
      expect(ids.fetch('Alpha.RunAll')).not_to eq(ids.fetch('Beta.RunAll'))

      unique = File.join(directory, 'Unique.mpr')
      define(unique, flow: :RunOther)
      expect(collections(unique).fetch('Alpha.RunAll'))
        .to eq(described_class.allocate.send(:stable_id, 'RunAll', 'object_collection'))
    end
  end

  it 'keeps the stable identity of uniquely named flows and qualifies a flow added beside an existing one' do
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'App.mpr')
      Mxrb.define(path) do
        mendix_version '11.12.1'
        self.module(:Alpha) { microflow(:RunAll) { log_message 'alpha' } }
      end
      before = collections(path).fetch('Alpha.RunAll')
      tests = Mxrb::Dsl::ModuleBuilder.new('Tests')
      tests.microflow(:RunAll) { log_message 'tests' }
      described_class.new(path, version: '11.12.1', modules: [tests.to_h], security: nil, native_units_path: nil).write!
      after = collections(path)
      expect(after.fetch('Alpha.RunAll')).to eq(before)
      expect(after.fetch('Tests.RunAll')).not_to eq(before)
    end
  end
end
# rubocop:enable Metrics/BlockLength
