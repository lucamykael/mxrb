# frozen_string_literal: true

require 'securerandom'

module Mxrb
  # Typed, storage-independent representation of Mendix system texts.
  module SystemTexts
    class CodecError < SerializationError; end

    Translation = Data.define(:language_code, :value) do
      def to_h = { language_code:, value: }
    end

    Entry = Data.define(:key, :translations) do
      def to_h = { key:, translations: translations.map(&:to_h) }
    end

    Collection = Data.define(:language_codes, :entries) do
      def self.build(&block)
        builder = CollectionBuilder.new
        builder.instance_eval(&block) if block
        builder.build
      end

      def self.from_h(value)
        attributes = value.to_h.transform_keys(&:to_sym)
        new(
          language_codes: Array(attributes.fetch(:language_codes)).map(&:to_s).freeze,
          entries: Array(attributes.fetch(:entries)).map { entry_from_h(_1) }.freeze
        )
      end

      def self.entry_from_h(value)
        fields = value.to_h.transform_keys(&:to_sym)
        translations = Array(fields.fetch(:translations)).map { translation_from_h(_1) }
        Entry.new(key: fields.fetch(:key).to_s, translations: translations.freeze)
      end

      def self.translation_from_h(value)
        fields = value.to_h.transform_keys(&:to_sym)
        Translation.new(
          language_code: fields.fetch(:language_code).to_s,
          value: fields.fetch(:value).to_s
        )
      end

      private_class_method :entry_from_h, :translation_from_h

      def to_h
        { language_codes:, entries: entries.map(&:to_h) }
      end
    end

    # Evaluation context used by `system_text_collection do ... end`.
    class CollectionBuilder
      def initialize
        @language_codes = []
        @entries = []
      end

      def languages(*codes)
        normalized = codes.flatten.map(&:to_s)
        duplicates = normalized.group_by(&:itself).select { |_code, values| values.size > 1 }
        raise ArgumentError, "duplicate system-text language(s): #{duplicates.keys.join(', ')}" unless
          duplicates.empty?

        @language_codes = normalized
      end

      def text(key, **translations, &block)
        raise ArgumentError, 'text accepts translations as keywords or a block, not both' if
          block && !translations.empty?

        values = block ? block_translations(block) : keyword_translations(translations)
        @entries << Entry.new(key: key.to_s, translations: values.freeze)
      end

      def build
        codes = @language_codes.empty? ? inferred_languages : @language_codes
        Collection.new(language_codes: codes.freeze, entries: @entries.freeze)
      end

      private

      def inferred_languages
        @entries.flat_map(&:translations).map(&:language_code).uniq
      end

      def block_translations(block)
        EntryBuilder.new.tap { _1.instance_eval(&block) }.translations
      end

      def keyword_translations(values)
        values.map do |language_code, value|
          Translation.new(language_code: language_code.to_s, value: value.to_s)
        end
      end
    end

    # Evaluation context for language codes that cannot be Ruby keywords, or
    # for the rare Mendix entry containing a language more than once.
    class EntryBuilder
      attr_reader :translations

      def initialize = (@translations = [])

      def translation(language_code, value)
        @translations << Translation.new(language_code: language_code.to_s, value: value.to_s)
      end
    end

    # Converts the typed model at the sole BSON boundary. Existing node IDs are
    # matched by semantic keys and kept out of editable Ruby source.
    class MprCodec # rubocop:disable Metrics/ClassLength
      COLLECTION_TYPE = 'Texts$SystemTextCollection'
      ENTRY_TYPE = 'Texts$SystemText'
      TEXT_TYPE = 'Texts$Text'
      TRANSLATION_TYPE = 'Texts$Translation'

      def decode(document)
        expect_type!(document, COLLECTION_TYPE, 'system text collection')
        entries = collection_items(document.fetch('SystemTexts'), 'SystemTexts').map do |entry|
          decode_entry(entry)
        end
        languages = entries.flat_map(&:translations).map(&:language_code).uniq.freeze
        Collection.new(language_codes: languages, entries: entries.freeze)
      rescue KeyError => e
        raise CodecError, "incomplete system text collection: #{e.message}"
      end

      def encode(collection, baseline: nil)
        model = collection.is_a?(Collection) ? collection : Collection.from_h(collection)
        baseline = usable_baseline(baseline)
        entries = encode_entries(model, baseline)
        {
          '$ID' => node_id(baseline),
          '$Type' => COLLECTION_TYPE,
          'SystemTexts' => IO::BsonCodec.build_array(
            entries, marker: collection_marker(baseline&.fetch('SystemTexts', nil), 2)
          )
        }
      end

      private

      def encode_entries(model, baseline)
        candidates = queues_by(baseline_entries(baseline)) { _1['InternalKey'].to_s }
        model.entries.map { |entry| encode_entry(entry, candidates[entry.key].shift) }
      end

      def baseline_entries(baseline)
        baseline ? collection_items(baseline['SystemTexts'], 'SystemTexts') : []
      end

      def decode_entry(entry)
        expect_type!(entry, ENTRY_TYPE, "system text #{entry['InternalKey'].inspect}")
        text = entry.fetch('Text')
        expect_type!(text, TEXT_TYPE, "text value for #{entry['InternalKey'].inspect}")
        translations = collection_items(text.fetch('Items'), 'Text.Items').map { decode_translation(_1) }
        Entry.new(key: entry.fetch('InternalKey').to_s, translations: translations.freeze)
      end

      def decode_translation(translation)
        expect_type!(translation, TRANSLATION_TYPE, 'system text translation')
        Translation.new(
          language_code: translation.fetch('LanguageCode').to_s,
          value: translation.fetch('Text').to_s
        )
      end

      def encode_entry(entry, baseline)
        baseline_text = baseline&.fetch('Text', nil)
        translations = encode_translations(entry, baseline_text)
        {
          '$ID' => node_id(baseline), '$Type' => ENTRY_TYPE, 'InternalKey' => entry.key,
          'Text' => encode_text(translations, baseline_text)
        }
      end

      def encode_translations(entry, baseline_text)
        candidates = queues_by(baseline_translation_items(baseline_text)) do
          _1['LanguageCode'].to_s
        end
        entry.translations.map do |translation|
          encode_translation(translation, candidates[translation.language_code].shift)
        end
      end

      def baseline_translation_items(baseline_text)
        return [] unless baseline_text

        collection_items(baseline_text['Items'], 'Text.Items')
      end

      def encode_translation(translation, baseline)
        {
          '$ID' => node_id(baseline), '$Type' => TRANSLATION_TYPE,
          'LanguageCode' => translation.language_code, 'Text' => translation.value
        }
      end

      def encode_text(translations, baseline)
        {
          '$ID' => node_id(baseline), '$Type' => TEXT_TYPE,
          'Items' => IO::BsonCodec.build_array(
            translations, marker: collection_marker(baseline&.fetch('Items', nil), 3)
          )
        }
      end

      def usable_baseline(value)
        return unless value.is_a?(Hash) && value['$Type'] == COLLECTION_TYPE

        value
      end

      def collection_items(value, path)
        raise CodecError, "#{path} must be a Mendix collection" unless value.is_a?(Array)

        IO::BsonCodec.parse_array(value).fetch(:items)
      end

      def collection_marker(value, fallback)
        value.is_a?(Array) && value.first.is_a?(Integer) ? value.first : fallback
      end

      def expect_type!(value, expected, path)
        actual = value.is_a?(Hash) ? value['$Type'] : nil
        return if actual == expected

        raise CodecError, "#{path} must be #{expected}, got #{actual || value.class}"
      end

      def queues_by(values)
        values.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |value, queues|
          queues[yield(value)] << value
        end
      end

      def node_id(value)
        id = value.is_a?(Hash) ? IO::BsonCodec.extract_id(value['$ID']).to_s : ''
        id.empty? ? SecureRandom.uuid : id
      end
    end

    # Emits concise Ruby that contains domain language only, never BSON fields.
    class SourceEmitter
      RUBY_KEYWORD = /\A[a-zA-Z_]\w*\z/

      def emit(collection)
        lines = ['system_text_collection do']
        append_languages(lines, collection)
        append_entries(lines, collection.entries)
        lines << 'end'
        "#{lines.join("\n")}\n"
      end

      private

      def append_languages(lines, collection)
        return if collection.language_codes.empty?

        languages = collection.language_codes.map { ruby_language(_1) }.join(', ')
        lines << "  languages #{languages}"
        lines << '' unless collection.entries.empty?
      end

      def append_entries(lines, entries)
        entries.each_with_index do |entry, index|
          lines.concat(entry_lines(entry))
          lines << '' unless index == entries.size - 1
        end
      end

      def entry_lines(entry)
        if keyword_translations?(entry.translations)
          keyword_entry_lines(entry)
        else
          block_entry_lines(entry)
        end
      end

      def keyword_translations?(translations)
        codes = translations.map(&:language_code)
        codes.uniq.size == codes.size && codes.all? { RUBY_KEYWORD.match?(_1) }
      end

      def keyword_entry_lines(entry)
        return ["  text #{entry.key.inspect}"] if entry.translations.empty?

        values = entry.translations.map { keyword_translation(_1) }
        return ["  text #{entry.key.inspect}, #{values.first}"] if values.one?

        ["  text #{entry.key.inspect},", *continued_keywords(values)]
      end

      def keyword_translation(translation)
        "#{translation.language_code}: #{translation.value.inspect}"
      end

      def continued_keywords(values)
        values.each_with_index.map do |value, index|
          "       #{value}#{index == values.size - 1 ? '' : ','}"
        end
      end

      def block_entry_lines(entry)
        lines = ["  text #{entry.key.inspect} do"]
        entry.translations.each do |translation|
          lines << "    translation #{ruby_language(translation.language_code)}, " \
                   "#{translation.value.inspect}"
        end
        lines << '  end'
        lines
      end

      def ruby_language(value)
        RUBY_KEYWORD.match?(value) ? ":#{value}" : value.inspect
      end
    end
  end
end
