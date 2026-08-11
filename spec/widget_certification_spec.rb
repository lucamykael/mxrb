# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::WidgetCertification do
  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      @mpr = File.join(root, 'Widgets.mpr')
      FileUtils.mkdir_p(File.join(root, 'widgets'))
      Zip::File.open(File.join(root, 'widgets', 'map.mpk'), create: true) do |zip|
        zip.get_output_stream('example/Map.mjs') { _1.write('export default () => null;') }
      end
      Mxrb.define(@mpr) do
        mendix_version '11.12.1'
        self.module :Demo do
          layout :Shell
          page :Home do
            layout 'Demo.Shell'
            text :Heading, caption: 'Widgets'
            pluggable_widget :Map, widget_id: 'example.Map'
          end
        end
        navigation { profile :Responsive, home_page: 'Demo.Home' }
      end
      example.run
    end
  end

  def inventory
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    described_class.new(@mpr, build: false).send(:widget_inventory, source)
  end

  # rubocop:disable Metrics/MethodLength
  def browser_report(extra = {})
    path = File.join(@root, 'browser.json')
    payload = {
      'passed' => true, 'scenario' => 'widgets', 'console_errors' => [],
      'certification' => {
        'widget_ids' => inventory.fetch(:custom).map { _1.fetch(:id) },
        'widget_types' => inventory.fetch(:core).map { _1.fetch(:type) }
      },
      'pages' => [{ 'snapshot' => { 'elements' => [{ 'text' => 'Widgets' }] } }]
    }.merge(extra)
    File.write(path, JSON.pretty_generate(payload))
    path
  end
  # rubocop:enable Metrics/MethodLength

  it 'certifies compiler support, package modules, native build, and matching browser evidence' do
    certification = described_class.new(@mpr, browser_report: browser_report)
    allow(certification).to receive(:build_web).and_return(
      status: 'pass', stages: 12, files: 3, bytes: 100, elapsed_ms: 10.0
    )
    report = certification.run

    expect(report).to include(status: 'pass', failures: [])
    expect(report.dig(:inventory, :custom)).to include(include(id: 'example.Map', occurrences: 1))
    expect(report.dig(:packages, :entries)).to include(include(file: 'map.mpk'))
    expect(report.dig(:compilation, :status)).to eq('pass')
    expect(report.dig(:browser, :status)).to eq('pass')
  end

  it 'fails closed for absent, invalid, incomplete, or visibly broken browser evidence' do
    missing = described_class.new(@mpr, build: false).run
    expect(missing).to include(status: 'fail')
    expect(missing.dig(:browser, :status)).to eq('missing')
    expect(missing.fetch(:failures)).to include('native web bundle did not pass')

    invalid_path = File.join(@root, 'invalid.json')
    File.write(invalid_path, '{')
    invalid = described_class.new(@mpr, browser_report: invalid_path, build: false)
    expect(invalid.send(:browser_evidence, inventory)).to include(status: 'fail', error: /invalid browser report/)

    broken = JSON.parse(File.read(browser_report))
    broken['passed'] = false
    broken['certification']['widget_ids'] = []
    broken['certification']['widget_types'] = []
    broken['failure_snapshot'] = {
      'elements' => [{ 'text' => "Could not render widget 'Demo.Home.Map'" }]
    }
    File.write(invalid_path, JSON.pretty_generate(broken))
    evidence = described_class.new(@mpr, browser_report: invalid_path, build: false)
                              .send(:browser_evidence, inventory)
    expect(evidence).to include(status: 'fail', passed: false)
    expect(evidence.fetch(:missing_widget_ids)).to eq(['example.Map'])
    expect(evidence.fetch(:visible_failures).first).to include('Could not render widget')
  end

  it 'reports missing and corrupt packages, build results, and fatal input errors' do
    Zip::File.open(File.join(@root, 'widgets', 'irrelevant.mpk'), create: true) do |zip|
      zip.get_output_stream('other/Widget.mjs') { _1.write('export default {};') }
    end
    File.binwrite(File.join(@root, 'widgets', 'broken.mpk'), 'broken')
    certification = described_class.new(@mpr, build: false)
    packages = certification.send(:packages, %w[example.Map example.Missing])
    expect(packages).to include(status: 'fail', missing_widget_ids: ['example.Missing'])
    expect(packages.fetch(:entries)).to include(include(file: 'broken.mpk', error: /Zip/))

    materialization = instance_double(Mxrb::Compiler::DeploymentMaterialization, stages: { one: true })
    web = instance_double(Mxrb::Compiler::WebBundleResult, files: 4, bytes: 250)
    allow(Mxrb::Compiler::DeploymentMaterializer).to receive(:new).and_return(
      instance_double(Mxrb::Compiler::DeploymentMaterializer, materialize: materialization)
    )
    allow(Mxrb::Compiler::WebBundleBuilder).to receive(:new).and_return(
      instance_double(Mxrb::Compiler::WebBundleBuilder, build: web)
    )
    expect(certification.send(:build_web, '11.12.1')).to include(
      status: 'pass', stages: 1, files: 4, bytes: 250
    )

    fatal = described_class.new(File.join(@root, 'missing.mpr'), build: false).run
    expect(fatal).to include(status: 'fail', error: include(class: kind_of(String)))
  end

  it 'resolves embedded widget types and aggregates failure categories' do
    source = Mxrb::Compiler::SourceModel.read(@mpr)
    custom = source.document_index.values.find { _1['$Type'] == 'CustomWidgets$CustomWidget' }
    certification = described_class.new(@mpr, build: false)
    expect(certification.send(:custom_widget_id, source, custom)).to eq('example.Map')

    indirect = Marshal.load(Marshal.dump(custom))
    indirect['Type'] = {}
    expect(certification.send(:custom_widget_id, source, indirect)).to eq('example.Map')
    indirect['Object']['TypePointer'] = 'missing'
    expect(certification.send(:custom_widget_id, source, indirect)).to eq('')

    bundle_attributes = {
      qualified_name: 'Demo.Unsupported', source: 'bundle',
      unsupported_widgets: ['Forms$Unknown'], unsupported_custom_widgets: []
    }
    bundle = instance_double(Mxrb::Compiler::PageBundle, **bundle_attributes)
    compiler = instance_double(
      Mxrb::Compiler::PageBundleCompiler, compile: bundle, compile_layout: bundle
    )
    allow(Mxrb::Compiler::PageBundleCompiler).to receive(:new).and_return(compiler)
    expect(certification.send(:compile_pages, source)).to include(status: 'fail')

    result = certification.send(
      :failures,
      { status: 'fail' }, { status: 'fail' }, { status: 'fail' }, { status: 'fail' }
    )
    expect(result.length).to eq(4)
  end
end
# rubocop:enable Metrics/BlockLength
