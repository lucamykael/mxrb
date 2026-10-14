# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::RubyApp::ProjectWidgetBundle do
  def widget_xml(id, platform: 'Web', plugin: true)
    <<~XML
      <widget id="#{id}" supportedPlatform="#{platform}" pluginWidget="#{plugin}">
        <name>Chart</name>
        <properties>
          <propertyGroup caption="General">
            <systemProperty key="Name" />
            <property key="points" type="datasource" isList="true"><caption>Points</caption></property>
            <property key="x" type="attribute" dataSource="points"><caption>X</caption>
              <attributeTypes><attributeType name="Decimal" /></attributeTypes></property>
            <property key="title" type="string" defaultValue="Chart"><caption>Title</caption></property>
            <property key="series" type="object" isList="true"><caption>Series</caption><properties>
              <propertyGroup caption="Series"><property key="label" type="string"><caption>Label</caption></property></propertyGroup>
            </properties></property>
          </propertyGroup>
        </properties>
      </widget>
    XML
  end

  def write_package(path, widgets, files = {})
    Zip::File.open(path, create: true) do |zip|
      widgets.each { |name, xml| zip.get_output_stream(name) { _1.write(xml) } }
      files.each { |name, contents| zip.get_output_stream(name) { _1.write(contents) } }
      zip.get_output_stream('package.xml') do |stream|
        paths = widgets.keys.map { "<widgetFile path=\"#{_1}\" />" }.join
        stream.write("<package><clientModule><widgetFiles>#{paths}</widgetFiles></clientModule></package>")
      end
    end
  end

  let(:module_source) { 'export function Chart() { return null; }' }

  def chart_files
    {
      'example/chart/Chart.mjs' => module_source, 'example/chart/Chart.js' => 'define([], {});',
      'example/chart/Chart.css' => '.chart {}', 'example/chart/assets/marker.svg' => '<svg/>',
      'other/Other.mjs' => 'export {};'
    }
  end

  it 'reads the web build of a project widget and the definitions the host maps' do
    Dir.mktmpdir do |root|
      widgets = File.join(root, 'widgets')
      FileUtils.mkdir_p(widgets)
      File.write(File.join(widgets, 'a-broken.mpk'), 'not a zip')
      write_package(File.join(widgets, 'b-native.mpk'),
                    { 'Native.xml' => widget_xml('example.chart.Chart', platform: 'Native') })
      write_package(File.join(widgets, 'c-amd.mpk'), { 'Chart.xml' => widget_xml('example.chart.Chart') },
                    'example/chart/Chart.js' => 'define([], {});')
      expect(described_class.find(root, 'example.chart.Chart')).to be_nil
      write_package(File.join(widgets, 'd-chart.mpk'), { 'Chart.xml' => widget_xml('example.chart.Chart') },
                    chart_files)

      bundle = described_class.find(root, 'example.chart.Chart')

      expect(bundle).to have_attributes(widget_id: 'example.chart.Chart', name: 'Chart', entry: 'Chart.mjs')
      expect(bundle.files).to eq('Chart.mjs' => module_source, 'Chart.css' => '.chart {}',
                                 'assets/marker.svg' => '<svg/>')
      expect(described_class.properties(bundle.definition.properties)).to eq(
        [
          { key: 'points', type: 'DataSource', list: true },
          { key: 'x', type: 'Attribute', list: false, data_source: 'points' },
          { key: 'title', type: 'String', list: false, default: 'Chart' },
          { key: 'series', type: 'Object', list: true, properties: [{ key: 'label', type: 'String', list: false }] }
        ]
      )
      expect(described_class.find(root, 'example.Missing')).to be_nil
    end
  end

  it 'registers only the rendered widgets the bridge does not render itself' do
    Dir.mktmpdir do |root|
      widgets = File.join(root, 'widgets')
      FileUtils.mkdir_p(widgets)
      line_chart = 'com.mendix.widget.web.linechart.LineChart'
      write_package(File.join(widgets, 'chart.mpk'),
                    { 'Chart.xml' => widget_xml('example.chart.Chart'), 'Line.xml' => widget_xml(line_chart),
                      'Unused.xml' => widget_xml('example.unused.Unused'),
                      'Gauge.xml' => widget_xml('example.gauge.Gauge') },
                    chart_files.merge('com/mendix/widget/web/linechart/LineChart.mjs' => 'export {};',
                                      'example/unused/Unused.mjs' => 'export {};',
                                      'example/gauge/Gauge.mjs' => 'export default function Gauge() {}'))
      path = File.join(root, 'App.mpr')
      Mxrb.define(path) do
        self.module :App do
          page :Charts do
            pluggable_widget :Chart, widget_id: 'example.chart.Chart'
            pluggable_widget :Line, widget_id: 'com.mendix.widget.web.linechart.LineChart'
            pluggable_widget :Plain, widget_id: 'example.plain.Plain'
            pluggable_widget :Gauge, widget_id: 'example.gauge.Gauge'
            pluggable_widget :Feedback, widget_id: 'SprintrFeedbackWidget.SprintrFeedback'
          end
        end
      end
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(path, target, mode: :ruby).export!
      generated = File.join(target, 'frontend', 'src', 'generated')
      registrations = File.read(File.join(generated, 'projectWidgets.ts'))
      vendor = File.join(generated, 'bridge', 'vendor', 'widgets')

      expect(registrations).to include(
        "import './bridge/vendor/widgets/example.chart.Chart/Chart.css';",
        "import * as widget0 from './bridge/vendor/widgets/example.chart.Chart/Chart.mjs';",
        'registerProjectWidget("example.chart.Chart", widget0, "Chart", [{"key":"points"'
      )
      expect(registrations).to include(
        "import * as widget1 from './bridge/vendor/widgets/example.gauge.Gauge/Gauge.mjs';"
      )
      expect(registrations).not_to include('Gauge.css', 'SprintrFeedback', 'LineChart', 'Unused')
      expect(Dir.children(vendor).sort).to eq(['example.chart.Chart', 'example.gauge.Gauge'])
      expect(File.read(File.join(vendor, 'example.chart.Chart', 'Chart.mjs'))).to eq(module_source)
      expect(File.read(File.join(vendor, 'example.chart.Chart', 'Chart.d.mts')))
        .to include('export { Widget as Chart };')
      expect(File.read(File.join(target, 'frontend', 'vite.config.ts'))).to include("'mendix/filters/builders'")
      report = Mxrb::RubyApp::WidgetSupport.new(target)
      expect(report.send(:adapter_registered?, 'example.chart.Chart')).to be(true)
      expect(report.send(:adapter_registered?, 'example.plain.Plain')).to be(false)
      expect(Mxrb::RubyApp::WidgetSupport.new.send(:adapter_registered?, 'example.chart.Chart')).to be(false)
    end
  end

  def legacy_xml(id)
    <<~XML
      <widget id="#{id}" needsEntityContext="true" xmlns="http://www.mendix.com/widget/1.0/">
        <name>Tags</name>
        <properties>
          <property key="caption" type="translatableString" required="false"><caption>Caption</caption></property>
          <property key="reference" type="entity" isPath="yes" pathType="referenceSet"><caption>Tags</caption></property>
          <property key="constraint" type="entityConstraint" entityProperty="reference"><caption>Constraint</caption></property>
          <property key="source" type="microflow"><caption>Source</caption></property>
        </properties>
      </widget>
    XML
  end

  it 'runs the Dojo widgets of the project packages through the legacy host' do
    Dir.mktmpdir do |root|
      widgets = File.join(root, 'widgets')
      FileUtils.mkdir_p(widgets)
      write_package(File.join(widgets, 'a-incomplete.mpk'), { 'Broken/Broken.xml' => legacy_xml('Broken.Broken') })
      expect(described_class.find(root, 'Broken.Broken')).to be_nil
      write_package(File.join(widgets, 'tags.mpk'), { 'Tags/Tags.xml' => legacy_xml('Tags.widget.Tags') },
                    'Tags/widget/Tags.js' => 'define([], function () { return function () {}; });',
                    'Tags/widget/templates/Tags.html' => '<div></div>',
                    'Tags/widget/ui/Tags.css' => '.tags {}', 'Tags/widget/ui/check.png' => 'png',
                    'Tags/lib/helper.js' => 'define([], {});', 'Other/Other.js' => 'define([], {});')
      write_package(File.join(widgets, 'feedback.mpk'),
                    { 'Feedback.xml' => legacy_xml('SprintrFeedbackWidget.SprintrFeedback') },
                    'SprintrFeedbackWidget/SprintrFeedback.js' => 'define([], {});')

      bundle = described_class.find(root, 'Tags.widget.Tags')
      expect(bundle).to have_attributes(name: 'Tags', entry: 'Tags/widget/Tags', legacy: true)
      expect(bundle.files.keys).to eq(%w[Tags/Tags.xml Tags/widget/Tags.js Tags/widget/templates/Tags.html
                                         Tags/widget/ui/Tags.css Tags/widget/ui/check.png Tags/lib/helper.js])
      expect(described_class.properties(bundle.definition.properties).map { _1.values_at(:key, :type) }).to eq(
        [%w[caption TranslatableString], %w[reference Entity], %w[constraint EntityConstraint], %w[source Microflow]]
      )

      path = File.join(root, 'App.mpr')
      Mxrb.define(path) do
        self.module :App do
          page :Tags do
            pluggable_widget :Tags, widget_id: 'Tags.widget.Tags'
            pluggable_widget :Feedback, widget_id: 'SprintrFeedbackWidget.SprintrFeedback'
          end
        end
      end
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(path, target, mode: :ruby).export!
      registrations = File.read(File.join(target, 'frontend', 'src', 'generated', 'projectWidgets.ts'))

      expect(registrations).to start_with(
        "import { registerLegacyWidget } from './bridge/legacy/LegacyWidgetHost';\n\n"
      )
      expect(registrations).not_to include('registerProjectWidget')
      expect(registrations).to include(
        "import './bridge/vendor/widgets/Tags.widget.Tags/Tags/widget/ui/Tags.css';",
        "const sources1 = import.meta.glob<string>('./bridge/vendor/widgets/Tags.widget.Tags/**/*.{js,html}', " \
        "{ query: '?raw', import: 'default', eager: true });",
        'registerLegacyWidget("Tags.widget.Tags", sources1, "./bridge/vendor/widgets/Tags.widget.Tags/", ' \
        '"Tags/widget/Tags", [{"key":"caption","type":"TranslatableString"',
        'registerLegacyWidget("SprintrFeedbackWidget.SprintrFeedback", sources0'
      )
      vendor = File.join(target, 'frontend', 'src', 'generated', 'bridge', 'vendor', 'widgets', 'Tags.widget.Tags')
      expect(File.read(File.join(vendor, 'Tags/widget/templates/Tags.html'))).to eq('<div></div>')
      expect(File.read(File.join(target, 'frontend', 'public', 'widgets', 'Tags/widget/ui/check.png'))).to eq('png')
      expect(File.exist?(File.join(target, 'frontend', 'public', 'widgets', 'Tags/widget/Tags.js'))).to be(false)
      expect(Mxrb::RubyApp::WidgetSupport.new(target).send(:adapter_registered?, 'Tags.widget.Tags')).to be(true)
    end
  end

  it 'writes an empty registration module when no project widget runs in the host' do
    Dir.mktmpdir do |root|
      path = File.join(root, 'App.mpr')
      Mxrb.define(path) { self.module(:App) { entity(:Item) { string :Name } } }
      target = File.join(root, 'ruby')
      Mxrb::Exporter.new(path, target, mode: :ruby).export!
      expect(File.read(File.join(target, 'frontend', 'src', 'generated', 'projectWidgets.ts'))).to eq("export {};\n")
    end
  end

  it 'records pluggable widgets nested in the options of another widget' do
    exporter = Mxrb::RubyApp::Exporter.allocate
    exporter.send(:record_rendered_widget, { 'type' => 'pluggable_widget', 'options' => { 'widget_id' => 'a.A' } })
    exporter.send(:record_rendered_widget, { type: :pluggable_widget, options: { widget_id: 'b.B' } })
    exporter.send(:record_rendered_widget, { type: :pluggable_widget })
    exporter.send(:record_rendered_widget, { type: :container, options: { widget_id: 'c.C' } })
    expect(exporter.instance_variable_get(:@rendered_widget_ids)).to eq(Set['a.A', 'b.B'])
  end
end
# rubocop:enable Metrics/BlockLength
