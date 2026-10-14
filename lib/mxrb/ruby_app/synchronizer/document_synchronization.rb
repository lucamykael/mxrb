# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Synchronizer
      # rubocop:disable Metrics
      # Synchronizes regular expressions, constants, enumerations, security, scheduled events and native documents.
      module DocumentSynchronization
        private

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
      end
      # rubocop:enable Metrics
    end
  end
end
