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
        @stored_units = stored_units(project.mpr)
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
        synchronize_page_edits(project)
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

      def stored_units(mpr) = mpr.all_units.to_h { [_1.fetch('UnitID'), mpr.parse_contents(_1)] }

      # The schema of the version applies to what synchronization wrote. A unit it left
      # alone stays as stored, and a rebuild of a version whose projects store exactly
      # its fields writes only those (see StoredFields).
      def finalize_studio_schema!(project)
        mpr = project.mpr
        version = project.mendix_version
        compatibility = StudioCompatibility.new(version)
        unless compatibility.schema_hash.empty?
          untouched = stored_units(mpr).select { |id, document| schema_only_change?(compatibility, id, document) }.keys
          mpr.transaction do
            mpr.apply_studio_compatibility!
            untouched.each { mpr.write_unit_as_stored(_1, @stored_units.fetch(_1)) }
            mpr.update_version!(version)
          end
        end
        project_onto_stored_fields(mpr, version)
      end

      # Synchronization rewrites documents through the schema projection, so a document
      # whose only change is that projection was not changed by the Ruby sources.
      def schema_only_change?(compatibility, id, document)
        stored = @stored_units[id]
        return false unless stored
        return true if stored == document

        compatibility.apply_document!(Marshal.load(Marshal.dump(stored))) == document
      end

      def project_onto_stored_fields(mpr, version)
        return unless StoredFields.applies_to?(version)

        fields = StoredFields.from(@stored_units.values, version:)
        mpr.transaction do
          mpr.all_units.each do |unit|
            document = mpr.parse_contents(unit)
            mpr.write_unit_as_stored(unit.fetch('UnitID'), document) if fields.project!(document)
          end
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
