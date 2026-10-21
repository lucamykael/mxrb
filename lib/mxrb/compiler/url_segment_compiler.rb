# frozen_string_literal: true

module Mxrb
  module Compiler
    # Compiles the URL of a page as the Runtime routes it: its literal parts and
    # a segment for each {Parameter} or {Parameter/Attribute}, as MxBuild splits it.
    class UrlSegmentCompiler
      include ModelValues

      def initialize(source)
        @entities = entity_index(source)
      end

      def segments(page)
        parameters = array(page['Parameters']).to_h { [_1['Name'].to_s, _1] }
        page['Url'].to_s.split(/(\{[^}]*\})/).reject(&:empty?).each_with_index.map do |part, index|
          id = derived_id(page, "url-#{index}")
          next { '$ID' => id, '$Type' => 'Url$StaticUrlSegment', 'Segment' => part } unless part.start_with?('{')

          parameter_segment(page, part[1..-2], parameters, id)
        end
      end

      private

      def parameter_segment(page, reference, parameters, id)
        name, attribute = reference.split('/', 2)
        parameter = parameters.fetch(name) do
          raise CompilationError, "the URL of page #{page['Name']} names no parameter #{name}"
        end
        type = parameter['ParameterType'] || {}
        segment = { '$ID' => id, '$Type' => segment_type(type, attribute), 'PageParameter' => name }
        return segment unless attribute

        segment.merge('Attribute' => "#{declaring_entity(type['Entity'].to_s, attribute)}.#{attribute}")
      end

      def segment_type(type, attribute)
        if attribute then 'Forms$ParameterAttributeUrlSegment'
        elsif type['$Type'] == 'DataTypes$ObjectType' then 'Forms$ParameterIdUrlSegment'
        else 'Forms$PagePrimitiveParameterUrlSegment'
        end
      end

      # The entity that declares an attribute: the entity itself or the nearest
      # generalization that does.
      def declaring_entity(entity, attribute)
        current = entity
        seen = []
        while current && !seen.include?(current)
          return current if entity_attributes(current).include?(attribute)

          seen << current
          current = @entities.dig(current, :generalization)
        end
        entity
      end

      def entity_attributes(entity)
        return Runtime::SystemDomain::ATTRIBUTES.fetch(entity, []).map(&:first) if entity.start_with?('System.')

        @entities.dig(entity, :attributes) || []
      end

      def entity_index(source)
        return {} unless source.respond_to?(:units_of)

        source.units_of('DomainModels$DomainModel').each_with_object({}) do |unit, index|
          array(unit.document['Entities']).each do |entity|
            index["#{unit.module_name}.#{entity['Name']}"] = entity_entry(entity)
          end
        end
      end

      def entity_entry(entity)
        generalization = entity.dig('MaybeGeneralization', 'Generalization').to_s
        { attributes: array(entity['Attributes']).map { _1['Name'].to_s },
          generalization: generalization.empty? ? nil : generalization }
      end
    end
  end
end
