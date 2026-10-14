# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Synchronizer
      # rubocop:disable Metrics
      # Synchronizes entities, associations, access rules, structures, behaviors and attributes.
      module EntitySynchronization
        private

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
      end
      # rubocop:enable Metrics
    end
  end
end
