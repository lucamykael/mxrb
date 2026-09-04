# frozen_string_literal: true

require 'base64'
require 'json'
require 'securerandom'

module Mxrb
  # Projects the version-neutral Ruby model onto an exact Studio Pro schema.
  # Each strategy contains only deterministic metamodel changes observed for
  # that build; unsupported build-specific semantics remain explicit.
  class StudioCompatibility
    SCHEMA_HASHES = {
      '9.6.1.29396' => '{SHA256}eucGg8X+FuNNZefjgsxntSNkZtIlobdKepWWPXO2rEY=',
      '10.24.0.73019' => '{SHA256}byCy5wQuf+bf8dMw0DjAfhv6C0uybmGxwdmtwuZDPkQ=',
      '11.12.1' => '{SHA256}ex8TFkjI5tikVWCC05OxODFVHlheQtT9XpJxPAwVGY0='
    }.freeze

    # No-op strategy for versions without a build-specific projection.
    class DefaultStrategy
      def apply_document!(_document); end
    end

    # Removes fields introduced after the initial Mendix 10.24 LTS build.
    class Mendix10240073019Strategy
      def apply_document!(document)
        case document['$Type']
        when 'DomainModels$DomainModel' then project_domain_model!(document)
        when 'Enumerations$Enumeration' then project_enumeration!(document)
        when 'ImportMappings$ImportMapping', 'ExportMappings$ExportMapping'
          document.delete('MessageDefinition2')
        when 'Microflows$Nanoflow' then document.delete('UseListParameterByReference')
        when 'Rest$PublishedRestService' then document.delete('PublicDocumentation')
        end
      end

      def project_domain_model!(document)
        items(document['Entities']).each do |entity|
          %w[IsRemote RemoteSource EventHandlers].each { entity.delete(_1) }
          items(entity['Indexes']).each do |index|
            items(index['Attributes']).each { _1.delete('AssociationPointer') }
          end
        end
      end

      def project_enumeration!(document)
        items(document['Values']).each { _1.delete('ExportLevel') }
      end

      def items(collection)
        return [] unless collection.is_a?(Array)

        collection.first.is_a?(Integer) ? collection.drop(1) : collection
      end
    end

    # Projects properties and settings introduced after 9.6 back onto the
    # exact 9.6.1 schema. Modern-only setting parts have no representation in
    # that metamodel and are omitted from the target MPR; their Ruby source
    # remains available in the conversion workspace.
    class Mendix96129396Strategy
      DELETIONS = {
        'CustomWidgets$WidgetValueType' => %w[AllowUpload].freeze,
        'Enumerations$EnumerationValue' => %w[ExportLevel].freeze,
        'Forms$CallNanoflowClientAction' => %w[ConfirmationInfo DisabledDuringExecution].freeze,
        'Forms$MicroflowAction' => %w[DisabledDuringExecution].freeze,
        'Forms$MicroflowSettings' => %w[ConfirmationInfo DisabledDuringExecution].freeze,
        'Forms$NoAction' => %w[DisabledDuringExecution].freeze,
        'Forms$Page' => %w[Autofocus].freeze,
        'Forms$PageParameter' => %w[DefaultValue IsRequired].freeze,
        'Forms$PageVariable' => %w[SubKey].freeze,
        'Forms$SnippetParameterMapping' => %w[Argument].freeze,
        'Forms$WebUIProjectSettingsPart' => %w[
          EnableNewStringBehavior EnableNewWidgetGeneration EnableRspackBundler UrlPrefix
          UseOptimizedClient
        ].freeze,
        'Menus$MenuItem' => %w[AlternativeText].freeze,
        'Microflows$Nanoflow' => %w[UseListParameterByReference].freeze,
        'Projects$ModuleSettings' => %w[
          Checksum ConvertedChecksum EnableDetailedTroubleshooting ModuleDependencies
          OriginalPackageId PackageId
        ].freeze,
        'Settings$ConventionSettings' => %w[
          DefaultAssociationStorage DefaultSequenceFlowLineType
        ].freeze,
        'Settings$ModelSettings' => %w[
          BcryptCost DecimalScale JavaMajorVersion SslCertificateAlgorithm
          UseDatabaseForeignKeyConstraints UseOQLVersion2
        ].freeze,
        'Settings$WorkflowsProjectSettingsPart' => %w[Groups OnWorkflowEvent].freeze
      }.freeze
      UNSUPPORTED_SETTING_PARTS = %w[
        Settings$DistributionSettings Settings$JarDeploymentSettings
      ].freeze

      def apply_document!(document)
        visit!(document)
      end

      private

      def visit!(value)
        case value
        when Hash
          project_node!(value)
          value.each_value { visit!(_1) }
        when Array
          value.each { visit!(_1) }
        end
      end

      def project_node!(node)
        type = node['$Type']
        project_settings!(node) if type == 'Settings$ProjectSettings'
        project_module!(node) if type == 'Projects$ModuleImpl'
        DELETIONS.fetch(type, []).each { node.delete(_1) }
      end

      def project_settings!(node)
        settings = node['Settings']
        return unless settings.is_a?(Array)

        settings.reject! do |part|
          part.is_a?(Hash) && UNSUPPORTED_SETTING_PARTS.include?(part['$Type'])
        end
      end

      def project_module!(node)
        package_id = node.delete('AppStorePackageIdString')
        node['AppStorePackageId'] = package_id.to_i unless package_id.nil?
      end
    end

    # Applies the schema migrations performed by Studio Pro 11.12.1 when it
    # opens a 10.24 project. The visitor also covers typed objects embedded in
    # pages, snippets, microflows, and project settings.
    class Mendix11121Strategy # rubocop:disable Metrics/ClassLength
      DEFAULTS = {
        'CustomWidgets$WidgetValueType' => { 'AllowUpload' => false }.freeze,
        'Forms$CallNanoflowClientAction' => {
          'ConfirmationInfo' => nil,
          'DisabledDuringExecution' => true,
          'Nanoflow' => '',
          'OutputMappings' => [3].freeze,
          'ParameterMappings' => [2].freeze,
          'ProgressBar' => 'None',
          'ProgressMessage' => nil
        }.freeze,
        'Forms$MicroflowAction' => { 'DisabledDuringExecution' => true }.freeze,
        'Forms$MicroflowSettings' => {
          'Asynchronous' => false,
          'ConfirmationInfo' => nil,
          'FormValidations' => 'All',
          'OutputMappings' => [3].freeze,
          'ParameterMappings' => [2].freeze,
          'ProgressBar' => 'None',
          'ProgressMessage' => nil
        }.freeze,
        'Forms$NoAction' => { 'DisabledDuringExecution' => true }.freeze,
        'Forms$Page' => { 'Autofocus' => 'Off' }.freeze,
        'Forms$PageParameter' => { 'DefaultValue' => '', 'IsRequired' => true }.freeze,
        'Forms$PageVariable' => { 'SubKey' => '' }.freeze,
        'Forms$SnippetParameterMapping' => { 'Argument' => '' }.freeze,
        'Forms$WebUIProjectSettingsPart' => {
          'EnableNewStringBehavior' => false,
          'EnableRspackBundler' => false
        }.freeze,
        'Menus$MenuItem' => { 'AlternativeText' => nil }.freeze,
        'Microflows$Nanoflow' => { 'UseListParameterByReference' => true }.freeze,
        'Projects$ModuleImpl' => { 'AppStorePackageIdString' => '' }.freeze,
        'Projects$ModuleSettings' => {
          'Checksum' => '',
          'ConvertedChecksum' => '',
          'EnableDetailedTroubleshooting' => true,
          'ModuleDependencies' => nil,
          'OriginalPackageId' => '',
          'PackageId' => ''
        }.freeze,
        'Settings$ModelSettings' => { 'DecimalScale' => 8, 'JavaMajorVersion' => '21' }.freeze,
        'Settings$ServerConfiguration' => { 'OpenTelemetry' => nil }.freeze,
        'Settings$WorkflowsProjectSettingsPart' => { 'Groups' => [2].freeze }.freeze
      }.freeze
      DELETIONS = {
        'DomainModels$EntityImpl' => %w[IsRemote RemoteSource].freeze,
        'Enumerations$EnumerationValue' => %w[ExportLevel].freeze,
        'Microflows$Nanoflow' => %w[ApplyEntityAccess].freeze,
        'Projects$ModuleImpl' => %w[AppStorePackageId].freeze,
        'Settings$IntegrationProjectSettingsPart' => %w[ObsoleteEnableUrlEncoding].freeze,
        'Settings$ModelSettings' => %w[JavaVersion].freeze,
        'Settings$WorkflowsProjectSettingsPart' => %w[
          UsertaskOnStateChangeEvent WorkflowOnStateChangeEvent
        ].freeze
      }.freeze
      RENAMES = {
        'Settings$ServerConfiguration' => { 'Tracing' => 'OpenTelemetry' }.freeze
      }.freeze
      TYPE_RENAMES = {
        'Settings$TracingConfiguration' => 'Settings$OpenTelemetryConfiguration'
      }.freeze
      REPLACEMENTS = {
        'Forms$Page' => { 'ExportLevel' => { 'Public' => 'Hidden' }.freeze }.freeze
      }.freeze
      PROJECT_SETTING_DEFAULTS = {
        'Settings$JarDeploymentSettings' => { 'Exclusions' => [2].freeze }.freeze,
        'Settings$DistributionSettings' => {
          'BasedOnVersion' => '', 'IsDistributable' => false, 'Version' => ''
        }.freeze
      }.freeze
      EMPTY_FIELDS = [].freeze
      EMPTY_MAP = {}.freeze

      def apply_document!(document)
        visit!(document)
      end

      private

      def visit!(value)
        case value
        when Hash
          project_node!(value)
          value.each_value { visit!(_1) }
        when Array
          value.each { visit!(_1) }
        end
      end

      def project_node!(node)
        type = node['$Type']
        project_settings!(node) if type == 'Settings$ProjectSettings'
        project_tracing_configuration!(node) if type == 'Settings$TracingConfiguration'
        node['$Type'] = TYPE_RENAMES.fetch(type, type)
        delete_empty_event_handlers!(node) if type == 'DomainModels$EntityImpl'
        rename_fields!(node, RENAMES.fetch(type, EMPTY_MAP))
        delete_fields!(node, DELETIONS.fetch(type, EMPTY_FIELDS))
        replace_values!(node, REPLACEMENTS.fetch(type, EMPTY_MAP))
        add_defaults!(node, DEFAULTS.fetch(type, EMPTY_MAP))
      end

      def add_defaults!(node, defaults)
        defaults.each do |key, value|
          node[key] = value.is_a?(Array) ? value.dup : value unless node.key?(key)
        end
      end

      def delete_fields!(node, fields)
        fields.each { node.delete(_1) }
      end

      def delete_empty_event_handlers!(node)
        value = node['EventHandlers']
        return unless value.is_a?(Array)

        items = value.first.is_a?(Integer) ? value.drop(1) : value
        node.delete('EventHandlers') if items.empty?
      end

      def project_tracing_configuration!(node)
        node['$ID'] = SecureRandom.uuid
        node['Endpoint'] = node['Endpoint'].sub(%r{/v1/traces/?\z}, '') if node['Endpoint'].is_a?(String)
        node['Logs'] = nil
        node['Traces'] = nil
      end

      def project_settings!(node)
        settings = node['Settings']
        return unless settings.is_a?(Array)

        present = items(settings).to_h { [_1['$Type'], true] }
        PROJECT_SETTING_DEFAULTS.each do |type, defaults|
          next if present.key?(type)

          values = defaults.transform_values { _1.is_a?(Array) ? _1.dup : _1 }
          settings << { '$ID' => SecureRandom.uuid, '$Type' => type }.merge(values)
        end
      end

      def items(collection)
        collection.first.is_a?(Integer) ? collection.drop(1) : collection
      end

      def rename_fields!(node, renames)
        renames.each do |source, target|
          node[target] = node[source] if node.key?(source) && !node.key?(target)
          node.delete(source)
        end
      end

      def replace_values!(node, replacements)
        replacements.each do |field, values|
          node[field] = values[node[field]] if values.key?(node[field])
        end
      end
    end

    STRATEGIES = {
      '9.6.1.29396' => Mendix96129396Strategy.new,
      '10.24.0.73019' => Mendix10240073019Strategy.new,
      '11.12.1' => Mendix11121Strategy.new
    }.freeze

    def initialize(version, template_root: File.join(__dir__, 'templates', 'project'))
      @version = version.to_s
      @template_root = template_root
    end

    def schema_hash
      SCHEMA_HASHES.fetch(@version, '')
    end

    def apply!(units)
      units.each { apply_document!(_1.fetch('doc')) }
      units
    end

    def apply_document!(document)
      reconcile_project_conversion!(document) if document['$Type'] == 'Projects$ProjectConversion'
      reconcile_system_texts!(document) if @version == '11.12.1' &&
                                           document['$Type'] == 'Texts$SystemTextCollection'
      STRATEGIES.fetch(@version, DefaultStrategy.new).apply_document!(document)
      document
    end

    private

    def reconcile_project_conversion!(document)
      target = template_document('Projects$ProjectConversion')
      return unless target

      document['OneTimeConversions'] = reconciled_conversions(document, target)
    end

    def reconciled_conversions(source, target)
      target_nodes = items(target.fetch('OneTimeConversions'))
      retained = retained_conversions(source, target_nodes)
      retained_names = retained.to_h { [_1['Name'], true] }
      missing = target_nodes.reject { retained_names.key?(_1['Name']) }.map { deep_copy(_1) }
      marker = array_marker(source['OneTimeConversions']) || array_marker(target['OneTimeConversions'])
      marker ? [marker, *retained, *missing] : retained + missing
    end

    def retained_conversions(source, target_nodes)
      target_names = target_nodes.to_h { [_1.fetch('Name'), true] }
      items(source['OneTimeConversions']).select { target_names.key?(_1['Name']) }
    end

    def reconcile_system_texts!(document)
      target = template_document('Texts$SystemTextCollection')
      return unless target

      document['SystemTexts'] = reconciled_system_texts(document, target)
    end

    def reconciled_system_texts(source, target)
      target_nodes = items(target.fetch('SystemTexts'))
      retained = retained_system_texts(source, target_nodes)
      retained_keys = retained.to_h { [_1.fetch('InternalKey'), true] }
      missing = target_nodes.reject { retained_keys.key?(_1['InternalKey']) }.map { deep_copy(_1) }
      marker = array_marker(source['SystemTexts']) || array_marker(target['SystemTexts'])
      marker ? [marker, *retained, *missing] : retained + missing
    end

    def retained_system_texts(source, target_nodes)
      target_keys = target_nodes.to_h { [_1.fetch('InternalKey'), true] }
      items(source['SystemTexts']).select { target_keys.key?(_1['InternalKey']) }
    end

    def template_document(type)
      path = File.join(@template_root, "#{@version}.json")
      return unless File.file?(path)

      unit = JSON.parse(File.read(path)).fetch('units', []).find { _1['type'] == type }
      return unless unit

      IO::BsonCodec.parse(Base64.strict_decode64(unit.fetch('contents')))
    end

    def items(collection)
      return [] unless collection.is_a?(Array)

      collection.first.is_a?(Integer) ? collection.drop(1) : collection
    end

    def array_marker(collection)
      collection&.first if collection.is_a?(Array) && collection.first.is_a?(Integer)
    end

    def deep_copy(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
