# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Applies the reversible Ruby domain contract to a generated MPR. Anything
    # outside this contract remains in the native sidecar and is never dropped.
    class Synchronizer
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

      def synchronize_entities(project)
        source_entities = @manifest.modules.flat_map do |mod|
          mod.fetch('models') + mod.fetch('dtos')
        end
        source_names = source_entities.map { _1.fetch('name') }
        registered = Registry.all(:record)

        (source_names - registered.keys).each do |name|
          plan = project.plan_remove_entity(name)
          raise ValidationError, plan.changes.join('; ') unless plan.safe?

          plan.apply!
        end
        (registered.keys - source_names).each do |name|
          implementation = registered.fetch(name)
          if project.find_artifact(name, kind: :entity)
            synchronize_entity(project, name, implementation)
          else
            add_entity(project, name, implementation)
          end
        end
        (source_names & registered.keys).each { synchronize_entity(project, _1, registered.fetch(_1)) }
      end

      def synchronize_enumeration_definitions(project)
        enumerations = Registry.all(:enumeration).values.group_by do |implementation|
          module_name(implementation.mendix_name)
        end
        return if enumerations.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        enumerations.each do |name, implementations|
          writer.synchronize_ruby_enumerations!(
            project.mpr, module_name: name,
                         enumerations: implementations.map(&:native_definition)
          )
        end
        project.refresh!
      end

      def preflight_regular_expressions!(project)
        registered = Registry.all(:regular_expression).values.group_by { module_name(_1.mendix_name) }
        sources = @manifest.modules.to_h do |mod|
          [mod.fetch('name'), mod.fetch('regular_expressions', [])]
        end
        @regular_expression_changes = {}
        return if registered.empty? && sources.values.all?(&:empty?)

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        (sources.keys + registered.keys).uniq.each do |name|
          declarations = Array(registered[name]).map(&:native_definition)
          baseline = sources.fetch(name, [])
          next if declarations.empty? && baseline.empty?

          declarations = declarations.map do |declaration|
            prior = baseline.find { _1.fetch('id').to_s == declaration[:id].to_s }
            next declaration unless prior

            absent = RegularExpression::FIELDS.values - prior.fetch('properties').keys -
                     declaration.fetch(:properties).keys
            declaration.merge(absent_properties: absent)
          end

          retained_ids = declarations.map { _1[:id].to_s }.reject(&:empty?)
          retained_names = Array(registered[name]).map(&:mendix_name)
          removed = baseline.reject do |entry|
            retained_ids.include?(entry.fetch('id').to_s) || retained_names.include?(entry.fetch('name'))
          end
          remove_ids = removed.map { _1.fetch('id') }
          plan = writer.plan_ruby_regular_expressions(project.mpr, module_name: name,
                                                                   expressions: declarations, remove_ids:)
          plan.fetch(:changes).each do |declaration, raw, previous|
            next unless previous && previous['Name'].to_s != declaration.fetch(:name).to_s

            validate_regular_expression_references!(project, raw, "#{name}.#{previous['Name']}", :rename)
          end
          removed.each do |entry|
            raw = project.mpr.unit(entry.fetch('id'))
            validate_regular_expression_references!(project, raw, entry.fetch('name'), :remove)
          end
          @regular_expression_changes[name] = { expressions: declarations, remove_ids: }
        end
      end

      def validate_regular_expression_references!(project, raw, name, operation)
        artifact = project.semantic_index.artifacts.find { _1.unit_id == raw.fetch('UnitID') }
        raise ValidationError, 'regular-expression reference baseline is unavailable' unless artifact

        incoming = project.references_to(artifact).reject { _1.source.id == artifact.id }
        explicit = project.all_units.any? do |unit|
          regular_expression_reference?(project.parse_bson(unit), name)
        end
        children = project.children_of(raw.fetch('UnitID'))
        return if incoming.empty? && !explicit && children.empty?

        raise ValidationError, "cannot #{operation} referenced regular expression #{name}"
      end

      def regular_expression_reference?(value, name)
        case value
        when Hash
          value['RegExIdentifier'] == name || value.values.any? { regular_expression_reference?(_1, name) }
        when Array then value.any? { regular_expression_reference?(_1, name) }
        else false
        end
      end

      def synchronize_regular_expression_definitions(project)
        return if @regular_expression_changes.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        @regular_expression_changes.each do |name, options|
          writer.synchronize_ruby_regular_expressions!(project.mpr, module_name: name, **options)
        end
        project.refresh!
      end

      def synchronize_constant_definitions(project)
        constants = Registry.all(:constant).values.group_by do |implementation|
          module_name(implementation.mendix_name)
        end
        return if constants.empty?

        validate_constant_renames!(project)
        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        constants.each do |name, implementations|
          writer.synchronize_ruby_constants!(
            project.mpr, module_name: name,
                         constants: implementations.map(&:native_definition)
          )
        end
        project.refresh!
      end

      def synchronize_module_security(project)
        declarations = Registry.all(:module_security).values
        return if declarations.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        declarations.each do |implementation|
          writer.synchronize_ruby_module_security!(
            project.mpr, module_name: implementation.mendix_name,
                         security: implementation.native_definition
          )
        end
        project.refresh!
      end

      def synchronize_project_security(project)
        implementation = Registry.all(:project_security).values.first
        return unless implementation

        Writer.new(@target, version: project.mendix_version, modules: [])
              .synchronize_ruby_project_security!(
                project.mpr, security: implementation.native_definition
              )
        project.refresh!
      end

      def synchronize_scheduled_events(project)
        registered = Registry.all(:scheduled_event).values.group_by do |implementation|
          module_name(implementation.mendix_name)
        end
        authoritative_modules = @manifest.modules.select do |mod|
          mod['scheduled_events_authoritative'] == true
        end
        manifest_modules = authoritative_modules.map { _1.fetch('name') }
        modules = (manifest_modules + registered.keys).uniq
        return if modules.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        modules.each do |name|
          writer.synchronize_ruby_scheduled_events!(
            project.mpr, module_name: name,
                         events: Array(registered[name]).map(&:native_definition)
          )
        end
        project.refresh!
      end

      def validate_constant_renames!(project)
        source_by_id = @manifest.modules.flat_map { _1.fetch('constants', []) }
                                .to_h { [_1.fetch('id', '').to_s, _1] }
        Registry.all(:constant).each_value do |implementation|
          id = implementation.mendix_id.to_s
          source = source_by_id[id]
          next unless source && source.fetch('name') != implementation.mendix_name

          artifact = project.find_artifact(source.fetch('name'))
          incoming = artifact ? project.references_to(artifact) : []
          next if incoming.empty?

          raise ValidationError,
                "cannot rename constant #{source.fetch('name')}: " \
                "#{incoming.size} incoming reference(s)"
        end
        nil
      end

      def prune_constants(project)
        registered = Registry.all(:constant)
        registered_ids = registered.values.map(&:mendix_id).reject(&:empty?)
        @manifest.modules.flat_map { _1.fetch('constants', []) }.each do |source|
          retained = registered.key?(source.fetch('name')) ||
                     registered_ids.include?(source.fetch('id', '').to_s)
          next if retained

          plan = project.plan_remove(source.fetch('name'))
          unless plan.safe?
            raise ValidationError,
                  "cannot remove constant #{source.fetch('name')}: " \
                  "#{plan.incoming.size} incoming reference(s), #{plan.children.size} child unit(s)"
          end

          plan.apply!
        end
      end

      def prune_enumerations(project)
        registered = Registry.all(:enumeration)
        registered_ids = registered.values.map(&:mendix_id).reject(&:empty?)
        @manifest.modules.flat_map { _1.fetch('enumerations', []) }.each do |source|
          retained = registered.key?(source.fetch('name')) ||
                     registered_ids.include?(source.fetch('id', '').to_s)
          next if retained

          attribute_references = enumeration_attribute_references(project, source.fetch('name'))
          unless attribute_references.empty?
            raise ValidationError,
                  "cannot remove enumeration #{source.fetch('name')}: incoming reference(s) from " \
                  "#{attribute_references.join(', ')}"
          end

          plan = project.plan_remove(source.fetch('name'))
          unless plan.safe?
            raise ValidationError,
                  "cannot remove enumeration #{source.fetch('name')}: " \
                  "#{plan.incoming.size} incoming reference(s), #{plan.children.size} child unit(s)"
          end

          plan.apply!
        end
      end

      def enumeration_attribute_references(project, enumeration_name)
        project.modules.flat_map do |mod|
          mod.entities.flat_map do |entity|
            entity.attributes.filter_map do |attribute|
              next unless attribute.respond_to?(:enumeration) &&
                          attribute.enumeration.to_s == enumeration_name

              "#{mod.name}.#{entity.name}/#{attribute.name}"
            end
          end
        end
      end

      def synchronize_native_documents(project)
        services = Registry.all(:service).values.select(&:native_definition)
        pages = if File.exist?(File.join(@root, '.mxrb', 'preserve_native_pages'))
                  []
                else
                  Registry.all(:page).values.select(&:native_definition)
                end
        modules = (services + pages).group_by { module_name(_1.mendix_name) }
        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        modules.each do |name, implementations|
          module_services = implementations.grep(Class).select { _1 <= Service }
          module_pages = implementations.grep(Class).select { _1 <= Page }
          writer.synchronize_ruby_documents!(
            project.mpr, module_name: name,
                         pages: module_pages.map(&:native_definition),
                         microflows: module_services.select { _1.native_kind == :microflow }
                                                    .map(&:native_definition),
                         nanoflows: module_services.select { _1.native_kind == :nanoflow }
                                                   .map(&:native_definition),
                         rules: module_services.select { _1.native_kind == :rule }.map(&:native_definition),
                         navigation_items: module_pages.filter_map(&:navigation_definition)
          )
        end
        project.refresh!
      end

      def synchronize_associations(project)
        records = Registry.all(:record).values.group_by { module_name(_1.mendix_name) }
        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        records.each do |name, implementations|
          writer.synchronize_ruby_associations!(
            project.mpr, module_name: name,
                         entities: implementations.map do |implementation|
                           {
                             name: qualified_parts(implementation.mendix_name).last,
                             associations: implementation.associations.to_a,
                             oql_view: implementation.oql_view_definition
                           }
                         end
          )
        end
        project.refresh!
      end

      def synchronize_entity_access(project, existing_only:)
        existing_names = project.modules.flat_map do |mod|
          mod.entities.map { "#{mod.name}.#{_1.name}" }
        end
        existing = existing_names.to_h { [_1, true] }
        records = Registry.all(:record).values.reject { _1.access_rules.nil? }
        records.select! { existing.key?(_1.mendix_name) } if existing_only
        records = records.group_by { module_name(_1.mendix_name) }
        return if records.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        records.each do |name, implementations|
          writer.synchronize_ruby_entity_access!(
            project.mpr, module_name: name,
                         entities: implementations.map do |implementation|
                           {
                             name: qualified_parts(implementation.mendix_name).last,
                             access_rules: implementation.access_rules
                           }
                         end
          )
        end
        project.refresh!
      end

      def synchronize_entity_structures(project, existing_only:)
        existing_names = project.modules.flat_map do |mod|
          mod.entities.map { "#{mod.name}.#{_1.name}" }
        end
        existing = existing_names.to_h { [_1, true] }
        records = Registry.all(:record).values.reject do |implementation|
          implementation.indexes.nil? && implementation.system_members.nil? &&
            implementation.generalization.nil? && implementation.oql_view_definition.nil?
        end
        records.select! { existing.key?(_1.mendix_name) } if existing_only
        records = records.group_by { module_name(_1.mendix_name) }
        return if records.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        records.each do |name, implementations|
          writer.synchronize_ruby_entity_structures!(
            project.mpr, module_name: name,
                         entities: implementations.map do |implementation|
                           {
                             name: qualified_parts(implementation.mendix_name).last,
                             indexes: implementation.indexes,
                             system_members: implementation.system_members,
                             generalization: implementation.generalization,
                             oql_view: implementation.oql_view_definition
                           }
                         end
          )
        end
        project.refresh!
      end

      def synchronize_entity_behaviors(project)
        implementations = Registry.all(:record).values.reject do |implementation|
          implementation.native_lifecycle_definitions.nil? && implementation.validation_rules.nil?
        end
        records = implementations.group_by { module_name(_1.mendix_name) }
        return if records.empty?

        writer = Writer.new(@target, version: project.mendix_version, modules: [])
        records.each do |name, implementations|
          writer.synchronize_ruby_entity_behaviors!(
            project.mpr, module_name: name,
                         entities: implementations.map do |implementation|
                           {
                             name: qualified_parts(implementation.mendix_name).last,
                             lifecycle: implementation.native_lifecycle_definitions,
                             validation_rules: implementation.validation_rules
                           }
                         end
          )
        end
        project.refresh!
      end

      def module_name(qualified)
        qualified_parts(qualified).first
      end

      def add_entity(project, name, implementation)
        module_name, entity_name = qualified_parts(name)
        attributes = implementation.attributes.to_a.map do |attribute|
          {
            name: attribute.fetch(:mendix_name), type: attribute.fetch(:type),
            default: attribute[:default], required: attribute.fetch(:required, false),
            unique: attribute.fetch(:unique, false), documentation: attribute[:documentation],
            length: attribute[:length], localize_date: attribute[:localize_date],
            enumeration: attribute[:enumeration]
          }
        end
        project.plan_add_entity(
          module_name, name: entity_name, attributes:,
                       non_persistent: implementation.persistable == false
        ).apply!
      end

      def synchronize_entity(project, name, implementation)
        artifact = project.find_artifact(name, kind: :entity)
        raise ValidationError, "entity #{name} is missing from generated MPR" unless artifact

        model = artifact.metadata.fetch(:model)
        expected_persistence = implementation.persistable != false
        if model.persistable != expected_persistence
          raise ValidationError,
                "changing persistence for #{name} is outside the reversible Ruby contract"
        end
        synchronize_attributes(project, name, model, implementation.attributes.to_a)
      end

      def synchronize_attributes(project, entity_name, entity, declarations)
        declared = declarations.to_h { [_1.fetch(:mendix_name), _1] }
        existing = entity.attributes.to_h { [_1.name, _1] }
        (existing.keys - declared.keys).each do |name|
          plan = project.plan_remove_attribute("#{entity_name}/#{name}")
          raise ValidationError, plan.changes.join('; ') unless plan.safe?

          plan.apply!
        end
        (declared.keys - existing.keys).each do |name|
          declaration = declared.fetch(name)
          project.plan_add_attribute(
            entity_name, name:, type: declaration.fetch(:type),
                         default: declaration[:default], required: declaration.fetch(:required, false),
                         unique: declaration.fetch(:unique, false),
                         documentation: declaration[:documentation], length: declaration[:length],
                         localize_date: declaration[:localize_date], enumeration: declaration[:enumeration]
          ).apply!
        end
        (declared.keys & existing.keys).each do |name|
          synchronize_attribute(project, entity_name, existing.fetch(name), declared.fetch(name))
        end
      end

      def synchronize_attribute(project, entity_name, attribute, declaration)
        updates = {}
        declared_required = declaration.fetch(:required, false)
        updates[:required] = declared_required if (attribute.required == true) != declared_required
        declared_unique = declaration.fetch(:unique, false)
        existing_unique = attribute.respond_to?(:unique) && attribute.unique == true
        updates[:unique] = declared_unique if existing_unique != declared_unique
        declared_type = declaration.fetch(:type).to_sym
        updates[:type] = declared_type if attribute.type != declared_type
        current_default = attribute.default_value.to_s
        declared_default = declaration[:default].to_s
        updates[:default] = declaration[:default] if current_default != declared_default
        if declaration.key?(:documentation)
          declared_documentation = declaration[:documentation].to_s
          existing_documentation = attribute.documentation if attribute.respond_to?(:documentation)
          updates[:documentation] = declared_documentation \
            if existing_documentation.to_s != declared_documentation
        end
        if declaration.key?(:length)
          declared_length = declaration[:length]
          declared_length = Model::Attribute::DEFAULT_STRING_LENGTH \
            if declared_type == :string && declared_length.nil?
          existing_length = attribute.length if attribute.respond_to?(:length)
          updates[:length] = declared_length if existing_length != declared_length
        end
        if declaration.key?(:localize_date)
          declared_localize_date = declaration[:localize_date]
          declared_localize_date = false if declared_type == :datetime && declared_localize_date.nil?
          existing_localize_date = attribute.localize_date if attribute.respond_to?(:localize_date)
          updates[:localize_date] = declared_localize_date \
            if existing_localize_date != declared_localize_date
        end
        if declaration.key?(:enumeration)
          existing_enumeration = attribute.enumeration if attribute.respond_to?(:enumeration)
          updates[:enumeration] = declaration[:enumeration] \
            if existing_enumeration.to_s != declaration[:enumeration].to_s
        end
        return if updates.empty?

        project.plan_change_attribute("#{entity_name}/#{attribute.name}", **updates).apply!
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
