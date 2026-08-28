# frozen_string_literal: true

require 'securerandom'

module Mxrb
  module Scaffold
    # Creates conventional Ruby-first artifacts and connects missing aggregators.
    # rubocop:disable Metrics/ClassLength
    class Generator
      include Recipes

      Result = Data.define(:root, :files, :updated, :kind, :name, :dry_run)
      IDENTIFIER = /\A[A-Za-z][A-Za-z0-9_]*\z/
      RESERVED_ENTITY_NAMES = %w[Owner ChangedBy CreatedDate ChangedDate].freeze
      PAGE_CHAINS = %w[page:microflow page:nanoflow page:nanoflow:microflow].freeze
      LAYER_AGGREGATORS = {
        'domain' => 'model.rb',
        'application' => 'application.rb',
        'presentation' => 'presentation.rb',
        'infrastructure' => 'infrastructure.rb'
      }.freeze

      def initialize(kind, name = nil, target: Dir.pwd, dry_run: false, **page_options)
        @kind = kind.to_sym
        @name = name.to_s
        @root = File.expand_path(target)
        @transaction = Transaction.new
        @dry_run = dry_run
        assign_options(page_options)
        raise ArgumentError, "unknown generator options: #{page_options.keys.join(', ')}" unless
          page_options.empty?
      end

      def scaffold
        send("scaffold_#{@kind}")
        registry = stage_registry unless @dry_run
        @transaction.commit unless @dry_run
        Result.new(
          @root, visible(@transaction.created, registry), visible(@transaction.updated, registry),
          @kind, @name, @dry_run
        )
      end

      private

      def assign_options(options)
        @page_chain = options.delete(:page_chain)
        @page_template = options.delete(:page_template)
        @page_roles = options.delete(:page_roles)
        @demo_entity = options.delete(:demo_entity)
        @demo_roles = options.delete(:demo_roles)
      end

      def page_chain
        return unless @page_chain
        return @page_chain if PAGE_CHAINS.include?(@page_chain)

        raise ArgumentError,
              "page chain must be one of: #{PAGE_CHAINS.join(', ')}"
      end

      def selected_page_template
        PageTemplates.fetch(@page_template)&.name
      end

      def page_roles
        Array(@page_roles).map(&:to_s).reject(&:empty?).uniq.tap do |roles|
          invalid = roles.reject { _1.match?(/\A[A-Za-z][A-Za-z0-9_]*\.[A-Za-z][A-Za-z0-9_]*\z/) }
          raise ArgumentError, "invalid page role(s): #{invalid.join(', ')}" unless invalid.empty?
        end
      end

      def stage_registry
        files = @transaction.created.dup
        if @kind == :demo_user
          shared = [project_path('.env'), project_path('.env.example')]
          files -= shared
        end
        Registry.stage(
          @transaction, root: @root, key: "#{@kind}:#{@name}", files:
        )
      end

      def visible(paths, registry)
        paths.reject { _1 == registry }.freeze
      end

      def ensure_presentation(module_name)
        ensure_module(module_name)
        path = module_path(module_name, 'presentation', 'presentation.rb')
        ensure_file(path, Templates.render(:presentation, module_name:, name: nil))
        %w[pages snippets client_actions].each do |directory|
          ensure_file(module_path(module_name, 'presentation', directory, '.keep'), '')
        end
        connect_module_aggregator(module_name, 'presentation', 'presentation.rb')
      end

      def ensure_infrastructure(module_name)
        ensure_module(module_name)
        path = module_path(module_name, 'infrastructure', 'infrastructure.rb')
        ensure_file(path, Templates.render(:infrastructure, module_name:, name: nil))
        connect_module_aggregator(module_name, 'infrastructure', 'infrastructure.rb')
      end

      def connect_artifact(aggregator, *segments)
        source = @transaction.content(aggregator)
        raise ArgumentError, "#{aggregator}: aggregator not found" unless source

        line = artifact_evaluation(source, segments)
        return if source.include?(line)

        @transaction.write(aggregator, "#{source.rstrip}\n#{line}\n")
      end

      def artifact_evaluation(source, segments)
        return evaluate_line(segments) unless source.match?(/^\s*evaluate_dir File\.join\(__dir__, /)

        %(evaluate_dir File.join(__dir__, "#{segments.fetch(0)}"))
      end

      def connect_module_aggregator(module_name, *segments)
        path = module_path(module_name, 'module.rb')
        source = @transaction.content(path)
        line = evaluate_line(segments)
        @transaction.write(path, insert_before_closing(source, line, path)) unless source.include?(line)
      end

      def connect_project_file(*segments)
        path = project_path('project.rb')
        source = @transaction.content(path)
        line = evaluate_line(segments)
        @transaction.write(path, insert_before_closing(source, line, path)) unless source.include?(line)
      end

      def connect_project_security(module_name)
        path = project_path('project.rb')
        source = @transaction.content(path)
        return if source.match?(/^\s*security do\s*$/)

        lines = source.lines
        version = lines.index { _1.match?(/^\s*mendix_version\s+/) }
        raise ArgumentError, "#{path}: mendix_version not found" unless version

        block = Templates.render(:project_security, module_name:, name: nil)
        lines.insert(version + 1, "\n#{block.lines.map { "  #{_1}" }.join}")
        @transaction.write(path, lines.join)
      end

      def connect_project_demo_users
        path = project_path('project.rb')
        source = connect_project_dotenv(@transaction.content(path))
        opening = source.lines.index { _1.match?(/^\s*security do\s*$/) }
        raise ArgumentError, security_initialization_error unless opening

        insert_demo_user_loader(path, source, opening)
      end

      def insert_demo_user_loader(path, source, opening)
        line = 'evaluate_dir File.join(__dir__, "app", "security", "demo_users")'
        return if source.include?(line)

        lines = source.lines
        indentation = "#{lines.fetch(opening)[/^\s*/]}  "
        lines.insert(opening + 1, "#{indentation}#{line}\n")
        @transaction.write(path, lines.join)
      end

      def connect_project_dotenv(source) # rubocop:disable Metrics/MethodLength
        return source if source.include?('Mxrb::Environment.load(root: __dir__).apply')

        dotenv_line = 'Dotenv.load(File.join(__dir__, ".env"))'
        return source if source.include?(dotenv_line)

        lines = source.lines
        require_line = lines.index { _1.match?(%r{^require ["']dotenv/load["']\s*$}) }
        return lines.insert(require_line + 1, "#{dotenv_line}\n").join if require_line

        mxrb_require = lines.index { _1.match?(/^require ["']mxrb["']\s*$/) }
        unless mxrb_require
          raise ArgumentError,
                'project.rb must require mxrb or dotenv/load before scaffolding demo users'
        end

        lines.insert(mxrb_require + 1, "\nMxrb::Environment.load(root: __dir__).apply\n").join
      end

      def security_initialization_error
        'project security is not initialized; run `mxrb security init Module` first'
      end

      def create_demo_user_file(name, entity, roles, password_env)
        path = project_path('app', 'security', 'demo_users', "#{Templates.snake_case(name)}.rb")
        @transaction.create(
          path,
          Templates.render(
            :demo_user, name:, entity:, roles:, password_env:
          )
        )
      end

      def ensure_demo_user_secret(password_env)
        path = project_path('.env')
        source = @transaction.content(path)
        if source
          @transaction.write(path, append_env(source, password_env, generated_demo_password)) unless
            env_key?(source, password_env)
        else
          create_demo_user_secret(path, password_env)
        end
        ensure_demo_user_env_example(password_env)
      end

      def create_demo_user_secret(path, password_env)
        source = "# Local secrets; never commit this file.\n"
        content = append_env(source, password_env, generated_demo_password)
        @transaction.create(path, content, mode: 0o600)
      end

      def ensure_demo_user_env_example(password_env)
        path = project_path('.env.example')
        source = @transaction.content(path) || "# Copy to .env and keep real values local.\n"
        @transaction.write(path, append_env(source, password_env, '')) unless env_key?(source, password_env)
      end

      def append_env(source, key, value)
        "#{source.rstrip}\n#{key}=#{value}\n"
      end

      def env_key?(source, key)
        source.lines.any? { _1.match?(/\A#{Regexp.escape(key)}=/) }
      end

      def generated_demo_password
        "Mxrb#{SecureRandom.alphanumeric(16)}7"
      end

      def validate_demo_user_references!(name, entity, roles)
        sources = project_ruby_sources
        errors = []
        missing_roles = roles - known_user_roles(sources)
        errors << "missing user role(s): #{missing_roles.join(', ')}" unless missing_roles.empty?
        errors << "missing user entity: #{entity}" unless
          entity == 'System.User' || known_entities(sources).include?(entity)
        return if errors.empty?

        raise ArgumentError, "demo user #{name}: #{errors.join('; ')}"
      end

      def project_ruby_sources
        Dir.glob(project_path('**', '*.rb')).to_h { [_1, File.read(_1)] }
      end

      def known_user_roles(sources)
        pattern = /\buser_role\s+(?::([A-Za-z][A-Za-z0-9_]*)|["']([^"']+)["'])/
        sources.values.flat_map { _1.scan(pattern).map { |match| match.compact.first } }.uniq
      end

      def known_entities(sources)
        pattern = /\bentity\s+(?::([A-Za-z][A-Za-z0-9_]*)|["']([^"']+)["'])/
        sources.flat_map do |path, source|
          mod = path.match(%r{/modules/([^/]+)/})&.[](1)
          mod ? source.scan(pattern).map { "#{mod}.#{_1.compact.first}" } : []
        end.uniq
      end

      def insert_before_closing(source, line, path)
        lines = source.lines
        closing = lines.rindex { _1.strip == 'end' }
        raise ArgumentError, "#{path}: closing end not found" unless closing

        indentation = lines.filter_map { _1[/\A\s+(?=evaluate )/] }.first || '  '
        lines.insert(closing, "#{indentation}#{line}\n")
        lines.join
      end

      def create_module_file(module_name, directories, artifact_name, template, **options)
        ensure_module(module_name)
        suffix = options.delete(:suffix)
        filename = "#{Templates.snake_case(artifact_name)}#{suffix}.rb"
        path = module_path(module_name, *directories, filename)
        @transaction.create(path, Templates.render(template, module_name:, name: artifact_name, **options))
        filename
      end

      def create_connected_module_file(module_name, directories, artifact_name, template, **options)
        suffix = options.delete(:suffix)
        filename = create_module_file(
          module_name, directories, artifact_name, template, suffix:, **options
        )
        layer, *relative = directories
        aggregator = module_path(module_name, layer, LAYER_AGGREGATORS.fetch(layer))
        connect_artifact(aggregator, *relative, filename)
        filename
      end

      def create_connected_module_content(module_name, directories, artifact_name, content)
        ensure_module(module_name)
        filename = "#{Templates.snake_case(artifact_name)}.rb"
        path = module_path(module_name, *directories, filename)
        @transaction.create(path, content)
        layer, *relative = directories
        aggregator = module_path(module_name, layer, LAYER_AGGREGATORS.fetch(layer))
        connect_artifact(aggregator, *relative, filename)
        filename
      end

      def create_page_template(module_name, artifact_name, template:, chain:)
        content = Templates.render(
          :page_from_template, module_name:, name: artifact_name,
                               template:, refresh_action: page_refresh_action(module_name, artifact_name, chain),
                               roles: page_roles
        )
        create_connected_module_content(
          module_name, %w[presentation pages], artifact_name, content
        )
      end

      def page_refresh_action(module_name, artifact_name, chain)
        return unless chain
        return "microflow: \"#{module_name}.ACT_Refresh#{artifact_name}\"" if
          chain == 'page:microflow'

        "nanoflow: \"#{module_name}.NAN_Refresh#{artifact_name}\""
      end

      def create_page_navigation(module_name, artifact_name)
        unless responsive_navigation_aggregator?
          raise ArgumentError,
                'page chain requires the generated Responsive navigation aggregator'
        end

        filename = "#{Templates.snake_case(module_name)}_#{Templates.snake_case(artifact_name)}.rb"
        @transaction.create(
          project_path('app', 'navigation', 'responsive', filename),
          Templates.render(:page_chain_navigation, module_name:, name: artifact_name)
        )
      end

      def responsive_navigation_aggregator?
        sources = [
          @transaction.content(project_path('project.rb')).to_s,
          @transaction.content(project_path('app', 'navigation', 'navigation.rb')).to_s
        ]
        expected = [
          'evaluate_dir File.join(__dir__, "app", "navigation", "responsive")',
          'evaluate_dir File.join(__dir__, "responsive")'
        ]
        sources.any? { |source| expected.any? { source.include?(_1) } }
      end

      def create_project_file(directories, artifact_name, content)
        path = project_path(*directories, "#{Templates.snake_case(artifact_name)}.rb")
        @transaction.create(path, content)
      end

      def qualified_name
        parts = @name.split('.', 2)
        raise ArgumentError, 'name must be qualified as Module.Artifact' unless parts.size == 2

        module_name = identifier(parts.first, label: 'module')
        artifact_name = identifier(parts.last, label: 'artifact')
        if @kind == :entity && RESERVED_ENTITY_NAMES.include?(artifact_name)
          raise ArgumentError, "entity name #{artifact_name.inspect} is reserved by Mendix"
        end

        [module_name, artifact_name]
      end

      def module_only = identifier(@name, label: 'module')

      def identifier(value, label:)
        raise ArgumentError, "#{label} name must be a Mendix identifier" unless IDENTIFIER.match?(value)

        value
      end

      def ensure_project
        path = project_path('project.rb')
        raise ArgumentError, "#{path}: project.rb not found" unless File.file?(path)
      end

      def ensure_module(module_name)
        ensure_project
        path = module_path(module_name, 'module.rb')
        raise ArgumentError, "#{path}: module not found" unless File.file?(path)
      end

      def project_path(*segments) = File.join(@root, *segments)
      def module_path(module_name, *segments) = project_path('modules', module_name, *segments)

      def evaluate_line(segments)
        quoted = segments.map { |segment| %("#{segment}") }.join(', ')
        "evaluate File.join(__dir__, #{quoted})"
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
