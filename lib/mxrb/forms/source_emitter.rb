# frozen_string_literal: true

require_relative 'node'

module Mxrb
  module Forms
    # Emits deterministic Ruby constructors for a typed Forms tree. It never
    # emits BSON identifiers, hashes, native fragments, or opaque sidecars.
    class SourceEmitter
      INDENT = 2

      def emit(node)
        if defined?(Mxrb::Pluggable::Node) && node.is_a?(Mxrb::Pluggable::Node)
          return "#{pluggable_node_lines(node, 0, root: true).join("\n")}\n"
        end
        raise TypeError, "expected a typed Forms widget, got #{node.class}" unless node.is_a?(Node)

        lines = node_lines(node, 0, root: true)
        "#{lines.join("\n")}\n"
      end

      def emit_as(node, declaration)
        raise TypeError, 'named Forms emission requires a Forms::Node' unless node.is_a?(Node)

        "#{node_lines(node, 0, declaration: declaration.to_s).join("\n")}\n"
      end

      private

      def node_lines(node, indent, root: false, declaration: nil)
        pad = ' ' * indent
        declaration ||= if root
                          "Mxrb::Forms.#{node.schema_type.ruby_name}"
                        else
                          node.schema_type.ruby_name
                        end
        return ["#{pad}#{declaration}"] if node.assignments.empty? && root

        body = []
        body.concat(node.assignments.flat_map { assignment_lines(_1, indent + INDENT) })
        ["#{pad}#{declaration} do", *body, "#{pad}end"]
      end

      def assignment_lines(assignment, indent)
        property = assignment.property
        value = assignment.value
        return collection_lines(property, value, indent) if property.many?
        return nested_lines(property, value, indent) if value.is_a?(Node)
        if defined?(Mxrb::Pluggable::Node) && value.is_a?(Mxrb::Pluggable::Node)
          return pluggable_node_lines(value, indent,
                                      declaration: "#{property.ruby_name}(#{value.widget_type.id.inspect})")
        end

        declaration = if value.nil?
                        "#{property.ruby_name}(nil)"
                      else
                        "#{property.ruby_name} #{literal(value)}"
                      end
        ["#{' ' * indent}#{declaration}"]
      end

      def collection_lines(property, values, indent)
        return ["#{' ' * indent}set :#{property.ruby_name}, []"] if values.empty?

        values.flat_map do |value|
          if value.is_a?(Node)
            declaration = "#{property.ruby_name}(:#{value.schema_type.ruby_name})"
            node_lines(value, indent, declaration:)
          elsif defined?(Mxrb::Pluggable::Node) && value.is_a?(Mxrb::Pluggable::Node)
            pluggable_node_lines(
              value, indent,
              declaration: "#{property.ruby_name}(#{value.widget_type.id.inspect})"
            )
          else
            ["#{' ' * indent}append :#{property.ruby_name}, #{literal(value)}"]
          end
        end
      end

      def nested_lines(property, value, indent)
        declared = property.type_name == value.schema_type.name
        type_argument = declared ? '' : "(:#{value.schema_type.ruby_name})"
        node_lines(value, indent, declaration: "#{property.ruby_name}#{type_argument}")
      end

      def pluggable_node_lines(node, indent, root: false, declaration: nil)
        pad = ' ' * indent
        declaration ||= if root
                          "Mxrb::Pluggable.widget #{node.widget_type.id.inspect}"
                        else
                          "widget #{node.widget_type.id.inspect}"
                        end
        body = node.assigned_outer.flat_map do |field, value|
          pluggable_outer_lines(field, value, indent + INDENT)
        end
        unless node.object.assignments.empty?
          body << "#{' ' * (indent + INDENT)}properties do"
          body.concat(pluggable_assignment_lines(node.object, indent + (INDENT * 2)))
          body << "#{' ' * (indent + INDENT)}end"
        end
        ["#{pad}#{declaration} do", *body, "#{pad}end"]
      end

      def pluggable_outer_lines(field, value, indent)
        return node_lines(value, indent, declaration: field.to_s) if value.is_a?(Node)

        ["#{' ' * indent}#{field} #{literal(value)}"]
      end

      def pluggable_assignment_lines(object, indent)
        object.assignments.flat_map do |assignment|
          lines = pluggable_property_lines(assignment.property, assignment.value, indent)
          if assignment.source_variable
            lines.concat(node_lines(assignment.source_variable, indent,
                                    declaration: "source(:#{assignment.property.ruby_name})"))
          end
          lines
        end
      end

      def pluggable_property_lines(property, value, indent)
        if property.value_type.widgets? || (property.value_type.object? && property.value_type.list?)
          return pluggable_collection_lines(property, value, indent)
        end
        return pluggable_object_lines(property, value, indent) if value.is_a?(Mxrb::Pluggable::ObjectNode)
        return pluggable_data_source_lines(property, value, indent) if value.is_a?(Mxrb::Pluggable::XPathSource)

        if value.is_a?(Node)
          declaration = pluggable_nested_declaration(property, type: ":#{value.schema_type.ruby_name}")
          return node_lines(value, indent, declaration:)
        end

        declaration = if pluggable_reserved_name?(property)
                        "set :#{property.ruby_name}, #{literal(value)}"
                      elsif value.nil?
                        "#{property.ruby_name}(nil)"
                      else
                        "#{property.ruby_name} #{literal(value)}"
                      end
        ["#{' ' * indent}#{declaration}"]
      end

      def pluggable_reserved_name?(property)
        klass = Mxrb::Pluggable::ObjectNode
        klass.method_defined?(property.ruby_name) ||
          klass.private_method_defined?(property.ruby_name) ||
          klass.protected_method_defined?(property.ruby_name)
      end

      def pluggable_nested_declaration(property, type: nil, collection: false)
        unless pluggable_reserved_name?(property)
          return "#{property.ruby_name}#{type ? "(#{type})" : ''}"
        end

        arguments = [":#{property.ruby_name}"]
        arguments << "type: #{type}" if type
        "#{collection ? 'append' : 'set'}(#{arguments.join(', ')})"
      end

      def pluggable_collection_lines(property, values, indent)
        return ["#{' ' * indent}set :#{property.ruby_name}, []"] if values.empty?

        values.flat_map do |value|
          case value
          when Mxrb::Pluggable::ObjectNode
            pluggable_object_lines(property, value, indent)
          when Node
            declaration = pluggable_nested_declaration(property, type: ":#{value.schema_type.ruby_name}",
                                                                 collection: true)
            node_lines(value, indent, declaration:)
          when Mxrb::Pluggable::Node
            declaration = pluggable_nested_declaration(property, type: value.widget_type.id.inspect, collection: true)
            pluggable_node_lines(value, indent, declaration:)
          else ["#{' ' * indent}append :#{property.ruby_name}, #{literal(value)}"]
          end
        end
      end

      def pluggable_object_lines(property, value, indent)
        pad = ' ' * indent
        body = pluggable_assignment_lines(value, indent + INDENT)
        declaration = pluggable_nested_declaration(property, collection: property.value_type.list?)
        ["#{pad}#{declaration} do", *body, "#{pad}end"]
      end

      def pluggable_data_source_lines(property, value, indent)
        pad = ' ' * indent
        body_indent = indent + INDENT
        body = []
        body << "#{' ' * body_indent}entity #{entity_reference_literal(value.entity)}" if value.entity
        body << "#{' ' * body_indent}constraint #{value.constraint.to_s.inspect}" if value.constraint
        body.concat(node_lines(value.sort_bar, body_indent, declaration: 'sort_bar')) if value.sort_bar
        if value.source_variable
          body.concat(node_lines(value.source_variable, body_indent, declaration: 'source_variable'))
        end
        body << "#{' ' * body_indent}force_full_objects true" if value.force_full_objects
        declaration = pluggable_nested_declaration(property)
        ["#{pad}#{declaration} do", *body, "#{pad}end"]
      end

      def literal(value)
        if defined?(Mxrb::Pluggable::Reference) && value.is_a?(Mxrb::Pluggable::Reference)
          if value.target.is_a?(EntityReference) && !value.target.indirect?
            return "Mxrb::Pluggable.reference(:#{Forms::Naming.ruby_name(value.kind)}, " \
              "Mxrb::Forms::EntityReference.direct(#{value.target.entity.inspect}))"
          end
          return "Mxrb::Pluggable.reference(:#{Forms::Naming.ruby_name(value.kind)}, #{literal(value.target)})"
        end
        if defined?(Mxrb::Pluggable::Decimal) && value.is_a?(Mxrb::Pluggable::Decimal)
          return "Mxrb::Pluggable.decimal(#{value.to_s.inspect})"
        end

        case value
        when EnumValue then ":#{value.to_sym}"
        when Reference then value.target.inspect
        when Text then text_literal(value)
        when AttributeReference then attribute_reference_literal(value)
        when EntityReference then entity_reference_literal(value)
        when Condition then condition_literal(value)
        when XPathConstraint then xpath_constraint_literal(value)
        when Expression then value.to_s.inspect
        when DataType then data_type_literal(value)
        when TextTemplate then text_template_literal(value)
        when BinaryAsset then binary_asset_literal(value)
        when Size then "Mxrb::Forms::Size.new(#{value.width}, #{value.height})"
        when String then value.inspect
        when Symbol, Integer, Float, TrueClass, FalseClass, NilClass then value.inspect
        else raise TypeError, "cannot emit Forms value #{value.class}"
        end
      end

      def data_type_literal(value)
        case value.name
        when 'Object' then "Mxrb::Forms::DataType.object(#{value.target.inspect})"
        when 'List' then "Mxrb::Forms::DataType.list(#{value.target.inspect})"
        when 'Enumeration' then "Mxrb::Forms::DataType.enumeration(#{value.target.inspect})"
        else value.name.inspect
        end
      end

      def text_literal(text)
        translations = text.translations
        return translations.first.text.inspect if translations.one? && translations.first.language.nil?

        entries = translations.map do |translation|
          "Mxrb::Forms::Translation.new(#{translation.language.inspect}, #{translation.text.inspect})"
        end
        "Mxrb::Forms::Text.coerce([#{entries.join(', ')}])"
      end

      def xpath_constraint_literal(constraint)
        return 'Mxrb::Forms::XPathConstraint.coerce([])' if constraint.clauses.empty?
        return constraint.to_s.inspect if constraint.clauses.one?

        "Mxrb::Forms::XPathConstraint.coerce(#{constraint.clauses.inspect})"
      end

      def attribute_reference_literal(reference)
        return reference.attribute.inspect unless reference.entity_reference

        "Mxrb::Forms::AttributeReference.through(#{reference.attribute.inspect}, " \
          "via: #{entity_reference_literal(reference.entity_reference)})"
      end

      def entity_reference_literal(reference)
        return reference.entity.inspect unless reference.indirect?

        steps = reference.steps.map do |step|
          "Mxrb::Forms::EntityPathStep.to(#{step.association.inspect}, " \
            "#{step.destination_entity.inspect})"
        end
        "Mxrb::Forms::EntityReference.through(#{steps.join(', ')})"
      end

      def condition_literal(condition)
        "Mxrb::Forms::Condition.when_value(#{condition.attribute_value.inspect}, " \
          "visible: #{condition.editable_visible})"
      end

      def text_template_literal(template)
        parameters = template.parameters.map { _1.expression.to_s.inspect }.join(', ')
        "Mxrb::Forms::TextTemplate.build(#{text_literal(template.text)}, parameters: [#{parameters}])"
      end

      def binary_asset_literal(asset)
        if asset.source_path.nil? && asset.bytes.empty?
          return "Mxrb::Forms::BinaryAsset.empty(subtype: #{asset.subtype.inspect})"
        end
        raise TypeError, 'binary Forms values must be exported as files before source emission' unless asset.source_path

        "Mxrb::Forms::BinaryAsset.read(File.join(__dir__, #{asset.source_path.inspect}), " \
          "subtype: #{asset.subtype.inspect})"
      end
    end
  end
end
