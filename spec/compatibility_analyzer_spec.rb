# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::CompatibilityAnalyzer do
  def unit(type, name, document = {})
    Mxrb::Compiler::SourceModel::Unit.new(
      id: name, container_id: 'module', containment: 'Documents', module_name: 'Demo',
      document: { '$Type' => type, 'Name' => name }.merge(document)
    )
  end

  def source(version:, units:, documents: [])
    instance_double(
      Mxrb::Compiler::SourceModel, version:, units:, documents:
    ).tap do |model|
      allow(model).to receive(:units_of) { |type| units.select { _1.document['$Type'] == type } }
    end
  end

  it 'reports page widgets, actions, and nanoflow activities in the React pipeline' do
    page = unit('Forms$Page', 'Home', 'FormCall' => { 'Arguments' => [2, {
      'Parameter' => 'Demo.Shell.Main', 'Widgets' => [2,
                                                      { '$Type' => 'Forms$UnknownWidget', 'Name' => 'group' },
                                                      { '$Type' => 'Forms$ActionButton', 'Name' => 'delete',
                                                        'Action' => { '$Type' => 'Forms$DeleteClientAction' } }]
    }] })
    nanoflow = unit('Microflows$Nanoflow', 'ClientFlow',
                    'ObjectCollection' => { 'Objects' => [2,
                                                          { '$ID' => 'start', '$Type' => 'Microflows$StartEvent' },
                                                          { '$ID' => 'action', '$Type' => 'Microflows$ActionActivity',
                                                            'Action' => {
                                                              '$ID' => 'log',
                                                              '$Type' => 'Microflows$UnsupportedAction'
                                                            } }] },
                    'Flows' => [2, {
                      'OriginPointer' => 'start', 'DestinationPointer' => 'action'
                    }])
    model = source(version: '11.12.1', units: [page, nanoflow])
    report = described_class.new('/tmp/App.mpr', source: model).analyze

    expect(report).not_to be_compatible
    expect(report.errors.map(&:category)).to include(:widget, :client_action, :nanoflow)
    expect(report.stats).to include(units: 2, pages: 1, nanoflows: 1, microflows: 0)
    expect(report.to_h).to include(compatible: false, mendix_version: '11.12.1')
  end

  it 'stops at an unsupported Mendix version instead of auditing it with the wrong renderer' do
    page = unit('Forms$Page', 'Home', 'Widgets' => [2, { '$Type' => 'Forms$UnknownWidget' }])
    report = described_class.new('/tmp/App.mpr', source: source(version: '10.18.0', units: [page])).analyze

    expect(report.errors.map(&:category)).to eq([:version])
  end

  it 'audits Mendix 6, 7, and 9 pages through the legacy renderer contract' do
    page = unit('Forms$Page', 'Home', 'Widgets' => [2,
                                                    { '$Type' => 'Forms$TextBox', 'Name' => 'name' },
                                                    { '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'map' }])
    report = described_class.new('/tmp/App.mpr', source: source(version: '9.24.0', units: [page])).analyze

    expect(report.errors.map(&:type)).to contain_exactly('CustomWidgets$CustomWidget', 'Forms$TextBox')
    expect(report.errors.map(&:message)).to all(include('legacy web renderer'))
  end

  it 'accepts a supported project whose pages use the compiled subset' do
    page = unit('Forms$Page', 'Home', 'FormCall' => { 'Arguments' => [2, {
      'Parameter' => 'Demo.Shell.Main', 'Widgets' => [2, {
        '$Type' => 'Forms$DynamicText', 'Name' => 'caption',
        'Content' => { 'Template' => { 'Items' => [2] } }
      }]
    }] })
    model = source(version: '11.12.1', units: [page])
    report = described_class.new('/tmp/App.mpr', source: model).analyze

    expect(report).to be_compatible
    expect(report.findings).to be_empty
  end
end
# rubocop:enable Metrics/BlockLength
