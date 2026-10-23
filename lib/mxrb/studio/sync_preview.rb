# frozen_string_literal: true

require 'tmpdir'
require_relative 'model_operations'
require_relative 'preview_sources'
require_relative 'preview_sandbox'
require_relative 'preview_comparison'

module Mxrb
  module Studio
    # Compiles only private snapshots and returns a read-only comparison. This
    # intentionally does not establish a Sync base or offer an apply operation.
    class SyncPreview
      LIMITATIONS = [
        'Compares the saved model with compiled Ruby; unsaved editor buffers are not included.',
        'No synchronization baseline is created and bidirectional conflicts are not assessed.',
        'Compilation can normalize native defaults even when no Ruby source was edited.',
        'Element reconciliation can use name or position; this preview is not an identity-preserving apply plan.',
        'Removing Ruby declarations may leave native baseline documents in the compiled model.'
      ].freeze

      def initialize(project, context: RequestContext.new)
        @project = project
        @context = context
      end

      def run(expected_revisions: nil) # rubocop:disable Metrics/MethodLength
        validate_revisions(expected_revisions)
        @context.check!
        representation = @project.status(persist_discovery: false)
        return result('missing_project') unless representation[:state] == 'ready'

        @root = representation.fetch(:root)
        @revisions = current_revisions
        return result('stale', reason: 'revision_changed') if expected_revisions && expected_revisions != @revisions

        @context.with_progress('Previewing Ruby changes') do |progress|
          preview(progress)
        end
      rescue PreviewIsolationUnavailable => e
        result('unavailable', reason: 'isolation_unavailable', message: e.message)
      end

      private

      def preview(progress) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        workspace = Dir.mktmpdir('mxrb-sync-preview-')
        worker = File.join(workspace, 'worker')
        progress.update(detail: 'Creating private model and Ruby snapshots')
        native = Snapshot.new(@project.source_model, destination_root: File.join(workspace, 'native'),
                                                     assets: false).create
        copied = PreviewSources.new(@root, context: @context).revision(destination: File.join(worker, 'ruby'))
        unless copied == @revisions.fetch('ruby') && model_revision(native.fetch(:model)) == @revisions.fetch('model')
          return result('stale', reason: 'snapshot_changed')
        end

        progress.update(detail: 'Compiling the Ruby copy in an isolated process')
        generated = PreviewSandbox.new(context: @context, model_name: File.basename(@project.source_model))
                                  .generate(worker)
        generated = Snapshot.new(generated, destination_root: File.join(workspace, 'verified'), assets: false)
                            .create.fetch(:model)
        progress.update(detail: 'Comparing native documents')
        comparison_result(native.fetch(:model), generated)
      ensure
        FileUtils.remove_entry_secure(workspace) if workspace && File.directory?(workspace)
      end

      def comparison_result(native, generated)
        comparison = PreviewComparison.new(native, generated, context: @context).units
        validation = Mxrb.validate(generated)
        current = current_revisions
        binding = @project.status(persist_discovery: false)
        unless binding[:state] == 'ready' && binding[:root] == @root
          return result('stale', reason: 'linked_project_changed', current_root: binding[:root],
                                 units: comparison, validation: validation.to_h)
        end

        result(current == @revisions ? 'ready' : 'stale', units: comparison, current_revisions: current,
                                                          validation: validation.to_h)
      end

      def result(state, **details)
        { state:, applied: false, comparison: 'saved_model_to_generated_ruby', source_model: @project.source_model,
          root: @root, revisions: @revisions, units: [], conflicts: { assessed: false, reason: 'no_sync_baseline' },
          limitations: LIMITATIONS, **details }
      end

      def current_revisions
        @context.check!
        { 'model' => model_revision(@project.source_model),
          'ruby' => PreviewSources.new(@root, context: @context).revision }
      end

      def model_revision(path)
        ModelOperations.new(path, workspace_root: File.dirname(path)).revision
      end

      def validate_revisions(value)
        return if value.nil?
        return if value.is_a?(Hash) && value.keys.sort == %w[model ruby] &&
                  value.values.all? { _1.is_a?(String) && _1.match?(/\A[0-9a-f]{64}\z/) }

        raise ArgumentError, 'expected_revisions requires model and ruby SHA-256 strings'
      end
    end
  end
end
