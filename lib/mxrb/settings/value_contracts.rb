# frozen_string_literal: true

module Mxrb
  module Settings
    # Contracts evidenced by the shipped Studio project templates and settings
    # fixtures. Unknown collection element schemas stay typed but unrestricted.
    module ValueContracts
      BOOLEAN_FIELDS = %w[
        EnableDownloadResources EnableMicroflowReachabilityAnalysis EnableNewStringBehavior
        EnableNewWidgetGeneration EnableRspackBundler EnableWidgetBundling ObsoleteEnableUrlEncoding
        AllowUserMultipleSessions EnableDataStorageNewQueryHandling EnableDataStorageOptimisticLocking
        EnforceDataStorageUniqueness UseDatabaseForeignKeyConstraints UseDeprecatedClientForWebServiceCalls
        UseOQLVersion2 UseSystemContextForBackgroundTasks LowerCaseMicroflowVariables IsDistributable
        GeneratePostfixesForParameters DatabaseUseIntegratedSecurity EmulateCloudSecurity OpenAdminPort
        OpenHttpPort Enabled CheckCompleteness RightToLeft
      ].freeze
      INTEGER_FIELDS = %w[
        BcryptCost DecimalScale DefaultTaskParallelism WorkflowEngineParallelism
        HttpPortNumber MaxJavaHeapSize ServerPortNumber
      ].freeze
      NULLABLE_FIELDS = %w[
        OpenTelemetry Tracing Logs Traces UsertaskOnStateChangeEvent WorkflowOnStateChangeEvent
      ].freeze
      COMPONENTS = {
        'OpenTelemetry' => 'Settings$OpenTelemetryConfiguration',
        'Tracing' => 'Settings$TracingConfiguration'
      }.freeze
      COLLECTION_COMPONENTS = {
        'ThemeModuleOrder' => 'Settings$ThemeModuleEntry',
        'Configurations' => 'Settings$ServerConfiguration',
        'ActionActivityDefaultColors' => 'Settings$ActionActivityDefaultColor',
        'Languages' => 'Texts$Language', 'Certificates' => 'Settings$Certificate',
        'CustomSettings' => 'Settings$CustomSetting'
      }.freeze

      module_function

      def normalize(type, field, value)
        return nil if value.nil? && NULLABLE_FIELDS.include?(field)
        return collection(type, field, value) if Catalog.collection?(field)

        expected = expected_type(field)
        unless valid?(expected, value)
          raise Error, "#{Catalog.method_for_type(type)}.#{Catalog.field_method(field)} " \
                       "expects #{expected}, got #{value.class}"
        end

        value.is_a?(String) ? value.dup.freeze : value
      end

      def expected_type(field)
        return :boolean if BOOLEAN_FIELDS.include?(field)
        return Integer if INTEGER_FIELDS.include?(field)
        return BinaryAsset if field == 'Data'
        return COMPONENTS.fetch(field) if COMPONENTS.key?(field)
        return :typed_value if %w[Logs Traces].include?(field)

        String
      end

      def valid?(expected, value)
        case expected
        when :boolean then value.equal?(true) || value.equal?(false)
        when :typed_value then typed_value?(value)
        when String then value.is_a?(Node) && value.storage_type == expected
        else value.is_a?(expected)
        end
      end

      def collection(type, field, value)
        unless value.is_a?(Collection)
          raise Error, "#{Catalog.method_for_type(type)}.#{Catalog.field_method(field)} expects Settings::Collection"
        end

        value.items.each_with_index do |item, index|
          next if collection_item?(field, item)

          raise Error, "#{Catalog.method_for_type(type)}.#{Catalog.field_method(field)}[#{index}] " \
                       'has an incompatible value'
        end
        value
      end

      def collection_item?(field, item)
        return item.is_a?(Node) && Catalog::PART_TYPES.value?(item.storage_type) if field == 'Settings'
        return valid?(COLLECTION_COMPONENTS.fetch(field), item) if COLLECTION_COMPONENTS.key?(field)
        return item.is_a?(String) if field == 'Exclusions'

        typed_value?(item)
      end

      def typed_value?(value)
        case value
        when Node, BinaryAsset, String, Integer, Float, Time, TrueClass, FalseClass, NilClass then true
        when Collection then value.items.all? { typed_value?(_1) }
        else false
        end
      end
    end
  end
end
