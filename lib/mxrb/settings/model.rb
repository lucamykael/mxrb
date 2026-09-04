# frozen_string_literal: true

module Mxrb
  # Typed, storage-independent representation of Mendix project settings.
  module Settings
    class Error < Mxrb::SerializationError; end

    # Names and collection contracts used by Studio Pro 11 project settings.
    module Catalog # rubocop:disable Metrics/ModuleLength
      TYPE_METHODS = {
        'Settings$ProjectSettings' => :project_settings,
        'Forms$WebUIProjectSettingsPart' => :web_ui,
        'Settings$IntegrationProjectSettingsPart' => :integration,
        'Settings$ConfigurationSettings' => :configuration,
        'Settings$ModelSettings' => :model,
        'Settings$ConventionSettings' => :conventions,
        'Settings$LanguageSettings' => :languages,
        'Settings$CertificateSettings' => :certificates,
        'Settings$WorkflowsProjectSettingsPart' => :workflows,
        'Settings$JarDeploymentSettings' => :jar_deployment,
        'Settings$DistributionSettings' => :distribution,
        'Settings$JavaActionsSettings' => :java_actions,
        'Settings$ThemeModuleEntry' => :theme_module,
        'Settings$ActionActivityDefaultColor' => :action_activity_default_color,
        'Settings$Certificate' => :certificate,
        'Settings$ServerConfiguration' => :server,
        'Settings$CustomSetting' => :custom_setting,
        'Settings$OpenTelemetryConfiguration' => :open_telemetry_configuration,
        'Settings$TracingConfiguration' => :tracing_configuration,
        'Texts$Language' => :language
      }.freeze
      METHOD_TYPES = TYPE_METHODS.invert.freeze
      PART_TYPES = TYPE_METHODS.slice(
        'Forms$WebUIProjectSettingsPart', 'Settings$IntegrationProjectSettingsPart',
        'Settings$ConfigurationSettings', 'Settings$ModelSettings',
        'Settings$ConventionSettings', 'Settings$LanguageSettings',
        'Settings$CertificateSettings', 'Settings$WorkflowsProjectSettingsPart',
        'Settings$JarDeploymentSettings', 'Settings$DistributionSettings',
        'Settings$JavaActionsSettings'
      ).invert.freeze
      FIELDS = {
        'Settings$ProjectSettings' => %w[Settings],
        'Forms$WebUIProjectSettingsPart' => %w[
          EnableDownloadResources EnableMicroflowReachabilityAnalysis EnableNewStringBehavior
          EnableNewWidgetGeneration EnableRspackBundler EnableWidgetBundling Theme ThemeModuleName
          ThemeModuleOrder UrlPrefix UseOptimizedClient
        ],
        'Settings$IntegrationProjectSettingsPart' => %w[ObsoleteEnableUrlEncoding],
        'Settings$ConfigurationSettings' => %w[Configurations],
        'Settings$ModelSettings' => %w[
          AfterStartupMicroflow AllowUserMultipleSessions BcryptCost BeforeShutdownMicroflow
          DecimalScale DefaultTimeZoneCode EnableDataStorageNewQueryHandling
          EnableDataStorageOptimisticLocking EnforceDataStorageUniqueness FirstDayOfWeek
          HashAlgorithm HealthCheckMicroflow JavaMajorVersion JavaVersion RoundingMode
          ScheduledEventTimeZoneCode SslCertificateAlgorithm UseDatabaseForeignKeyConstraints
          UseDeprecatedClientForWebServiceCalls UseOQLVersion2 UseSystemContextForBackgroundTasks
        ],
        'Settings$ConventionSettings' => %w[
          ActionActivityDefaultColors DefaultAssociationStorage DefaultSequenceFlowLineType
          LowerCaseMicroflowVariables
        ],
        'Settings$LanguageSettings' => %w[DefaultLanguageCode Languages],
        'Settings$CertificateSettings' => %w[Certificates],
        'Settings$WorkflowsProjectSettingsPart' => %w[
          DefaultTaskParallelism Groups OnWorkflowEvent UserEntity UsertaskOnStateChangeEvent
          WorkflowEngineParallelism WorkflowOnStateChangeEvent
        ],
        'Settings$JarDeploymentSettings' => %w[Exclusions],
        'Settings$DistributionSettings' => %w[BasedOnVersion IsDistributable Version],
        'Settings$JavaActionsSettings' => %w[GeneratePostfixesForParameters],
        'Settings$ThemeModuleEntry' => %w[ModuleName],
        'Settings$ActionActivityDefaultColor' => %w[ActionActivityType BackgroundColor],
        'Settings$Certificate' => %w[Data Type],
        'Settings$ServerConfiguration' => %w[
          ApplicationRootUrl ConstantValues CustomSettings DatabaseName DatabasePassword
          DatabaseType DatabaseUrl DatabaseUseIntegratedSecurity DatabaseUserName EmulateCloudSecurity
          ExtraJvmParameters HttpPortNumber MaxJavaHeapSize Name OpenAdminPort OpenHttpPort
          OpenTelemetry ServerPortNumber Tracing
        ],
        'Settings$CustomSetting' => %w[Name Value],
        'Settings$OpenTelemetryConfiguration' => %w[Enabled Endpoint Logs ServiceName Traces],
        'Settings$TracingConfiguration' => %w[Enabled Endpoint ServiceName],
        'Texts$Language' => %w[
          CheckCompleteness Code CustomDateFormat CustomDateTimeFormat CustomTimeFormat
          Description RightToLeft
        ]
      }.freeze
      COLLECTION_MARKERS = {
        ['Settings$ProjectSettings', 'Settings'] => 2,
        ['Settings$WorkflowsProjectSettingsPart', 'Groups'] => 2,
        ['Settings$WorkflowsProjectSettingsPart', 'OnWorkflowEvent'] => 2,
        ['Settings$JarDeploymentSettings', 'Exclusions'] => 2
      }.freeze
      COLLECTION_FIELDS = %w[
        Settings ThemeModuleOrder Configurations ActionActivityDefaultColors Languages
        Certificates Groups OnWorkflowEvent Exclusions ConstantValues CustomSettings
      ].freeze

      module_function

      def method_for_type(type)
        TYPE_METHODS.fetch(type) { raise Error, "unsupported project-settings type #{type}" }
      end

      def type_for_method(method)
        METHOD_TYPES.fetch(method.to_sym) do
          raise Error, "unsupported project-settings component #{method.inspect}"
        end
      end

      def field_method(field)
        field.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
             .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase.to_sym
      end

      def field_for(type, method)
        FIELDS.fetch(type, []).find { field_method(_1) == method.to_sym } ||
          raise(Error, "unknown #{method} property for #{method_for_type(type)}")
      end

      def collection?(field) = COLLECTION_FIELDS.include?(field)

      def collection_marker(type, field)
        COLLECTION_MARKERS.fetch([type, field], 3)
      end
    end

    # External binary value, primarily used for trusted certificates.
    class BinaryAsset
      attr_reader :bytes, :subtype, :path

      def self.read(path, subtype: :generic)
        new(File.binread(path), subtype:, path: File.basename(path))
      end

      def self.from_bytes(bytes, subtype: :generic) = new(bytes, subtype:)
      def self.empty(subtype: :generic) = new(''.b, subtype:)

      def initialize(bytes, subtype: :generic, path: nil)
        @bytes = bytes.to_s.b.freeze
        @subtype = subtype.to_sym
        @path = path&.to_s
      end

      def at(path) = self.class.new(bytes, subtype:, path:)
    end

    Collection = Data.define(:items, :marker) do
      def initialize(items:, marker: 3)
        super(items: Array(items).freeze, marker: Integer(marker))
      end
    end

    # A schema-checked settings component. Storage names remain internal.
    class Node
      attr_reader :storage_type, :fields

      def initialize(storage_type)
        Catalog.method_for_type(storage_type)
        @storage_type = storage_type.freeze
        @fields = {}
      end

      def set(field, value)
        Catalog.field_for(storage_type, Catalog.field_method(field))
        fields[field.to_s] = value
        self
      end

      def fetch(field) = fields.fetch(field.to_s)
    end

    # Builds a homogeneous or empty component collection in the Ruby DSL.
    class CollectionBuilder
      def initialize
        @items = []
      end

      def method_missing(method, *arguments, &block)
        return super unless block && arguments.empty?

        node = Node.new(Catalog.type_for_method(method))
        NodeBuilder.new(node).instance_eval(&block)
        @items << node
        node
      end

      def respond_to_missing?(method, include_private = false)
        Catalog::METHOD_TYPES.key?(method.to_sym) || super
      end

      def items = @items.freeze
    end

    # Provides property methods for one settings component.
    class NodeBuilder
      def initialize(node)
        @node = node
      end

      def method_missing(method, *arguments, &block)
        field = Catalog.field_for(@node.storage_type, method)
        value = block ? nested_value(field, arguments, block) : scalar_value(field, arguments)
        @node.set(field, value)
      end

      def respond_to_missing?(method, include_private = false)
        Catalog::FIELDS.fetch(@node.storage_type, []).any? do |field|
          Catalog.field_method(field) == method.to_sym
        end || super
      end

      private

      def nested_value(field, arguments, block)
        return nested_collection(field, arguments, block) if Catalog.collection?(field)

        nested_component(field, arguments, block)
      end

      def nested_component(field, arguments, block)
        type_method = arguments.fetch(0) do
          raise Error, "#{Catalog.field_method(field)} requires a component type"
        end
        raise Error, "#{Catalog.field_method(field)} accepts one component type" \
          unless arguments.length == 1

        Node.new(Catalog.type_for_method(type_method)).tap do |node|
          NodeBuilder.new(node).instance_eval(&block)
        end
      end

      def nested_collection(field, arguments, block)
        raise Error, "#{Catalog.field_method(field)} does not accept arguments with a block" \
          unless arguments.empty?

        children = CollectionBuilder.new
        children.instance_eval(&block)
        Collection.new(items: children.items,
                       marker: Catalog.collection_marker(@node.storage_type, field))
      end

      def scalar_value(field, arguments)
        if Catalog.collection?(field)
          return Collection.new(items: arguments,
                                marker: Catalog.collection_marker(@node.storage_type, field))
        end
        raise Error, "#{Catalog.field_method(field)} expects exactly one value" \
          unless arguments.length == 1

        arguments.first
      end
    end

    # Root builder exposed as `project_settings do ... end`.
    class ProjectBuilder
      def initialize
        @root = Node.new('Settings$ProjectSettings')
        @parts = []
      end

      def method_missing(method, *arguments, &block)
        type = Catalog::PART_TYPES[method.to_sym]
        return super unless type && block && arguments.empty?

        node = Node.new(type)
        NodeBuilder.new(node).instance_eval(&block)
        @parts << node
        node
      end

      def respond_to_missing?(method, include_private = false)
        Catalog::PART_TYPES.key?(method.to_sym) || super
      end

      def to_model
        @root.set('Settings', Collection.new(items: @parts, marker: 2))
      end
    end
  end
end
