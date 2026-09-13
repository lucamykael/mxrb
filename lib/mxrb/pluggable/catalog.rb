# frozen_string_literal: true

require_relative '../forms/catalog'

module Mxrb
  # Runtime schemas carried by pluggable-widget packages and MPR documents.
  # The public model is deliberately typed; storage pointers never leave the
  # codec boundary.
  module Pluggable
    Translation = Data.define(:language, :text)
    EnumerationValue = Data.define(:key, :caption)
    ActionVariable = Data.define(:key, :kind, :caption)
    ReturnType = Data.define(:kind, :list, :entity_property, :assignable_to) do
      def list? = list
    end

    ValueType = Data.define(
      :kind, :list, :linked, :metadata, :entity_property,
      :allow_non_persistable_entities, :path_kind, :path_type, :parameter_list,
      :multiline, :default_value, :required, :on_change_property,
      :data_source_property, :selectable_objects_property, :attribute_types,
      :association_types, :selection_types, :enumeration_values,
      :action_variables, :object_type, :return_type, :translations, :set_label,
      :default_type, :allow_upload
    ) do
      def list? = list
      def required? = required
      def object? = kind == 'Object'
      def widgets? = kind == 'Widgets'
    end

    PropertyType = Data.define(
      :key, :ruby_name, :category, :caption, :description, :prompt,
      :default, :value_type
    ) do
      def system? = value_type.kind == 'System'
    end

    ObjectType = Data.define(:properties) do
      def property(identifier)
        ruby_identifier = Forms::Naming.ruby_name(identifier)
        properties.find { _1.key == identifier.to_s } ||
          properties.find { _1.ruby_name == ruby_identifier }
      end

      def fetch_property(identifier)
        property(identifier) || raise(KeyError, "unknown pluggable property #{identifier.inspect}")
      end
    end

    WidgetType = Data.define(
      :id, :name, :description, :prompt, :studio_pro_category,
      :studio_category, :platform, :offline, :needs_context, :plugin,
      :help_url, :object_type
    )

    # A semantic registry resolves the stable widget id used in Ruby source to
    # its complete embedded/MPK schema. It never exposes physical TypePointers.
    class Catalog
      def self.default
        @default ||= new
      end

      def initialize
        @types = {}
        @revisions = Hash.new { |types, widget_id| types[widget_id] = [] }
      end

      def register(widget_type)
        raise TypeError, 'expected Pluggable::WidgetType' unless widget_type.is_a?(WidgetType)

        revisions = @revisions[widget_type.id]
        revisions << widget_type unless revisions.include?(widget_type)
        existing = @types[widget_type.id]
        merged = existing ? merge_widget_types(existing, widget_type) : widget_type
        @types[widget_type.id] = merged
        merged
      end

      def type(widget_id) = @types[widget_id.to_s]

      def fetch(widget_id)
        type(widget_id) || raise(KeyError, "unknown pluggable widget #{widget_id.inspect}")
      end

      def types = @types.values.sort_by(&:id).freeze
      def schema_definitions = @revisions.values.flatten.freeze

      # Ruby source is authored against the union of all schemas seen for a
      # stable widget id. At the MPR boundary, select the concrete embedded
      # schema that can represent this particular instance. This keeps schema
      # revisions out of application source while avoiding a synthetic union
      # that Studio Pro would flag as an outdated widget definition.
      def resolve(widget_id, object)
        candidates = @revisions[widget_id.to_s]
        return fetch(widget_id) if candidates.empty?

        compatible = candidates.select { compatible_object?(_1.object_type, object) }
        return fetch(widget_id) if compatible.empty?

        compatible.min_by { schema_excess(_1.object_type, object) }
      end

      def property_count = types.sum { count_properties(_1.object_type) }

      private

      def merge_widget_types(existing, incoming)
        incoming.with(object_type: merge_object_types(existing.object_type, incoming.object_type))
      end

      def merge_object_types(existing, incoming)
        by_key = existing.properties.to_h { [_1.key, _1] }
        incoming.properties.each do |property|
          previous = by_key[property.key]
          by_key[property.key] = previous ? merge_property_types(previous, property) : property
        end
        ObjectType.new(by_key.values.freeze)
      end

      def merge_property_types(existing, incoming)
        old_value = existing.value_type
        new_value = incoming.value_type
        return incoming unless old_value.kind == new_value.kind
        return incoming unless old_value.object_type && new_value.object_type

        incoming.with(value_type: new_value.with(
          object_type: merge_object_types(old_value.object_type, new_value.object_type)
        ))
      end

      def compatible_object?(schema, object)
        object.assignments.all? do |assignment|
          property = schema.property(assignment.property.key)
          property && property.value_type.kind == assignment.property.value_type.kind &&
            compatible_nested_value?(property.value_type, assignment.value)
        end
      end

      def compatible_nested_value?(value_type, value)
        return true unless value_type.object_type

        Array(value).compact.all? { compatible_object?(value_type.object_type, _1) }
      end

      def schema_excess(schema, object)
        assigned = object.assignments
        own = schema.properties.length - assigned.length
        nested = assigned.sum do |assignment|
          property = schema.property(assignment.property.key)
          next 0 unless property&.value_type&.object_type

          Array(assignment.value).compact.sum do |value|
            schema_excess(property.value_type.object_type, value)
          end
        end
        own + nested
      end

      def count_properties(object_type)
        object_type.properties.sum do |property|
          1 + (property.value_type.object_type ? count_properties(property.value_type.object_type) : 0)
        end
      end
    end
  end
end
