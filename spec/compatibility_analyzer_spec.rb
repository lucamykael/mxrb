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
    report = described_class.new('/tmp/App.mpr', source: source(version: '8.18.0', units: [page])).analyze

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

  it 'classifies generic and identified custom widget bundle findings' do
    model = source(version: '11.12.1', units: [])
    analyzer = described_class.new('/tmp/App.mpr', source: model)
    bundle = double(
      unsupported_widgets: ['CustomWidgets$CustomWidget', 'Forms$UnknownWidget'],
      unsupported_custom_widgets: ['vendor.widget.Uncompiled']
    )

    analyzer.send(:add_bundle_findings, bundle, 'Demo.Shell')

    expect(analyzer.send(:collapsed_findings).map(&:category)).to contain_exactly(:custom_widget, :widget)
  end

  it 'classifies identified custom widgets found while compiling pages' do
    page = unit('Forms$Page', 'Home')
    model = source(version: '11.12.1', units: [page])
    bundle = double(
      unsupported_widgets: ['CustomWidgets$CustomWidget'],
      unsupported_custom_widgets: ['vendor.widget.Uncompiled']
    )
    compiler = instance_double(Mxrb::Compiler::PageBundleCompiler, compile: bundle)
    allow(Mxrb::Compiler::PageBundleCompiler).to receive(:new).and_return(compiler)

    report = described_class.new('/tmp/App.mpr', source: model).analyze

    expect(report.errors.map(&:category)).to eq([:custom_widget])
    expect(report.errors.first.type).to eq('vendor.widget.Uncompiled')
  end

  it 'turns legacy page, React page, and layout compiler failures into findings' do
    page = unit('Forms$Page', 'Home')
    layout = unit('Forms$Layout', 'Shell')

    legacy_model = source(version: '7.17.0', units: [page])
    legacy = described_class.new('/tmp/Legacy.mpr', source: legacy_model)
    legacy.instance_variable_set(:@adapter, Mxrb::Compiler::Adapter.for('7.17.0'))
    allow(Mxrb::Compiler::LegacyPageBuilder).to receive(:new).and_raise(
      Mxrb::CompilationError, 'legacy failure'
    )
    legacy.send(:analyze_legacy_pages)
    expect(legacy.send(:collapsed_findings).last.message).to eq('legacy failure')

    modern_model = source(version: '11.12.1', units: [page, layout])
    modern = described_class.new('/tmp/Modern.mpr', source: modern_model)
    allow(Mxrb::Compiler::PageBundleCompiler).to receive(:new).and_return(
      double(compile: nil, compile_layout: nil)
    )
    allow(Mxrb::Compiler::PageBundleCompiler).to receive(:new).and_raise(
      Mxrb::CompilationError, 'React failure'
    )
    modern.send(:analyze_pages)
    modern.send(:analyze_layouts)
    expect(modern.send(:collapsed_findings).map(&:message))
      .to include('React failure')
  end

  it 'exposes compatibility through the public MXRB API' do
    report = double
    analyzer = instance_double(described_class, analyze: report)
    allow(described_class).to receive(:new).with('/tmp/App.mpr').and_return(analyzer)
    expect(Mxrb.compatibility('/tmp/App.mpr')).to equal(report)
  end
end
# rubocop:enable Metrics/BlockLength
