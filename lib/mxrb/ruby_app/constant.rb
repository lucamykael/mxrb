# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Editable Mendix constant definition. Private defaults are omitted from
    # generated source and can be supplied locally through process/.env values.
    class Constant
      OPTION_UNSET = Object.new.freeze

      class << self
        attr_reader :mendix_id

        def inherited(child)
          super
          child.instance_variable_set(:@documentation, '')
          child.instance_variable_set(:@type, :string)
          child.instance_variable_set(:@default_supplied, false)
          child.instance_variable_set(:@default_value, nil)
          child.instance_variable_set(:@exposed_to_client, false)
          child.instance_variable_set(:@excluded, false)
          child.instance_variable_set(:@export_level, 'Hidden')
        end

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :constant, @mendix_name, id:)
          Registry.register(:constant, @mendix_name, self)
        end

        def documentation(value = OPTION_UNSET)
          return @documentation.to_s if value.equal?(OPTION_UNSET)

          @documentation = value.to_s
        end

        def type(value = OPTION_UNSET)
          return @type if value.equal?(OPTION_UNSET)

          @type = value.to_sym
        end

        def default(value = OPTION_UNSET)
          return @default_value if value.equal?(OPTION_UNSET)

          @default_supplied = true
          @default_value = value
        end

        def default_from_env(name)
          default ENV.fetch(name.to_s)
        end

        def preserve_default!
          @default_supplied = false
          @default_value = nil
        end

        def exposed_to_client(value = OPTION_UNSET)
          return @exposed_to_client == true if value.equal?(OPTION_UNSET)

          @exposed_to_client = value == true
        end

        def excluded(value = OPTION_UNSET)
          return @excluded == true if value.equal?(OPTION_UNSET)

          @excluded = value == true
        end

        def export_level(value = OPTION_UNSET)
          return @export_level.to_s if value.equal?(OPTION_UNSET)

          @export_level = value.to_s
        end

        def native_definition
          {
            name: @mendix_name.to_s.split('.', 2).last, id: @mendix_id.to_s,
            documentation: @documentation.to_s, type: @type || :string,
            default_supplied: @default_supplied == true, default_value: @default_value,
            exposed_to_client: @exposed_to_client == true, excluded: @excluded == true,
            export_level: @export_level.to_s
          }
        end

        def client_value
          case type
          when :integer then Integer(default)
          when :decimal then Runtime::DecimalValues.encode(BigDecimal(default.to_s))
          when :boolean then default.to_s == 'true'
          else default
          end
        end
      end
    end
  end
end
