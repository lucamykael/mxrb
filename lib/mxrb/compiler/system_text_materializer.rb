# frozen_string_literal: true

module Mxrb
  module Compiler
    SystemTextMaterialization = Data.define(:model_path, :texts)

    # Stores the Runtime system-text index; localized values live in i18n properties.
    class SystemTextMaterializer
      include ModelValues

      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        source = SourceModel.read(@mpr_path).units_of('Texts$SystemTextCollection').first
        document = source ? compile(source.document) : empty_collection
        path = File.join(@deployment, 'model', 'model.mdp')
        ModelPackage.read(path).upsert(document).write(path)
        SystemTextMaterialization.new(model_path: path, texts: document.fetch('SystemTexts').length)
      end

      private

      def compile(source)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'SystemTexts' => array(source['SystemTexts']).map { compile_text(_1) }
        }
      end

      def empty_collection
        {
          '$ID' => '57d2ecb5-6c2f-4ffa-a0b3-a37a40da3adf',
          '$Type' => 'Texts$SystemTextCollection', 'SystemTexts' => []
        }
      end

      def compile_text(source)
        {
          '$ID' => source['$ID'], '$Type' => source['$Type'],
          'Text' => source.fetch('Text').slice('$ID', '$Type'),
          'InternalKey' => source['InternalKey']
        }
      end
    end
  end
end
