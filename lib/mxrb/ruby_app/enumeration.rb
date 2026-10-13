# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Editable Mendix enumeration definition. Generated Ruby sources retain
    # document/value ids and every standard localized caption.
    class Enumeration
      OPTION_UNSET = Object.new.freeze

      # Localized captions are authored as ordered, typed translations.
      class TranslationBuilder
        def initialize = (@translations = [])

        def translation(language, text)
          @translations << Forms::Translation.new(language.to_s, text.to_s)
        end

        def build = Forms::Text.new(@translations)
      end

      class << self
        attr_reader :mendix_id, :values

        def inherited(child)
          super
          child.instance_variable_set(:@values, [])
          child.instance_variable_set(:@removed_values, [])
          child.instance_variable_set(:@documentation, '')
        end

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :enumeration, @mendix_name, id:)
          Registry.register(:enumeration, @mendix_name, self)
        end

        def documentation(value = OPTION_UNSET)
          return @documentation.to_s if value.equal?(OPTION_UNSET)

          @documentation = value.to_s
        end

        def value(name, id: nil, caption: OPTION_UNSET, captions: nil, renamed_from: nil, &block)
          if block && (!captions.nil? || !caption.equal?(OPTION_UNSET))
            raise ArgumentError, 'value accepts either caption options or a translation block'
          end

          localized = if block
                        builder = TranslationBuilder.new
                        block.arity.zero? ? builder.instance_eval(&block) : block.call(builder)
                        builder.build.translations.to_h { [_1.language, _1.text] }
                      elsif captions.nil?
                        {}
                      else
                        captions.to_h.transform_keys(&:to_s).transform_values(&:to_s)
                      end
          localized['en_US'] = caption.to_s unless caption.equal?(OPTION_UNSET)
          localized['en_US'] = name.to_s if !block && captions.nil? && caption.equal?(OPTION_UNSET)
          @values ||= []
          declaration = { name: name.to_s, id: id.to_s, captions: localized.freeze }
          declaration[:renamed_from] = renamed_from.to_s unless renamed_from.nil?
          @values << declaration.freeze
        end

        def remove_value(name)
          value = name.to_s
          raise ArgumentError, 'remove_value requires a value name' if value.empty?

          (@removed_values ||= []) << value
        end

        def resolve_value_identities!(previous)
          @values = MemberIdentity.resolve(
            previous:, declarations: Array(@values), removed: Array(@removed_values)
          ).map(&:freeze)
        end

        def native_definition
          {
            name: @mendix_name.to_s.split('.', 2).last, id: @mendix_id.to_s,
            documentation: @documentation.to_s, values: Array(@values)
          }
        end
      end
    end
    # rubocop:enable Metrics
  end
end
