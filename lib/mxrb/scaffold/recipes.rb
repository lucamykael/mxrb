# frozen_string_literal: true

module Mxrb
  module Scaffold
    # Command recipes; filesystem mechanics remain in Generator.
    # rubocop:disable Metrics/ModuleLength
    module Recipes
      SIMPLE = {
        entity: %w[domain entities], enumeration: %w[domain enumerations],
        use_case: %w[application use_cases], validation: %w[application validations],
        query: %w[application queries], constant: %w[domain constants]
      }.freeze
      INFRASTRUCTURE = {
        integration: 'integrations', published_rest: 'endpoints',
        consumed_rest: 'integrations', java_action: 'actions'
      }.freeze

      private

      def scaffold_entity = scaffold_simple(:entity)
      def scaffold_enumeration = scaffold_simple(:enumeration)
      def scaffold_use_case = scaffold_simple(:use_case)
      def scaffold_validation = scaffold_simple(:validation)
      def scaffold_query = scaffold_simple(:query)

      def scaffold_constant
        module_name, artifact_name = qualified_name
        create_connected_module_file(
          module_name, SIMPLE.fetch(:constant), artifact_name, :constant
        )
      end

      def scaffold_page
        module_name, artifact_name = qualified_name
        chain = page_chain
        template = selected_page_template
        return scaffold_basic_page(module_name, artifact_name) unless chain || template

        scaffold_templated_page(module_name, artifact_name, template || 'form-vertical', chain)
      end

      def scaffold_templated_page(module_name, artifact_name, template, chain)
        ensure_presentation(module_name)
        page_support_specs(artifact_name, chain, template).each do |directories, name, source|
          create_connected_module_file(module_name, directories, name, source)
        end
        create_page_template(module_name, artifact_name, template:, chain:)
        create_page_navigation(module_name, artifact_name)
      end

      def scaffold_basic_page(module_name, artifact_name)
        ensure_presentation(module_name)
        create_connected_module_file(module_name, %w[presentation pages], artifact_name, :page)
      end

      def page_support_specs(name, chain, template)
        specs = PageTemplates.fetch(template).data_backed ? page_chain_base_specs(name) : []
        specs << page_chain_microflow_spec(name) if chain&.end_with?('microflow')
        specs << page_chain_nanoflow_spec(name, chain) if chain&.include?('nanoflow')
        specs
      end

      def page_chain_base_specs(name)
        [
          [%w[domain entities], name, :page_chain_entity],
          [%w[application use_cases], "ACT_Load#{name}", :page_chain_loader]
        ]
      end

      def page_chain_microflow_spec(name)
        [%w[application use_cases], "ACT_Refresh#{name}", :page_chain_action]
      end

      def page_chain_nanoflow_spec(name, chain)
        template = chain.end_with?('microflow') ? :page_chain_client_server : :page_chain_nanoflow
        [%w[presentation client_actions], "NAN_Refresh#{name}", template]
      end

      def scaffold_nanoflow
        module_name, artifact_name = qualified_name
        ensure_presentation(module_name)
        create_connected_module_file(
          module_name, %w[presentation client_actions], artifact_name, :nanoflow
        )
      end

      def scaffold_repository
        module_name, artifact_name = qualified_name
        ensure_infrastructure(module_name)
        create_connected_module_file(
          module_name, %w[application repositories], artifact_name, :repository
        )
        create_connected_module_file(
          module_name, %w[infrastructure repositories], artifact_name,
          :repository_implementation, suffix: '_implementation'
        )
      end

      def scaffold_scheduled_event
        module_name, artifact_name = qualified_name
        create_connected_module_file(
          module_name, %w[application jobs], artifact_name, :scheduled_event
        )
      end

      def scaffold_integration = scaffold_infrastructure_artifact(:integration)
      def scaffold_published_rest = scaffold_infrastructure_artifact(:published_rest)
      def scaffold_consumed_rest = scaffold_infrastructure_artifact(:consumed_rest)
      def scaffold_java_action = scaffold_infrastructure_artifact(:java_action)

      def scaffold_presentation
        module_name = module_only
        aggregator = module_path(module_name, 'presentation', 'presentation.rb')
        keep_files = %w[pages snippets client_actions].map do |directory|
          module_path(module_name, 'presentation', directory, '.keep')
        end
        initialized = @transaction.content(aggregator) && keep_files.all? { @transaction.content(_1) }
        abort "#{aggregator}: presentation already initialized" if initialized

        ensure_presentation(module_name)
      end

      def scaffold_security
        module_name = module_only
        ensure_module(module_name)
        path = module_path(module_name, 'security', 'security.rb')
        @transaction.create(path, Templates.render(:security, module_name:, name: nil))
        connect_module_aggregator(module_name, 'security', 'security.rb')
        connect_project_security(module_name)
      end

      def scaffold_functional_test
        module_name, artifact_name = qualified_name
        ensure_project
        create_project_file(
          %w[functional_tests], artifact_name,
          Templates.render(:functional_test, module_name:, name: artifact_name)
        )
      end

      def scaffold_evaluation
        ensure_project
        artifact_name = identifier(@name, label: 'evaluation')
        create_project_file(
          %w[evaluations], artifact_name,
          Templates.render(:evaluation, module_name: nil, name: artifact_name)
        )
      end

      def scaffold_design
        ensure_project
        abort 'Usage: mxrb design init' unless @name.empty?

        design_assets.each do |parts, template|
          ensure_file(project_path(*parts), Templates.render(template, module_name: nil, name: nil))
        end
        connect_project_file('app', 'design_system', 'design_system.rb')
      end

      def design_assets
        {
          %w[app design_system design_system.rb] => :design_system,
          %w[theme web custom-variables.scss] => :theme_custom_variables,
          %w[theme web main.scss] => :theme_main,
          %w[theme web exclusion-variables.scss] => :theme_exclusion_variables,
          %w[theme web settings.json] => :theme_settings,
          %w[theme-cache web theme.compiled.css] => :theme_compiled
        }
      end

      def scaffold_ci
        ensure_project
        raise ArgumentError, 'ci provider must be github' unless @name == 'github'

        path = project_path('.github', 'workflows', 'mxrb.yml')
        @transaction.create(path, Templates.render(:github_workflow, module_name: nil, name: nil))
      end

      def scaffold_simple(kind)
        module_name, artifact_name = qualified_name
        create_connected_module_file(module_name, SIMPLE.fetch(kind), artifact_name, kind)
      end

      def scaffold_infrastructure_artifact(kind)
        module_name, artifact_name = qualified_name
        ensure_infrastructure(module_name)
        create_connected_module_file(
          module_name, ['infrastructure', INFRASTRUCTURE.fetch(kind)], artifact_name, kind
        )
      end

      def ensure_file(path, content)
        @transaction.create(path, content) unless @transaction.content(path)
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
