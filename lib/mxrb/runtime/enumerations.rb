# frozen_string_literal: true

require_relative 'languages'
require_relative 'system_metamodel'

module Mxrb
  module Runtime
    # The enumerations of a project as a microflow sees them. An enumeration
    # attribute holds the key of its value, as the Mendix Runtime stores it, and the
    # literal Module.Enumeration.key evaluates to that key; getCaption finds the
    # enumeration the key belongs to through the literal or the attribute.
    class Enumerations
      # The key of an enumeration value, which still knows its enumeration.
      class Value < String
        attr_reader :enumeration

        def initialize(key, enumeration)
          super(key)
          @enumeration = enumeration
        end
      end

      def initialize(project)
        @project = project
        @values = {}
        @attributes = {}
      end

      # The value Module.Enumeration.key names, or nil for any other identifier.
      def literal(text)
        enumeration, separator, key = text.to_s.rpartition('.')
        return if separator.empty? || !values(enumeration).key?(key)

        Value.new(key, enumeration)
      end

      # The value an enumeration attribute holds, knowing its enumeration; the
      # qualified text earlier versions of mxrb stored reads as its key.
      def attribute_value(entity, member, value)
        return value unless value.is_a?(String) && !value.is_a?(Value)

        enumeration = attribute_enumeration(entity, member)
        return value unless enumeration

        Value.new(value.delete_prefix("#{enumeration}."), enumeration)
      end

      # getCaption: the caption in the default language; getKey: the key.
      def text(function, value)
        return '' if value.nil? || value == ''

        value = known(value)
        return value.to_s.split('.').last.to_s if function == 'getkey' || !value.is_a?(Value)

        caption(value)
      end

      private

      def known(value) = value.is_a?(String) && !value.is_a?(Value) ? literal(value) || value : value

      def caption(value)
        captions = values(value.enumeration).fetch(value.to_s, {})
        captions[language] || captions['en_US'] || captions.values.first || value.to_s
      end

      def language
        @language ||= Languages.settings(@project).fetch('default', '').to_s
      end

      # { key => { language => caption } } of an enumeration.
      def values(enumeration)
        @values[enumeration] ||= if @project.respond_to?(:enumeration_values)
                                   @project.enumeration_values(enumeration)
                                 else
                                   model_values(enumeration)
                                 end || system_values(enumeration)
      end

      def model_values(enumeration)
        module_name, name = enumeration.split('.', 2)
        mod = @project.modules.find { _1.name == module_name }
        document = mod.respond_to?(:enumerations) && mod.enumerations.find { _1['Name'].to_s == name }
        return unless document

        items(document['Values']).to_h { [_1['Name'].to_s, captions(_1['Caption'])] }
      end

      def captions(text)
        items(text.is_a?(Hash) ? text['Items'] : nil).to_h { [_1['LanguageCode'].to_s, _1['Text'].to_s] }
      end

      def system_values(enumeration)
        SystemMetamodel.enumerations(@project.mendix_version).fetch(enumeration, []).to_h do |value|
          [value.fetch('id'), { 'en_US' => value.fetch('caption').to_s }]
        end
      rescue StandardError
        {}
      end

      def attribute_enumeration(entity, member)
        key = [entity, member]
        return @attributes[key] if @attributes.key?(key)

        @attributes[key] = find_attribute_enumeration(entity, member)
      end

      def find_attribute_enumeration(entity, member, seen = {})
        return if entity.to_s.empty? || seen[entity]

        seen[entity] = true
        definition = entity_definition(entity)
        attribute = definition&.attributes&.find { _1.name == member }
        return qualified_enumeration(entity, attribute) if attribute

        find_attribute_enumeration(definition.generalization_target.to_s, member, seen) if definition
      end

      # A reference by name inside the entity's module may leave the module out.
      def qualified_enumeration(entity, attribute)
        enumeration = attribute.respond_to?(:enumeration) ? attribute.enumeration.to_s : ''
        return if enumeration.empty?

        enumeration.include?('.') ? enumeration : "#{entity.split('.').first}.#{enumeration}"
      end

      def entity_definition(entity)
        module_name, name = entity.to_s.split('.', 2)
        @project.modules.find { _1.name == module_name }&.entities&.find { _1.name == name }
      end

      def items(value)
        return [] if value.nil?

        IO::BsonCodec.parse_array(value).fetch(:items).select { _1.is_a?(Hash) }
      end
    end
  end
end
