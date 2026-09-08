# frozen_string_literal: true

module Mxrb
  module RubyApp
    ScheduleDefinition = Data.define(:type, :id, :properties)

    # These four shapes are shared with Exporter::SCHEDULE_FIELDS and the
    # runtime scheduler. In particular, the native names are DaySchedule and
    # WeekSchedule, not DailySchedule and WeeklySchedule.
    #
    # No defaults are materialized: an absent field, explicit nil and false
    # must remain distinct. Unsupported shapes belong to the legacy schedule
    # properties API; compatible? lets source emitters retain that API intact.
    class ScheduleBuilder
      TYPES = {
        minute: 'ScheduledEvents$MinuteSchedule',
        hour: 'ScheduledEvents$HourSchedule',
        day: 'ScheduledEvents$DaySchedule',
        week: 'ScheduledEvents$WeekSchedule'
      }.freeze
      PROPERTY_NAMES = {
        'Multiplier' => :multiplier,
        'MinuteOffset' => :minute_offset,
        'HourOfDay' => :hour_of_day,
        'MinuteOfHour' => :minute_of_hour,
        'Monday' => :monday,
        'Tuesday' => :tuesday,
        'Wednesday' => :wednesday,
        'Thursday' => :thursday,
        'Friday' => :friday,
        'Saturday' => :saturday,
        'Sunday' => :sunday
      }.freeze
      FIELDS = {
        minute: %i[multiplier].freeze,
        hour: %i[multiplier minute_offset].freeze,
        day: %i[hour_of_day minute_of_hour].freeze,
        week: %i[hour_of_day minute_of_hour monday tuesday wednesday thursday friday saturday sunday].freeze
      }.freeze
      BOOLEAN_FIELDS = %i[monday tuesday wednesday thursday friday saturday sunday].freeze
      private_constant :FIELDS, :BOOLEAN_FIELDS

      class << self
        def kind(type)
          name = type.to_s
          TYPES.key(name) || TYPES.keys.find { |candidate| candidate.to_s == name }
        end

        def compatible?(type, properties = {})
          return false unless properties.is_a?(Hash)
          return false unless properties.keys.all? { |key| PROPERTY_NAMES.key?(key) }

          new(type, properties:)
          true
        rescue ArgumentError, TypeError
          false
        end
      end

      def initialize(type, id: nil, properties: {})
        @kind = self.class.kind(type)
        unless @kind
          raise ArgumentError, "unsupported typed schedule #{type.inspect}; use the legacy properties API"
        end

        @id = id.to_s.dup.freeze
        @properties = {}
        assigned = {}
        properties.to_h.each do |key, value|
          field = property_name(key)
          raise ArgumentError, "duplicate schedule property #{field}" if assigned.key?(field)

          public_send(field, value)
          assigned[field] = true
        end
      end

      PROPERTY_NAMES.each_value do |field|
        define_method(field) do |value|
          unless FIELDS.fetch(@kind).include?(field)
            raise ArgumentError, "#{field} is not a property of #{@kind} schedules"
          end
          validate_value!(field, value)
          @properties[PROPERTY_NAMES.key(field)] = value
          self
        end
      end

      def evaluate(&block)
        previous = @properties.dup
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      rescue StandardError
        @properties = previous
        raise
      end

      def properties = @properties.dup.freeze

      def build
        ScheduleDefinition.new(type: TYPES.fetch(@kind), id: @id, properties:)
      end

      private

      def property_name(key)
        name = key.to_s
        return PROPERTY_NAMES.fetch(name) if PROPERTY_NAMES.key?(name)

        field = name.to_sym
        return field if PROPERTY_NAMES.value?(field)

        raise ArgumentError, "unsupported typed schedule property #{key.inspect}; use the legacy properties API"
      end

      def validate_value!(field, value)
        return if value.nil?

        if BOOLEAN_FIELDS.include?(field)
          return if value.equal?(true) || value.equal?(false)

          raise TypeError, "#{field} requires true, false or nil"
        end
        raise TypeError, "#{field} requires an Integer or nil" unless value.is_a?(Integer)

        valid = case field
                when :multiplier then value.positive?
                when :hour_of_day then (0..23).cover?(value)
                else (0..59).cover?(value)
                end
        raise ArgumentError, "invalid schedule #{field}: #{value.inspect}" unless valid
      end
    end
  end
end
