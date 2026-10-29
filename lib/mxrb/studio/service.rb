# frozen_string_literal: true

require 'json'
require 'open3'
require 'prism'
require 'rbconfig'
require 'securerandom'
require 'shellwords'
require_relative 'artifacts'
require_relative 'catalog'
require_relative 'files'
require_relative 'protocol'
require_relative 'request_context'
require_relative 'write_lock'

module Mxrb
  module Studio
    # The methods of the Studio protocol. Every method takes a params object
    # and a RequestContext and returns a JSON-compatible value. Heavier parts
    # of MXRB load on first use, so the catalog and files answer immediately.
    class Service # rubocop:disable Metrics/ClassLength
      METHODS = {
        'catalog/list' => :catalog_list, 'catalog/arguments' => :catalog_arguments,
        'tasks/prepare' => :tasks_prepare, 'tasks/run' => :tasks_run, 'tasks/input' => :tasks_input,
        'tasks/configurations' => :tasks_configurations, 'tasks/saveConfiguration' => :tasks_save_configuration,
        'tasks/deleteConfiguration' => :tasks_delete_configuration,
        'files/list' => :files_list, 'files/read' => :files_read, 'files/write' => :files_write,
        'files/create' => :files_create, 'files/move' => :files_move, 'files/delete' => :files_delete,
        'files/worktrees' => :files_worktrees, 'files/worktreeAdd' => :files_worktree_add,
        'files/worktreeRemove' => :files_worktree_remove,
        'ruby/syntax' => :ruby_syntax, 'ruby/declarations' => :ruby_declarations,
        'snapshot/create' => :snapshot_create,
        'project/status' => :project_status, 'project/convert' => :project_convert, 'project/attach' => :project_attach,
        'documents/list' => :documents_list, 'documents/read' => :documents_read, 'documents/patch' => :documents_patch,
        'documents/ruby' => :documents_ruby,
        'model/capabilities' => :model_capabilities, 'model/revision' => :model_revision,
        'model/preview' => :model_preview, 'model/apply' => :model_apply, 'model/history' => :model_history,
        'model/undo' => :model_undo, 'model/redo' => :model_redo,
        'model/catalog' => :model_catalog, 'model/domainDiagram' => :model_domain_diagram,
        'data/logical' => :data_logical, 'data/connections' => :data_connections, 'data/physical' => :data_physical,
        'data/query' => :data_query, 'data/explain' => :data_explain, 'parity/matrix' => :parity_matrix,
        'sync/link' => :sync_link, 'sync/unlink' => :sync_unlink, 'sync/status' => :sync_status,
        'sync/run' => :sync_run, 'sync/preview' => :sync_preview, 'sync/document' => :sync_document,
        'locks/acquire' => :locks_acquire, 'locks/release' => :locks_release, 'locks/status' => :locks_status
      }.freeze

      # Version 1 single-shot action names (`Backend#call`).
      LEGACY = {
        'catalog' => 'catalog/list', 'command_arguments' => 'catalog/arguments', 'prepare' => 'tasks/prepare',
        'files' => 'files/list', 'ruby_syntax' => 'ruby/syntax', 'file_read' => 'files/read',
        'file_write' => 'files/write', 'file_create' => 'files/create', 'file_move' => 'files/move',
        'worktrees' => 'files/worktrees', 'snapshot' => 'snapshot/create',
        'ruby_project_status' => 'project/status', 'ruby_project_convert' => 'project/convert',
        'ruby_project_attach' => 'project/attach', 'model_capabilities' => 'model/capabilities',
        'model_revision' => 'model/revision', 'model_preview' => 'model/preview', 'model_apply' => 'model/apply',
        'documents' => 'documents/list', 'document_read' => 'documents/read', 'document_patch' => 'documents/patch',
        'model_catalog' => 'model/catalog', 'domain_diagram' => 'model/domainDiagram',
        'data_logical' => 'data/logical', 'data_physical' => 'data/physical', 'data_query' => 'data/query',
        'data_explain' => 'data/explain'
      }.freeze

      # Request parameters; a missing one is an invalid-params failure.
      class Params
        def initialize(values)
          raise Protocol::Failure.new(Protocol::INVALID_PARAMS, 'params must be an object') unless values.is_a?(Hash)

          @values = values
        end

        def fetch(key, *default)
          @values.fetch(key) do
            raise Protocol::Failure.new(Protocol::INVALID_PARAMS, "missing parameter: #{key}") if default.empty?

            default.first
          end
        end

        def [](key) = @values[key]
        def key?(key) = @values.key?(key)
      end

      def self.default_state_root
        File.join(ENV.fetch('XDG_STATE_HOME', File.join(Dir.home, '.local', 'state')), 'mxrb', 'studio')
      end

      def initialize(state_root: self.class.default_state_root, repository: File.expand_path('../../..', __dir__))
        @state_root = state_root
        @repository = repository
        @tasks = {}
        @leases = {}
        @mutex = Mutex.new
      end

      def methods_list = METHODS.keys

      def dispatch(method, params, context = RequestContext.new)
        name = METHODS.fetch(method) do
          raise Protocol::Failure.new(Protocol::METHOD_NOT_FOUND, "unknown Studio method: #{method}")
        end
        public_send(name, Params.new(params || {}), context)
      end

      # Releases what the connection still holds: leases and running tasks.
      def close
        @mutex.synchronize { @leases.values }.each { _1[:lock].release(_1[:file]) }
        @mutex.synchronize { @tasks.values }.each { stop(_1) }
        @leases.clear
      end

      # ── Catalog and tasks ────────────────────────────────────────────────

      def catalog_list(_params, _context) = Catalog.new.entries

      def catalog_arguments(params, _context)
        Catalog.new.arguments(params.fetch('command_id'), params.fetch('values', {}),
                              extra: Shellwords.split(params.fetch('extra', '')))
      end

      def tasks_prepare(params, _context) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        raw = if params.key?('command_id')
                catalog_arguments(params, nil)
              elsif params.key?('arguments')
                params.fetch('arguments')
              else
                Shellwords.split(params.fetch('command'))
              end
        unless raw.is_a?(Array) && !raw.empty? && raw.all? { _1.is_a?(String) && !_1.include?("\0") }
          raise ArgumentError, 'select an MXRB command'
        end

        substitute(raw, params.fetch('substitutions', {}))
      end

      # Runs an MXRB command as a child process, streaming its output as
      # `tasks/output` notifications. Cancelling the request stops the task.
      def tasks_run(params, context) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        argv = tasks_prepare(params, context)
        directory = File.realpath(params.fetch('directory'))
        task = params.fetch('task_id', SecureRandom.uuid)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stdin, stdout, stderr, waiter = Open3.popen3(task_environment, RbConfig.ruby, mxrb_executable,
                                                     '--no-progress', *argv, chdir: directory, pgroup: true)
        record = { stdin:, pid: waiter.pid, cancelled: false }
        @mutex.synchronize { @tasks[task] = record }
        hook = context.on_cancel { stop(record) }
        context.notify('tasks/started', { task:, arguments: argv, directory:, pid: waiter.pid })
        readers = [[stdout, 'stdout'], [stderr, 'stderr']].map do |io, stream|
          Thread.new { io.each_line { context.notify('tasks/output', { task:, stream:, text: _1.scrub }) } }
        end
        readers.each(&:join)
        status = waiter.value
        { task:, arguments: argv, directory:, exit_code: status.exitstatus, signal: status.termsig,
          cancelled: record[:cancelled], success: status.success? == true,
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round }
      ensure
        context.remove_cancel_hook(hook) if hook
        @mutex.synchronize { @tasks.delete(task) } if task
        [stdin, stdout, stderr].each { _1&.close unless _1&.closed? }
      end

      def tasks_configurations(params, _context) = task_configurations(params).list

      def tasks_save_configuration(params, _context)
        task_configurations(params).save(params.fetch('configuration'))
      end

      def tasks_delete_configuration(params, _context) = task_configurations(params).delete(params.fetch('id'))

      def tasks_input(params, _context)
        record = @mutex.synchronize { @tasks[params.fetch('task')] }
        raise ArgumentError, 'task is not running' unless record

        record[:stdin].write(params.fetch('text'))
        record[:stdin].close if params.fetch('close', false)
        { written: true }
      end

      # ── Files and Ruby ───────────────────────────────────────────────────

      def files_list(params, _context)
        files(params).list(params.fetch('path', '.'), include_ignored: params.fetch('include_ignored', false))
      end

      def files_read(params, _context) = files(params).read(params.fetch('path'))

      def files_write(params, _context)
        files(params).write(params.fetch('path'), text: params.fetch('text'), revision: params.fetch('revision'))
      end

      def files_create(params, _context)
        files(params).create(params.fetch('path'), directory: params.fetch('directory', false),
                                                   text: params.fetch('text', ''))
      end

      def files_move(params, _context)
        files(params).move(params.fetch('path'), destination: params.fetch('destination'))
      end

      def files_delete(params, _context)
        files(params).delete(params.fetch('path'), recursive: params.fetch('recursive', false) == true,
                                                   revision: params['revision'])
      end

      def files_worktrees(params, _context) = files(params).worktrees

      def files_worktree_add(params, _context)
        files(params).add_worktree(params.fetch('path'), branch: params.fetch('branch'), base: params['base'])
      end

      def files_worktree_remove(params, _context) = files(params).remove_worktree(params.fetch('path'))

      def ruby_syntax(params, _context)
        text = params.fetch('text')
        raise ArgumentError, 'source exceeds 4 MiB' if text.bytesize > Files::MAXIMUM_BYTES

        diagnostics = Artifacts.diagnostics(text, file: params.fetch('path', nil))
        { valid: diagnostics.none? { _1[:severity] == 'error' }, diagnostics: }
      end

      def ruby_declarations(params, _context)
        Artifacts.declarations(params.fetch('text'), path: params.fetch('path', nil))
      end

      # ── Model ────────────────────────────────────────────────────────────

      def snapshot_create(params, _context)
        load_model_support
        Snapshot.new(params.fetch('model'), destination_root: params.fetch('destination_root')).create
      end

      def project_status(params, _context) = ruby_project(params).status
      def project_attach(params, _context) = ruby_project(params).attach(root: params.fetch('root'))

      # With `link`, the new Ruby project also becomes the synchronization
      # base of the source model at once, before either side is edited.
      def project_convert(params, context)
        project = ruby_project(params)
        result = context.with_progress('Converting to Ruby') do
          Isolated.run(context) { project.convert(model: params['model']) }
        end
        return result unless params.fetch('link', false) && result[:state] == 'ready'

        result.merge(sync: link_conversion(project, result.fetch(:root), params, context))
      end

      # The conversion stands even when linking fails; the base can be linked later.
      def link_conversion(project, root, params, context)
        sync = Sync.new(project.source_model, ruby_root: root, state_root: state_root(params), context:,
                                              isolation: sync_isolation)
        sync.linked? ? sync.status : sync.link!
      rescue Cancelled
        raise
      rescue StandardError, ScriptError => e
        { linked: false, state: 'unlinked', error: e.message }
      end

      def documents_list(params, _context) = documents(params).list
      def documents_read(params, _context) = documents(params).read(params.fetch('unit_id'))

      def documents_ruby(params, context)
        project = ruby_project(params)
        RubyDocument.new(project, context:).resolve(unit_id: params.fetch('unit_id'),
                                                    qualified_name: params['qualified_name'], type: params['type'])
      end

      def documents_patch(params, _context)
        journaled(params, 'Edit document properties') do
          documents(params).patch(params.fetch('unit_id'), revision: params.fetch('revision'),
                                                           changes: params.fetch('changes'))
        end
      end

      def model_capabilities(params, _context) = operations(params).capabilities
      def model_revision(params, _context) = operations(params).revision

      def model_preview(params, _context)
        operations(params).preview(params.fetch('operation'), revision: params.fetch('revision'))
      end

      def model_apply(params, _context)
        journaled(params, "Model operation #{params.fetch('operation')['operation']}") do
          operations(params).apply(params.fetch('operation'), revision: params.fetch('revision'))
        end
      end

      def model_history(params, _context) = history(params).entries
      def model_undo(params, _context) = history(params).undo
      def model_redo(params, _context) = history(params).redo

      def model_catalog(params, _context)
        load_model_support
        Modeler::Catalog.new(params.fetch('model')).to_h
      end

      def model_domain_diagram(params, _context)
        load_model_support
        DomainDiagram::Document.new(params.fetch('model'), modules: params.fetch('modules', [])).to_h
      end

      # ── Data ─────────────────────────────────────────────────────────────

      def data_logical(params, _context) = explorer(params).logical
      def data_connections(params, _context) = connections(params).list

      # Physical schema, queries and plans run only on the connection the
      # client chose; each result names that connection.
      def data_physical(params, _context) = connected(params, &:physical)
      def data_query(params, _context) = connected(params) { _1.query(params.fetch('payload')) }
      def data_explain(params, _context) = connected(params) { _1.explain(params.fetch('payload')) }

      # ── Parity ───────────────────────────────────────────────────────────

      def parity_matrix(_params, _context)
        require_relative 'parity'
        Parity.new(methods: methods_list).to_h
      end

      # ── Sync ─────────────────────────────────────────────────────────────

      def sync_link(params, context) = sync(params, context).link!
      def sync_unlink(params, context) = sync(params, context).unlink!
      def sync_status(params, context) = sync(params, context).status

      # `lease` (from locks/acquire on the same model) runs the write under the
      # lock the client already holds, e.g. while the IDE keeps its own saves
      # out until it has reloaded the model.
      def sync_run(params, context)
        with_lease(params) do
          sync(params, context).run(resolutions: params.fetch('resolutions', {}),
                                    dry_run: params.fetch('dry_run', false),
                                    expected_revisions: params['expected_revisions'])
        end
      end

      def sync_document(params, context)
        sync(params, context).document_state(unit_id: params['unit_id'], path: params['path'])
      end

      def sync_preview(params, context)
        project = ruby_project(params)
        require_relative 'sync_preview'
        SyncPreview.new(project, context:).run(expected_revisions: params['expected_revisions'])
      end

      # ── Locks ────────────────────────────────────────────────────────────

      # Holds the write lock of a model (or workspace) for the client until
      # `locks/release` or the end of the connection, e.g. while the IDE saves.
      def locks_acquire(params, _context)
        lock = WriteLock.new(File.realpath(params.fetch('target')))
        file = lock.acquire(params.fetch('timeout', WriteLock::DEFAULT_TIMEOUT))
        lease = SecureRandom.uuid
        @mutex.synchronize { @leases[lease] = { lock:, file: } }
        { lease:, target: lock.target, path: lock.path }
      end

      def locks_release(params, _context)
        lease = @mutex.synchronize { @leases.delete(params.fetch('lease')) }
        raise ArgumentError, 'unknown lease' unless lease

        lease[:lock].release(lease[:file])
        { released: true }
      end

      def locks_status(params, _context)
        lock = WriteLock.new(File.realpath(params.fetch('target')))
        file = lock.acquire(0)
        lock.release(file)
        { locked: false, path: lock.path }
      rescue Busy
        { locked: true, path: lock.path }
      end

      private

      def substitute(raw, substitutions)
        raw.map do |argument|
          value = substitutions.fetch(argument, argument)
          if value.to_s.empty? || value.match?(/\A\{\w+\}\z/)
            raise ArgumentError, "unresolved workspace argument: #{argument}"
          end

          value
        end
      end

      def mxrb_executable = File.join(@repository, 'bin', 'mxrb')

      def task_environment
        { 'NO_COLOR' => '1', 'TERM' => 'dumb', 'PAGER' => 'cat', 'GIT_PAGER' => 'cat', 'PSQL_PAGER' => 'cat' }
      end

      def stop(record)
        record[:cancelled] = true
        Process.kill('TERM', -record[:pid])
      rescue Errno::ESRCH
        nil
      end

      def files(params) = Files.new(params.fetch('root'))

      def state_root(params) = params.fetch('state_root', @state_root)

      def load_model_support
        require_relative '../../mxrb'
        require_relative 'snapshot'
        require_relative 'ruby_project'
        require_relative 'ruby_document'
        require_relative 'documents'
        require_relative 'model_operations'
        require_relative 'history'
        require_relative 'data_explorer'
        require_relative 'sync'
        require_relative 'isolated'
      end

      def ruby_project(params)
        load_model_support
        RubyProject.new(params.fetch('source_model'), state_root: state_root(params))
      end

      def documents(params)
        load_model_support
        Documents.new(params.fetch('model'))
      end

      def operations(params)
        load_model_support
        ModelOperations.new(params.fetch('model'), workspace_root: params.fetch('workspace_root'),
                                                   source_model: params['source_model'])
      end

      def history(params)
        load_model_support
        History.new(params.fetch('model'), state_root: state_root(params))
      end

      def journaled(params, label, &)
        result, entry = history(params).record(label, &)
        result.merge(history: entry)
      end

      def explorer(params)
        load_model_support
        DataExplorer.new(params.fetch('model'), modules: params.fetch('modules', []),
                                                database_port: params.fetch('database_port', 55_432))
      end

      def connections(params)
        load_model_support
        require_relative 'data_connections'
        DataConnections.new(params.fetch('model'), database_port: params.fetch('database_port', 55_432),
                                                   runtime_port: params.fetch('runtime_port', 18_080))
      end

      def connected(params)
        workspace, connection = connections(params).resolve!(params.fetch('connection'))
        explorer = DataExplorer.new(params.fetch('model'), workspace:, modules: params.fetch('modules', []))
        yield(explorer).merge(connection:)
      end

      def task_configurations(params)
        require_relative 'task_configurations'
        TaskConfigurations.new(params.fetch('project'), state_root: state_root(params))
      end

      def sync(params, context)
        load_model_support
        Sync.new(params.fetch('model'), ruby_root: params.fetch('ruby_root'), state_root: state_root(params), context:,
                                        isolation: sync_isolation)
      end

      # Ruby generation for synchronization runs in the sandbox; only the
      # process that starts the backend can relax that (e.g. CI without user
      # namespaces).
      def sync_isolation = ENV.fetch('MXRB_STUDIO_SYNC_ISOLATION', 'sandbox').to_sym

      def with_lease(params)
        return yield if params['lease'].nil?

        path = leased_path(params['lease'], params.fetch('model'))
        held = (Thread.current[WriteLock::HELD] ||= [])
        held << path
        begin
          yield
        ensure
          held.delete_at(held.rindex(path))
        end
      end

      def leased_path(id, model)
        lease = @mutex.synchronize { @leases[id] }
        raise ArgumentError, 'unknown lease' unless lease
        unless lease[:lock].path == WriteLock.path_for(File.realpath(model))
          raise ArgumentError,
                'the lease does not hold this model'
        end

        lease[:lock].path
      end
    end
  end
end
