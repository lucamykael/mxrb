# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Only page-owned popup properties; layout mode, parameters and actions remain guarded.
    module PageEditContracts
      POPUP_FIELDS = { 'width' => 'PopupWidth', 'height' => 'PopupHeight', 'resizable' => 'PopupResizable' }.freeze

      module_function

      def changes(before, after)
        return [] if before == after

        unless before.except('popup') == after.except('popup') && compatible_popups?(before['popup'], after['popup'])
          raise ArgumentError, 'presentation parameters, variables, popup mode or autofocus changed'
        end

        popup_changes(before.fetch('popup'), after.fetch('popup'))
      end

      def compatible_popups?(before, after)
        before.is_a?(Hash) && after.is_a?(Hash) &&
          before.except(*POPUP_FIELDS.keys) == after.except(*POPUP_FIELDS.keys)
      end

      def popup_changes(before, after)
        POPUP_FIELDS.keys.filter_map do |key|
          next if before[key] == after[key]

          raise ArgumentError, 'popup fields must remain explicit' unless before.key?(key) && after.key?(key)

          [:popup, key, before[key], after[key]]
        end
      end

      def apply(owner, key, before, after)
        field = POPUP_FIELDS.fetch(key)
        unless owner['$Type'] == 'Forms$Page' && owner.key?(field) && owner[field] == before
          raise ArgumentError, "#{field} has no matching native page baseline"
        end

        valid = key == 'resizable' ? [true, false].include?(after) : valid_dimension?(after)
        raise ArgumentError, "invalid popup #{key}: #{after.inspect}" unless valid

        owner[field] = after
      end

      def valid_dimension?(value) = value.is_a?(Integer) && value.between?(0, 2_147_483_647)
    end
  end
end
