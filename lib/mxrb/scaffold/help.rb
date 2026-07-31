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
        'page' => ['new Module.Page', 'Create a page', 'presentation/pages'],
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
          --help         Show this help

        Documentation:
          https://github.com/lucamykael/mxrb/blob/main/docs/pt-BR/scaffolds.md
      HELP

      def text(command)
        usage, description, destination = COMMANDS.fetch(command)
        <<~HELP
          Usage: mxrb #{command} #{usage} [--target DIR]

          #{description}.
          Destination: #{destination}
          Existing files are never overwritten. Aggregators are connected automatically.

          #{OPTIONS}
        HELP
      end
    end
  end
end
