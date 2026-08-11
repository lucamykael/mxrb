# frozen_string_literal: true

module Mxrb
  module CLI
    # Central command catalog used by the welcome screen, --help and --commands.
    # A single catalog keeps discovery text consistent with command dispatch.
    # rubocop:disable Metrics
    module Help
      module_function

      Command = Data.define(:name, :usage, :summary, :example)

      COMMANDS = [
        ['analyze', 'analyze FILE.mpr [--json]', 'Analyze native OQL and SQL query plans', 'mxrb analyze Shop.mpr'],
        ['benchmark', 'benchmark FILE.mpr [--iterations N]', 'Measure model loading and validation performance',
         'mxrb benchmark Shop.mpr --iterations 5'],
        ['cache', 'cache <status|warm|clear> FILE.mpr', 'Inspect or manage the semantic index cache',
         'mxrb cache status Shop.mpr'],
        ['callees', 'callees FILE.mpr NAME', 'List artifacts called by a callable artifact',
         'mxrb callees Shop.mpr Sales.Submit'],
        ['callers', 'callers FILE.mpr NAME', 'List callers of a callable artifact',
         'mxrb callers Shop.mpr Sales.Submit'],
        ['changelog', 'changelog [VERSION]', 'Show release notes without updating MXRB', 'mxrb changelog'],
        ['compare', 'compare LEFT.mpr RIGHT.mpr', 'Compare structural MPR snapshots',
         'mxrb compare before.mpr after.mpr'],
        ['db', 'db <ACTION> FILE.mpr [options]', 'Manage the isolated PostgreSQL and Runtime workspace',
         'mxrb db status Shop.mpr'],
        ['design', 'design <init|scan|migrate> ...', 'Create or migrate the project design system',
         'mxrb design scan Shop.mpr'],
        ['describe', 'describe FILE.mpr NAME', 'Show incoming and outgoing artifact references',
         'mxrb describe Shop.mpr Sales.Order'],
        ['diff', 'diff LEFT.mpr RIGHT.mpr', 'Print typed semantic model changes', 'mxrb diff before.mpr after.mpr'],
        ['doctor', 'doctor [DIR] [--json]', 'Check project files and the local toolchain', 'mxrb doctor .'],
        ['diagram-er', 'diagram-er FILE.mpr [options]',
         'Edit a DBeaver-style browser ER diagram and export PNG',
         'mxrb diagram-er Shop.mpr --module Sales'],
        ['dump-unit', 'dump-unit FILE.mpr UNIT_ID', 'Hex-dump a raw MPR unit', 'mxrb dump-unit Shop.mpr UNIT_ID'],
        ['env', 'env [DIR] [--environment NAME] [--json]', 'Inspect an environment profile without values',
         'mxrb env . --environment qa'],
        ['evaluate', 'evaluate FILE.mpr EVALUATION.rb', 'Run Ruby model evaluations',
         'mxrb evaluate Shop.mpr checks.rb'],
        ['export', 'export FILE.mpr DIR [--mode mendix|ruby] [stack]',
         'Export an MPR as editable Mendix DSL or a Ruby app',
         'mxrb export Shop.mpr shop-ruby --mode ruby'],
        ['find', 'find FILE.mpr TEXT [--semantic]', 'Find artifacts by name or semantic text',
         'mxrb find Shop.mpr Order'],
        ['frontend', 'frontend migrate FILE.mpr [--apply] [--json]', 'Inspect or apply frontend schema migrations',
         'mxrb frontend migrate Shop.mpr'],
        ['functional-instrument', 'functional-instrument FILE.mpr TEST.rb', 'Instrument an MPR for functional testing',
         'mxrb functional-instrument Shop.mpr smoke.rb'],
        ['generate', 'generate DEFINITION.rb [FILE.mpr]', 'Generate an MPR from Ruby DSL',
         'mxrb generate project.rb build/Shop.mpr'],
        ['impact', 'impact FILE.mpr NAME', 'Find transitive dependents of an artifact',
         'mxrb impact Shop.mpr Sales.Order'],
        ['init', 'init NAME [--mode mendix|ruby] [--mxrb-path DIR]',
         'Create a new editable Mendix DSL or conventional Ruby application',
         'mxrb init MyApp --mode ruby'],
        ['inspect', 'inspect FILE.mpr', 'Explore every raw unit in an MPR', 'mxrb inspect Shop.mpr'],
        ['lint', 'lint FILE.mpr', 'Run semantic diagnostics', 'mxrb lint Shop.mpr'],
        ['marketplace', 'marketplace <ACTION> [options]', 'Work with official and GitHub marketplace packages',
         'mxrb marketplace search charts'],
        ['mda', 'mda <inspect|compare> ...', 'Inspect or compare Mendix deployment archives',
         'mxrb mda inspect Shop.mda'],
        ['migrate', 'migrate <check|plan> [DIR] [--json]', 'Compare project.rb output with the current MPR',
         'mxrb migrate check .'],
        ['module', 'module <new|search|add> ...', 'Create or install Ruby modules', 'mxrb module new Billing'],
        ['modules', 'modules FILE.mpr', 'List modules in an MPR', 'mxrb modules Shop.mpr'],
        ['move', 'move FILE.mpr NAME CONTAINER [--apply]', 'Preview or apply a same-module unit move',
         'mxrb move Shop.mpr Sales.Flow Sales.Folder --apply'],
        ['oql', 'oql FILE.mpr [--dialect DIALECT] [--json]', 'Show native OQL and its read-only SQL projection',
         'mxrb oql Shop.mpr --dialect postgresql'],
        ['pack', 'pack FILE.mpr --output FILE.mda [--force]', 'Build an MDA without mx or mxbuild',
         'mxrb pack Shop.mpr --output Shop.mda'],
        ['portable', 'portable FILE.mpr --output runtime.zip', 'Build a portable executable Runtime ZIP',
         'mxrb portable Shop.mpr --output Shop.zip'],
        ['preflight', 'preflight FILE.mpr [--json]', 'Audit compiler and Runtime compatibility',
         'mxrb preflight Shop.mpr'],
        ['project', 'project inspect [DIR] [--json]', 'Inspect an MXRB project workspace', 'mxrb project inspect .'],
        ['protocols', 'protocols FILE.mpr [--json]', 'Audit known protocol connector modules',
         'mxrb protocols Shop.mpr'],
        ['refs', 'refs FILE.mpr NAME', 'Find direct references to an artifact', 'mxrb refs Shop.mpr Sales.Order'],
        ['remove', 'remove FILE.mpr NAME [--apply]', 'Preview or apply a reference-safe removal',
         'mxrb remove Shop.mpr Sales.Legacy --apply'],
        ['rename', 'rename FILE.mpr OLD NEW [--apply]', 'Preview or apply a model-wide rename',
         'mxrb rename Shop.mpr Sales.Old Sales.New --apply'],
        ['report', 'report FILE.mpr', 'Print coupling and reference summaries', 'mxrb report Shop.mpr'],
        ['run', 'run [DIR] [options]', 'Start the Ruby backend and React client together',
         'mxrb run . --server-port 9292 --client-port 5173'],
        ['scaffold', 'scaffold <list|destroy> ...', 'Inspect or remove registered scaffolds', 'mxrb scaffold list'],
        ['search', 'search TEXT FILE.mpr [options]', 'Run ranked semantic search', 'mxrb search checkout Shop.mpr'],
        ['serve', 'serve FILE.mpr [--port PORT]', 'Serve read-only SQL/OQL over loopback HTTP',
         'mxrb serve Shop.mpr --port 4567'],
        ['sql', 'sql FILE.mpr "SELECT ..."', 'Run raw SQL against the MPR SQLite database',
         'mxrb sql Shop.mpr "SELECT * FROM Unit"'],
        ['query', 'query "SELECT ..." --from sql|oql [options]',
         'Convert safe read-only queries between SQL and OQL',
         'mxrb query "SELECT p.name FROM shop$product p" --from sql --to oql'],
        ['team-server', 'team-server <ACTION> [options]', 'Work with Mendix Team Server repositories',
         'mxrb team-server status ./app'],
        ['test', 'test FILE.mpr TEST.rb [options]', 'Run isolated functional Runtime tests',
         'mxrb test Shop.mpr smoke.rb --native'],
        ['tree', 'tree FILE.mpr [MODULE]', 'Browse the semantic project tree', 'mxrb tree Shop.mpr Sales'],
        ['uml', 'uml FILE.mpr [options]',
         'View the project modeler or export class, activity, and sequence UML diagrams',
         'mxrb uml Shop.mpr --export class'],
        ['update', 'update [--check|--changelog]', 'Check or install the latest published MXRB gem',
         'mxrb update --check'],
        ['upgrade', 'upgrade --mendix VERSION [--target DIR] [--apply]', 'Transition the Mendix version in project.rb',
         'mxrb upgrade --mendix 11.12.1 --apply'],
        ['validate', 'validate FILE.mpr', 'Validate MPR structure, hashes and contents', 'mxrb validate Shop.mpr'],
        ['widgets', 'widgets sync DEFINITION.rb FILE.mpr', 'Synchronize pluggable widget schemas',
         'mxrb widgets sync project.rb Shop.mpr']
      ].to_h { |values| [values.first, Command.new(*values)] }.freeze

      SUBCOMMANDS = {
        'cache' => %w[status warm clear],
        'db' => %w[up sync down destroy status credentials url sql explain workload indexes shell],
        'design' => %w[init scan migrate],
        'diagram-er' => %w[up down status destroy],
        'frontend' => %w[migrate],
        'marketplace' => %w[login search show versions pull import audit list verify dependencies update remove],
        'mda' => %w[inspect compare],
        'migrate' => %w[check plan],
        'module' => %w[new search add],
        'project' => %w[inspect],
        'scaffold' => %w[list destroy],
        'team-server' => %w[login projects info branches commits clone status fetch pull push],
        'widgets' => %w[sync]
      }.freeze

      OPTIONS = {
        'init' => [
          ['--mode MODE', 'Project structure: mendix (default) or ruby'],
          ['--flymetothemoon', 'Sinatra/Puma/Rake/RSpec/ActiveRecord preset'],
          ['--onrails', 'Rails/Puma/RSpec/ActiveRecord preset'],
          ['--mxrb-path DIR', 'Use a local MXRB checkout in the Gemfile']
        ],
        'export' => [
          ['--mode MODE', 'Project structure: mendix (default) or ruby'],
          ['--flymetothemoon', 'Apply the full Sinatra-based Ruby preset'],
          ['--onrails', 'Apply the conventional Rails preset']
        ],
        'diagram-er' => [
          ['--module NAME', 'Show one module; repeat to show several'],
          ['--output FILE', 'MPR copy that receives saved visual layout'],
          ['--port PORT', 'Loopback browser editor port (default: 4568)'],
          ['--force', 'Replace an existing output MPR copy']
        ],
        'query' => [
          ['--from LANGUAGE', 'Required source language: sql or oql'],
          ['--to LANGUAGE', 'Target language; defaults to the opposite language'],
          ['--dialect DIALECT', 'SQL dialect: ansi, postgresql or sql_server'],
          ['--project FILE.mpr', 'Use the MPR to restore canonical entity and attribute names'],
          ['--input FILE', 'Read the query from a file; use - for stdin'],
          ['--json', 'Render the conversion result as JSON']
        ],
        'uml' => [
          ['--export TYPE', 'Print class, activity, or sequence diagram text'],
          ['--format FORMAT', 'Export format: mermaid (default) or plantuml'],
          ['--module NAME', 'Filter class diagram or select sequence module mode'],
          ['--microflow NAME', 'Microflow for an activity diagram'],
          ['--root NAME', 'Root microflow for a sequence call chain'],
          ['--depth N', 'Sequence expansion depth (default: 2)'],
          ['--port PORT', 'Loopback viewer port (default: 4569)']
        ],
        'run' => [
          ['--host HOST', 'Bind host (default: 127.0.0.1)'],
          ['--server-port PORT', 'Ruby backend port (default: 9292)'],
          ['--client-port PORT', 'React + Vite port (default: 5173)'],
          ['--environment NAME', 'Load .env plus config/environments/NAME.env'],
          ['--no-frontend', 'Start only the Ruby backend']
        ],
        'env' => [
          ['--environment NAME', 'Profile: development, qa, staging, production, or a safe custom name'],
          ['--json', 'Print profile metadata and key names; values remain hidden']
        ],
        'test' => [
          ['--environment NAME', 'Apply the selected profile while the test runtime executes']
        ]
      }.freeze

      NOTES = {
        'query' => [
          '`--project` applies only when converting SQL to OQL.',
          'Unsafe or unsupported constructs are reported instead of approximated.'
        ],
        'run' => [
          'Compatibility aliases: --api-port for --server-port, --port for --client-port.',
          'The global --no-progress option is optional and only suppresses progress output.'
        ]
      }.freeze

      SUBCOMMAND_HELP = {
        'cache status' => ['cache status FILE.mpr [--json]', 'Inspect semantic cache health and size',
                           'mxrb cache status Shop.mpr'],
        'cache warm' => ['cache warm FILE.mpr [--json]', 'Build or refresh the semantic cache',
                         'mxrb cache warm Shop.mpr'],
        'cache clear' => ['cache clear FILE.mpr [--json]', 'Remove semantic cache entries',
                          'mxrb cache clear Shop.mpr'],
        'diagram-er up' => ['diagram-er up FILE.mpr [options]', 'Start the ER editor in the background',
                            'mxrb diagram-er up Shop.mpr --module Sales'],
        'diagram-er down' => ['diagram-er down FILE.mpr', 'Stop the ER editor and preserve its layout copy',
                              'mxrb diagram-er down Shop.mpr'],
        'diagram-er status' => ['diagram-er status FILE.mpr [--json]', 'Show managed ER editor state',
                                'mxrb diagram-er status Shop.mpr'],
        'diagram-er destroy' => ['diagram-er destroy FILE.mpr --yes',
                                 'Stop the ER editor and remove only its managed files',
                                 'mxrb diagram-er destroy Shop.mpr --yes'],
        'db up' => ['db up FILE.mpr [--port PORT]', 'Build, synchronize and start PostgreSQL and Runtime',
                    'mxrb db up Shop.mpr'],
        'db sync' => ['db sync FILE.mpr [--port PORT]', 'Rebuild and synchronize the retained database',
                      'mxrb db sync Shop.mpr'],
        'db down' => ['db down FILE.mpr', 'Stop containers while preserving data', 'mxrb db down Shop.mpr'],
        'db destroy' => ['db destroy FILE.mpr --yes', 'Remove the isolated containers, data and state',
                         'mxrb db destroy Shop.mpr --yes'],
        'db status' => ['db status FILE.mpr', 'Show database and Runtime status', 'mxrb db status Shop.mpr'],
        'db credentials' => ['db credentials FILE.mpr [--copy]', 'Show or copy Runtime credentials',
                             'mxrb db credentials Shop.mpr'],
        'db url' => ['db url FILE.mpr [--port PORT]', 'Print the read-only PostgreSQL URL', 'mxrb db url Shop.mpr'],
        'db sql' => ['db sql FILE.mpr "SELECT ..." [--write]', 'Execute SQL against the managed database',
                     'mxrb db sql Shop.mpr "SELECT 1"'],
        'db explain' => ['db explain FILE.mpr "SELECT ..." [--analyze]',
                         'Inspect a PostgreSQL or SQL Server query plan',
                         'mxrb db explain Shop.mpr "SELECT * FROM orders"'],
        'db workload' => ['db workload FILE.mpr [--limit N]', 'Rank workload and schema pressure',
                          'mxrb db workload Shop.mpr --limit 20'],
        'db indexes' => ['db indexes FILE.mpr [--limit N]', 'Advise evidence-backed indexes',
                         'mxrb db indexes Shop.mpr'],
        'db shell' => ['db shell FILE.mpr [--write]', 'Open psql for the managed database', 'mxrb db shell Shop.mpr'],
        'design init' => ['design init [--target DIR]', 'Initialize design-system Ruby files', 'mxrb design init'],
        'design scan' => ['design scan FILE.mpr [--json]', 'Inventory CSS and SCSS design tokens',
                          'mxrb design scan Shop.mpr'],
        'design migrate' => ['design migrate FILE.mpr LITERAL TOKEN [--apply]',
                             'Preview or apply a literal-to-token migration',
                             'mxrb design migrate Shop.mpr "#fff" color.surface --apply'],
        'frontend migrate' => ['frontend migrate FILE.mpr [--apply] [--json]',
                               'Preview a frontend migration; the MPR is changed only when --apply is provided',
                               'mxrb frontend migrate Shop.mpr --apply'],
        'marketplace login' => [
          'marketplace login (--pat-file FILE | --store-pat) [--no-verify]',
          'Configure a PAT file reference or explicit managed storage; ' \
          'MXRB_MENDIX_PAT_FILE also works without persisted login',
          'mxrb marketplace login --pat-file ~/.config/mxrb/pat'
        ],
        'marketplace search' => ['marketplace search QUERY', 'Search official marketplace components',
                                 'mxrb marketplace search charts'],
        'marketplace show' => ['marketplace show NAME|CONTENT_ID', 'Show component metadata',
                               'mxrb marketplace show charts'],
        'marketplace versions' => ['marketplace versions NAME|CONTENT_ID', 'List component versions and compatibility',
                                   'mxrb marketplace versions charts'],
        'marketplace pull' => ['marketplace pull NAME[@VERSION] [--mpr FILE]',
                               'Download and import a marketplace release',
                               'mxrb marketplace pull charts@2.1.0 --mpr Shop.mpr'],
        'marketplace import' => ['marketplace import FILE.mpk [--mpr FILE]', 'Import a local marketplace package',
                                 'mxrb marketplace import charts.mpk --mpr Shop.mpr'],
        'marketplace audit' => ['marketplace audit [--mpr FILE]', 'Audit locked updates and vulnerabilities',
                                'mxrb marketplace audit --mpr Shop.mpr'],
        'marketplace list' => ['marketplace list [--mpr FILE]', 'List locked marketplace packages',
                               'mxrb marketplace list --mpr Shop.mpr'],
        'marketplace verify' => ['marketplace verify [--mpr FILE]', 'Verify locked package checksums and identity',
                                 'mxrb marketplace verify --mpr Shop.mpr'],
        'marketplace dependencies' => ['marketplace dependencies NAME [--mpr FILE]', 'Resolve package dependencies',
                                       'mxrb marketplace dependencies charts --mpr Shop.mpr'],
        'marketplace update' => ['marketplace update NAME[@VERSION] [--mpr FILE] --apply',
                                 'Update an imported package', 'mxrb marketplace update charts --mpr Shop.mpr --apply'],
        'marketplace remove' => ['marketplace remove NAME [--mpr FILE] --apply', 'Remove an imported package safely',
                                 'mxrb marketplace remove charts --mpr Shop.mpr --apply'],
        'mda inspect' => ['mda inspect FILE.mda [--json]', 'Inspect archive contents and metadata',
                          'mxrb mda inspect Shop.mda'],
        'mda compare' => ['mda compare LEFT.mda RIGHT.mda', 'Compare two deployment archives',
                          'mxrb mda compare before.mda after.mda'],
        'migrate check' => ['migrate check [DIR] [--json]', 'Fail when project.rb and the MPR drift',
                            'mxrb migrate check .'],
        'migrate plan' => ['migrate plan [DIR] [--json]', 'Preview project.rb and MPR drift', 'mxrb migrate plan .'],
        'module new' => ['module new NAME [--target DIR]', 'Create and connect an application module',
                         'mxrb module new Billing'],
        'module search' => ['module search [QUERY]', 'Search the Ruby module catalog', 'mxrb module search payments'],
        'module add' => ['module add NAME|DIR [--target DIR]', 'Install and lock a Ruby module',
                         'mxrb module add Billing'],
        'project inspect' => ['project inspect [DIR] [--json]', 'Inspect version, modules, MPRs and scaffolds',
                              'mxrb project inspect .'],
        'scaffold list' => ['scaffold list [--target DIR]', 'List generators and registered scaffolds',
                            'mxrb scaffold list'],
        'scaffold destroy' => ['scaffold destroy KIND:NAME [--target DIR]', 'Remove an unchanged registered scaffold',
                               'mxrb scaffold destroy entity:Sales.Order'],
        'team-server login' => ['team-server login --pat-file FILE', 'Configure a Team Server PAT file',
                                'mxrb team-server login --pat-file ~/.config/mxrb/pat'],
        'team-server projects' => ['team-server projects [--pat-file FILE]', 'List accessible Team Server apps',
                                   'mxrb team-server projects'],
        'team-server info' => ['team-server info APP_ID', 'Show Team Server app metadata',
                               'mxrb team-server info APP_ID'],
        'team-server branches' => ['team-server branches APP_ID', 'List repository branches',
                                   'mxrb team-server branches APP_ID'],
        'team-server commits' => ['team-server commits APP_ID BRANCH', 'List commits on a branch',
                                  'mxrb team-server commits APP_ID main'],
        'team-server clone' => ['team-server clone APP_ID|URL TARGET', 'Clone and validate a Team Server app',
                                'mxrb team-server clone APP_ID ./shop'],
        'team-server status' => ['team-server status DIR', 'Show local Team Server repository status',
                                 'mxrb team-server status ./shop'],
        'team-server fetch' => ['team-server fetch DIR', 'Fetch repository changes', 'mxrb team-server fetch ./shop'],
        'team-server pull' => ['team-server pull DIR', 'Pull repository changes', 'mxrb team-server pull ./shop'],
        'team-server push' => ['team-server push DIR', 'Push repository changes', 'mxrb team-server push ./shop'],
        'widgets sync' => ['widgets sync DEFINITION.rb FILE.mpr', 'Synchronize pluggable widget schemas',
                           'mxrb widgets sync project.rb Shop.mpr']
      }.to_h { |path, values| [path, Command.new(path, *values)] }.freeze

      FEATURED = %w[init generate export run validate doctor update].freeze

      def welcome(release: nil)
        lines = ["mxrb #{Mxrb::VERSION} — Ruby-first Mendix toolkit"]
        if release&.available?
          lines << "Update available: #{release.latest} (installed: #{release.installed})"
          lines << '  Review: mxrb changelog'
          lines << '  Update: mxrb update'
        end
        lines.concat(['', 'Common next steps:'])
        FEATURED.each do |name|
          command = COMMANDS.fetch(name)
          lines << format('  %-24s %s', command.example, command.summary)
        end
        lines.concat(['', 'Use `mxrb --help` for guided examples or `mxrb --commands` for every command.'])
        lines.join("\n")
      end

      def overview
        <<~HELP
          mxrb #{Mxrb::VERSION} — Ruby-first Mendix toolkit

          Start a new project:
            mxrb init MyApp
            cd MyApp
            bundle install
            bundle exec mxrb generate project.rb

          Convert and run an existing Mendix application as Ruby + React:
            mxrb export App.mpr app-ruby --mode ruby
            mxrb run app-ruby

          Understand an existing model:
            mxrb doctor .
            mxrb validate App.mpr
            mxrb tree App.mpr

          Discovery:
            mxrb --commands          List every top-level command
            mxrb COMMAND --help     Explain one command with an example
            mxrb GROUP --commands  List subcommands in a group

          Updates:
            mxrb update --check     Check the latest published version
            mxrb changelog          Read release notes before updating
            mxrb update             Install the latest published version
        HELP
      end

      def commands(prefix = nil)
        return group_commands(prefix) if prefix && SUBCOMMANDS.key?(prefix)

        entries = COMMANDS.values + scaffold_commands
        width = entries.map { _1.name.length }.max
        (["Available MXRB commands (#{entries.size}):", ''] + entries.sort_by(&:name).map do |command|
          format("  %-#{width}s  %s", command.name, command.summary)
        end + ['', 'Run `mxrb COMMAND --help` for usage and an example.']).join("\n")
      end

      def command(path)
        parts = Array(path).map(&:to_s)
        parts[0] = 'diagram-er' if parts.first == 'domain-model'
        name = parts.first
        return Mxrb::Scaffold::Help.text(name) if scaffold_command?(name)

        item = COMMANDS[name]
        return unknown(parts) unless item

        subcommand = parts[1]
        detail = SUBCOMMAND_HELP[[name, subcommand].compact.join(' ')]
        if detail
          return ["Usage: mxrb #{detail.usage}", '', "#{detail.summary}.", '', 'Example:',
                  "  #{detail.example}", '', "Parent help: mxrb #{name} --help"].join("\n")
        end
        body = ["Usage: mxrb #{item.usage}", '', "#{item.summary}.", '', 'Example:', "  #{item.example}"]
        if OPTIONS.key?(name)
          body.concat(['', 'Options:'])
          OPTIONS.fetch(name).each { |option, description| body << format('  %-22s %s', option, description) }
        end
        body.concat([''] + NOTES.fetch(name)) if NOTES.key?(name)
        if SUBCOMMANDS.key?(name)
          body.concat(['', group_commands(name, heading: 'Subcommands:')])
          body << "\nUse `mxrb #{name} SUBCOMMAND --help` for layered help."
        end
        body.join("\n")
      end

      def known?(name)
        COMMANDS.key?(name.to_s) || scaffold_command?(name.to_s)
      end

      def scaffold_command?(name)
        Mxrb::Scaffold::Help::COMMANDS.key?(name) && !COMMANDS.key?(name)
      end

      def scaffold_commands
        commands = Mxrb::Scaffold::Help::COMMANDS.reject do |name, _|
          COMMANDS.key?(name)
        end
        commands.map do |name, (usage, summary, _destination)|
          Command.new(name, "#{name} #{usage}", summary, "mxrb #{name} #{usage.split(/[|\[]/).first.strip}")
        end
      end

      def group_commands(name, heading: nil)
        rows = SUBCOMMANDS.fetch(name).map do |action|
          detail = SUBCOMMAND_HELP["#{name} #{action}"]
          format('  %-28s %s', "#{name} #{action}", detail&.summary.to_s)
        end
        ([heading || "Subcommands for `mxrb #{name}`:", ''] + rows).join("\n")
      end

      def unknown(path)
        "No help is registered for `mxrb #{path.join(' ')}`. " \
          'Run `mxrb --commands` to list every command.'
      end
    end
    # rubocop:enable Metrics
  end
end
