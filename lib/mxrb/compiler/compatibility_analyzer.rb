# frozen_string_literal: true

module Mxrb
  module Compiler
    CompatibilityFinding = Data.define(:severity, :category, :type, :location, :message, :count) do
      def to_h = { severity:, category:, type:, location:, message:, count: }
    end

    CompatibilityReport = Data.define(:path, :mendix_version, :findings, :stats) do
      def compatible? = findings.none? { _1.severity == :error }
      def errors = findings.select { _1.severity == :error }
      def warnings = findings.select { _1.severity == :warning }

      def to_h
        {
          path:, mendix_version:, compatible: compatible?, stats:,
          findings: findings.map(&:to_h)
        }
      end
    end

    # Read-only preflight for features consumed by the native compiler and web runtime.
    # rubocop:disable Metrics
    class CompatibilityAnalyzer
      include ModelValues

      def initialize(path, source: nil)
        @path = File.expand_path(path)
        @source = source || SourceModel.read(@path)
        @findings = []
      end

      def analyze
        analyze_version
        analyze_features if @adapter
        CompatibilityReport.new(
          path: @path, mendix_version: @source.version, findings: collapsed_findings.freeze,
          stats: statistics.freeze
        )
      end

      private

      NATIVE_ACTIONS = %w[Microflows$SynchronizeAction Microflows$PushToClientAction].freeze

      def analyze_features
        if @adapter.web_profiles.include?(:react)
          analyze_pages
          analyze_layouts
          analyze_nanoflows
        else
          analyze_legacy_pages
        end
        analyze_native
      end

      # The native app fails closed: a native profile, native pages and layouts
      # and device synchronization are reported instead of silently left out of
      # the web build.
      def analyze_native
        @source.units_of('Navigation$NavigationDocument').each do |unit|
          array(unit.document['Profiles']).grep(Hash).each do |profile|
            next unless profile['$Type'] == 'Navigation$NativeNavigationProfile'

            add(:error, :native, profile['$Type'], "Navigation.#{profile['Name']}",
                'a native navigation profile is not built by the native compiler')
          end
        end
        native_layouts = @source.units_of('Forms$Layout').select do |unit|
          unit.document.dig('Content', '$Type') == 'Forms$NativeLayoutContent'
        end
        native_layouts.each do |unit|
          add(:error, :native, 'Forms$Layout', qualified_name(unit),
              'a native layout is not compiled by the native compiler')
        end
        layout_names = native_layouts.map { qualified_name(_1) }
        @source.units_of('Forms$Page').each do |unit|
          next unless layout_names.include?(unit.document.dig('FormCall', 'Form').to_s)

          add(:error, :native, 'Forms$Page', qualified_name(unit),
              'a native page is not compiled by the native compiler')
        end
        %w[Microflows$Microflow Microflows$Nanoflow].flat_map { @source.units_of(_1) }.each do |unit|
          native_actions(unit.document).each do |type|
            add(:error, :native, type, qualified_name(unit), "#{type} is not executed by the web runtime")
          end
        end
      end

      def native_actions(value, found = [])
        case value
        when Hash
          found << value['$Type'] if NATIVE_ACTIONS.include?(value['$Type'])
          value.each_value { native_actions(_1, found) }
        when Array then value.each { native_actions(_1, found) }
        end
        found
      end

      def analyze_version
        @adapter = Adapter.for(@source.version, source: @source)
      rescue UnsupportedVersion => e
        add(:error, :version, "Mendix #{@source.version}", 'project', e.message)
      end

      def analyze_legacy_pages
        LegacyPageBuilder.new(@source, '', profiles: @adapter.web_profiles).audit.each do |location, types|
          types.each do |type|
            add(:error, page_category(type), type, location,
                "#{type} is not compiled by the native legacy web renderer")
          end
        end
      rescue CompilationError, KeyError, TypeError => e
        add(:error, :page, 'Forms$Page', 'project', e.message)
      end

      def analyze_pages
        @source.units_of('Forms$Page').select { web_page?(_1) }.each do |unit|
          location = qualified_name(unit)
          bundle = PageBundleCompiler.new(@source).compile(unit)
          bundle.unsupported_widgets.each do |type|
            if type == 'CustomWidgets$CustomWidget'
              bundle.unsupported_custom_widgets.each do |identifier|
                add(:error, :custom_widget, identifier, location,
                    "#{identifier} is not compiled by the native web renderer")
              end
            else
              add(:error, page_category(type), type, location,
                  "#{type} is not compiled by the native web renderer")
            end
          end
        rescue CompilationError, KeyError, TypeError => e
          add(:error, :page, 'Forms$Page', location, e.message)
        end
      end

      def analyze_nanoflows
        compiler = NanoflowProgramCompiler.new(@source)
        @source.units_of('Microflows$Nanoflow').each { compiler.reference(qualified_name(_1)) }
        compiler.unsupported.each do |entry|
          location, type = entry.split(':', 2)
          add(:error, :nanoflow, type, location, "#{type} is not compiled by the native nanoflow runtime")
        end
      end

      def analyze_layouts
        @source.units_of('Forms$Layout').select { web_layout?(_1) }.each do |unit|
          location = qualified_name(unit)
          bundle = PageBundleCompiler.new(@source).compile_layout(unit)
          add_bundle_findings(bundle, location)
        rescue CompilationError, KeyError, TypeError => e
          add(:error, :layout, 'Forms$Layout', location, e.message)
        end
      end

      def add_bundle_findings(bundle, location)
        bundle.unsupported_widgets.each do |type|
          if type == 'CustomWidgets$CustomWidget'
            bundle.unsupported_custom_widgets.each do |identifier|
              add(:error, :custom_widget, identifier, location,
                  "#{identifier} is not compiled by the native web renderer")
            end
          else
            add(:error, page_category(type), type, location,
                "#{type} is not compiled by the native web renderer")
          end
        end
      end

      def page_category(type)
        return :client_action if type.end_with?('Action')
        return :custom_widget if type == 'CustomWidgets$CustomWidget' || !type.include?('$')

        :widget
      end

      def web_page?(unit) = !@source.is_a?(SourceModel) || @source.web_page?(unit)
      def web_layout?(unit) = !@source.is_a?(SourceModel) || @source.web_layout?(unit)

      def add(severity, category, type, location, message)
        @findings << CompatibilityFinding.new(
          severity:, category:, type: type.to_s, location: location.to_s, message:, count: 1
        )
      end

      def collapsed_findings
        grouped = @findings.group_by { finding_key(_1) }
        findings = grouped.map { |key, matches| collapsed_finding(key, matches.size) }
        findings.sort_by { [_1.severity.to_s, _1.category.to_s, _1.location, _1.type] }
      end

      def finding_key(finding)
        [finding.severity, finding.category, finding.type, finding.location, finding.message]
      end

      def collapsed_finding(key, count)
        severity, category, type, location, message = key
        CompatibilityFinding.new(severity:, category:, type:, location:, message:, count:)
      end

      def statistics
        {
          units: @source.units.size,
          pages: @source.units_of('Forms$Page').size,
          layouts: @source.units_of('Forms$Layout').size,
          nanoflows: @source.units_of('Microflows$Nanoflow').size,
          microflows: @source.units_of('Microflows$Microflow').size
        }
      end

      def qualified_name(unit) = [unit.module_name, unit.document['Name']].compact.join('.')
    end
    # rubocop:enable Metrics
  end
end
