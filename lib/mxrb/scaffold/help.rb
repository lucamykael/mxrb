# frozen_string_literal: true

module Mxrb
  module Scaffold
    # Human-readable command catalog used by both top-level and subcommand help.
    module Help
      module_function

      COMMANDS = {
        'entity' => ['new Module.Entity', 'Create a domain entity file', 'domain/entities'],
        'enumeration' => ['new Module.Enum', 'Create an enumeration', 'domain/enumerations'],
        'use-case' => ['new Module.Flow', 'Create an application use case', 'application/use_cases'],
        'validation' => ['new Module.Flow', 'Create a validation flow', 'application/validations'],
        'query' => ['new Module.Flow', 'Create a query flow', 'application/queries'],
        'functional-test' => ['new Module.Flow', 'Create a runtime test', 'functional_tests'],
        'evaluation' => ['new Name', 'Create static model checks', 'evaluations'],
        'presentation' => ['init Module', 'Initialize presentation directories', 'presentation'],
        'page' => [
          'new|generate|g Module.Page [--template NAME] [--chain CHAIN] | templates [--json]',
          'Create a page or an executable page-led vertical slice',
          'presentation or domain/application/presentation/navigation'
        ],
        'nanoflow' => ['new Module.Flow', 'Create a client nanoflow', 'presentation/client_actions'],
        'repository' => ['new Module.Repository', 'Create repository port and adapter', 'application/infrastructure'],
        'security' => ['init Module', 'Create module roles template', 'security'],
        'scheduled-event' => ['new Module.Event', 'Create scheduled event and handler', 'application/jobs'],
        'constant' => ['new Module.Constant', 'Create a string constant', 'domain/constants'],
        'integration' => ['new Module.Adapter', 'Create integration adapter flow', 'infrastructure/integrations'],
        'published-rest' => ['new Module.Handler', 'Create published REST handler flow', 'infrastructure/endpoints'],
        'consumed-rest' => ['new Module.Client', 'Create consumed REST adapter flow', 'infrastructure/integrations'],
        'java-action' => ['new Module.Adapter', 'Create Java Action adapter flow', 'infrastructure/actions'],
        'design' => ['init', 'Initialize the project design system', 'app/design_system'],
        'ci' => ['init github', 'Create a GitHub Actions workflow', '.github/workflows']
      }.freeze
      OPTIONS = <<~HELP
        Options:
          --target DIR   Project root (default: current directory)
          --dry-run      Preview paths and aggregator updates without writing
          --json         Render the result as JSON
          --help         Show this help

        Documentation:
          https://github.com/lucamykael/mxrb/blob/main/docs/pt-BR/scaffolds.md
      HELP
      PAGE_OPTIONS = <<~HELP
        Page chains:
          --chain page:microflow           Page calls a microflow directly
          --chain page:nanoflow             Page calls a client nanoflow
          --chain page:nanoflow:microflow   Page calls a nanoflow that calls a microflow

        Without --chain, creates the minimal page scaffold.

        Page templates:
          mxrb page templates [--json]
          --template starter|blank|dashboard|form-vertical
      HELP

      def text(command)
        usage, description, destination = COMMANDS.fetch(command)
        <<~HELP
          Usage: mxrb #{command} #{usage} [--target DIR]

          #{description}.
          Destination: #{destination}
          Existing files are never overwritten. Aggregators are connected automatically.

          #{page_options(command)}

          #{OPTIONS}
        HELP
      end

      def page_options(command)
        return '' unless command == 'page'

        PAGE_OPTIONS
      end
    end
  end
end
