# frozen_string_literal: true

require_relative "mxrb/version"
require_relative "mxrb/errors"
require_relative "mxrb/doctor"
require_relative "mxrb/benchmark"
require_relative "mxrb/project_lifecycle"
require_relative "mxrb/initializer"
require_relative "mxrb/module_initializer"
require_relative "mxrb/scaffold/transaction"
require_relative "mxrb/scaffold/registry"
require_relative "mxrb/scaffold/templates"
require_relative "mxrb/scaffold/recipes"
require_relative "mxrb/scaffold/generator"
require_relative "mxrb/scaffold/help"
require_relative "mxrb/scaffold/cli"
require_relative "mxrb/io/bson_codec"
require_relative "mxrb/widget_package"
require_relative "mxrb/io/mxunit_codec"
require_relative "mxrb/io/mpr_file"
require_relative "mxrb/model/unit"
require_relative "mxrb/model/attribute"
require_relative "mxrb/model/association"
require_relative "mxrb/model/entity"
require_relative "mxrb/model/domain_model"
require_relative "mxrb/model/microflow"
require_relative "mxrb/model/page"
require_relative "mxrb/model/menu"
require_relative "mxrb/model/navigation"
require_relative "mxrb/model/design_system"
require_relative "mxrb/model/design_materializer"
require_relative "mxrb/model/design_migration"
require_relative "mxrb/model/module"
require_relative "mxrb/model/project"
require_relative "mxrb/oql"
require_relative "mxrb/oql/plan_analyzer"
require_relative "mxrb/oql/workload_analyzer"
require_relative "mxrb/oql/workload_baseline"
require_relative "mxrb/oql/index_advisor"
require_relative "mxrb/oql/sql_server_workload_analyzer"
require_relative "mxrb/oql/sql_server_plan_analyzer"
require_relative "mxrb/dsl/builder"
require_relative "mxrb/architecture/graph"
require_relative "mxrb/architecture/validator"
require_relative "mxrb/integrity/validator"
require_relative "mxrb/semantic/index"
require_relative "mxrb/semantic/renamer"
require_relative "mxrb/semantic/remover"
require_relative "mxrb/semantic/mover"
require_relative "mxrb/semantic/analyzer"
require_relative "mxrb/semantic/extractor"
require_relative "mxrb/semantic/inliner"
require_relative "mxrb/semantic/domain_mutator"
require_relative "mxrb/semantic/batch_plan"
require_relative "mxrb/github/annotator"
require_relative "mxrb/evaluation"
require_relative "mxrb/marketplace"
require_relative "mxrb/official_marketplace"
require_relative "mxrb/team_server"
require_relative "mxrb/functional"
require_relative "mxrb/runtime/toolchain"
require_relative "mxrb/runtime/java_locator"
require_relative "mxrb/compiler/adapter"
require_relative "mxrb/compiler/mda"
require_relative "mxrb/compiler/model_package"
require_relative "mxrb/compiler/source_model"
require_relative "mxrb/compiler/model_values"
require_relative "mxrb/compiler/constants_materializer"
require_relative "mxrb/compiler/domain_security_compiler"
require_relative "mxrb/compiler/domain_document_compiler"
require_relative "mxrb/compiler/domain_model_materializer"
require_relative "mxrb/compiler/artifact_document_compiler"
require_relative "mxrb/compiler/artifact_materializer"
require_relative "mxrb/compiler/translation_materializer"
require_relative "mxrb/compiler/system_text_materializer"
require_relative "mxrb/compiler/system_queue_materializer"
require_relative "mxrb/compiler/runtime_model_schema"
require_relative "mxrb/compiler/runtime_data_types"
require_relative "mxrb/compiler/page_document_compiler"
require_relative "mxrb/compiler/navigation_document_compiler"
require_relative "mxrb/compiler/client_model_materializer"
require_relative "mxrb/compiler/code_action_type_compiler"
require_relative "mxrb/compiler/code_action_document_compiler"
require_relative "mxrb/compiler/code_action_materializer"
require_relative "mxrb/compiler/settings_document_compiler"
require_relative "mxrb/compiler/settings_materializer"
require_relative "mxrb/compiler/database_connector_action_compiler"
require_relative "mxrb/compiler/microflow_node_compiler"
require_relative "mxrb/compiler/microflow_document_compiler"
require_relative "mxrb/compiler/microflow_materializer"
require_relative "mxrb/compiler/project_model_orderer"
require_relative "mxrb/compiler/project_materializer"
require_relative "mxrb/compiler/security_materializer"
require_relative "mxrb/compiler/system_model_seed"
require_relative "mxrb/compiler/deployment_metadata"
require_relative "mxrb/compiler/deployment_asset_copier"
require_relative "mxrb/compiler/deployment_bootstrapper"
require_relative "mxrb/compiler/web_shell_materializer"
require_relative "mxrb/compiler/deployment_materializer"
require_relative "mxrb/compiler/packager"
require_relative "mxrb/compiler/project_jar_archive"
require_relative "mxrb/compiler/java_proxy_generator"
require_relative "mxrb/compiler/project_jar_builder"
require_relative "mxrb/compiler/widget_package_extractor"
require_relative "mxrb/compiler/web_operation_compiler"
require_relative "mxrb/compiler/data_grid_bundle_compiler"
require_relative "mxrb/compiler/legacy_data_grid_compiler"
require_relative "mxrb/compiler/legacy_page_builder"
require_relative "mxrb/compiler/page_bundle_compiler"
require_relative "mxrb/compiler/page_bundle_builder"
require_relative "mxrb/compiler/web_bundle_builder"
require_relative "mxrb/compiler/portable_packager"
require_relative "mxrb/widget_synchronizer"
require_relative "mxrb/runtime/docker_workspace"
require_relative "mxrb/runtime/executor"
require_relative "mxrb/runtime/native"
require_relative "mxrb/runtime/docker_executor"
require_relative "mxrb/runtime/database_workspace"
require_relative "mxrb/runtime/sql_server_database"
require_relative "mxrb/oql/server"
require_relative "mxrb/compare"
require_relative "mxrb/writer"
require_relative "mxrb/exporter"

module Mxrb
  # Open an existing .mpr file.
  #
  #   Mxrb.open("MyApp.mpr") { |p| puts p.modules.map(&:name) }
  #
  def self.open(path, readonly: true, &block)
    project = Model::Project.open(path, readonly: readonly)
    return project unless block

    begin
      block.call(project)
    ensure
      project.close
    end
  end

  # Define a new project via the Ruby DSL.
  #
  #   Mxrb.define("MyApp.mpr") do
  #     mendix_version "10.18.0"
  #     module :MyModule do
  #       entity :Customer do
  #         string  :Name, required: true
  #         integer :Age
  #       end
  #     end
  #   end
  #
  def self.define(path, &block)
    output = ENV.fetch("MXRB_OUTPUT_PATH", path)
    Dsl::Builder.new(output).tap { _1.instance_eval(&block) }.build!
  end

  def self.validate(path)
    Integrity::Validator.new(path).validate
  end

  def self.evaluate(path, &block)
    open(path) { _1.evaluate(&block) }
  end

  def self.functional_definition(path)
    Functional::Suite.new.evaluate(path).definition
  end

  def self.runtime_plan(path, **options)
    Runtime::Toolchain.new(path, **options).plan
  end
end
