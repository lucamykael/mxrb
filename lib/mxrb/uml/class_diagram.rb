# frozen_string_literal: true

require_relative 'support'

module Mxrb
  module Uml
    # Projects Mendix domain models as Mermaid and PlantUML class diagrams.
    # rubocop:disable Metrics/AbcSize
    class ClassDiagram
      TYPES = {
        string: 'String', integer: 'Integer', long: 'Long', float: 'Float',
        decimal: 'Decimal', boolean: 'Boolean', datetime: 'DateTime',
        autonumber: 'AutoNumber', hashstring: 'HashedString', binary: 'Binary',
        enum: 'Enumeration'
      }.freeze

      def initialize(modules)
        @modules = Array(modules)
        @entities = @modules.flat_map(&:entities)
        @module_by_entity = @modules.each_with_object({}) do |mod, result|
          mod.entities.each { result[_1.id.to_s] = mod.name.to_s }
        end
        @entity_by_key = @entities.each_with_object({}) do |entity, result|
          qualified = qualified_name(entity)
          result[entity.id.to_s] = entity
          result[qualified] = entity
        end
      end

      def to_mermaid
        lines = ['classDiagram']
        @entities.each { append_mermaid_class(lines, _1) }
        associations.each { lines << mermaid_association(_1) }
        "#{lines.join("\n")}\n"
      end

      def to_plantuml
        lines = ['@startuml', 'hide empty methods']
        @entities.each { append_plantuml_class(lines, _1) }
        associations.each { lines << plantuml_association(_1) }
        lines << '@enduml'
        "#{lines.join("\n")}\n"
      end

      private

      def append_mermaid_class(lines, entity)
        identifier = entity_identifier(entity)
        lines << %(class #{identifier}["#{Support.mermaid_text(qualified_name(entity))}"])
        lines << "class #{identifier} {"
        entity.attributes.each do |attribute|
          lines << "  +#{attribute_type(attribute)} #{Support.mermaid_text(attribute.name)}"
        end
        lines << '}'
        stereotype(entity).then { lines << "<<#{_1}>> #{identifier}" if _1 }
      end

      def append_plantuml_class(lines, entity)
        identifier = entity_identifier(entity)
        suffix = stereotype(entity).then { _1 ? " <<#{_1}>>" : '' }
        lines << %(class "#{Support.plantuml_text(qualified_name(entity))}" as #{identifier}#{suffix} {)
        entity.attributes.each do |attribute|
          lines << "  +#{Support.plantuml_text(attribute.name)} : #{attribute_type(attribute)}"
        end
        lines << '}'
      end

      def associations
        @modules.flat_map(&:associations).filter_map do |association|
          from = @entity_by_key[association.from_entity_id.to_s]
          to = @entity_by_key[association.to_entity_id.to_s]
          [association, from, to] if from && to
        end
      end

      def mermaid_association(tuple)
        association, from, to = tuple
        left, right = multiplicities(association)
        label = Support.mermaid_text(association.name)
        %(#{entity_identifier(from)} "#{left}" --> "#{right}" #{entity_identifier(to)} : #{label})
      end

      def plantuml_association(tuple)
        association, from, to = tuple
        left, right = multiplicities(association)
        label = Support.plantuml_text(association.name)
        %(#{entity_identifier(from)} "#{left}" --> "#{right}" #{entity_identifier(to)} : #{label})
      end

      def multiplicities(association)
        association.association_type.to_sym == :ReferenceSet ? ['*', '*'] : %w[1 N]
      end

      def attribute_type(attribute)
        return Support.words(attribute.enumeration.to_s.split('.').last) unless attribute.enumeration.to_s.empty?

        TYPES.fetch(attribute.type.to_sym, Support.words(attribute.type))
      end

      def stereotype(entity)
        return 'OQL View' if entity.respond_to?(:oql_view?) && entity.oql_view?
        return 'DTO' unless entity.persistable == true

        nil
      end

      def qualified_name(entity)
        value = entity.qualified_name.to_s
        return value unless value.empty?

        "#{@module_by_entity.fetch(entity.id.to_s)}.#{entity.name}"
      end

      def entity_identifier(entity) = Support.identifier(qualified_name(entity), prefix: 'class')
    end
    # rubocop:enable Metrics/AbcSize
  end
end
