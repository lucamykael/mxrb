# frozen_string_literal: true

module Mxrb
  module Scaffold
    # Parses and renders the conventional scaffold subcommands.
    class CLI
      INIT_COMMANDS = %w[presentation security design ci].freeze
      QUIET_COMMANDS = %w[ci evaluation functional-test].freeze

      def initialize(command, argv, output: $stdout)
        @command = command
        @argv = argv
        @output = output
      end

      def run
        return show_help if help?
        return render_page_templates if page_templates?

        validate_action!
        @dry_run = @argv.delete('--dry-run') ? true : false
        @json = @argv.delete('--json') ? true : false
        result = generator.scaffold
        render(result)
      rescue ArgumentError => e
        abort "[mxrb] error: #{e.message}"
      end

      private

      def generator
        chain = extract_option('--chain') if @command == 'page'
        template = extract_option('--template') if @command == 'page'
        entity = extract_option('--entity') if @command == 'demo-user'
        roles = extract_options('--role') if @command == 'demo-user'
        Generator.new(
          kind, scaffold_name, target: target, dry_run: @dry_run,
                               page_chain: chain, page_template: template,
                               demo_entity: entity, demo_roles: roles
        )
      end

      def page_templates? = @command == 'page' && @argv.first == 'templates'

      def render_page_templates
        @argv.shift
        json = @argv.delete('--json')
        abort "Unknown arguments: #{@argv.join(' ')}" unless @argv.empty?

        @output.puts(json ? JSON.pretty_generate(PageTemplates.payload) : PageTemplates.tree)
      end

      def help?
        @argv.first == '--help' || @argv.delete('--help')
      end

      def show_help
        @output.puts Help.text(@command)
      end

      def validate_action!
        if @command == 'demo-user'
          @argv.shift if @argv.first == 'new'
          abort Help.text(@command) if @argv.empty?
          return
        end

        action = @argv.shift
        abort Help.text(@command) unless accepted_actions.include?(action)
      end

      def accepted_actions
        return %w[new generate g] if @command == 'page'

        [expected_action]
      end

      def expected_action
        INIT_COMMANDS.include?(@command) ? 'init' : 'new'
      end

      def scaffold_name
        return nil if @command == 'design'

        @scaffold_name ||= @argv.shift || abort(Help.text(@command))
      end

      def target
        value = extract_option('--target') || Dir.pwd
        abort "Unknown arguments: #{@argv.join(' ')}" unless @argv.empty?
        value
      end

      def extract_option(name)
        index = @argv.index(name)
        return unless index

        abort "#{name} requires a value" unless @argv[index + 1]
        @argv.slice!(index, 2).last
      end

      def extract_options(name)
        values = []
        while (index = @argv.index(name))
          abort "#{name} requires a value" unless @argv[index + 1]

          values << @argv.slice!(index, 2).last
        end
        values
      end

      def kind = @command.tr('-', '_').to_sym

      def render(result) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        if @json
          return @output.puts JSON.pretty_generate(
            kind: result.kind, name: result.name, dry_run: result.dry_run,
            files: result.files, updated: result.updated
          )
        end

        prefix = result.dry_run ? 'would create' : 'create'
        result.files.each { @output.puts "  #{prefix}  #{_1}" }
        result.updated.each { @output.puts "  update  #{_1}" }
        return if QUIET_COMMANDS.include?(@command)

        @output.puts "\nDone. Run:"
        @output.puts '  bundle exec mxrb generate project.rb'
      end
    end
  end
end
