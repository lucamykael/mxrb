# frozen_string_literal: true

module Mxrb
  module RubyApp
    # Editable Mendix scheduled event, including its nested schedule identity
    # and version-specific schedule properties.
    class ScheduledEvent
      OPTION_UNSET = Object.new.freeze

      class << self
        attr_reader :mendix_id

        def inherited(child)
          super
          child.instance_variable_set(
            :@definition,
            { documentation: '', export_level: 'Hidden', enabled: true, interval: 1 }
          )
        end

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :scheduled_event, @mendix_name, id:)
          Registry.register(:scheduled_event, @mendix_name, self)
        end

        def documentation(value) = (@definition[:documentation] = value.to_s)
        def export_level(value) = (@definition[:export_level] = value.to_s)
        def unbound = (@definition[:unbound] = true)
        def microflow(value) = (@definition[:microflow] = value.to_s)
        def start_at(value) = (@definition[:start_at] = value)
        def time_zone(value) = (@definition[:time_zone] = value.to_s)
        def on_overlap(value) = (@definition[:on_overlap] = value.to_s)
        def enabled(value: true) = (@definition[:enabled] = value == true)
        def interval_type(value) = (@definition[:interval_type] = value.to_s)
        def interval(value) = (@definition[:interval] = Integer(value))

        def schedule(type, id: nil, properties: {}, **options, &block)
          values = properties.to_h.merge(options)
          definition = if block
                         ScheduleBuilder.new(type, id:, properties: values).evaluate(&block).build.to_h
                       else
                         { type: type.to_s, id: id.to_s, properties: values.transform_keys(&:to_s) }
                       end
          @definition[:schedule] = definition
        end

        def native_definition
          @definition.to_h.merge(
            name: @mendix_name.to_s.split('.', 2).last,
            qualified_name: @mendix_name.to_s, id: @mendix_id.to_s
          )
        end
      end
    end
  end
end
