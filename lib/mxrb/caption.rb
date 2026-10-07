# frozen_string_literal: true

module Mxrb
  # Public, storage-independent caption parameters shared by the writer and Ruby DSL.
  module Caption
    FORMAT_FIELDS = {
      date_format: 'DateFormat', custom_date_format: 'CustomDateFormat',
      decimal_precision: 'DecimalPrecision', enum_format: 'EnumFormat', group_digits: 'GroupDigits'
    }.freeze
    FORMAT_DEFAULTS = {
      date_format: 'Date', custom_date_format: '', decimal_precision: 2, enum_format: 'Text', group_digits: false
    }.freeze

    module_function

    def string(value, label)
      raise ArgumentError, "#{label} must be a String" unless value.is_a?(String)

      value.dup.freeze
    end

    def options(value, allowed, label)
      raise ArgumentError, "#{label} must be a Hash" unless value.is_a?(Hash)

      result = value.to_h do |key, item|
        raise ArgumentError, "unknown #{label} key #{key.inspect}" unless allowed.include?(key.to_s.to_sym)

        [key.to_s.to_sym, item]
      end
      raise ArgumentError, "duplicate #{label} keys" unless result.length == value.length

      result
    end

    def translations(value)
      pairs = value.is_a?(Hash) ? value.to_a : value
      unless pairs.is_a?(Array) && pairs.all? { _1.is_a?(Array) && _1.length == 2 }
        raise ArgumentError, 'caption translations must be a Hash or an Array of pairs'
      end

      pairs.to_h { |language, text| [string(language.to_s, 'language'), string(text, 'translation')] }.freeze
    end

    def source(value)
      result = options(value, %i[kind name sub_key use_all_pages], 'caption source')
      kinds = %w[current page_parameter snippet_parameter local_variable widget]
      result[:kind] = choice(result.fetch(:kind).to_s, kinds, 'source kind')
      string_options!(result, %i[name sub_key])
      boolean_option!(result, :use_all_pages)
      result.freeze
    end

    def choice(value, choices, label)
      raise ArgumentError, "unknown caption #{label}" unless choices.include?(value)

      value.dup.freeze
    end

    def string_options!(result, keys)
      keys.each { |key| result[key] = string(result[key], key) if result.key?(key) }
    end

    def boolean_option!(result, key)
      return unless result.key?(key)
      raise ArgumentError, "caption #{key} must be boolean" unless [true, false].include?(result[key])
    end

    def format(value)
      result = options(value, FORMAT_FIELDS.keys, 'caption format')
      string_options!(result, %i[custom_date_format])
      validate_format_choices!(result)
      validate_precision!(result[:decimal_precision]) if result.key?(:decimal_precision)
      boolean_option!(result, :group_digits)
      result.freeze
    end

    def validate_format_choices!(result)
      { date_format: %w[Date Time DateTime Custom], enum_format: %w[Text Image] }.each do |key, choices|
        result[key] = choice(result[key], choices, key) if result.key?(key)
      end
    end

    def validate_precision!(value)
      return if value.is_a?(Integer) && value.between?(0, 100)

      raise ArgumentError, 'caption decimal_precision must be an integer between 0 and 100'
    end

    def parameter(value)
      return string(value, 'caption parameter') if value.is_a?(String)

      result = options(value, %i[expression attribute source format], 'caption parameter')
      parameter_value!(result)
      result[:source] = source(result[:source]) if result.key?(:source)
      result[:format] = format(result[:format]) if result.key?(:format)
      result.freeze
    end

    def parameter_value!(result)
      keys = result.keys & %i[expression attribute]
      raise ArgumentError, 'caption parameter requires exactly one expression or attribute' unless keys.length == 1

      key = keys.first
      result[key] = string(result[key], key)
    end
  end
end
