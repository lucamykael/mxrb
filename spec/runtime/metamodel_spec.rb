# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::Metamodel do
  let(:fixture) { 'spec/fixtures/native_metamodel' }
  let(:expected) { JSON.parse(File.read(File.join(fixture, 'expected.json'))) }

  around do |example|
    Dir.mktmpdir('mxrb-metamodel-') do |root|
      @root = root
      source = File.join(root, 'project', 'Meta.mpr')
      previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
      ENV['MXRB_OUTPUT_PATH'] = source
      load File.join(fixture, 'project.rb')
      ENV['MXRB_OUTPUT_PATH'] = previous
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(source, target, mode: :ruby).export!
      @application = Mxrb::RubyApp::Application.new(target, process: { 'MXRB_DATABASE_PATH' => ':memory:' })
      example.run
    ensure
      @application&.close
      Mxrb::RubyApp::Registry.reset!
    end
  end

  it 'reports what the Mendix 11.12.1 Runtime reports to MxModelReflection' do
    metamodel = described_class.new(@application.send(:bridge).project)
    expect(metamodel.objects).to eq(expected.fetch('objects'))
    expect(metamodel.associations).to eq(expected.fetch('associations'))
    expect(metamodel.microflows).to eq(expected.fetch('microflows'))
  end

  it 'defaults text lengths, keeps qualified association names and refuses unknown enumerations' do
    metamodel = described_class.new(@application.send(:bridge).project)
    expect(metamodel.send(:length, { length: nil }, 'String')).to eq(200)
    record = Struct.new(:mendix_name, :associations, :runtime_system_members)
                   .new('Views.Tag', [{ name: 'Views.Tag_Item', target: 'Views.Item', type: :ReferenceSet,
                                        owner: :Both }], {})
    expect(metamodel.send(:record_associations, record))
      .to eq([{ 'name' => 'Views.Tag_Item', 'parent' => 'Views.Tag', 'child' => 'Views.Item',
                'type' => 'REFERENCESET', 'owner' => 'BOTH' }])
    expect { metamodel.send(:enum_values, 'Views.Missing') }
      .to raise_error(Mxrb::NativeRuntimeError, 'unknown enumeration Views.Missing')
  end
end
# rubocop:enable Metrics/BlockLength
