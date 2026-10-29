# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'securerandom'
require 'time'
require 'tmpdir'
require_relative '../../mxrb'
require_relative 'artifacts'
require_relative 'files'
require_relative 'history'
require_relative 'isolated'
require_relative 'preview_sandbox'
require_relative 'request_context'
require_relative 'snapshot'
require_relative 'structure'
require_relative 'text_merge'
require_relative 'write_lock'

# rubocop:disable Metrics
module Mxrb
  module Studio
    # Keeps a native Mendix model and its Ruby project in step, artifact by
    # artifact. The last synchronized state is kept as a base: a copy of the
    # model, the Ruby export of that model and the model generated from the
    # Ruby. A synchronization then
    #
    # * finds the Mendix edits: units of the model that differ from the base
    #   model (by meaning, not bytes);
    # * finds the Ruby edits: units whose generation from the current Ruby
    #   differs from the generation of the base Ruby, expressed as element
    #   operations in the IDs of the model;
    # * reports a conflict for every element both sides changed, and applies
    #   nothing until each conflict is resolved (`ruby` or `mendix`), so both
    #   works are always preserved;
    # * applies the Ruby edits to the model element by element (IDs, layout
    #   and untouched properties stay as they are), journaled for undo;
    # * merges the Mendix edits into the Ruby files with a three-way text
    #   merge, so comments and Ruby code outside the edited lines survive.
    #
    # Ruby that does not parse or evaluate leaves the model untouched and
    # reports the error with its file and line.
    #
    # Writes are coordinated: the model and the Ruby project are compared by
    # revision (compare-and-swap) under the write locks every cooperating
    # writer takes, the Ruby is generated from a private copy taken when the
    # run starts, and Ruby saved while a run is in progress stays pending
    # instead of being folded into the new base. Ruby generation runs in the
    # sandbox by default, so project code cannot touch the user's files.
    class Sync
      VERSION = 1
      ISOLATIONS = %i[sandbox process].freeze
      SKIPPED_DIRECTORIES = (Files::HIDDEN_DIRECTORIES + %w[build deployment tmp]).freeze
      MANAGED = %r{\A\.mxrb/}
      RESOLUTIONS = %w[ruby mendix].freeze
      DOCUMENT_TYPES = {
        'microflow' => 'Microflows$Microflow', 'nanoflow' => 'Microflows$Nanoflow', 'rule' => 'Microflows$Rule',
        'page' => 'Forms$Page', 'snippet' => 'Forms$Snippet', 'layout' => 'Forms$Layout',
        'building_block' => 'Forms$BuildingBlock', 'page_template' => 'Forms$PageTemplate',
        'enumeration' => 'Enumerations$Enumeration', 'constant' => 'Constants$Constant',
        'java_action' => 'JavaActions$JavaAction', 'javascript_action' => 'JavaScriptActions$JavaScriptAction',
        'workflow' => 'Workflows$Workflow', 'scheduled_event' => 'ScheduledEvents$ScheduledEvent',
        'regular_expression' => 'RegularExpressions$RegularExpression',
        'image_collection' => 'Images$ImageCollection', 'json_structure' => 'JsonStructures$JsonStructure',
        'import_mapping' => 'ImportMappings$ImportMapping', 'export_mapping' => 'ExportMappings$ExportMapping'
      }.freeze

      attr_reader :model_path, :ruby_root, :state_directory, :isolation

      def initialize(model_path, ruby_root:, state_root:, context: RequestContext.new, isolation: :sandbox)
        @model_path = File.realpath(model_path)
        @ruby_root = File.realpath(ruby_root)
        raise ArgumentError, 'Ruby project root must contain project.rb' unless File.file?(entrypoint)

        @isolation = isolation.to_sym
        raise ArgumentError, "isolation must be one of #{ISOLATIONS.join(', ')}" unless ISOLATIONS.include?(@isolation)

        @state_directory = File.join(File.expand_path(state_root), 'sync', Digest::SHA256.hexdigest(@model_path))
        @context = context
      end

      def entrypoint = File.join(ruby_root, 'project.rb')

      # Linked to this Ruby project: a model has at most one synchronization
      # base, and linking another Ruby project replaces it.
      def linked?
        File.file?(link_path) && read_link['ruby_root'] == ruby_root
      rescue JSON::ParserError
        false
      end

      # Records the current model and Ruby project as the synchronized base.
      # The Ruby must generate; only the MXRB-owned `.mxrb/` metadata of the
      # Ruby project is refreshed from the model.
      # Without `base_model` the current model and Ruby project are the base: they
      # are taken to be in sync. With the model the Ruby project was converted
      # from, what either side changed since the conversion stays pending.
      def link!(base_model: nil)
        return link_from(base_model) if base_model

        with_progress('Linking Ruby project') do
          Dir.mktmpdir('mxrb-link-') do |scratch|
            export = File.join(scratch, 'export')
            generated = File.join(scratch, 'generated')
            snapshot = File.join(scratch, 'ruby')
            export(model_path, export)
            WriteLock.synchronize(ruby_root) { refresh_managed(export) }
            copy_tree(ruby_root, snapshot)
            generate(generated, root: snapshot)
            write_link(build_base(base_ruby: export, generated: File.join(generated, File.basename(model_path)),
                                  ruby_source: snapshot))
          end
          clear_conflicts
          status
        end
      end

      def link_from(base_model)
        with_progress('Linking Ruby project') do
          Dir.mktmpdir('mxrb-link-') do |scratch|
            export = File.join(scratch, 'export')
            export(base_model, export)
            write_link(build_base(base_ruby: export, generated: nil, ruby_source: export, base_model:))
          end
          clear_conflicts
          status
        end
      end

      def unlink!
        FileUtils.rm_rf(state_directory)
        { linked: false }
      end

      # Cheap view of pending work: changed Ruby files (with parse
      # diagnostics), changed Mendix units and the last unresolved conflicts.
      def status
        return { linked: false, state: 'unlinked', model: model_path, ruby_root: } unless linked?

        link = read_link
        ruby = ruby_changes(link)
        diagnostics = ruby.flat_map { _1[:diagnostics] }
        mendix = mendix_changes(link)
        revisions = { 'model' => model_revision, 'ruby' => ruby_revision(ruby_root) }
        conflicts = read_conflicts(revisions)
        state = if conflicts.any? then 'conflict'
                elsif diagnostics.any? { _1[:severity] == 'error' } then 'conversion_error'
                elsif ruby.any? || mendix.any? then 'pending'
                else 'synced'
                end
        { linked: true, state:, model: model_path, ruby_root:, synced_at: link['synced_at'], revisions:,
          ruby_changes: ruby, mendix_changes: mendix, conflicts:, diverged: link.fetch('diverged', []),
          documents: documents(link, ruby, mendix, conflicts) }
      end

      # The representation state of one artifact, by native unit id or by Ruby
      # file path: synced, pending (either side changed), conversion_error (its
      # Ruby does not parse) or conflict (both sides changed the same element).
      def document_state(unit_id: nil, path: nil)
        raise ArgumentError, 'document_state needs a unit_id or a path' unless unit_id || path

        current = status
        unless current[:linked]
          # Unlinked, the file's declarations still name their documents in the current model.
          units = unit_id ? [unit_id.downcase] : declared_units_in(model_path, [ruby_root], path)
          return current.slice(:linked, :state).merge(unit_ids: units)
        end

        units = unit_id ? [unit_id.downcase] : declared_units(read_link, path)
        matches = current[:documents].select { units.include?(_1[:unit_id]) || (path && _1[:files].include?(path)) }
        file = path && current[:ruby_changes].find { _1[:path] == path }
        conflicts = current[:conflicts].select do |conflict|
          units.include?(conflict[:unit_id]) || (path && conflict[:path] == path)
        end
        diagnostics = (file ? file[:diagnostics] : []) + matches.flat_map { _1[:diagnostics] }
        state = if conflicts.any? then 'conflict'
                elsif diagnostics.any? { _1[:severity] == 'error' } then 'conversion_error'
                elsif file || matches.any? { _1[:state] != 'synced' } then 'pending'
                else 'synced'
                end
        { linked: true, state:, unit_ids: units, path:, ruby: file&.slice(:path, :action),
          mendix: matches.filter_map { _1[:mendix] && _1.slice(:unit_id, :mendix) },
          conflicts: conflicts.map { _1[:id] }, diagnostics: diagnostics.uniq, revisions: current[:revisions] }
      end

      # Synchronizes both directions. `resolutions` maps conflict ids to
      # `ruby` or `mendix`; `dry_run` reports without writing anything.
      # Synchronizes both directions. `resolutions` maps conflict ids to
      # `ruby` or `mendix`; `dry_run` reports without writing anything.
      # `expected_revisions` ({model, ruby}, as reported by a previous dry run
      # or status) makes the run refuse to apply anything but the compared
      # state.
      def run(resolutions: {}, dry_run: false, expected_revisions: nil)
        raise ArgumentError, 'Ruby project is not linked; convert or link it first' unless linked?

        resolutions = normalize_resolutions(resolutions)
        expected_revisions = normalize_revisions(expected_revisions)
        with_progress('Synchronizing Ruby and Mendix') do |progress|
          link = read_link
          Dir.mktmpdir('mxrb-sync-') do |scratch|
            snapshot = File.join(scratch, 'ruby')
            copy_tree(ruby_root, snapshot)
            revision = model_revision
            revisions = { 'model' => revision, 'ruby' => ruby_revision(snapshot) }
            if expected_revisions && expected_revisions != revisions
              raise Conflict, 'the model or the Ruby project changed since they were compared; compare again'
            end

            ruby = ruby_changes(link, snapshot)
            syntax = ruby.flat_map { _1[:diagnostics] }.select { _1[:severity] == 'error' }
            raise RubySourceError.new(syntax.first[:message], locations: syntax) if syntax.any?

            progress.update(detail: 'reading the Ruby and Mendix changes')
            inputs = prepare(link, scratch, ruby: ruby.any?, mendix: mendix_changes(link).any?, root: snapshot)
            plan = plan(link, inputs, root: snapshot)
            text = merge_text(inputs, plan, root: snapshot)
            conflicts = plan[:conflicts] + text[:conflicts]
            unresolved = conflicts.reject { resolutions.key?(_1[:id]) }
            result = { dry_run:, ruby_units: plan[:ruby_units], mendix_units: plan[:mendix_units],
                       files: text[:files].map { _1.slice(:path, :action) }, conflicts:, revisions: }
            if unresolved.any? || dry_run
              write_conflicts(unresolved, revisions)
              next result.merge(applied: false, state: unresolved.any? ? 'conflict' : 'pending')
            end

            progress.update(detail: 'writing the model and Ruby files')
            entry = write(plan, text, resolutions, revision, snapshot)
            base_ruby = inputs[:theirs]
            if plan[:ruby_units].any?
              base_ruby = export(model_path, File.join(scratch, 'export-after'))
              WriteLock.synchronize(ruby_root) { refresh_managed(base_ruby, roots: [ruby_root, snapshot]) }
            end
            base = build_base(
              base_ruby:,
              generated: text[:files].empty? ? inputs[:generated] || link['generated_model'] : nil,
              previous: link, ruby_source: snapshot
            )
            write_link(base)
            clear_conflicts
            result.merge(applied: true, state: 'synced', history: entry,
                         revisions: { 'model' => model_revision, 'ruby' => ruby_revision(ruby_root) })
          end
        end
      end

      private

      # ── Base ────────────────────────────────────────────────────────────

      def link_path = File.join(state_directory, 'link.json')
      def conflicts_path = File.join(state_directory, 'conflicts.json')
      def read_link = JSON.parse(File.read(link_path))

      # The base is a copy of the model and of the Ruby files. The Ruby export
      # of the model and the model generated from the Ruby are kept when they
      # are already known and otherwise produced when a later run needs them.
      def build_base(base_ruby:, generated:, ruby_source:, previous: {}, base_model: model_path)
        FileUtils.mkdir_p(state_directory, mode: 0o700)
        directory = Dir.mktmpdir('base-', state_directory)
        base_record(directory, base_ruby, generated, previous, ruby_source, base_model)
      rescue StandardError
        FileUtils.rm_rf(directory)
        raise
      end

      def base_record(directory, base_ruby, generated, previous, ruby_source, base_model = model_path)
        model = Snapshot.new(base_model, destination_root: File.join(directory, 'model'), assets: false).create
        ruby = File.join(directory, 'ruby')
        copy_tree(ruby_source, ruby)
        export = File.join(directory, 'export')
        copy_tree(base_ruby, export) if base_ruby
        generated_copy = (copy_model(generated, File.join(directory, 'generated')) if generated)
        { 'version' => VERSION, 'model' => model_path, 'ruby_root' => ruby_root, 'directory' => directory,
          'base_model' => model.fetch(:model), 'base_files' => ruby, 'base_ruby' => (export if base_ruby),
          'generated_model' => generated_copy, 'ruby_files' => digests(ruby),
          'diverged' => generated_copy ? diverged(model.fetch(:model), generated_copy) : previous.fetch('diverged', []),
          'synced_at' => Time.now.utc.iso8601 }.compact
      end

      # Produces what the plan and merge need: the generation of the base and
      # of the current Ruby when Ruby changed, the export of the base and of
      # the current model when the model changed, all in parallel.
      def prepare(link, scratch, ruby:, mendix:, root:)
        inputs = { generated_base: link['generated_model'], base_ruby: link['base_ruby'] }
        jobs = []
        if ruby
          inputs[:generated] = File.join(scratch, 'generated', File.basename(model_path))
          jobs << -> { generate(File.dirname(inputs[:generated]), root:) }
          unless inputs[:generated_base]
            inputs[:generated_base] = File.join(scratch, 'generated-base', File.basename(model_path))
            jobs << -> { generate(File.dirname(inputs[:generated_base]), root: link.fetch('base_files')) }
          end
        end
        if mendix
          inputs[:theirs] = File.join(scratch, 'export')
          jobs << -> { export(model_path, inputs[:theirs]) }
          unless inputs[:base_ruby]
            inputs[:base_ruby] = File.join(scratch, 'export-base')
            jobs << -> { export(link.fetch('base_model'), inputs[:base_ruby]) }
          end
        end
        parallel(*jobs)
        inputs
      end

      def parallel(*jobs)
        threads = jobs.map do |job|
          Thread.new do
            job.call
          rescue StandardError, ScriptError => e
            e
          end
        end
        results = threads.map(&:value)
        error = results.find { _1.is_a?(Exception) }
        raise error if error

        results
      end

      def write_link(base)
        previous = read_link if linked?
        temporary = "#{link_path}.#{SecureRandom.hex(6)}.tmp"
        File.write(temporary, JSON.generate(base))
        File.rename(temporary, link_path)
        FileUtils.rm_rf(previous['directory']) if previous
      end

      # `.mxrb/` holds MXRB-owned metadata (the native baseline and assets
      # manifest); it always mirrors the synchronized model.
      def refresh_managed(export, roots: [ruby_root])
        managed = ->(root) { each_file(root).select { _1.match?(MANAGED) } }
        incoming = managed.call(export)
        roots.each do |destination|
          (managed.call(destination) - incoming).each { FileUtils.rm_f(File.join(destination, _1)) }
          incoming.each do |path|
            source = File.join(export, path)
            target = File.join(destination, path)
            next if File.file?(target) && FileUtils.identical?(source, target)

            FileUtils.mkdir_p(File.dirname(target))
            FileUtils.cp(source, target)
          end
        end
        true
      end

      def copy_tree(source, destination)
        each_file(source).each do |path|
          FileUtils.mkdir_p(File.dirname(File.join(destination, path)))
          FileUtils.cp(File.join(source, path), File.join(destination, path))
        end
        FileUtils.mkdir_p(destination)
      end

      def copy_model(source, destination)
        Snapshot.new(source, destination_root: destination, assets: false).create.fetch(:model)
      end

      # Units where the model generated from the synchronized Ruby means
      # something different from the model itself: the Ruby projection does
      # not (yet) capture them, so they are reported rather than hidden.
      def diverged(model, generated)
        left = fingerprints(model)
        right = fingerprints(generated)
        (left.keys & right.keys).reject { left[_1] == right[_1] }.sort
      end

      # ── Ruby side ───────────────────────────────────────────────────────

      # Generates the model of the Ruby project at `root` into `directory`.
      # Error locations name the files of the linked Ruby project, whichever
      # copy was evaluated.
      def generate(directory, root: ruby_root)
        FileUtils.mkdir_p(directory)
        target = File.join(directory, File.basename(model_path))
        isolation == :sandbox ? generate_sandboxed(target, root) : generate_in_process(target, root)
      rescue RubySourceError, Protocol::Failure => e
        raise relocate(e, root)
      end

      def generate_in_process(target, root)
        entry = File.join(root, 'project.rb')
        Isolated.run(@context, roots: [root]) { evaluate_project(entry, target, root) }
      end

      # The Ruby runs in a mount/PID/network namespace that sees only a copy
      # of the project; without it the run fails instead of evaluating the
      # code unconfined.
      def generate_sandboxed(target, root)
        workspace = Dir.mktmpdir('mxrb-sync-sandbox-')
        copy_tree(root, File.join(workspace, 'ruby'))
        generated = PreviewSandbox.new(context: @context, model_name: File.basename(model_path)).generate(workspace)
        FileUtils.cp(generated, target)
        # MPR v2 keeps unit contents in the sibling mprcontents directory.
        contents = File.join(File.dirname(generated), 'mprcontents')
        FileUtils.cp_r(contents, File.dirname(target)) if File.directory?(contents)
        target
      rescue PreviewIsolationUnavailable => e
        raise Protocol::Failure.new(Protocol::TOOLCHAIN, e.message, { reason: 'isolation_unavailable' })
      ensure
        FileUtils.rm_rf(workspace) if workspace
      end

      def relocate(error, root)
        prefix = "#{File.expand_path(root)}/"
        moved = lambda do |locations|
          Array(locations).map do |location|
            file = location[:file].to_s
            relative = file.start_with?(prefix) ? file.delete_prefix(prefix) : file
            next location if relative.start_with?('/')

            location.merge(file: File.join(ruby_root, relative), path: relative)
          end
        end
        if error.is_a?(RubySourceError)
          RubySourceError.new(error.message, locations: moved.call(error.locations)).tap do
            _1.set_backtrace(error.backtrace)
          end
        else
          data = error.data
          data = data.merge(locations: moved.call(data[:locations])) if data.is_a?(Hash) && data[:locations]
          Protocol::Failure.new(error.code, error.message, data).tap { _1.set_backtrace(error.backtrace) }
        end
      end

      # The open model is exported from a snapshot with its assets, the same
      # inputs a conversion uses: caches the IDE rewrites (theme-cache) never
      # enter the Ruby project's asset manifest.
      def export(model, destination)
        return Isolated.run(@context) { export_model(model, destination) } unless File.realpath(model) == model_path

        Dir.mktmpdir('mxrb-sync-export-') do |scratch|
          snapshot = Snapshot.new(model_path, destination_root: scratch).create.fetch(:model)
          Isolated.run(@context) { export_model(snapshot, destination) }
        end
      end

      # Runs in the isolated worker: evaluates project.rb into `target`. Any
      # failure of the Ruby project is a Ruby source error with locations.
      def evaluate_project(entry, target, root)
        previous = ENV.fetch('MXRB_OUTPUT_PATH', nil)
        ENV['MXRB_OUTPUT_PATH'] = target
        Kernel.load(entry)
        raise RubySourceError, 'project.rb did not generate a model' unless File.file?(target)

        target
      rescue RubySourceError
        raise
      rescue StandardError, ScriptError => e
        raise RubySourceError.new("#{e.class}: #{e.message}", locations: Protocol.locations_for(e, [root]))
      ensure
        ENV['MXRB_OUTPUT_PATH'] = previous
      end

      def export_model(model, destination)
        Exporter.new(model, destination, mode: :mendix).export!(parallel: false)
        destination
      end

      def ruby_changes(link, root = ruby_root)
        base = link.fetch('ruby_files')
        current = digests(root)
        (base.keys | current.keys).sort.filter_map do |path|
          next if base[path] == current[path]

          change = { path:, action: if base[path].nil? then 'added'
                                    else
                                      current[path].nil? ? 'removed' : 'modified'
                                    end }
          change.merge(artifact_details(path, current[path], root))
        end
      end

      def artifact_details(path, digest, root)
        return { diagnostics: [], artifacts: [] } unless digest && path.end_with?('.rb')

        text = File.read(File.join(root, path), encoding: Encoding::UTF_8)
        { diagnostics: Artifacts.diagnostics(text, file: path), artifacts: Artifacts.declarations(text, path:) }
      end

      def digests(root)
        each_file(root).to_h { |path| [path, Digest::SHA256.file(File.join(root, path)).hexdigest] }
      end

      # One revision for the whole Ruby project: paths and contents.
      def ruby_revision(root)
        digest = Digest::SHA256.new
        digests(root).sort.each { |path, value| digest.update(path).update("\0").update(value).update("\n") }
        digest.hexdigest
      end

      def each_file(root, relative = nil, &block)
        return enum_for(:each_file, root, relative) unless block

        directory = relative ? File.join(root, relative) : root
        Dir.children(directory).sort.each do |name|
          path = relative ? File.join(relative, name) : name
          full = File.join(root, path)
          next if File.symlink?(full) || name == '.git' || name.start_with?('.mxrb-')

          if File.directory?(full)
            each_file(root, path, &block) unless SKIPPED_DIRECTORIES.include?(name)
          elsif File.file?(full)
            yield path
          end
        end
      end

      # ── Mendix side ─────────────────────────────────────────────────────

      def model_revision
        units = units_of(model_path)
        Digest::SHA256.hexdigest(units.sort.map { |id, unit| [id, unit[:container], unit[:containment], unit[:bytes]] }
                                   .then { Marshal.dump(_1) })
      end

      def units_of(path)
        mpr = IO::MprFile.open(path, readonly: true, apply_studio_compatibility: false)
        begin
          mpr.all_units.to_h do |unit|
            [unit.fetch('UnitID'), { container: unit.fetch('ContainerID'), containment: unit.fetch('ContainmentName'),
                                     bytes: mpr.content_bytes(unit).to_s.b }]
          end
        ensure
          mpr.close
        end
      end

      def fingerprints(path)
        units_of(path).transform_values { Structure.fingerprint(IO::BsonCodec.parse(_1[:bytes])) }
      end

      def mendix_changes(link)
        changed_units(units_of(link.fetch('base_model')), units_of(model_path)).map do |id, kind, document|
          { unit_id: id, action: kind, type: document['$Type'], name: document['Name'] }
        end
      end

      # [unit id, added|removed|modified, document] for units that differ.
      def changed_units(before, after)
        (before.keys | after.keys).sort.filter_map do |id|
          old = before[id]
          new = after[id]
          next if old && new && old[:bytes] == new[:bytes] && old[:container] == new[:container]

          old_document = old && IO::BsonCodec.parse(old[:bytes])
          new_document = new && IO::BsonCodec.parse(new[:bytes])
          kind = if old.nil? then 'added'
                 elsif new.nil? then 'removed'
                 else
                   next if old[:container] == new[:container] &&
                           Structure.fingerprint(old_document) == Structure.fingerprint(new_document)

                   'modified'
                 end
          [id, kind, new_document || old_document]
        end
      end

      # ── Plan ────────────────────────────────────────────────────────────

      def plan(link, inputs, root:)
        base = units_of(link.fetch('base_model'))
        working = units_of(model_path)
        mendix = changed_units(base, working).to_h { [_1[0], _1[1]] }
        before = inputs[:generated] ? units_of(inputs.fetch(:generated_base)) : {}
        after = inputs[:generated] ? units_of(inputs[:generated]) : {}
        ruby = changed_units(before, after)
        removed = inputs[:generated] ? removed_documents(link, base, root) - ruby.map(&:first) : []
        ruby += removed.map { [_1, 'removed', nil] }
        plan = { units: [], conflicts: [], mendix_units: mendix.keys,
                 ruby_units: ruby.map(&:first) }
        ruby.each do |id, kind, _document|
          case kind
          when 'added' then plan[:units] << { unit_id: id, action: 'insert', state: after.fetch(id) }
          when 'removed' then plan_removal(plan, id, base, working, mendix)
          else plan_change(plan, id, base:, working:, before:, after:, mendix:)
          end
        end
        plan
      end

      # Documents whose Ruby declaration was deleted. The native baseline
      # would restore them on generation, so their removal is explicit.
      def removed_documents(link, base, root)
        declared = lambda do |root, paths|
          paths.flat_map do |path|
            file = File.join(root, path)
            next [] unless path.end_with?('.rb') && File.file?(file)

            Artifacts.declarations(File.read(file, encoding: Encoding::UTF_8), path:)
                     .filter_map { [DOCUMENT_TYPES[_1[:kind]], _1[:qualified_name]] if DOCUMENT_TYPES.key?(_1[:kind]) }
          end
        end
        changed = ruby_changes(link, root).map { _1[:path] }
        gone = declared.call(link.fetch('base_files'), changed) - declared.call(root, changed)
        return [] if gone.empty?

        documents = document_index(base)
        gone.filter_map { documents[_1] }
      end

      # [document type, Module.Name] => unit id
      def document_index(units, documents = units.transform_values { IO::BsonCodec.parse(_1[:bytes]) })
        modules = documents.select { _2['$Type'] == 'Projects$ModuleImpl' }.transform_values { _1['Name'] }
        documents.each_with_object({}) do |(id, document), index|
          container = units.dig(id, :container)
          seen = [id]
          until modules.key?(container) || seen.include?(container) || !units.key?(container)
            seen << container
            container = units.dig(container, :container)
          end
          next unless modules.key?(container) && document['Name'].is_a?(String)

          index[[document['$Type'], "#{modules[container]}.#{document['Name']}"]] = id
        end
      end

      def plan_removal(plan, id, _base, working, mendix)
        return unless working.key?(id)

        if mendix.key?(id)
          document = IO::BsonCodec.parse(working.fetch(id)[:bytes])
          plan[:conflicts] << unit_conflict(id, document, 'removed in Ruby, changed in Mendix')
          plan[:units] << { unit_id: id, action: 'delete', conflict: plan[:conflicts].last[:id] }
        else
          plan[:units] << { unit_id: id, action: 'delete' }
        end
      end

      def plan_change(plan, id, base:, working:, before:, after:, mendix:)
        unless working.key?(id)
          change = { unit_id: id, action: 'insert', state: after.fetch(id) }
          if base.key?(id)
            plan[:conflicts] << unit_conflict(id, IO::BsonCodec.parse(after.fetch(id)[:bytes]),
                                              'changed in Ruby, removed in Mendix')
            change[:conflict] = plan[:conflicts].last[:id]
          end
          return plan[:units] << change
        end

        reference = base[id] || working[id]
        base_document = IO::BsonCodec.parse(reference[:bytes])
        old_generated = Structure.reconcile(IO::BsonCodec.parse(before.fetch(id)[:bytes]), base_document)
        new_generated = Structure.reconcile(IO::BsonCodec.parse(after.fetch(id)[:bytes]), base_document)
        ruby_operations = Structure.diff(old_generated, new_generated)
        working_document = IO::BsonCodec.parse(working.fetch(id)[:bytes])
        mendix_operations = mendix.key?(id) ? Structure.diff(base_document, working_document) : []
        nodes = Structure.index(base_document)
        operations = ruby_operations.map do |operation|
          clash = mendix_operations.find { Structure.clash?(operation, _1, nodes) }
          next { operation: } unless clash

          plan[:conflicts] << element_conflict(id, operation, clash, base_document, working_document,
                                               new_generated)
          { operation:, conflict: plan[:conflicts].last[:id] }
        end
        plan[:units] << { unit_id: id, action: 'update', document: working_document, operations: }
      end

      def unit_conflict(id, document, reason)
        { id: "unit:#{id}", kind: 'unit', unit_id: id, type: document['$Type'], name: document['Name'], reason:,
          resolutions: RESOLUTIONS }
      end

      def element_conflict(id, operation, clash, base, working, generated)
        target = %w[set remove].include?(operation[:op]) ? operation[:element] : operation[:parent]
        shown = operation[:key] unless operation[:op] == 'remove'
        { id: "element:#{id}:#{target}:#{operation[:key]}:#{operation[:op]}", kind: 'element', unit_id: id,
          type: base['$Type'], name: base['Name'], key: operation[:key], ruby_operation: operation[:op],
          mendix_operation: clash[:op], element: Structure.describe(Structure.index(base), target),
          base: value_at(base, target, shown), mendix: value_at(working, target, shown),
          ruby: value_at(generated, target, shown), resolutions: RESOLUTIONS }
      end

      def value_at(document, element_id, key)
        element = Structure.index(document)[element_id]&.element
        return { present: false } unless element

        value = key ? element[key] : element
        { present: key.nil? || element.key?(key), value: Structure.present(value) }
      end

      # ── Text merge ──────────────────────────────────────────────────────

      def merge_text(inputs, plan, root:)
        return { files: [], conflicts: [] } if plan[:mendix_units].empty?

        theirs = inputs.fetch(:theirs)
        base = inputs.fetch(:base_ruby)
        paths = (each_file(base).to_a | each_file(theirs).to_a | each_file(root).to_a).sort
        files = []
        conflicts = []
        paths.each do |path|
          merged = merge_file(path, File.join(root, path), File.join(base, path), File.join(theirs, path))
          next unless merged

          files << merged
          conflicts << file_conflict(merged) if merged[:conflicts].positive?
        end
        { files:, conflicts: }
      end

      # nil when the Ruby file stays as it is; otherwise the new content.
      def merge_file(path, ours, base, theirs)
        mine = read_optional(ours)
        original = read_optional(base)
        incoming = read_optional(theirs)
        return if incoming == original || mine == incoming
        if mine == original || path.match?(MANAGED)
          return { path:, action: incoming.nil? ? 'delete' : 'write', text: incoming, conflicts: 0 }
        end

        if [mine, original, incoming].any? { _1.nil? || !text?(_1) }
          return { path:, action: 'write', text: incoming, ours: mine, conflicts: 1, binary: true }
        end

        merged, conflicts = TextMerge.merge(original, mine, incoming)
        { path:, action: 'write', text: merged, ours: mine, base: original, theirs: incoming, conflicts: }
      end

      def read_optional(path) = File.file?(path) ? File.binread(path) : nil

      def text?(bytes) = !bytes.include?("\0") && bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?

      def file_conflict(merged)
        { id: "file:#{merged[:path]}", kind: 'file', path: merged[:path], hunks: merged[:conflicts],
          ruby: merged[:ours]&.then { text_value(_1) }, mendix: text_value(merged[:text]),
          resolutions: RESOLUTIONS }
      end

      def text_value(bytes)
        return if bytes.nil?

        text?(bytes) ? bytes.dup.force_encoding(Encoding::UTF_8) : { binary: bytes.bytesize }
      end

      # ── Writing ─────────────────────────────────────────────────────────

      # Model lock, then Ruby project lock: the model must still be at the
      # compared revision, and no Ruby file the merge rewrites may have been
      # saved since the run took its copy. Nothing is written otherwise.
      def write(plan, text, resolutions, revision, snapshot)
        entry = nil
        WriteLock.synchronize(model_path) do
          unless model_revision == revision
            raise Conflict,
                  'the model changed during synchronization; synchronize again'
          end

          WriteLock.synchronize(ruby_root) do
            check_files(text[:files], snapshot)
            changes = plan[:units].select { applicable?(_1, resolutions) }
            if changes.any?
              _result, entry = History.new(model_path, state_root: File.dirname(File.dirname(state_directory)))
                                      .record('Synchronize Ruby changes') { write_units(changes, resolutions) }
            end
            write_files(text[:files], resolutions, roots: [ruby_root, snapshot])
          end
        end
        entry
      end

      def check_files(files, snapshot)
        files.each do |file|
          current = read_optional(File.join(ruby_root, file[:path]))
          next if current == read_optional(File.join(snapshot, file[:path]))

          raise Conflict, "#{file[:path]} was saved during synchronization; synchronize again"
        end
      end

      def applicable?(change, resolutions)
        return resolutions[change[:conflict]] != 'mendix' if change[:conflict]

        change[:action] != 'update' || change[:operations].any? { resolutions[_1[:conflict]] != 'mendix' }
      end

      def write_units(changes, resolutions)
        mpr = IO::MprFile.open(model_path, readonly: false, apply_studio_compatibility: false)
        begin
          write_changes(mpr, changes, resolutions)
        ensure
          mpr.close
        end
      end

      def write_changes(mpr, changes, resolutions)
        mpr.transaction do
          changes.sort_by { _1[:action] == 'insert' ? [0, depth(changes, _1)] : [1, 0] }.each do |change|
            case change[:action]
            when 'insert'
              state = change.fetch(:state)
              mpr.insert_unit_bytes(unit_uuid: change[:unit_id], container_uuid: state[:container],
                                    containment_name: state[:containment], bson_bytes: state[:bytes])
            when 'delete' then mpr.delete_unit(change[:unit_id])
            else
              operations = change[:operations].reject { resolutions[_1[:conflict]] == 'mendix' }.map { _1[:operation] }
              mpr.update_unit(change[:unit_id], Structure.apply(change[:document], operations))
            end
          end
        end
      end

      # Inserted units are written parents first.
      def depth(changes, change)
        inserted = changes.select { _1[:action] == 'insert' }.to_h { [_1[:unit_id], _1.dig(:state, :container)] }
        level = 0
        parent = change.dig(:state, :container)
        while inserted.key?(parent) && level < inserted.size
          level += 1
          parent = inserted[parent]
        end
        level
      end

      def write_files(files, resolutions, roots:)
        return if files.empty?

        backup = File.join(state_directory, 'backups', Time.now.utc.strftime('%Y%m%dT%H%M%S%6N'))
        files.each do |file|
          target = File.join(ruby_root, file[:path])
          if File.file?(target)
            FileUtils.mkdir_p(File.dirname(File.join(backup, file[:path])))
            FileUtils.cp(target, File.join(backup, file[:path]))
          end
          text = resolved_text(file, resolutions["file:#{file[:path]}"])
          roots.each { write_file(File.join(_1, file[:path]), file[:action] == 'delete' ? nil : text) }
        end
      end

      # Replaces a file atomically, so readers never see a partial merge.
      def write_file(target, text)
        return FileUtils.rm_f(target) if text.nil?

        FileUtils.mkdir_p(File.dirname(target))
        temporary = File.join(File.dirname(target), ".mxrb-sync-#{SecureRandom.hex(6)}.tmp")
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |output|
          output.write(text)
          output.flush
          output.fsync
        end
        File.chmod(File.stat(target).mode & 0o7777, temporary) if File.file?(target)
        File.rename(temporary, target)
      ensure
        FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
      end

      def resolved_text(file, resolution)
        return file[:text] if file[:conflicts].zero? || (resolution == 'mendix' && file[:binary])
        return file[:ours] if file[:binary]

        TextMerge.merge(file[:base], file[:ours], file[:theirs], favor: resolution == 'ruby' ? :ours : :theirs).first
      end

      # ── Artifacts ───────────────────────────────────────────────────────

      # Changed artifacts with what each side did: one entry per native unit
      # (a document, or the domain model of a module for entities).
      def documents(link, ruby, mendix, conflicts)
        units = units_of(link.fetch('base_model'))
        index = artifact_index(units)
        names = index.invert
        entries = Hash.new do |hash, id|
          type, name = names[id] || [nil, nil]
          hash[id] = { unit_id: id, type:, qualified_name: name, ruby: nil, mendix: nil, files: [],
                       diagnostics: [], conflicts: [] }
        end
        ruby.each do |file|
          file[:artifacts].filter_map { artifact_unit(index, _1) }.uniq.each do |id|
            entries[id][:ruby] = file[:action]
            entries[id][:files] << file[:path]
            entries[id][:diagnostics].concat(file[:diagnostics])
          end
        end
        mendix.each do |change|
          entry = entries[change[:unit_id]]
          entry[:mendix] = change[:action]
          entry[:type] ||= change[:type]
          entry[:qualified_name] ||= change[:name]
        end
        conflicts.each do |conflict|
          ids = if conflict[:unit_id] then [conflict[:unit_id]]
                else entries.values.select { _1[:files].include?(conflict[:path]) }.map { _1[:unit_id] }
                end
          ids.each { entries[_1][:conflicts] << conflict[:id] }
        end
        entries.values.map { _1.merge(state: document_state_of(_1)) }
               .sort_by { [_1[:qualified_name].to_s, _1[:unit_id]] }
      end

      def document_state_of(entry)
        if entry[:conflicts].any? then 'conflict'
        elsif entry[:diagnostics].any? { _1[:severity] == 'error' } then 'conversion_error'
        elsif entry[:ruby] || entry[:mendix] then 'pending'
        else 'synced'
        end
      end

      # Units a Ruby file declares, read from the file as it is now (or from
      # the base when it was removed).
      def declared_units(link, path)
        declared_units_in(link.fetch('base_model'), [ruby_root, link.fetch('base_files')], path)
      end

      def declared_units_in(model, roots, path)
        file = roots.map { File.join(_1, path) }.find { File.file?(_1) }
        return [] unless file && path.end_with?('.rb')

        index = artifact_index(units_of(model))
        Artifacts.declarations(File.read(file, encoding: Encoding::UTF_8), path:)
                 .filter_map { artifact_unit(index, _1) }.uniq
      end

      def artifact_unit(index, artifact)
        if %w[entity dto].include?(artifact[:kind])
          index[['DomainModels$DomainModel', artifact[:qualified_name].split('.').first]]
        elsif DOCUMENT_TYPES.key?(artifact[:kind])
          index[[DOCUMENT_TYPES[artifact[:kind]], artifact[:qualified_name]]]
        end
      end

      # document_index plus each module's domain model, keyed by module name.
      def artifact_index(units)
        documents = units.transform_values { IO::BsonCodec.parse(_1[:bytes]) }
        index = document_index(units, documents)
        modules = documents.select { _2['$Type'] == 'Projects$ModuleImpl' }.transform_values { _1['Name'] }
        documents.each do |id, document|
          container = units.dig(id, :container)
          next unless document['$Type'] == 'DomainModels$DomainModel' && modules.key?(container)

          index[['DomainModels$DomainModel', modules[container]]] = id
        end
        index
      end

      # ── Conflicts ───────────────────────────────────────────────────────

      def normalize_resolutions(resolutions)
        raise ArgumentError, 'resolutions must be an object' unless resolutions.is_a?(Hash)

        resolutions.to_h do |id, choice|
          raise ArgumentError, "resolution for #{id} must be ruby or mendix" unless RESOLUTIONS.include?(choice)

          [id.to_s, choice]
        end
      end

      def normalize_revisions(revisions)
        return if revisions.nil?

        valid = revisions.is_a?(Hash) && revisions.keys.map(&:to_s).sort == %w[model ruby] &&
                revisions.values.all? { _1.is_a?(String) && _1.match?(/\A[0-9a-f]{64}\z/) }
        raise ArgumentError, 'expected_revisions requires model and ruby SHA-256 strings' unless valid

        revisions.transform_keys(&:to_s)
      end

      # Conflicts of the last run; they describe the revisions they were found
      # at and are dropped once either side changes again.
      def read_conflicts(revisions)
        return [] unless File.file?(conflicts_path)

        stored = JSON.parse(File.read(conflicts_path), symbolize_names: true)
        return [] unless stored.is_a?(Hash) && stored[:revisions]&.transform_keys(&:to_s) == revisions

        stored.fetch(:conflicts, [])
      rescue JSON::ParserError
        []
      end

      def write_conflicts(conflicts, revisions)
        FileUtils.mkdir_p(state_directory, mode: 0o700)
        temporary = "#{conflicts_path}.#{SecureRandom.hex(6)}.tmp"
        File.write(temporary, JSON.generate({ revisions:, conflicts: }))
        File.rename(temporary, conflicts_path)
      end

      def clear_conflicts = FileUtils.rm_f(conflicts_path)

      def with_progress(label, &)
        @context.with_progress(label, &)
      end
    end
  end
end
# rubocop:enable Metrics
