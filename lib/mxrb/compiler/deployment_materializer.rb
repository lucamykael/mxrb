# frozen_string_literal: true

module Mxrb
  module Compiler
    DeploymentMaterialization = Data.define(:deployment, :mendix_version, :stages)

    # Runs the complete native MPR-to-deployment model pipeline in dependency order.
    class DeploymentMaterializer
      STAGES = [
        SecurityMaterializer, ConstantsMaterializer, DomainModelMaterializer,
        ArtifactMaterializer, TranslationMaterializer, SystemTextMaterializer,
        SystemQueueMaterializer, ClientModelMaterializer,
        CodeActionMaterializer, SettingsMaterializer, MicroflowMaterializer, ProjectMaterializer
      ].freeze

      def initialize(mpr_path, deployment: nil, mendix_home: nil)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment || File.join(File.dirname(@mpr_path), 'deployment'))
        @mendix_home = mendix_home
      end

      def materialize
        source = SourceModel.read(@mpr_path)
        DeploymentBootstrapper.new(
          @mpr_path, deployment: @deployment, mendix_home: @mendix_home
        ).prepare
        Adapter.for(source.version).validate_deployment!(@deployment)
        results = materialize_stages
        DeploymentMaterialization.new(
          deployment: @deployment, mendix_version: source.version, stages: results.freeze
        )
      end

      private

      def materialize_stages
        STAGES.to_h do |stage|
          [stage.name.split('::').last, stage.new(@mpr_path, deployment: @deployment).materialize]
        end
      end
    end
  end
end
