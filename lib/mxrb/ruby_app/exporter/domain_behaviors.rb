# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Exporter
      # Domain behavior metadata shared by source export and identity tracking.
      module DomainBehaviors
        private

        def generalization_manifest(entity)
          target = entity.respond_to?(:generalization_target) ? entity.generalization_target : nil
          return unless target

          {
            'target' => target,
            'id' => IO::BsonCodec.extract_id(
              entity.respond_to?(:generalization) ? entity.generalization&.fetch('$ID', nil) : nil
            )
          }.compact
        end

        def lifecycle_manifest(callback)
          {
            'id' => callback.fetch(:id, '').to_s,
            'event' => callback.fetch(:event).to_s,
            'handler' => callback.fetch(:handler).to_s,
            'pass_event_object' => callback.fetch(:pass_event_object, true) == true,
            'raise_error_on_false' => callback.fetch(:raise_error_on_false, false) == true
          }
        end

        def validation_rule_manifest(rule)
          info = rule['RuleInfo'].is_a?(Hash) ? rule['RuleInfo'] : {}
          message = rule['Message'].is_a?(Hash) ? rule['Message'] : {}
          validation_rule_header(rule, info).merge(validation_message_manifest(message))
                                            .merge(validation_info_manifest(info))
        end

        def validation_rule_header(rule, info)
          { 'id' => native_identifier(rule['$ID']), 'attribute' => rule['Attribute'].to_s.split('.').last,
            'kind' => validation_rule_kind(info) }
        end

        def validation_rule_kind(info)
          type = info['$Type'].to_s
          short_kind = type.sub(/\ADomainModels\$/, '').sub(/RuleInfo\z/, '')
          %w[Required Unique].include?(short_kind) ? short_kind.downcase : type
        end

        def validation_message_manifest(message)
          { 'message_id' => native_identifier(message['$ID']),
            'translations' => native_items(message['Items']).map { validation_translation_manifest(_1) } }
        end

        def validation_translation_manifest(translation)
          { 'id' => native_identifier(translation['$ID']), 'language_code' => translation['LanguageCode'].to_s,
            'text' => translation['Text'].to_s }
        end

        def validation_info_manifest(info)
          { 'rule_info_id' => native_identifier(info['$ID']),
            'rule_info' => runtime_value(info.reject { |key, _value| %w[$ID $Type].include?(key) }) }
        end
      end
    end
  end
end
