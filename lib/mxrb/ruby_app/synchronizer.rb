# frozen_string_literal: true

require_relative 'synchronizer/document_synchronization'
require_relative 'synchronizer/entity_synchronization'

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Applies the reversible Ruby domain contract to a generated MPR. Anything
    # outside this contract remains in the native sidecar and is never dropped.
    class Synchronizer
      include DocumentSynchronization
      include EntitySynchronization

      def initialize(root, target, manifest: Manifest.load(root), rebase_member_identities: false)
        @root = File.expand_path(root)
        @target = File.expand_path(target)
        @manifest = manifest
        @rebase_member_identities = rebase_member_identities
      end

      def synchronize!
        Registry.reset!
        project = Model::Project.open(@target, readonly: false)
        Environment.load(root: @root).with do
          identity_project = project if @rebase_member_identities
          @source_identities = RubyApp.load_sources(@manifest, member_identity_project: identity_project)
        end
        @source_identities.validate_entity_names!
        DatasetSynchronizer.new(project, @manifest).synchronize!
        preflight_regular_expressions!(project)
        synchronize_regular_expression_definitions(project)
        synchronize_constant_definitions(project)
        synchronize_enumeration_definitions(project)
        synchronize_module_security(project)
        synchronize_project_security(project)
        synchronize_entity_structures(project, existing_only: true)
        synchronize_entity_access(project, existing_only: true)
        synchronize_entities(project)
        synchronize_entity_structures(project, existing_only: false)
        synchronize_entity_access(project, existing_only: false)
        synchronize_associations(project)
        synchronize_entity_behaviors(project)
        prune_constants(project)
        prune_enumerations(project)
        synchronize_native_documents(project)
        synchronize_scheduled_events(project)
        @source_identities.reconcile!(project)
        finalize_studio_schema!(project)
        project.close
        project = nil
        embed_sources!
        @target
      ensure
        project&.close
      end

      private

      def finalize_studio_schema!(project)
        return if StudioCompatibility.new(project.mendix_version).schema_hash.empty?

        project.mpr.transaction do
          project.mpr.apply_studio_compatibility!
          project.mpr.update_version!(project.mendix_version)
        end
      end

      def embed_sources!
        files = RubyApp.source_bundle(@root)
        files << @source_identities.bundle if @source_identities
        mpr = IO::MprFile.open(@target, readonly: false)
        mpr.transaction { mpr.write_ruby_app_sources(files) }
      ensure
        mpr&.close
      end

      def module_name(qualified)
        qualified_parts(qualified).first
      end

      def qualified_parts(name)
        parts = name.to_s.split('.', 2)
        raise ValidationError, "Ruby model name must be Module.Entity: #{name}" unless parts.size == 2

        parts
      end
    end
    # rubocop:enable Metrics
  end
end
