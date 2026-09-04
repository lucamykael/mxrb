# frozen_string_literal: true

require_relative 'schema_dsl'

module Mxrb
  module Pluggable
    # Emits portable widget-definition Ruby. Empty/default metadata is omitted,
    # while every semantic constraint and nested property remains explicit.
    class SchemaSourceEmitter
      INDENT = 2

      def emit(widget_types)
        header = "# frozen_string_literal: true\n\n"
        header + Array(widget_types).sort_by(&:id).map { widget_lines(_1).join("\n") }.join("\n\n") + "\n"
      end

      private

      def widget_lines(widget)
        lines = ["Mxrb::Pluggable.widget_type #{widget.id.inspect} do"]
        lines.concat(metadata_lines(widget, INDENT))
        lines << '  properties do'
        lines.concat(object_lines(widget.object_type, INDENT * 2))
        lines << '  end'
        lines << 'end'
      end

      def metadata_lines(widget, indent)
        values = {
          name: widget.name, description: widget.description, prompt: widget.prompt,
          studio_pro_category: widget.studio_pro_category,
          studio_category: widget.studio_category, platform: widget.platform,
          help_url: widget.help_url
        }
        lines = values.filter_map do |name, value|
          next if value.to_s.empty? || (name == :platform && value == 'Web')

          "#{pad(indent)}#{name} #{value.inspect}"
        end
        lines << "#{pad(indent)}offline!" if widget.offline
        lines << "#{pad(indent)}needs_context!" if widget.needs_context
        lines << "#{pad(indent)}plugin!" if widget.plugin
        lines
      end

      def object_lines(object_type, indent)
        object_type.properties.flat_map { property_lines(_1, indent) }
      end

      def property_lines(property, indent) # rubocop:disable Metrics/MethodLength
        type = property.value_type
        lines = ["#{pad(indent)}property #{property.key.inspect}, :#{Forms::Naming.ruby_name(type.kind)} do"]
        values = {
          category: property.category, caption: property.caption,
          description: property.description, prompt: property.prompt,
          entity_property: type.entity_property, default_value: type.default_value,
          on_change_property: type.on_change_property,
          data_source_property: type.data_source_property,
          selectable_objects_property: type.selectable_objects_property
        }
        values.each do |name, value|
          lines << "#{pad(indent + INDENT)}#{name} #{value.inspect}" unless value.to_s.empty?
        end
        lines.concat(flag_lines(property, indent + INDENT))
        lines.concat(value_collection_lines(type, indent + INDENT))
        lines.concat(nested_schema_lines(type, indent + INDENT))
        lines << "#{pad(indent)}end"
      end

      def flag_lines(property, indent)
        type = property.value_type
        flags = {
          default_property!: property.default, list!: type.list, linked!: type.linked,
          metadata!: type.metadata,
          allow_non_persistable_entities!: type.allow_non_persistable_entities,
          parameter_list!: type.parameter_list, multiline!: type.multiline,
          required!: type.required, set_label!: type.set_label, allow_upload!: type.allow_upload
        }
        lines = flags.filter_map { |name, enabled| "#{pad(indent)}#{name}" if enabled }
        lines << "#{pad(indent)}path #{type.path_kind.inspect}, #{type.path_type.inspect}" \
          unless type.path_kind == 'No' && type.path_type == 'None'
        lines << "#{pad(indent)}default_type #{type.default_type.inspect}" unless type.default_type == 'None'
        lines
      end

      def value_collection_lines(type, indent)
        lines = []
        type.attribute_types.each { lines << "#{pad(indent)}attribute_type #{_1.inspect}" }
        type.association_types.each { lines << "#{pad(indent)}association_type #{_1.inspect}" }
        type.selection_types.each { lines << "#{pad(indent)}selection_type #{_1.inspect}" }
        type.enumeration_values.each do |value|
          lines << "#{pad(indent)}choice #{value.key.inspect}, #{value.caption.inspect}"
        end
        type.action_variables.each do |value|
          lines << "#{pad(indent)}action_variable #{value.key.inspect}, " \
                   "#{value.kind.inspect}, #{value.caption.inspect}"
        end
        type.translations.each do |value|
          lines << "#{pad(indent)}translation #{value.language.inspect}, #{value.text.inspect}"
        end
        lines
      end

      def nested_schema_lines(type, indent)
        lines = []
        if type.return_type
          lines << "#{pad(indent)}return_type :#{Forms::Naming.ruby_name(type.return_type.kind)} do"
          lines << "#{pad(indent + INDENT)}list!" if type.return_type.list
          unless type.return_type.entity_property.empty?
            lines << "#{pad(indent + INDENT)}entity_property #{type.return_type.entity_property.inspect}"
          end
          unless type.return_type.assignable_to.empty?
            lines << "#{pad(indent + INDENT)}assignable_to #{type.return_type.assignable_to.inspect}"
          end
          lines << "#{pad(indent)}end"
        end
        if type.object_type
          lines << "#{pad(indent)}properties do"
          lines.concat(object_lines(type.object_type, indent + INDENT))
          lines << "#{pad(indent)}end"
        end
        lines
      end

      def pad(size) = ' ' * size
    end
  end
end
