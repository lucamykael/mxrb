# frozen_string_literal: true

module Mxrb
  module Compiler
    # The type of every attribute a project can show: the ones its domain
    # models declare, the dates Mendix keeps for an entity, and the attributes
    # of the System module as the metamodel of the version lists them.
    class AttributeTypeIndex
      include ModelValues

      # The date attributes Mendix adds to an entity whose generalization asks for them.
      SYSTEM_DATES = { 'HasCreatedDateAttr' => 'createdDate', 'HasChangedDateAttr' => 'changedDate' }.freeze

      def initialize(source)
        @source = source
      end

      # The type name of a qualified attribute, such as String or DateTime, or nil.
      def type(qualified_name)
        entity, _, attribute = qualified_name.to_s.rpartition('.')
        types.dig(entity, attribute)
      end

      private

      def types
        @types ||= system_types.merge(project_types)
      end

      def project_types
        @source.units_of('DomainModels$DomainModel').each_with_object({}) do |unit, types|
          array(unit.document['Entities']).each do |entity|
            types["#{unit.module_name}.#{entity['Name']}"] = entity_types(entity)
          end
        end
      end

      def entity_types(entity)
        declared = array(entity['Attributes']).to_h { [_1['Name'].to_s, attribute_type(_1)] }
        generalization = entity['MaybeGeneralization'] || {}
        SYSTEM_DATES.each { |flag, name| declared[name] = 'DateTime' if generalization[flag] == true }
        declared
      end

      def attribute_type(attribute)
        type = (attribute['NewType'] || attribute['Type'] || {})['$Type'].to_s
        type.delete_prefix('DomainModels$').delete_suffix('AttributeType')
      end

      def system_types
        Runtime::SystemMetamodel.for(@source.version).fetch('objects').to_h do |object|
          [object['name'], object.fetch('primitives').to_h { [_1['name'], _1['type']] }]
        end
      end
    end
  end
end
