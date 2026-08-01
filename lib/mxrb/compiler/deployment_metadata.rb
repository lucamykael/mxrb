# frozen_string_literal: true

module Mxrb
  module Compiler
    # Derives initial Runtime metadata from an application MPR.
    class DeploymentMetadata
      def initialize(mpr_path, source)
        @mpr_path = mpr_path
        @source = source
      end

      def document
        {
          'RuntimeVersion' => @source.version, 'ProjectID' => project_id,
          'ProjectName' => project_name, 'ModelVersion' => 'unversioned', 'Description' => '',
          'AdminUser' => 'MxAdmin', 'AdminRole' => '', 'JavaVersion' => java_version,
          'Roles' => {}, 'Constants' => [], 'ScheduledEvents' => [], 'Languages' => languages,
          'Configuration' => configuration, 'RequestHandlers' => request_handlers,
          'ModelRuntimeCompatibilityHash' => ''
        }
      end

      def dependencies
        { 'schemaVersion' => '2.3', 'appName' => project_name, 'published' => [], 'consumed' => [] }
      end

      private

      def project_id
        @source.units.find { _1.document['$Type'] == 'Projects$Project' }&.id.to_s
      end

      def project_name = File.basename(@mpr_path, File.extname(@mpr_path))
      def java_version = Runtime::Toolchain.new(@mpr_path).plan.java_version.to_i

      def languages
        @source.documents.flat_map { collect_languages(_1) }.uniq.sort
      end

      def collect_languages(value)
        case value
        when Hash
          own = value['$Type'] == 'Texts$Translation' ? [value['LanguageCode'].to_s] : []
          own + value.values.flat_map { collect_languages(_1) }
        when Array then value.flat_map { collect_languages(_1) }
        else []
        end.reject(&:empty?)
      end

      def configuration
        {
          'SourceDatabaseType' => 'HSQLDB', 'SourceDatabaseName' => 'home',
          'SourceBuiltInDatabasePath' => 'model/sampledata/data/database'
        }
      end

      def request_handlers
        [['/api/', true], ['/link/', true], ['/p/', false]].map do |name, enabled|
          { 'Name' => name, 'DefaultEnabled' => enabled, 'MatchExactly' => false }
        end
      end
    end
  end
end
