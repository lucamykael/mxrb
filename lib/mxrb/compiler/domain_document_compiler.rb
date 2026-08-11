# frozen_string_literal: true

module Mxrb
  module Compiler
    # Converts domain-model documents from editor shape to Runtime shape.
    class DomainDocumentCompiler # rubocop:disable Metrics/ClassLength
      include ModelValues

      def initialize(source)
        @source = source
        domain_units = source.respond_to?(:units_of) ? source.units_of('DomainModels$DomainModel') : []
        @entities = domain_units.each_with_object({}) do |unit, result|
          array(unit.document['Entities']).each do |entity|
            result["#{unit.module_name}.#{entity['Name']}"] = entity
          end
        end
        @security = DomainSecurityCompiler.new(source)
      end

      def compile(unit) # rubocop:disable Metrics/AbcSize
        source = unit.document
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Entities' => array(source['Entities']).map { compile_entity(_1, unit.module_name) },
          'Associations' => array(source['Associations']).map { @security.association(_1, unit.module_name) },
          'CrossAssociations' => array(source['CrossAssociations']).map do |association|
            @security.association(association, unit.module_name)
          end
        }
      end

      private

      def compile_entity(source, module_name)
        name = source['Name'].to_s
        entity_content(source).merge(
          'Source' => compile_entity_source(source['Source']),
          'GUID' => source['GUID'], 'Image' => source['Image'].to_s,
          'QualifiedName' => "#{module_name}.#{name}", 'UnqualifiedName' => name
        )
      end

      def compile_entity_source(source) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        return nil unless source
        return plain_document(source) unless source['$Type'] == 'DomainModels$OqlViewEntitySource'

        qualified_name = source['SourceDocument'].to_s
        document = @source.units.find do |unit|
          unit.document['$Type'] == 'DomainModels$ViewEntitySourceDocument' &&
            "#{unit.module_name}.#{unit.document['Name']}" == qualified_name
        end
        raise CompilationError, "OQL view source #{qualified_name.inspect} not found" unless document

        source.slice('$ID', '$Type', 'SourceDocument').merge(
          'OqlRuntime' => document.document['Oql'].to_s,
          'SourceDocumentName' => qualified_name,
          'SourceType' => 'OQL'
        )
      end

      def entity_content(source) # rubocop:disable Metrics/AbcSize
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'MaybeGeneralization' => compile_generalization(source['MaybeGeneralization']),
          'Attributes' => array(source['Attributes']).map { compile_attribute(_1) },
          'ValidationRules' => array(source['ValidationRules']).map { compile_validation(_1) },
          'Events' => plain_array(source['Events']),
          'Indexes' => array(source['Indexes']).map { compile_index(_1) },
          'AccessRules' => array(source['AccessRules']).map { @security.access_rule(_1) }
        }
      end

      def compile_generalization(source)
        type = source.fetch('$Type')
        result = { '$ID' => source['$ID'], '$Type' => type }
        result['Key'] = source['Key'] if type == 'DomainModels$NoGeneralization'
        result.merge(generalization_flags(source, type))
              .merge('Generalization' => source['Generalization'].to_s)
      end

      def generalization_flags(source, type)
        inherited = inherited_flags(source['Generalization']) if type == 'DomainModels$Generalization'
        {
          'Persistable' => source.fetch('Persistable', inherited&.fetch('Persistable', false)) == true,
          'HasCreatedDateAttr' => source.fetch('HasCreatedDateAttr',
                                               inherited&.fetch('HasCreatedDateAttr', false)) == true,
          'HasChangedDateAttr' => source.fetch('HasChangedDateAttr',
                                               inherited&.fetch('HasChangedDateAttr', false)) == true,
          'HasOwnerAttr' => source.fetch('HasOwnerAttr', inherited&.fetch('HasOwnerAttr', false)) == true,
          'HasChangedByAttr' => source.fetch('HasChangedByAttr', inherited&.fetch('HasChangedByAttr', false)) == true
        }
      end

      def inherited_flags(qualified_name)
        return system_flags if qualified_name.to_s.start_with?('System.')

        parent = @entities[qualified_name.to_s]
        return system_flags unless parent

        generalization = parent['MaybeGeneralization'] || {}
        generalization_flags(generalization, generalization['$Type'])
      end

      def system_flags
        {
          'Persistable' => true, 'HasCreatedDateAttr' => true, 'HasChangedDateAttr' => true,
          'HasOwnerAttr' => true, 'HasChangedByAttr' => true
        }
      end

      def compile_attribute(source)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Value' => plain_document(source['Value']), 'Type' => compile_attribute_type(source['NewType']),
          'Name' => source['Name'], 'GUID' => source['GUID']
        }
      end

      def compile_attribute_type(source)
        result = plain_document(source)
        if result['$Type'] == 'DomainModels$StringAttributeType'
          result['Length'] ||= Model::Attribute::DEFAULT_STRING_LENGTH
        end
        if result['$Type'] == 'DomainModels$DateTimeAttributeType'
          result['LocalizeDate'] = source.fetch('LocalizeDate', true) == true
        end
        result
      end

      def compile_validation(source)
        message = source['Message'] || {}
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Message' => message.slice('$ID', '$Type'),
          'RuleInfo' => plain_document(source['RuleInfo']), 'Attribute' => source['Attribute'].to_s
        }
      end

      def compile_index(source)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Attributes' => array(source['Attributes']).map { compile_indexed_attribute(_1) },
          'GUID' => source['GUID'], 'IncludeInOffline' => source['IncludeInOffline'] == true
        }
      end

      def compile_indexed_attribute(source)
        result = plain_document(source)
        result['AssociationPointer'] ||= BSON::Binary.new(
          IO::BsonCodec.uuid_to_blob('00000000-0000-0000-0000-000000000000'), :generic
        )
        result
      end
    end
  end
end
