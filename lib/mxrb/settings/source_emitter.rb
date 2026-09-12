# frozen_string_literal: true

module Mxrb
  module Settings
    # Renders typed project settings as editable, idiomatic Ruby declarations.
    class SourceEmitter
      def emit(model)
        unless model.is_a?(Node) && model.storage_type == 'Settings$ProjectSettings'
          raise Error, 'project settings source requires a Settings::Node root'
        end

        parts = model.fetch('Settings')
        raise Error, 'project settings must contain a Settings collection' unless parts.is_a?(Collection)

        lines = ['project_settings do']
        parts.items.each { emit_node(_1, lines, 1) }
        lines << 'end'
        "#{lines.join("\n")}\n"
      end

      private

      def emit_node(node, lines, depth)
        indent = '  ' * depth
        lines << "#{indent}#{Catalog.method_for_type(node.storage_type)} do"
        node.fields.each { |field, value| emit_field(field, value, lines, depth + 1) }
        lines << "#{indent}end"
      end

      def emit_field(field, value, lines, depth)
        method = Catalog.field_method(field)
        case value
        when Collection
          emit_collection(method, value, lines, depth)
        when Node
          emit_nested_node(method, value, lines, depth)
        else
          lines << "#{'  ' * depth}#{method} #{literal(value)}"
        end
      end

      def emit_nested_node(method, node, lines, depth)
        indent = '  ' * depth
        lines << "#{indent}#{method} #{Catalog.method_for_type(node.storage_type).inspect} do"
        node.fields.each { |field, value| emit_field(field, value, lines, depth + 1) }
        lines << "#{indent}end"
      end

      def emit_collection(method, collection, lines, depth)
        indent = '  ' * depth
        if collection.items.empty?
          lines << "#{indent}#{method}"
        elsif collection.items.all? { !_1.is_a?(Node) }
          emit_scalar_collection(method, collection, lines, indent)
        else
          emit_node_collection(method, collection, lines, depth, indent)
        end
      end

      def emit_scalar_collection(method, collection, lines, indent)
        values = collection.items.map { literal(_1) }.join(', ')
        lines << "#{indent}#{method} #{values}"
      end

      def emit_node_collection(method, collection, lines, depth, indent)
        raise Error, "#{method} mixes scalar and component values" \
          unless collection.items.all? { _1.is_a?(Node) }

        lines << "#{indent}#{method} do"
        collection.items.each { emit_node(_1, lines, depth + 1) }
        lines << "#{indent}end"
      end

      def literal(value)
        case value
        when BinaryAsset
          binary_literal(value)
        when Time
          "Time.iso8601(#{value.iso8601(9).inspect})"
        else
          value.inspect
        end
      end

      def binary_literal(value)
        return "Mxrb::Settings::BinaryAsset.empty(subtype: #{value.subtype.inspect})" \
          if value.bytes.empty?
        raise Error, 'binary project setting was not externalized' if value.path.to_s.empty?

        'Mxrb::Settings::BinaryAsset.read(' \
          "File.join(__dir__, #{value.path.inspect}), subtype: #{value.subtype.inspect})"
      end
    end
  end
end
