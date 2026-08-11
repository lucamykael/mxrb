# frozen_string_literal: true

require 'digest'
require 'json'
require 'tmpdir'
require 'zip'

module Mxrb
  # Fail-closed evidence gate for core and pluggable widgets used by an MPR.
  # rubocop:disable Metrics
  class WidgetCertification
    CORE_WIDGET_TYPES = %w[
      Forms$DivContainer Forms$LayoutGrid Forms$LayoutGridRow Forms$LayoutGridColumn Forms$Table
      Forms$DynamicText Forms$Title Forms$ActionButton Forms$DataView Forms$ListView Forms$TextBox
      Forms$TextArea Forms$DatePicker Forms$CheckBox Forms$RadioButtonGroup Forms$FileManager
      Forms$GroupBox Forms$SnippetCallWidget Forms$Label Forms$TabControl Forms$StaticImageViewer
      Forms$ScrollContainer Forms$Placeholder Forms$SidebarToggleButton Forms$Header
      Forms$NavigationTree Forms$MenuBar Forms$SimpleMenuBar
    ].freeze
    FAILURE_MARKERS = [
      'Could not render widget',
      'An error occurred, please contact your system administrator.',
      'Executing runtime operation failed for security reasons',
      'Out of context', 'out of context', 'must be placed inside',
      'should be placed within', 'failed to load'
    ].freeze

    def initialize(path, browser_report: nil, build: true, mendix_home: nil)
      @path = File.expand_path(path)
      @browser_report = browser_report && File.expand_path(browser_report)
      @build = build
      @mendix_home = mendix_home
    end

    def run
      started = monotonic
      source = Compiler::SourceModel.read(@path)
      inventory = widget_inventory(source)
      compilation = compile_pages(source)
      package_inventory = packages(inventory.fetch(:custom).map { _1.fetch(:id) })
      native_build = @build ? build_web(source.version) : { status: 'not_run' }
      browser = browser_evidence(inventory)
      failures = failures(compilation, package_inventory, native_build, browser)
      {
        path: @path, mendix_version: source.version,
        status: failures.empty? ? 'pass' : 'fail', failures:,
        inventory:, packages: package_inventory, compilation:, native_build:, browser:,
        elapsed_seconds: (monotonic - started).round(3)
      }
    rescue StandardError => e
      {
        path: @path, status: 'fail', failures: [e.message],
        error: { class: e.class.name, message: e.message },
        elapsed_seconds: (monotonic - started).round(3)
      }
    end

    private

    def widget_inventory(source)
      found = web_units(source).flat_map do |unit|
        nested_widgets(unit.document).map do |widget|
          custom = widget['$Type'] == 'CustomWidgets$CustomWidget'
          {
            page: "#{unit.module_name}.#{unit.document['Name']}", name: widget['Name'].to_s,
            type: widget['$Type'].to_s, id: (custom ? custom_widget_id(source, widget) : nil)
          }
        end
      end
      core = found.reject { _1[:id] }.group_by { _1.fetch(:type) }.map do |type, entries|
        { type:, occurrences: entries.length, pages: entries.map { _1.fetch(:page) }.uniq.sort }
      end
      core.sort_by! { _1.fetch(:type) }
      custom = found.select { _1[:id] }.group_by { _1.fetch(:id) }.map do |id, entries|
        { id:, occurrences: entries.length, pages: entries.map { _1.fetch(:page) }.uniq.sort }
      end
      custom.sort_by! { _1.fetch(:id) }
      { total: found.length, core:, custom: }
    end

    def nested_widgets(value, found = [])
      case value
      when Hash
        type = value['$Type'].to_s
        found << value if CORE_WIDGET_TYPES.include?(type) || type == 'CustomWidgets$CustomWidget'
        value.each_value { nested_widgets(_1, found) }
      when Array then value.each { nested_widgets(_1, found) }
      end
      found
    end

    def custom_widget_id(source, widget)
      direct = widget.dig('Type', 'WidgetId').to_s
      return direct unless direct.empty?

      pointer = IO::BsonCodec.extract_id(widget.dig('Object', 'TypePointer'))
      source.document_index.values.find do |document|
        IO::BsonCodec.extract_id(document.dig('ObjectType', '$ID')) == pointer
      end&.fetch('WidgetId', '').to_s
    end

    def compile_pages(source)
      pages = web_units(source).map do |unit|
        bundle = if unit.document['$Type'] == 'Forms$Layout'
                   Compiler::PageBundleCompiler.new(source).compile_layout(unit)
                 else
                   Compiler::PageBundleCompiler.new(source).compile(unit)
                 end
        {
          name: bundle.qualified_name, bytes: bundle.source.bytesize,
          unsupported: bundle.unsupported_widgets,
          unsupported_custom: bundle.unsupported_custom_widgets
        }
      end
      { status: pages.all? { _1[:unsupported].empty? && _1[:unsupported_custom].empty? } ? 'pass' : 'fail', pages: }
    end

    def packages(widget_ids)
      paths = Dir.glob(File.join(File.dirname(@path), 'widgets', '*.mpk')).sort
      entries = paths.map do |path|
        modules = Zip::File.open(path) { _1.map(&:name).grep(/\.mjs\z/) }
        ids = widget_ids.select { modules.include?("#{_1.tr('.', '/')}.mjs") }
        next if ids.empty?

        { file: File.basename(path), sha256: Digest::SHA256.file(path).hexdigest, widget_ids: ids.sort }
      rescue Zip::Error => e
        { file: File.basename(path), error: e.message, widget_ids: [] }
      end.compact
      covered = entries.flat_map { _1.fetch(:widget_ids) }.uniq
      {
        status: (widget_ids - covered).empty? ? 'pass' : 'fail', entries:,
        missing_widget_ids: (widget_ids - covered).sort
      }
    end

    def build_web(version)
      root = @mendix_home || File.join(Dir.home, '.local', 'share', 'mendix', version)
      started = monotonic
      Dir.mktmpdir('mxrb-widget-certification-') do |directory|
        deployment = File.join(directory, 'deployment')
        stages = Compiler::DeploymentMaterializer.new(
          @path, deployment:, mendix_home: root
        ).materialize.stages.length
        web = Compiler::WebBundleBuilder.new(
          @path, deployment:, mendix_home: root
        ).build
        return {
          status: 'pass', stages:, files: web.files, bytes: web.bytes,
          elapsed_ms: ((monotonic - started) * 1000).round(1)
        }
      end
    end

    def browser_evidence(inventory)
      required_ids = inventory.fetch(:custom).map { _1.fetch(:id) }
      required_types = inventory.fetch(:core).map { _1.fetch(:type) }
      return { status: 'missing', missing_widget_ids: required_ids, missing_widget_types: required_types } unless
        @browser_report && File.file?(@browser_report)

      report = JSON.parse(File.read(@browser_report))
      declared = Array(report.dig('certification', 'widget_ids')).map(&:to_s).uniq
      declared_types = Array(report.dig('certification', 'widget_types')).map(&:to_s).uniq
      visible_failures = browser_failure_markers(report)
      missing = required_ids - declared
      missing_types = required_types - declared_types
      status = if report['passed'] == true && visible_failures.empty? && missing.empty? && missing_types.empty?
                 'pass'
               else
                 'fail'
               end
      {
        status:, passed: report['passed'] == true, scenario: report['scenario'],
        widget_ids: declared.sort, missing_widget_ids: missing.sort,
        widget_types: declared_types.sort, missing_widget_types: missing_types.sort,
        visible_failures:, console_errors: Array(report['console_errors']),
        report: @browser_report
      }
    rescue JSON::ParserError => e
      { status: 'fail', error: "invalid browser report: #{e.message}" }
    end

    def browser_failure_markers(report)
      elements = Array(report['pages']).flat_map { Array(_1.dig('snapshot', 'elements')) } +
                 Array(report.dig('failure_snapshot', 'elements'))
      elements.filter_map do |element|
        text = element['text'].to_s
        text if FAILURE_MARKERS.any? { text.include?(_1) }
      end.uniq
    end

    def failures(compilation, package_inventory, native_build, browser)
      [].tap do |result|
        result << 'page compiler reported unsupported widgets' unless compilation[:status] == 'pass'
        result << 'one or more pluggable widget modules are missing' unless package_inventory[:status] == 'pass'
        result << 'native web bundle did not pass' unless native_build[:status] == 'pass'
        result << 'passing browser evidence does not cover every widget contract' unless browser[:status] == 'pass'
      end
    end

    def web_units(source)
      source.units_of('Forms$Page').select { source.web_page?(_1) } +
        source.units_of('Forms$Layout').select { source.web_layout?(_1) }
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
  # rubocop:enable Metrics
end
