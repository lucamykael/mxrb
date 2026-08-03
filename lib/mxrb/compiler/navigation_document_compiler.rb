# frozen_string_literal: true

module Mxrb
  module Compiler
    # Compiles server-visible navigation profiles while preserving Runtime widget inventories.
    class NavigationDocumentCompiler
      include ModelValues

      def initialize(schema)
        @schema = schema
      end

      def compile(unit) # rubocop:disable Metrics/MethodLength
        source = unit.document
        existing = @schema.counterpart(source) || {}
        @schema.fields_for(source).to_h do |field|
          value = if field == 'Profiles'
                    array(source['Profiles']).map { profile(_1) }
                  elsif %w[$ID $Type].include?(field)
                    source[field]
                  else
                    existing.fetch(field, source.fetch(field, []))
                  end
          [field, value]
        end
      end # rubocop:enable Metrics/MethodLength

      private

      def profile(source) # rubocop:disable Metrics/AbcSize
        existing = @schema.counterpart(source) || {}
        values = {
          'OfflineEntityConfigsRuntime' => offline_configs(source, existing),
          'HomePage' => home_page(source['HomePage']), 'HomeItems' => plain_array(source['HomeItems']),
          'AppTitle' => text_reference(source['AppTitle']),
          'LoginPageSettings' => form_settings(source['LoginPageSettings'])
        }.merge(profile_settings(source, existing))
        @schema.fields_for(source).to_h do |field|
          [field, values.fetch(field, source.fetch(field, existing[field]))]
        end
      end # rubocop:enable Metrics/AbcSize

      def profile_settings(source, existing)
        {
          'ProgressiveWebAppSettings' => plain_document(source['ProgressiveWebAppSettings']),
          'NotFoundHomepage' => plain_document(source['NotFoundHomepage']),
          'Name' => source['Name'], 'IsOffline' => source['Kind'] == 'Offline',
          'ThrowPartialSyncError' => source['ThrowPartialSyncError'] == true,
          'Kind' => source['Kind'], 'AppIcon' => source.fetch('AppIcon', existing.fetch('AppIcon', ''))
        }
      end

      def offline_configs(source, existing)
        return existing['OfflineEntityConfigsRuntime'] if existing.key?('OfflineEntityConfigsRuntime')

        plain_array(source['OfflineEntityConfigs'])
      end

      def home_page(source)
        return nil unless source

        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Page' => source['Page'].to_s, 'Microflow' => source['Microflow'].to_s
        }
      end

      def form_settings(source)
        return nil unless source

        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'TitleOverride' => text_reference(source['TitleOverride']),
          'ParameterMappings' => plain_array(source['ParameterMappings']),
          'Form' => source['Form'].to_s, 'Location' => source.fetch('Location', 'Content')
        }
      end

      def text_reference(source)
        return nil unless source

        @schema.fields_for(source).to_h do |field|
          value = case field
                  when 'Parameters' then array(source[field]).map { text_reference(_1) }
                  when 'Text' then text_reference(source[field])
                  else source[field]
                  end
          [field, value]
        end
      end
    end
  end
end
