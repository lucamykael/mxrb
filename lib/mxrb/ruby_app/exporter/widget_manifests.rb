# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # rubocop:disable Metrics
      # Builds the runtime manifests of page widgets.
      module WidgetManifests
        private

        def widget_manifest(widget)
          record_rendered_widget(widget)
          type = runtime_widget_type(widget)
          raw_options = widget.fetch(:options, {})
          options = runtime_widget_options(raw_options)
          options['native_fragment'] = native_widget_fragment_manifest(raw_options) if
            type == 'native_widget'
          value = { 'type' => type, 'name' => widget.fetch(:name, '').to_s }
          value['options'] = options unless options.empty?
          caption = options['caption']
          value['caption'] = caption unless caption.to_s.empty?
          events = runtime_value(widget.fetch(:events, []))
          value['events'] = events unless events.empty?
          children = Array(widget[:children]).map { widget_manifest(_1) }
          value['children'] = children unless children.empty?
          %i[body footer].each do |region|
            widgets = Array(widget[region]).map { widget_manifest(_1) }
            value[region.to_s] = widgets unless widgets.empty?
          end
          regions = widget[:regions]
          if regions.is_a?(Hash)
            value['regions'] = regions.to_h do |name, widgets|
              [name.to_s, Array(widgets).map { widget_manifest(_1) }]
            end
          end
          slots = Array(widget[:slots]).map do |slot|
            manifest = {
              'path' => runtime_value(slot.fetch(:path)),
              'widgets' => Array(slot[:widgets]).map { widget_manifest(_1) }
            }
            manifest['role'] = slot.fetch(:role).to_s if slot.key?(:role)
            manifest
          end
          value['slots'] = slots unless slots.empty?
          value
        end

        def runtime_widget_options(value)
          if runtime_native_widget_hash?(value)
            manifest = runtime_value(value)
            raw_options = value[:options] || value['options']
            manifest.fetch('options')['native_fragment'] = native_widget_fragment_manifest(raw_options)
            return manifest
          end

          case value
          when Hash
            record_rendered_widget(value)
            value.each_with_object({}) do |(key, child), result|
              next if key.to_s == 'deep_structure'

              result[key.to_s] = runtime_widget_options(child)
            end
          when Array then value.map { runtime_widget_options(_1) }
          else runtime_value(value)
          end
        end

        # The pluggable widget ids the rendered pages, snippets and layouts use,
        # including those nested in the options of another widget.
        def record_rendered_widget(widget)
          return unless (widget[:type] || widget['type']).to_s == 'pluggable_widget'

          options = widget[:options] || widget['options'] || {}
          widget_id = options[:widget_id] || options['widget_id']
          (@rendered_widget_ids ||= Set.new) << widget_id.to_s if widget_id
        end

        def runtime_native_widget_hash?(value)
          return false unless value.is_a?(Hash)

          type = value[:type] || value['type']
          options = value[:options] || value['options']
          type.to_s == 'native_widget' && options.is_a?(Hash)
        end

        def native_widget_fragment_manifest(options)
          deep_structure = options[:deep_structure] || options['deep_structure']
          raise SerializationError, 'native widget deep_structure must be a Hash' unless
            deep_structure.is_a?(Hash)
          raise SerializationError, 'native fragment store is not initialized' unless
            @native_fragment_store

          { 'digest' => @native_fragment_store.put(deep_structure) }
        end

        def runtime_widget_type(widget)
          type = widget.fetch(:type).to_s
          return type unless type == 'text_box'

          path = widget.dig(:options, :attribute).to_s.tr('/', '.')
          module_name, entity_name, attribute_name = path.split('.', 3)
          return type unless attribute_name

          entity = @project.modules.find { _1.name == module_name }
                           &.entities&.find { _1.name == entity_name }
          attribute = entity&.attributes&.find { _1.name == attribute_name }
          %i[integer long decimal autonumber].include?(attribute&.type) ? 'number_input' : type
        end

        def runtime_value(value)
          case value
          when BSON::Binary
            {
              '$binary' => Base64.strict_encode64(value.data),
              '$subtype' => value.type.to_s
            }
          when Hash
            value.each_with_object({}) do |(key, child), result|
              next if key.to_s == 'deep_structure'

              result[key.to_s] = runtime_value(child)
            end
          when Array then value.map { runtime_value(_1) }
          when Symbol then value.to_s
          when String, Numeric, TrueClass, FalseClass, NilClass then value
          else value.to_s
          end
        end
      end
      # rubocop:enable Metrics
    end
  end
end
