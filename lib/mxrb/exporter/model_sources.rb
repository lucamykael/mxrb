# frozen_string_literal: true

module Mxrb
  class Exporter
    # Writes entities, access rules, microflows, rules, nanoflows and repositories.
    module ModelSources
      private

      def entity_source(entity, mod, associations, metadata = nil)
        attrs = entity.attributes.map do |attr|
          options = []
          options << "default: #{ruby(attr.default_value)}" unless attr.default_value.nil? || attr.default_value == ''
          options << "documentation: #{ruby(attr.documentation)}" unless attr.documentation.to_s.empty?
          options << "length: #{attr.length}" unless attr.length.nil?
          options << "localize_date: #{attr.localize_date}" unless attr.localize_date.nil?
          options << "enumeration: #{ruby(attr.enumeration)}" unless attr.enumeration.to_s.empty?
          options << 'required: true' if attr.required
          options << 'unique: true' if attr.unique
          options << "calculated: #{ruby(attr.calculated)}" if attr.calculated
          options << 'pass_entity: false' if attr.calculated && attr.pass_entity == false
          "  #{attr.type || :string} #{symbol(attr.name)}#{options.empty? ? '' : ", #{options.join(', ')}"}"
        end
        assocs = associations.map do |assoc|
          target = mod.entities.find { _1.id == assoc.to_entity_id }&.name || assoc.to_entity_id
          qualified_target = target.to_s.include?('.') ? target : "#{mod.name}.#{target}"
          cardinality = association_cardinality(assoc)
          options = ["cardinality: #{symbol(cardinality)}"]
          # ReferenceSet does not encode ownership in the cardinality name.
          # `Both` makes the association navigable from either entity and must
          # therefore remain explicit in clean Ruby source.
          options << 'owner: :Both' if assoc.association_type == :ReferenceSet && assoc.owner == :Both
          options << "name: #{ruby(assoc.name)}"
          documentation = assoc.respond_to?(:documentation) ? assoc.documentation : nil
          options << "documentation: #{ruby(documentation)}" unless documentation.to_s.empty?
          inferred_storage = assoc.association_type == :ReferenceSet ? :Table : :Column
          storage_format = assoc.respond_to?(:storage_format) ? assoc.storage_format : nil
          options << "storage_format: #{symbol(storage_format)}" if storage_format && storage_format != inferred_storage
          parent_delete = if assoc.respond_to?(:parent_delete_behavior)
                            assoc.parent_delete_behavior
                          else
                            :NoAction
                          end
          child_delete = if assoc.respond_to?(:child_delete_behavior)
                           assoc.child_delete_behavior
                         else
                           :NoAction
                         end
          options << "parent_delete: #{symbol(parent_delete)}" unless parent_delete == :NoAction
          options << "child_delete: #{symbol(child_delete)}" unless child_delete == :NoAction
          "  association #{ruby(qualified_target)}, #{options.join(', ')}"
        end
        flags = []
        flags << '  non_persistent!' unless entity.persistable
        if oql_view_entity?(entity)
          options = []
          options << "source: #{ruby(entity.oql_source_document)}" if entity.oql_source_document
          options << "query: #{ruby(entity.oql_query)}" unless entity.oql_query.to_s.empty?
          flags << "  oql_view #{options.join(', ')}" unless options.empty?
        end
        flags << "  documentation #{ruby(entity.documentation)}" unless entity.documentation.to_s.empty?
        generalization = entity.respond_to?(:generalization_target) ? entity.generalization_target : nil
        if generalization
          native_generalization = entity.respond_to?(:generalization) ? entity.generalization : nil
          generalization_id = IO::BsonCodec.extract_id(native_generalization&.fetch('$ID', nil))
          flags << "  generalizes #{ruby(generalization)}, id: #{ruby(generalization_id)}"
        end
        system_members = entity.respond_to?(:system_members) ? entity.system_members : {}
        system_options = system_members.to_h.select { |_key, value| value }
        unless system_options.empty?
          flags << "  system_members #{system_options.map { |key, value| "#{key}: #{value}" }.join(', ')}"
        end
        indexes = entity.respond_to?(:indexes) ? entity.indexes : []
        Array(indexes).each do |index|
          indexed = IO::BsonCodec.parse_array(
            index['attributes'] || index['Attributes'] || index['IndexedAttributes']
          )[:items]
          member_declarations = indexed.map do |member|
            type = (member['type'] || member['Type'] || 'Normal').to_s
            name = exported_index_member_name(entity, member, type)
            {
              id: IO::BsonCodec.extract_id(member['$ID']), name:,
              ascending: member.fetch('ascending', member.fetch('Ascending', true)),
              type: type.to_sym
            }
          end
          members = member_declarations.map { _1.fetch(:name) }
          next if members.empty?

          directions = indexed.map { |member| member.fetch('ascending', member.fetch('Ascending', true)) }
          options = []
          index_id = IO::BsonCodec.extract_id(index['$ID'])
          guid = IO::BsonCodec.extract_id(index['GUID'])
          options << "id: #{ruby(index_id)}" if index_id
          options << "guid: #{ruby(guid)}" if guid
          options << "ascending: #{ruby(directions)}" unless directions.all?
          include_offline = index['includeInOffline'] || index['IncludeInOffline']
          options << 'include_offline: true' if include_offline
          options << "members: #{native_ruby(member_declarations)}"
          flags << "  index #{members.map { symbol(_1) }.join(', ')}, #{options.join(', ')}"
        end
        lifecycle = if entity.respond_to?(:lifecycle)
                      entity.lifecycle
                    else
                      metadata&.fetch(:lifecycle, [])
                    end
        lifecycle.to_a.each do |callback|
          flags << "  #{callback.fetch(:event)} microflow: #{ruby(callback.fetch(:handler))}, " \
                   "id: #{ruby(callback.fetch(:id, nil))}, " \
                   "pass_event_object: #{callback.fetch(:pass_event_object, true)}, " \
                   "raise_error_on_false: #{callback.fetch(:raise_error_on_false, false)}"
        end
        access_rules = Array(entity.access_rules)
        access_lines = access_rules.filter_map { |rule| access_rule_source(rule) }
        # A partial access-rule export would replace the complete native rule
        # collection. Keep the collection opaque unless every rule is editable.
        access_lines = [] unless access_lines.size == access_rules.size
        <<~RUBY
          # frozen_string_literal: true

          entity #{symbol(entity.name)} do
          #{(attrs + assocs + flags + access_lines).join("\n")}
          end
        RUBY
      end

      def association_cardinality(association)
        return :many_to_many if association.association_type == :ReferenceSet
        return :one_to_one if association.owner == :Both

        :many_to_one
      end

      def exported_index_member_name(entity, member, type)
        unless %w[Normal CreatedDate ChangedDate].include?(type)
          raise SerializationError,
                "unsupported index member type #{type} in #{entity.qualified_name}"
        end
        explicit = (member['attribute'] || member['Attribute']).to_s.split('.').last.to_s
        return explicit unless explicit.empty?
        return type unless type == 'Normal'

        pointer = IO::BsonCodec.extract_id(member['AttributePointer'])
        candidate = entity.attributes.find { _1.id.to_s == pointer }
        return candidate.name unless candidate.nil?

        raise SerializationError,
              "unresolved index attribute pointer #{pointer} in #{entity.qualified_name}"
      end

      def access_rule_source(rule)
        role_list = rule.fetch(:roles).reject { _1.to_s.empty? }
        return nil if role_list.empty?

        roles = role_list.map { ruby(_1) }.join(', ')
        opts = []
        opts << "id: #{ruby(rule.fetch(:id))}" unless rule.fetch(:id, '').to_s.empty?
        documentation = rule.fetch(:documentation, '').to_s
        opts << "documentation: #{ruby(documentation)}" unless documentation.empty?
        opts << 'create: true' if rule[:create]
        opts << 'delete: true' if rule[:delete]
        read_val = reconstruct_access(rule.fetch(:default_rights, 'None'), rule.fetch(:members, []), 'ReadOnly',
                                      'ReadWrite')
        write_val = reconstruct_access(rule.fetch(:default_rights, 'None'), rule.fetch(:members, []), 'ReadWrite', nil)
        opts << "read: #{format_access(read_val)}"   unless read_val  == :none
        opts << "write: #{format_access(write_val)}" unless write_val == :none
        opts << "default_rights: #{ruby(rule.fetch(:default_rights, 'None'))}"
        opts << "members: #{native_ruby(rule.fetch(:members, []))}"
        xpath = rule.fetch(:xpath, '')
        opts << "xpath: #{ruby(xpath)}" unless xpath.empty?
        xpath_caption = rule.fetch(:xpath_caption, nil)
        opts << "xpath_caption: #{ruby(xpath_caption)}" unless xpath_caption.nil?
        "  access_rule #{[roles, *opts].join(', ')}"
      end

      def reconstruct_access(default_rights, members, primary_rights, secondary_rights)
        if default_rights == 'ReadWrite'
          return :all if primary_rights == 'ReadWrite'
          return :all if primary_rights == 'ReadOnly'
        end
        if default_rights == 'ReadOnly'
          return :all if primary_rights == 'ReadOnly'

          explicit = members.select { _1[:rights] == primary_rights }.map { _1[:name] }
          return explicit unless explicit.empty?

          return :none
        end
        # default_rights == "None"
        explicit = members.select do |m|
          m[:rights] == primary_rights ||
            (secondary_rights && m[:rights] == secondary_rights)
        end.map { _1[:name] }
        explicit.empty? ? :none : explicit
      end

      def format_access(value)
        case value
        when :all, :none then ":#{value}"
        when Array       then "[#{value.map { symbol(_1) }.join(', ')}]"
        else ":#{value}"
        end
      end

      def unique_entity_filenames(entities, route: nil)
        suffix = route == 'dtos' ? '_dto' : nil
        unique_filenames(entities, suffix:)
      end

      def unique_filenames(entities, suffix: nil)
        used = {}
        entities.to_h do |entity|
          base = underscore(entity.name)
          base = "#{base}#{suffix}" if suffix && !base.end_with?(suffix)
          candidate = "#{base}.rb"
          sequence = 2
          while used[candidate]
            candidate = "#{base}_#{sequence}.rb"
            sequence += 1
          end
          used[candidate] = true
          [entity.id, candidate]
        end
      end

      def underscore(value)
        value.to_s
             .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
             .gsub(/([a-z\d])([A-Z])/, '\1_\2')
             .tr(' -', '__')
             .gsub(/[^a-zA-Z0-9_]/, '')
             .downcase
      end

      def microflow_source(flow, metadata = nil, internal_metadata: false, declaration: :microflow,
                           methods: true)
        parameters = flow.parameters.filter_map do |param|
          next unless param.is_a?(Hash)

          flow_parameter_source(param)
        end
        body = parameters
        return_type = if flow.respond_to?(:return_type_document) && flow.return_type_document
                        "return_type(#{flow_type_source(flow.return_type_document)})"
                      elsif flow.return_type.is_a?(String)
                        "return_type #{symbol(flow.return_type)}"
                      end
        body << "  #{return_type}" if return_type
        body << "  documentation #{ruby(flow.documentation)}" unless flow.documentation.to_s.empty?
        body << '  allow_concurrent_execution false' unless flow.allow_concurrent_execution
        apply_entity_access = flow.respond_to?(:apply_entity_access) && flow.apply_entity_access
        body << '  apply_entity_access' if apply_entity_access
        body << '  mark_as_used' if flow.mark_as_used
        body << '  excluded' if flow.excluded
        unless flow.allowed_module_roles.empty?
          body << "  allowed_roles #{flow.allowed_module_roles.map do
            symbol(_1)
          end.join(', ')}"
        end
        metadata&.fetch(:calls, [])&.each do |call|
          body << "  call #{call.fetch(:kind)}: #{symbol(call.fetch(:name))}"
        end
        metadata&.fetch(:repositories, [])&.each do |repository|
          body << "  uses_repository #{symbol(repository)}"
        end
        objects = Array(flow.objects)
        flows = Array(flow.flows)
        if editable_flow_body?(objects, flows)
          dsl_lines = body_dsl_lines(objects, flows, 2)
          body << '  annotations_authoritative' if flow_objects_contain_annotation?(objects)
          body.concat(dsl_lines)
          if internal_metadata && (fingerprint = flow_body_fingerprint(dsl_lines, flow))
            body << "  body_fingerprint #{ruby(fingerprint)}"
          end
        elsif objects.any?
          body << '  # Native body baseline retained: this graph shape has no typed DSL mapping yet'
        end
        arguments = [symbol(flow.name)]
        if declaration == :rule
          arguments << "unit_id: #{ruby(flow.id)}"
          arguments << "export_level: #{ruby(flow.export_level)}"
        elsif metadata&.fetch(:public, false)
          arguments << 'public: true'
        end
        if methods && editable_flow_body?(objects, flows)
          program = MethodFlowSource.new(body.join("\n"), captions: flow_activity_captions(flow)).source(indent: 2)
          return [
            '# frozen_string_literal: true', '',
            "#{declaration} #{arguments.join(', ')}, plan: Class.new(Mxrb::Dsl::FlowProgram) {",
            program, '}', ''
          ].join("\n")
        end
        [
          '# frozen_string_literal: true', '',
          "#{declaration} #{arguments.join(', ')} do",
          *body,
          'end', ''
        ].join("\n")
      end

      def rule_source(flow)
        microflow_source(flow, nil, declaration: :rule)
      end

      def flow_parameter_source(parameter)
        name = parameter['Name'] || parameter['name']
        type = parameter['VariableType'] || parameter['Type'] || parameter['type']
        return unless name && type

        type_source = if type.is_a?(Hash)
                        flow_type_source(type)
                      else
                        symbol(type)
                      end
        "  parameter #{symbol(name)}, type: #{type_source}"
      end

      def flow_type_spec(type)
        name = type.fetch('$Type').to_s.delete_prefix('DataTypes$').delete_suffix('Type')
        spec = { kind: underscore(name).to_sym }
        spec[:entity] = type.fetch('Entity', '') if %w[Object List].include?(name)
        spec[:enumeration] = type.fetch('Enumeration', '') if name == 'Enumeration'
        spec
      end

      def flow_type_source(type)
        spec = flow_type_spec(type)
        helper, target = case spec.fetch(:kind)
                         when :object then [:object_of, spec.fetch(:entity)]
                         when :list then [:list_of, spec.fetch(:entity)]
                         when :enumeration then [:enum_of, spec.fetch(:enumeration)]
                         end
        return symbol(spec.fetch(:kind)) unless helper

        "#{helper}(#{ruby(target)})"
      end

      def nanoflow_source(flow, metadata = nil, internal_metadata: false, methods: true)
        microflow_source(flow, metadata, internal_metadata:, methods:)
          .sub(/(^\s*)microflow /, '\1nanoflow ')
      end

      def flow_activity_captions(flow)
        return {} unless flow.is_a?(Model::Microflow)

        nested_flow_objects(Array(flow.objects)).each_with_object({}) do |object, result|
          next unless object['$Type'] == 'Microflows$ActionActivity'
          next if object['Caption'].to_s.empty?

          source = action_dsl_line(object, 0)
          next unless source

          key = MethodFlowSource.normalize(source)
          (result[key] ||= []) << object['Caption'].to_s
        end
      end

      def flow_body_fingerprint(lines, flow)
        builder = Dsl::FlowBuilder.new(
          flow.name, runtime: :server, kind: :microflow, public: false
        )
        builder.instance_eval(lines.join("\n"), @mpr_path, 1)
        definition = builder.to_h
        Dsl::FlowBuilder.body_digest(
          definition[:body], definition[:return_expression]
        )
      rescue StandardError, SyntaxError
        nil
      end

      def repositories_source(repositories)
        repositories.map do |repository|
          options = []
          options << "implementation: #{symbol(repository[:implementation])}" if repository[:implementation]
          options << 'public: true' if repository[:public]
          options << "documentation: #{ruby(repository[:documentation])}" unless repository[:documentation].to_s.empty?
          "repository #{symbol(repository.fetch(:name))}#{options.empty? ? '' : ", #{options.join(', ')}"}"
        end.join("\n") + "\n"
      end
    end
  end
end
