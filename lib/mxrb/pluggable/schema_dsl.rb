# frozen_string_literal: true

require_relative 'catalog'

module Mxrb
  module Pluggable
    class ReturnTypeBuilder
      def initialize(kind)
        @kind = kind.to_s
        @list = false
        @entity_property = ''
        @assignable_to = ''
      end

      def list! = (@list = true)
      def entity_property(value) = (@entity_property = value.to_s)
      def assignable_to(value) = (@assignable_to = value.to_s)
      def build = ReturnType.new(@kind, @list, @entity_property.freeze, @assignable_to.freeze)
    end

    class PropertyTypeBuilder # rubocop:disable Metrics/ClassLength
      def initialize(key, kind)
        @key = key.to_s
        @kind = camelize(kind)
        @category = @caption = @description = @prompt = ''
        @default_property = @list = @linked = @metadata = false
        @allow_non_persistable = @parameter_list = @multiline = false
        @required = @set_label = @allow_upload = false
        @entity_property = @default_value = @on_change_property = ''
        @data_source_property = @selectable_objects_property = ''
        @path_kind = 'No'
        @path_type = @default_type = 'None'
        @attribute_types = []
        @association_types = []
        @selection_types = []
        @enumeration_values = []
        @action_variables = []
        @translations = []
      end

      %i[category caption description prompt entity_property default_value
         on_change_property data_source_property selectable_objects_property].each do |field|
        define_method(field) { |value| instance_variable_set("@#{field}", value.to_s) }
      end

      def default_property! = (@default_property = true)
      def list! = (@list = true)
      def linked! = (@linked = true)
      def metadata! = (@metadata = true)
      def allow_non_persistable_entities! = (@allow_non_persistable = true)
      def parameter_list! = (@parameter_list = true)
      def multiline! = (@multiline = true)
      def required! = (@required = true)
      def set_label! = (@set_label = true)
      def allow_upload! = (@allow_upload = true)
      def path(kind, type = 'None') = (@path_kind, @path_type = camelize(kind), camelize(type))
      def default_type(value) = (@default_type = camelize(value))
      def attribute_type(value) = (@attribute_types << camelize(value))
      def association_type(value) = (@association_types << camelize(value))
      def selection_type(value) = (@selection_types << camelize(value))
      def choice(key, caption) = (@enumeration_values << EnumerationValue.new(key.to_s, caption.to_s))
      def translation(language, text) = (@translations << Translation.new(language.to_s, text.to_s))

      def action_variable(key, kind, caption)
        @action_variables << ActionVariable.new(key.to_s, camelize(kind), caption.to_s)
      end

      def return_type(kind, &block)
        builder = ReturnTypeBuilder.new(camelize(kind))
        builder.instance_eval(&block) if block
        @return_type = builder.build
      end

      def properties(&block)
        builder = ObjectTypeBuilder.new
        builder.instance_eval(&block) if block
        @object_type = builder.build
      end

      def build # rubocop:disable Metrics/MethodLength
        value_type = ValueType.new(
          kind: @kind.freeze, list: @list, linked: @linked, metadata: @metadata,
          entity_property: @entity_property.freeze,
          allow_non_persistable_entities: @allow_non_persistable,
          path_kind: @path_kind.freeze, path_type: @path_type.freeze,
          parameter_list: @parameter_list, multiline: @multiline,
          default_value: @default_value.freeze, required: @required,
          on_change_property: @on_change_property.freeze,
          data_source_property: @data_source_property.freeze,
          selectable_objects_property: @selectable_objects_property.freeze,
          attribute_types: @attribute_types.freeze, association_types: @association_types.freeze,
          selection_types: @selection_types.freeze,
          enumeration_values: @enumeration_values.freeze, action_variables: @action_variables.freeze,
          object_type: @object_type, return_type: @return_type, translations: @translations.freeze,
          set_label: @set_label, default_type: @default_type.freeze, allow_upload: @allow_upload
        )
        PropertyType.new(
          key: @key.freeze, ruby_name: Forms::Naming.ruby_name(@key).freeze,
          category: @category.freeze, caption: @caption.freeze,
          description: @description.freeze, prompt: @prompt.freeze,
          default: @default_property, value_type:
        )
      end

      private

      def camelize(value)
        text = value.to_s
        return text if text.match?(/[A-Z]/) && !text.include?('_')

        text.split('_').map(&:capitalize).join
      end
    end

    class ObjectTypeBuilder
      def initialize = (@properties = [])

      def property(key, kind, &block)
        builder = PropertyTypeBuilder.new(key, kind)
        builder.instance_eval(&block) if block
        @properties << builder.build
      end

      def build = ObjectType.new(@properties.freeze)
    end

    class WidgetTypeBuilder
      def initialize(id)
        @id = id.to_s
        @name = @description = @prompt = @studio_pro_category = @studio_category = ''
        @platform = 'Web'
        @offline = @needs_context = @plugin = false
        @help_url = ''
        @object_type = ObjectType.new([].freeze)
      end

      %i[name description prompt studio_pro_category studio_category help_url].each do |field|
        define_method(field) { |value| instance_variable_set("@#{field}", value.to_s) }
      end

      def platform(value) = (@platform = value.to_s)
      def offline! = (@offline = true)
      def needs_context! = (@needs_context = true)
      def plugin! = (@plugin = true)

      def properties(&block)
        builder = ObjectTypeBuilder.new
        builder.instance_eval(&block) if block
        @object_type = builder.build
      end

      def build
        WidgetType.new(
          id: @id.freeze, name: @name.freeze, description: @description.freeze,
          prompt: @prompt.freeze, studio_pro_category: @studio_pro_category.freeze,
          studio_category: @studio_category.freeze, platform: @platform.freeze,
          offline: @offline, needs_context: @needs_context, plugin: @plugin,
          help_url: @help_url.freeze, object_type: @object_type
        )
      end
    end

    def self.widget_type(widget_id, catalog: Catalog.default, &block)
      builder = WidgetTypeBuilder.new(widget_id)
      builder.instance_eval(&block) if block
      catalog.register(builder.build)
    end
  end
end
