# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'securerandom'
require 'time'
require 'tmpdir'
require_relative '../../mxrb'
require_relative 'artifacts'
require_relative 'files'
require_relative 'history'
require_relative 'isolated'
require_relative 'request_context'
require_relative 'snapshot'
require_relative 'structure'
require_relative 'write_lock'

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
    class Sync # rubocop:disable Metrics/ClassLength
      VERSION = 1
      SKIPPED_DIRECTORIES = (Files::HIDDEN_DIRECTORIES + %w[build deployment tmp]).freeze
      MANAGED = %r{\A\.mxrb/}
      RESOLUTIONS = %w[ruby mendix].freeze

      attr_reader :model_path, :ruby_root, :state_directory

      def initialize(model_path, ruby_root:, state_root:, context: RequestContext.new)
        @model_path = File.realpath(model_path)
        @ruby_root = File.realpath(ruby_root)
        raise ArgumentError, 'Ruby project root must contain project.rb' unless File.file?(entrypoint)

        @state_directory = File.join(File.expand_path(state_root), 'sync', Digest::SHA256.hexdigest(@model_path))
        @context = context
      end

      def entrypoint = File.join(ruby_root, 'project.rb')
      def linked? = File.file?(link_path)

      # Records the current model and Ruby project as the synchronized base.
      # The Ruby must generate; the Ruby files themselves are never modified.
      def link!
        with_progress('Linking Ruby project') do
          base = build_base(nil)
          write_link(base)
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
      def status # rubocop:disable Metrics/AbcSize
        return { linked: false, state: 'unlinked', model: model_path, ruby_root: } unless linked?

        link = read_link
        ruby = ruby_changes(link)
        diagnostics = ruby.flat_map { _1[:diagnostics] }
        mendix = mendix_changes(link)
        conflicts = read_conflicts
        state = if conflicts.any? then 'conflict'
                elsif diagnostics.any? then 'conversion_error'
                elsif ruby.any? || mendix.any? then 'pending'
                else 'synced'
                end
        { linked: true, state:, model: model_path, ruby_root:, synced_at: link['synced_at'],
          ruby_changes: ruby, mendix_changes: mendix, conflicts:, diverged: link.fetch('diverged', []) }
      end

      # Synchronizes both directions. `resolutions` maps conflict ids to
      # `ruby` or `mendix`; `dry_run` reports without writing anything.
      def run(resolutions: {}, dry_run: false) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        raise ArgumentError, 'Ruby project is not linked; convert or link it first' unless linked?

        resolutions = normalize_resolutions(resolutions)
        with_progress('Synchronizing Ruby and Mendix') do |progress|
          link = read_link
          revision = model_revision
          syntax = ruby_changes(link).flat_map { _1[:diagnostics] }
          raise RubySourceError.new(syntax.first[:message], locations: syntax) if syntax.any?

          progress.update(detail: 'generating the model from Ruby')
          Dir.mktmpdir('mxrb-sync-') do |scratch|
            generated = generate(File.join(scratch, 'generated'))
            plan = plan(link, generated)
            progress.update(detail: 'merging Mendix changes into Ruby')
            text = merge_text(link, plan, scratch)
            conflicts = plan[:conflicts] + text[:conflicts]
            unresolved = conflicts.reject { resolutions.key?(_1[:id]) }
            result = { dry_run:, ruby_units: plan[:ruby_units], mendix_units: plan[:mendix_units],
                       files: text[:files].map { _1.slice(:path, :action) }, conflicts: }
            if unresolved.any? || dry_run
              write_conflicts(unresolved) unless dry_run
              next result.merge(applied: false, state: unresolved.any? ? 'conflict' : 'pending')
            end

            progress.update(detail: 'writing the model and Ruby files')
            entry = write(plan, text, resolutions, revision)
            progress.update(detail: 'recording the synchronized base')
            base = build_base(text[:files].any? || plan[:ruby_units].any? ? nil : link)
            write_link(base)
            clear_conflicts
            result.merge(applied: true, state: 'synced', history: entry, diverged: base['diverged'])
          end
        end
      end

      private

      # ── Base ────────────────────────────────────────────────────────────

      def link_path = File.join(state_directory, 'link.json')
      def conflicts_path = File.join(state_directory, 'conflicts.json')
      def read_link = JSON.parse(File.read(link_path))

      def build_base(previous) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        FileUtils.mkdir_p(state_directory, mode: 0o700)
        directory = Dir.mktmpdir('base-', state_directory)
        model = Snapshot.new(model_path, destination_root: File.join(directory, 'model'), assets: false).create
        ruby = File.join(directory, 'ruby')
        export(model.fetch(:model), ruby)
        refresh_managed(ruby)
        generated = if previous && File.file?(previous.fetch('generated_model'))
                      copy_model(previous.fetch('generated_model'), File.join(directory, 'generated'))
                    else
                      generate(File.join(directory, 'generated'))
                    end
        { 'version' => VERSION, 'model' => model_path, 'ruby_root' => ruby_root, 'directory' => directory,
          'base_model' => model.fetch(:model), 'base_ruby' => ruby, 'generated_model' => generated,
          'ruby_files' => digests(ruby_root), 'diverged' => diverged(model.fetch(:model), generated, previous),
          'synced_at' => Time.now.utc.iso8601 }
      rescue StandardError
        FileUtils.rm_rf(directory) if directory
        raise
      end

      # `.mxrb/` holds MXRB-owned metadata (the native baseline and assets
      # manifest); it always mirrors the synchronized model.
      def refresh_managed(export)
        managed = ->(root) { each_file(root).select { _1.match?(MANAGED) } }
        incoming = managed.call(export)
        (managed.call(ruby_root) - incoming).each { FileUtils.rm_f(File.join(ruby_root, _1)) }
        incoming.each do |path|
          source = File.join(export, path)
          target = File.join(ruby_root, path)
          next if File.file?(target) && FileUtils.identical?(source, target)

          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(source, target)
        end
      end

      def write_link(base)
        previous = read_link if linked?
        temporary = "#{link_path}.#{SecureRandom.hex(6)}.tmp"
        File.write(temporary, JSON.generate(base))
        File.rename(temporary, link_path)
        FileUtils.rm_rf(previous['directory']) if previous && previous['directory'] != base['directory']
      end

      def copy_model(source, destination)
        Snapshot.new(source, destination_root: destination, assets: false).create.fetch(:model)
      end

      # Units where the model generated from the synchronized Ruby means
      # something different from the model itself: the Ruby projection does
      # not (yet) capture them, so they are reported rather than hidden.
      def diverged(model, generated, previous)
        return previous.fetch('diverged', []) if previous

        left = fingerprints(model)
        right = fingerprints(generated)
        (left.keys & right.keys).reject { left[_1] == right[_1] }.sort
      end

      # ── Ruby side ───────────────────────────────────────────────────────

      def generate(directory)
        FileUtils.mkdir_p(directory)
        target = File.join(directory, File.basename(model_path))
        entry = entrypoint
        Isolated.run(@context, roots: [ruby_root]) do
          ENV['MXRB_OUTPUT_PATH'] = target
          Kernel.load(entry)
          raise RubySourceError, 'project.rb did not generate a model' unless File.file?(target)

          target
        end
      end

      def export(model, destination)
        Isolated.run(@context) do
          Exporter.new(model, destination, mode: :mendix).export!(parallel: false)
          destination
        end
      end

      def ruby_changes(link) # rubocop:disable Metrics/AbcSize
        base = link.fetch('ruby_files')
        current = digests(ruby_root)
        (base.keys | current.keys).sort.filter_map do |path|
          next if base[path] == current[path]

          change = { path:, action: if base[path].nil? then 'added'
                                    else
                                      current[path].nil? ? 'removed' : 'modified'
                                    end }
          change.merge(artifact_details(path, current[path]))
        end
      end

      def artifact_details(path, digest)
        return { diagnostics: [], artifacts: [] } unless digest && path.end_with?('.rb')

        text = File.read(File.join(ruby_root, path), encoding: Encoding::UTF_8)
        { diagnostics: Artifacts.diagnostics(text, file: path), artifacts: Artifacts.declarations(text, path:) }
      end

      def digests(root)
        each_file(root).to_h { |path| [path, Digest::SHA256.file(File.join(root, path)).hexdigest] }
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
        mpr.all_units.to_h do |unit|
          [unit.fetch('UnitID'), { container: unit.fetch('ContainerID'), containment: unit.fetch('ContainmentName'),
                                   bytes: mpr.content_bytes(unit).to_s.b }]
        end
      ensure
        mpr&.close
      end

      def fingerprints(path)
        units_of(path).transform_values { Structure.fingerprint(IO::BsonCodec.parse(_1[:bytes])) }
      end

      def mendix_changes(link)
        changed_units(units_of(link.fetch('base_model')), units_of(model_path)).map do |id, kind, document|
          { unit_id: id, action: kind, type: document&.dig('$Type'), name: document&.dig('Name') }
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

      def plan(link, generated) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        base = units_of(link.fetch('base_model'))
        working = units_of(model_path)
        before = units_of(link.fetch('generated_model'))
        after = units_of(generated)
        mendix = changed_units(base, working).to_h { [_1[0], _1[1]] }
        ruby = changed_units(before, after)
        plan = { units: [], conflicts: [], mendix_units: mendix.keys,
                 ruby_units: ruby.map(&:first), working:, generated: after }
        ruby.each do |id, kind, _document|
          case kind
          when 'added' then plan[:units] << { unit_id: id, action: 'insert', state: after.fetch(id) }
          when 'removed' then plan_removal(plan, id, base, working, mendix)
          else plan_change(plan, id, base:, working:, before:, after:, mendix:)
          end
        end
        plan
      end

      def plan_removal(plan, id, base, working, mendix)
        return unless working.key?(id)

        if mendix.key?(id)
          document = IO::BsonCodec.parse(working.fetch(id)[:bytes])
          plan[:conflicts] << unit_conflict(id, document, 'removed in Ruby, changed in Mendix')
          plan[:units] << { unit_id: id, action: 'delete', conflict: plan[:conflicts].last[:id] }
        else
          plan[:units] << { unit_id: id, action: 'delete' }
        end
      end

      def plan_change(plan, id, base:, working:, before:, after:, mendix:) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
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

      def element_conflict(id, operation, clash, base, working, generated) # rubocop:disable Metrics/ParameterLists
        target = operation[:element] if operation[:op] == 'set'
        target ||= operation[:op] == 'remove' ? operation[:element] : operation[:parent]
        key = operation[:key] || operation[:op]
        { id: "element:#{id}:#{target}:#{key}:#{operation[:op]}", kind: 'element', unit_id: id,
          type: base['$Type'], name: base['Name'], key: operation[:key], ruby_operation: operation[:op],
          mendix_operation: clash[:op], element: Structure.describe(Structure.index(base), target),
          base: value_at(base, target, operation[:key]), mendix: value_at(working, target, operation[:key]),
          ruby: value_at(generated, target, operation[:key]), resolutions: RESOLUTIONS }
      end

      def value_at(document, element_id, key)
        element = Structure.index(document)[element_id]&.element
        return { present: false } unless element

        value = key ? element[key] : element
        { present: key.nil? || element.key?(key), value: Structure.present(value) }
      end

      # ── Text merge ──────────────────────────────────────────────────────

      def merge_text(link, plan, scratch) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        return { files: [], conflicts: [] } if plan[:mendix_units].empty?

        theirs = export(model_path, File.join(scratch, 'export'))
        base = link.fetch('base_ruby')
        paths = (each_file(base).to_a | each_file(theirs).to_a | each_file(ruby_root).to_a).sort
        files = []
        conflicts = []
        paths.each do |path|
          merged = merge_file(path, File.join(ruby_root, path), File.join(base, path), File.join(theirs, path))
          next unless merged

          files << merged
          conflicts << file_conflict(merged) if merged[:conflicts].positive?
        end
        { files:, conflicts: }
      end

      # nil when the Ruby file stays as it is; otherwise the new content.
      def merge_file(path, ours, base, theirs) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        mine = read_optional(ours)
        original = read_optional(base)
        incoming = read_optional(theirs)
        return if incoming == original || mine == incoming
        return { path:, action: incoming.nil? ? 'delete' : 'write', text: incoming, conflicts: 0 } if mine == original

        if path.match?(MANAGED) || [mine, original, incoming].any? { _1.nil? || !text?(_1) }
          return { path:, action: 'write', text: incoming, ours: mine, conflicts: 1, binary: true }
        end

        merged, conflicts = three_way(ours, base, theirs)
        { path:, action: 'write', text: merged, ours: mine, base: original, theirs: incoming, conflicts: }
      end

      def read_optional(path) = File.file?(path) ? File.binread(path) : nil

      def text?(bytes) = !bytes.include?("\0") && bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?

      def three_way(ours, base, theirs, favor: nil)
        arguments = ['git', 'merge-file', '-p', '-L', 'ruby', '-L', 'base', '-L', 'mendix']
        arguments << "--#{favor}" if favor
        output, errors, status = Open3.capture3(*arguments, ours, base, theirs)
        raise ToolchainError, "git merge-file failed: #{errors.strip}" if status.exitstatus.negative? ||
                                                                         status.exitstatus > 127

        [output.b, status.exitstatus]
      end

      def file_conflict(merged)
        { id: "file:#{merged[:path]}", kind: 'file', path: merged[:path], hunks: merged[:conflicts],
          ruby: merged[:ours]&.then { text_value(_1) }, mendix: text_value(merged[:text]),
          resolutions: RESOLUTIONS }
      end

      def text_value(bytes) = text?(bytes) ? bytes.dup.force_encoding(Encoding::UTF_8) : { binary: bytes.bytesize }

      # ── Writing ─────────────────────────────────────────────────────────

      def write(plan, text, resolutions, revision) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        entry = nil
        WriteLock.synchronize(model_path) do
          raise Conflict, 'the model changed during synchronization; synchronize again' unless model_revision == revision

          changes = plan[:units].select { applicable?(_1, resolutions) }
          if changes.any?
            _result, entry = History.new(model_path, state_root: File.dirname(File.dirname(state_directory)))
                                    .record('Synchronize Ruby changes') { write_units(changes, resolutions) }
          end
        end
        write_files(text[:files], resolutions)
        entry
      end

      def applicable?(change, resolutions)
        return resolutions[change[:conflict]] != 'mendix' if change[:conflict]

        change[:action] != 'update' || change[:operations].any? { resolutions[_1[:conflict]] != 'mendix' }
      end

      def write_units(changes, resolutions) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        mpr = IO::MprFile.open(model_path, readonly: false, apply_studio_compatibility: false)
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
      ensure
        mpr&.close
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

      def write_files(files, resolutions) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        return if files.empty?

        backup = File.join(state_directory, 'backups', Time.now.utc.strftime('%Y%m%dT%H%M%S%6N'))
        files.each do |file|
          target = File.join(ruby_root, file[:path])
          if File.file?(target)
            FileUtils.mkdir_p(File.dirname(File.join(backup, file[:path])))
            FileUtils.cp(target, File.join(backup, file[:path]))
          end
          text = resolved_text(file, resolutions["file:#{file[:path]}"])
          if file[:action] == 'delete' || text.nil?
            FileUtils.rm_f(target)
          else
            FileUtils.mkdir_p(File.dirname(target))
            File.binwrite(target, text)
          end
        end
      end

      def resolved_text(file, resolution)
        return file[:text] if file[:conflicts].zero? || resolution == 'mendix' && file[:binary]
        return file[:ours] if resolution == 'ruby' && file[:binary]

        Dir.mktmpdir('mxrb-merge-') do |directory|
          ours, base, theirs = %w[ours base theirs].map { File.join(directory, _1) }
          File.binwrite(ours, file[:ours])
          File.binwrite(base, file[:base])
          File.binwrite(theirs, file[:theirs])
          three_way(ours, base, theirs, favor: resolution == 'ruby' ? 'ours' : 'theirs').first
        end
      end

      # ── Conflicts ───────────────────────────────────────────────────────

      def normalize_resolutions(resolutions)
        raise ArgumentError, 'resolutions must be an object' unless resolutions.is_a?(Hash)

        resolutions.to_h do |id, choice|
          raise ArgumentError, "resolution for #{id} must be ruby or mendix" unless RESOLUTIONS.include?(choice)

          [id.to_s, choice]
        end
      end

      def read_conflicts
        File.file?(conflicts_path) ? JSON.parse(File.read(conflicts_path), symbolize_names: true) : []
      end

      def write_conflicts(conflicts)
        File.write(conflicts_path, JSON.generate(conflicts))
      end

      def clear_conflicts = FileUtils.rm_f(conflicts_path)

      def with_progress(label, &)
        @context.with_progress(label, &)
      end
    end
  end
end
