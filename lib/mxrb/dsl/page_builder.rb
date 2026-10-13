# frozen_string_literal: true

module Mxrb
  module Dsl
    class PageBuilder # rubocop:disable Metrics/ClassLength
      include WidgetDsl
      include PresentationValues

      WRITE_MODES = %i[replace overlay].freeze

      def initialize(name, default_layout: 'Atlas_Default', public: false, unit_id: nil)
        @name          = name.to_s
        @public        = public == true
        @layout        = default_layout.to_s
        @title         = name.to_s
        @popup         = false
        @data_source   = nil
        @events        = []
        @widgets       = []
        @parameters    = []
        @variables = []
        @popup_options = nil
        @autofocus = nil
        @allowed_roles = nil
        @deep_structure = nil
        @forms_model = nil
        @overlay_metadata = nil
        @unit_id = unit_id&.to_s
        @write_mode = :replace
      end

      def layout(l) = (@layout = l)
      def title(t)  = (@title = t)

      def popup!(mode: :modal, width: 600, height: 400, resizable: true, close_action: '')
        raise ArgumentError, 'popup mode must be modal or popup' unless %i[modal popup].include?(mode.to_sym)
        raise ArgumentError, 'popup dimensions must be nonnegative' unless [width, height].all? do
          _1.is_a?(Integer) && _1 >= 0
        end

        @popup = true
        @popup_options = { mode: mode.to_s, width:, height:, resizable:, close_action: close_action.to_s }
      end

      def autofocus(mode)
        value = { disabled: 'Off', desktop: 'DesktopOnly', all: 'AllPlatforms' }.fetch(mode.to_sym) do
          raise ArgumentError, 'autofocus must be disabled, desktop or all'
        end
        @autofocus = value
      end

      # Complete schema-checked Forms representation for lossless Ruby-first
      # pages. The block runs directly against Mxrb::Forms::Node.
      def form(&block)
        @forms_model = Forms::Node.build(:page, &block)
      end

      def write_mode(mode)
        normalized = mode.to_sym
        raise ArgumentError, 'page write_mode must be :replace or :overlay' unless
          WRITE_MODES.include?(normalized)

        @write_mode = normalized
      end

      # Full, editable Mendix page payload for structures without a concise
      # typed DSL yet (layout grids, custom widgets, list views, etc.).
      def deep_structure(value)
        raise ArgumentError, 'deep_structure requires a Hash' unless value.is_a?(Hash)

        @deep_structure = value
      end

      def form_structure(value = nil, mode: :replace, **keyword_value)
        unless keyword_value.empty?
          raise ArgumentError, 'form_structure accepts one structure' unless value.nil?

          value = keyword_value
        end
        raise ArgumentError, 'form_structure requires a Hash' unless value.is_a?(Hash)

        write_mode(mode)
        @deep_structure = presentation_value_document(value)
      end

      def baseline_overlay(page_id:, module_id:, baseline_digest:, version: 2,
                           apply_fields: true)
        @unit_id = page_id.to_s
        @write_mode = :overlay
        @overlay_metadata = {
          'version' => version.to_i, 'page_unit_id' => page_id.to_s,
          'module_unit_id' => module_id.to_s, 'baseline_digest' => baseline_digest.to_s,
          'apply_fields' => apply_fields == true, 'widgets' => []
        }
      end

      def baseline_widget(type, name, fingerprint:)
        raise ArgumentError, 'baseline_widget requires baseline_overlay first' unless @overlay_metadata

        @overlay_metadata.fetch('widgets') << {
          'type' => type.to_s, 'name' => name.to_s, 'fingerprint' => fingerprint.to_s
        }
      end

      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype.to_sym)
      end

      def allowed_roles(*roles)
        @allowed_roles = roles.map(&:to_s)
      end

      def parameter(name, entity: nil, type: nil, enumeration: nil, required: true,
                    default_value: '', id: nil, type_id: nil)
        @parameters << {
          name: name.to_s, entity: entity&.to_s, type: type&.to_s, enumeration: enumeration&.to_s,
          required: required == true,
          default_value: default_value.to_s, id: id&.to_s, type_id: type_id&.to_s
        }.compact
      end

      def variable(name, type: nil, entity: nil, enumeration: nil, default_value: '')
        @variables << { name: name.to_s, type: type&.to_s, entity: entity&.to_s,
                        enumeration: enumeration&.to_s, default_value: default_value.to_s }.compact
      end

      def data_source(query: nil, microflow: nil, nanoflow: nil)
        choices = { microflow: microflow || query, nanoflow: nanoflow }.compact
        raise ArgumentError, 'data_source requires exactly one target' unless choices.size == 1

        @data_source = { kind: choices.keys.first, name: choices.values.first.to_s }
      end

      %i[on_change on_click on_submit on_load].each do |event|
        define_method(event) do |target: nil, microflow: nil, nanoflow: nil, page: nil,
                                action: nil, pass: {}|
          choices = { microflow: microflow, nanoflow: nanoflow, page: page, action: action }.compact
          raise ArgumentError, "#{event} requires exactly one handler" unless choices.size == 1
          raise ArgumentError, "#{event} pass: must be a Hash" unless pass.is_a?(Hash)

          declaration = {
            event: event, target: target&.to_s,
            kind: choices.keys.first, handler: choices.values.first.to_s
          }
          declaration[:arguments] = pass unless pass.empty?
          @events << declaration
        end
      end

      def to_h
        {
          name: @name, public: @public, layout: @layout, title: @title, popup: @popup,
          data_source: @data_source, events: @events, widgets: @widgets,
          parameters: @parameters, allowed_roles: @allowed_roles,
          variables: @variables, popup_options: @popup_options, autofocus: @autofocus,
          deep_structure: @deep_structure, write_mode: @write_mode
        }.merge(
          unit_id: @unit_id, overlay_metadata: @overlay_metadata,
          forms_model: @forms_model
        )
      end

      private

      def _widget_list = @widgets
    end # rubocop:enable Metrics/ClassLength

    # Collects ordered call parameter mappings without exposing the BSON-shaped
    # hashes used internally by Mendix. Keeping this as a small builder also
    # preserves duplicate parameter names, which Ruby Hash arguments cannot do.
    class CallArgumentsBuilder
      CODE_ACTION_KINDS = %i[
        entity entity_type microflow import_mapping export_mapping
      ].freeze

      attr_reader :mappings

      def initialize(code_action: false)
        @code_action = code_action
        @mappings = []
      end

      def argument(parameter, value)
        @mappings << { param: parameter.to_s, value: value }
      end

      CODE_ACTION_KINDS.each do |kind|
        define_method(:"#{kind}_argument") do |parameter, value|
          raise ArgumentError, "#{kind}_argument is only valid for code actions" unless @code_action

          @mappings << {
            param: parameter.to_s,
            value: { kind: kind, value: value }
          }
        end
      end
    end

    # Collects ordered Database Connector mappings without exposing storage
    # hashes in exported application code. Separate methods keep query and
    # connection parameters unambiguous while preserving duplicate names.
    class DatabaseQueryArgumentsBuilder
      attr_reader :parameters, :connection_parameters

      def initialize
        @parameters = []
        @connection_parameters = []
      end

      def parameter(name, value)
        @parameters << { name: name.to_s, value: value }
      end

      def connection_parameter(name, value)
        @connection_parameters << { name: name.to_s, value: value }
      end
    end
  end
end
