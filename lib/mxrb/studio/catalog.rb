# frozen_string_literal: true

require_relative '../cli/help'
require_relative '../scaffold/help'

module Mxrb
  # Public, UI-independent backend contract. Desktop clients consume this
  # metadata rather than duplicating CLI parsing or model operations.
  module Studio
    # rubocop:disable Metrics, Layout/LineLength
    # Complete CLI operation schemas for editors and other API clients.
    class Catalog
      # Ordered positional arguments, with ? denoting an optional value.
      # Flags remain flags, including when their values contain spaces.
      POSITIONALS = {
        'analyze' => 'model', 'benchmark' => 'model',
        'callees' => 'model name', 'callers' => 'model name', 'changelog' => 'version?',
        'compare' => 'left_model right_model', 'convert' => 'model output_directory',
        'describe' => 'model name', 'diff' => 'left_model right_model', 'doctor' => 'directory?',
        'diagram-er' => 'model', 'dump-unit' => 'model unit_id', 'env' => 'directory?',
        'evaluate' => 'model evaluation', 'export' => 'model output_directory',
        'java-actions' => 'model application_directory', 'find' => 'model text',
        'functional-instrument' => 'model test_file', 'generate' => 'definition output_model?',
        'impact' => 'model name', 'init' => 'name', 'inspect' => 'model', 'lint' => 'model',
        'modules' => 'model', 'move' => 'model name container', 'oql' => 'model',
        'pack' => 'model', 'portable' => 'model', 'portability' => 'directory?', 'preflight' => 'model',
        'protocols' => 'model', 'refs' => 'model name', 'remove' => 'model name',
        'rename' => 'model old_name new_name', 'report' => 'model', 'run' => 'application_directory?',
        'search' => 'text model', 'serve' => 'model', 'sql' => 'model query', 'query' => 'query?',
        'test' => 'model test_file', 'tree' => 'model module?', 'uml' => 'model', 'update' => '',
        'upgrade' => '', 'validate' => 'model',
        'design init' => '', 'design scan' => 'model', 'design migrate' => 'model literal token',
        'frontend migrate' => 'model', 'marketplace login' => '', 'marketplace search' => 'text',
        'marketplace show' => 'component', 'marketplace versions' => 'component',
        'marketplace pull' => 'component', 'marketplace import' => 'package',
        'marketplace audit' => '', 'marketplace list' => '', 'marketplace verify' => '',
        'marketplace dependencies' => 'component', 'marketplace update' => 'component',
        'marketplace remove' => 'component', 'mda inspect' => 'archive', 'mda compare' => 'left_archive right_archive',
        'migrate check' => 'directory?', 'migrate plan' => 'directory?', 'module new' => 'name',
        'module search' => 'text?', 'module add' => 'name', 'project inspect' => 'directory?',
        'scaffold list' => '', 'scaffold destroy' => 'scaffold', 'team-server login' => '',
        'team-server projects' => '', 'team-server info' => 'app_id', 'team-server branches' => 'app_id',
        'team-server commits' => 'app_id branch', 'team-server clone' => 'app_id target_directory',
        'team-server status' => 'source_directory', 'team-server fetch' => 'source_directory',
        'team-server pull' => 'source_directory', 'team-server push' => 'source_directory',
        'widgets new' => 'name output_directory?', 'widgets build' => 'directory',
        'widgets sync' => 'definition model', 'page templates' => ''
      }.freeze

      DEFAULTS = {
        'model' => '{mpr}', 'left_model' => '{mpr}', 'output_model' => '{generated}',
        'definition' => '{file}', 'evaluation' => '{file}', 'test_file' => '{file}',
        'directory' => '{root}', 'source_directory' => '{source}',
        'application_directory' => '{ruby}', 'output_directory' => '{ruby}'
      }.freeze

      FILES = %w[model left_model right_model output_model definition evaluation test_file package archive left_archive right_archive pat-file input].freeze
      DIRECTORIES = %w[directory source_directory application_directory output_directory target_directory target project mxrb-path deployment].freeze

      # Additional CLI options not yet present in the human-readable help.
      EXTRA_OPTIONS = {
        'benchmark' => '--iterations N --json', 'find' => '--semantic',
        'search' => '--backend auto|tfidf|onnx --limit N',
        'move' => '--apply', 'remove' => '--apply', 'rename' => '--apply',
        'pack' => '--output FILE.mda --deployment DIR --force',
        'portable' => '--output FILE.zip', 'portability' => '--json --require-native',
        'doctor' => '--json', 'preflight' => '--json', 'protocols' => '--json',
        'analyze' => '--dialect ansi|postgresql|sql_server --json',
        'serve' => '--port PORT', 'upgrade' => '--mendix VERSION --target DIR --apply',
        'test' => '--native --docker --plan', 'frontend migrate' => '--apply --json',
        'design init' => '--target DIR --dry-run --json', 'design scan' => '--json',
        'design migrate' => '--apply --json', 'mda inspect' => '--json',
        'migrate check' => '--json', 'migrate plan' => '--json', 'project inspect' => '--json',
        'module new' => '--target DIR', 'module add' => '--target DIR --registry SOURCE',
        'scaffold list' => '--target DIR', 'scaffold destroy' => '--target DIR',
        'marketplace login' => '--pat-file FILE --store-pat --no-verify',
        'marketplace pull' => '--mpr FILE.mpr', 'marketplace import' => '--mpr FILE.mpr --target DIR',
        'marketplace audit' => '--mpr FILE.mpr', 'marketplace list' => '--mpr FILE.mpr',
        'marketplace verify' => '--mpr FILE.mpr', 'marketplace dependencies' => '--mpr FILE.mpr --apply --apply-resolved',
        'marketplace update' => '--mpr FILE.mpr --apply', 'marketplace remove' => '--mpr FILE.mpr --apply',
        'team-server login' => '--pat-file FILE', 'team-server projects' => '--pat-file FILE',
        'widgets build' => '--project DIR', 'page templates' => '--json'
      }.freeze

      def entries
        main_entries + scaffold_entries
      end

      def fetch(name)
        entries.find { _1[:name] == name } || raise(ArgumentError, "unknown Studio command: #{name}")
      end

      def arguments(name, values = {}, extra: [])
        entry = fetch(name)
        unknown = values.keys.map(&:to_s) - entry[:fields].map { _1[:key] }
        raise ArgumentError, "unknown fields: #{unknown.join(', ')}" unless unknown.empty?

        arguments = entry[:prefix].dup
        entry[:fields].each do |field|
          value = values.fetch(field[:key], field[:default])
          next if field[:kind] == 'boolean' && ![true, 'true'].include?(value)

          if value.nil? || value == ''
            raise ArgumentError, "#{field[:label]} is required" if field[:required]

            next
          end
          raise ArgumentError, "invalid #{field[:label]}" if value.to_s.include?("\0")

          choices = field[:choices]
          raise ArgumentError, "invalid #{field[:label]}: #{value}" if choices.any? && !choices.include?(value.to_s)

          arguments << field[:flag] if field[:flag]
          arguments << value.to_s unless field[:kind] == 'boolean'
        end
        raise ArgumentError, 'extra arguments must be strings' unless extra.is_a?(Array) && extra.all? { _1.is_a?(String) && !_1.include?("\0") }

        arguments + extra
      end

      private

      def main_entries
        CLI::Help::COMMANDS.values.flat_map do |command|
          subcommands = CLI::Help::SUBCOMMANDS.fetch(command.name, [])
          paths = subcommands.map { "#{command.name} #{_1}" }
          paths.unshift(command.name) if subcommands.empty? || command.name == 'diagram-er'
          paths.map do |path|
            detail = CLI::Help::SUBCOMMAND_HELP.fetch(path, command)
            build(path, detail.usage, detail.summary, detail.example)
          end
        end
      end

      def scaffold_entries
        Scaffold::Help::COMMANDS.flat_map do |name, (usage, summary, _destination)|
          next [] if name == 'design'

          actions = name == 'page' ? %w[new generate templates] : [usage.split.first]
          actions.map do |action|
            path = "#{name} #{action}"
            arguments = if action == 'templates'
                          ''
                        elsif name == 'ci'
                          ''
                        else
                          'name'
                        end
            build(path, "#{name} #{usage}", summary, "mxrb #{path}", positional: arguments, scaffold: action != 'templates')
          end
        end
      end

      def build(path, usage, summary, example, positional: nil, scaffold: false)
        parent = path.split.first
        prefix = path.split
        prefix << 'github' if path == 'ci init'
        tokens = positional || POSITIONALS[path] || inferred_positionals(path)
        fields = tokens.split.map { field(_1.delete_suffix('?'), required: !_1.end_with?('?')) }
        options = option_text(path, parent, scaffold)
        options.scan(/(--[\w-]+)(?:\s+([A-Z][A-Z_.]*|[a-z_]+\|[\w|]+))?/).each do |flag, value|
          key = flag.delete_prefix('--')
          next if fields.any? { _1[:key] == key }

          required = (path == 'convert' && key == 'studio') || (path == 'query' && key == 'from') ||
                     (path == 'upgrade' && key == 'mendix') || (%w[pack portable].include?(path) && key == 'output') ||
                     (path == 'team-server login' && key == 'pat-file')
          item = field(key, required:, flag:, kind: value ? nil : 'boolean')
          item[:choices] = value.split('|') if value&.include?('|')
          item[:choices] = %w[mendix ruby] if key == 'mode'
          item[:choices] = %w[sql oql] if %w[from to].include?(key) && path == 'query'
          item[:choices] = %w[ansi postgresql sql_server] if key == 'dialect'
          item[:choices] = %w[class activity sequence] if key == 'export' && path == 'uml'
          item[:choices] = %w[mermaid plantuml] if key == 'format' && path == 'uml'
          item[:default] = '{mpr}' if key == 'mpr'
          item[:default] = '{mda}' if path == 'pack' && key == 'output'
          item[:default] = '{portable}' if path == 'portable' && key == 'output'
          item[:default] = 'sql' if path == 'query' && key == 'from'
          fields << item
        end
        context = if parent == 'db'
                    'database'
                  elsif parent == 'team-server'
                    'repository'
                  elsif fields.any? { %w[model mpr].include?(_1[:key]) }
                    'model'
                  elsif scaffold || %w[run generate module migrate upgrade env project portability].include?(parent)
                    'ruby'
                  else
                    'global'
                  end
        { name: path, usage:, summary:, example:, subcommands: [], prefix:, fields:, context:, effect: effect(path, scaffold) }
      end

      def inferred_positionals(path)
        return 'model query' if ['db sql', 'db explain'].include?(path)
        return 'model' if %w[cache db diagram-er].include?(path.split.first)

        raise ArgumentError, "missing Studio argument schema: #{path}"
      end

      def field(key, required:, flag: nil, kind: nil)
        kind ||= if FILES.include?(key) || (flag && %w[mpr output].include?(key))
                   key.start_with?('output') || key == 'output' ? 'save_file' : 'file'
                 elsif DIRECTORIES.include?(key)
                   'directory'
                 elsif %w[query text].include?(key)
                   'multiline'
                 else
                   'text'
                 end
        { key:, label: flag || key.tr('_', ' '), kind:, required:, flag:, default: kind == 'boolean' ? false : DEFAULTS[key], choices: [] }
      end

      def option_text(path, parent, scaffold)
        common = CLI::Help::OPTIONS.fetch(parent, []).map(&:first).join(' ')
        extra = EXTRA_OPTIONS.fetch(path, '')
        extra += ' --target DIR --dry-run --json' if scaffold
        extra += ' --template NAME --chain CHAIN --role ROLE' if path.start_with?('page ') && scaffold
        extra += ' --entity ENTITY --role ROLE' if path == 'demo-user new'
        extra += ' --json' if parent == 'cache'
        extra += ' --yes' if ['db destroy', 'diagram-er destroy'].include?(path)
        if parent == 'db'
          extra += ' --engine postgresql|sql_server --server SERVER --database DATABASE --user USER --sqlcmd FILE' if ['db explain', 'db workload'].include?(path)
          extra += ' --copy --show-password --json' if path == 'db credentials'
          extra += ' --write' if ['db sql', 'db shell'].include?(path)
          extra += ' --analyze --json' if path == 'db explain'
          extra += ' --limit N --save FILE --compare FILE --json' if path == 'db workload'
          extra += ' --limit N --json' if path == 'db indexes'
        end
        "#{common} #{extra}"
      end

      def effect(path, scaffold)
        return 'read_or_write' if path == 'db sql'
        return 'write' if scaffold || ['functional-instrument', 'scaffold destroy', 'db destroy', 'diagram-er destroy', 'marketplace import', 'marketplace pull'].include?(path)
        return 'publish' if path == 'team-server push'
        return 'authentication' if path.end_with?(' login') || ['db credentials', 'db url'].include?(path)
        return 'service' if ['run', 'serve', 'uml', 'diagram-er', 'db up', 'db sync', 'db down', 'db shell', 'diagram-er up', 'diagram-er down'].include?(path)
        return 'install' if ['update', 'team-server clone', 'team-server fetch', 'team-server pull', 'module add', 'widgets build'].include?(path)
        return 'preview_or_write' if ['move', 'rename', 'remove', 'design migrate', 'frontend migrate', 'upgrade', 'marketplace update', 'marketplace remove', 'marketplace dependencies'].include?(path)
        return 'write' if ['init', 'export', 'convert', 'generate', 'pack', 'portable', 'java-actions', 'widgets new', 'widgets sync', 'module new', 'design init', 'cache warm', 'cache clear'].include?(path)

        'read'
      end
    end
    # rubocop:enable Metrics, Layout/LineLength
  end
end
