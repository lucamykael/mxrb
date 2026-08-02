# frozen_string_literal: true

module Mxrb
  module Compiler
    # Compiles Runtime roots whose executable representation is independent of UI bundles.
    class ArtifactDocumentCompiler
      include ModelValues

      NAME_ONLY_TYPES = %w[
        CustomIcons$CustomIconCollection Forms$Layout Forms$Snippet Menus$MenuDocument
      ].freeze
      TYPES = (NAME_ONLY_TYPES + %w[
        Enumerations$Enumeration Images$ImageCollection RegularExpressions$RegularExpression
        ScheduledEvents$ScheduledEvent DomainModels$ViewEntitySourceDocument
      ]).freeze

      def compile(unit) # rubocop:disable Metrics/AbcSize
        source = unit.document
        return named(source, unit.module_name) if NAME_ONLY_TYPES.include?(source['$Type'])

        case source['$Type']
        when 'Enumerations$Enumeration' then enumeration(source, unit.module_name)
        when 'Images$ImageCollection' then image_collection(source, unit.module_name)
        when 'RegularExpressions$RegularExpression' then regular_expression(source, unit.module_name)
        when 'ScheduledEvents$ScheduledEvent' then scheduled_event(source, unit.module_name)
        when 'DomainModels$ViewEntitySourceDocument' then named(source, unit.module_name)
        else raise CompilationError, "unsupported Runtime artifact #{source['$Type']}"
        end
      end

      private

      def named(source, module_name)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'], 'Name' => source['Name'],
          'QualifiedName' => qualified_name(module_name, source['Name'])
        }
      end

      def enumeration(source, module_name)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Values' => array(source['Values']).map { enumeration_value(_1) },
          'Name' => source['Name'], 'QualifiedName' => qualified_name(module_name, source['Name'])
        }
      end

      def enumeration_value(source)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Caption' => text_reference(source['Caption']), 'RemoteValue' => source['RemoteValue'],
          'Name' => source['Name'], 'Image' => source['Image'].to_s
        }
      end

      def image_collection(source, module_name)
        collection_name = qualified_name(module_name, source['Name'])
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Images' => array(source['Images']).map { image(_1, collection_name) },
          'Name' => source['Name'], 'QualifiedName' => collection_name
        }
      end

      def image(source, collection_name)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'], 'Name' => source['Name'],
          'Image' => source['Image'], 'Format' => image_format(source),
          'QualifiedName' => "#{collection_name}.#{source['Name']}"
        }
      end

      def regular_expression(source, module_name)
        named(source, module_name).merge('Expression' => source['Expression'].to_s)
      end

      def scheduled_event(source, module_name)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Schedule' => plain_document(source['Schedule']), 'Name' => source['Name'],
          'QualifiedName' => qualified_name(module_name, source['Name']),
          'StartDateTime' => source['StartDateTime'], 'TimeZone' => source['TimeZone'],
          'OnOverlap' => source['OnOverlap'], 'Interval' => source['Interval'],
          'IntervalType' => source['IntervalType'], 'Microflow' => source['Microflow'],
          'Documentation' => source['Documentation'].to_s
        }
      end

      def text_reference(source)
        return nil unless source

        source.slice('$ID', '$Type')
      end

      def qualified_name(module_name, name)
        raise CompilationError, "artifact #{name} is outside a module" unless module_name

        "#{module_name}.#{name}"
      end
    end
  end
end
