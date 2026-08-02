# frozen_string_literal: true

require 'fileutils'

module Mxrb
  module Compiler
    TranslationMaterialization = Data.define(:directory, :languages, :strings, :files)

    # Synchronizes all MPR Texts$Text values into Runtime Java-properties catalogs.
    class TranslationMaterializer
      include ModelValues

      def initialize(mpr_path, deployment:)
        @mpr_path = File.expand_path(mpr_path)
        @deployment = File.expand_path(deployment)
      end

      def materialize
        translations = collect(SourceModel.read(@mpr_path))
        directory = File.join(@deployment, 'model', 'i18n')
        FileUtils.mkdir_p(directory)
        write_languages(directory, translations)
        write_default(directory, translations)
        result(directory, translations)
      end

      private

      def collect(source)
        result = Hash.new { |hash, language| hash[language] = {} }
        source.documents.each { collect_value(_1, result) }
        result
      end

      def collect_value(value, result)
        case value
        when Hash
          collect_text(value, result) if value['$Type'] == 'Texts$Text'
          value.each_value { collect_value(_1, result) }
        when Array then array(value).each { collect_value(_1, result) }
        end
      end

      def collect_text(text, result)
        key = IO::BsonCodec.extract_id(text['$ID'])
        return unless key

        array(text['Items']).each do |translation|
          language = translation['LanguageCode'].to_s
          result[language][key] = translation['Text'].to_s unless language.empty?
        end
      end

      def update(path, values)
        lines = File.file?(path) ? File.readlines(path, chomp: true) : []
        seen = {}
        rendered = lines.map { replace_line(_1, values, seen) }
        values.keys.sort.each { |key| rendered << property(key, values.fetch(key)) unless seen[key] }
        File.write(path, "#{rendered.join("\n")}\n")
      end

      def replace_line(line, values, seen)
        key = line[/\A([0-9a-f-]{36})=/i, 1]
        return line unless key && values.key?(key)

        seen[key] = true
        property(key, values.fetch(key))
      end

      def property(key, value)
        escaped = value.to_s.gsub('\\', '\\\\').gsub(/\r\n|\r|\n/, '\\n')
                       .gsub(/([:=#!])/) { |character| "\\#{character}" }
        "#{key}=#{escaped}"
      end

      def write_languages(directory, translations)
        translations.each do |language, values|
          update(File.join(directory, "translations_#{language}.properties"), values)
        end
      end

      def write_default(directory, translations)
        language = translations.key?('en_US') ? 'en_US' : translations.keys.min
        update(File.join(directory, 'translations.properties'), translations.fetch(language, {}))
      end

      def result(directory, translations)
        TranslationMaterialization.new(
          directory:, languages: translations.keys.sort.freeze,
          strings: translations.values.sum(&:length), files: translations.length + 1
        )
      end
    end
  end
end
