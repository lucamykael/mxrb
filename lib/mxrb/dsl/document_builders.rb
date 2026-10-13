# frozen_string_literal: true

module Mxrb
  module Dsl
    class EnumerationBuilder
      attr_reader :name

      def initialize(name, **options)
        @name = name.to_s
        @values = []
        @id = options[:id]&.to_s
        @unit_id = options[:unit_id]&.to_s
        @doc = options.fetch(:documentation, '').to_s
        @excluded = options.fetch(:excluded, false) == true
        @export_level = options.fetch(:export_level, 'Hidden').to_s
        @remote_source = options[:remote_source]
        if options[:remote_service]
          remote_id = options[:remote_source_id].to_s
          @remote_source = {
            '$ID' => remote_id.empty? ? SecureRandom.uuid : remote_id,
            '$Type' => 'Rest$ODataRemoteEnumerationSource',
            'ConsumedODataService' => options.fetch(:remote_service).to_s,
            'RemoteName' => options.fetch(:remote_name, '').to_s
          }
        end
        @values_marker = options.fetch(:values_marker, 3).to_i
      end

      def value(name, caption: nil, captions: nil, id: nil, caption_id: nil,
                caption_ids: {}, image: '', remote_value: nil, remote_id: nil,
                remote_name: nil,
                translations_marker: 3, export_level: nil)
        localized = normalized_captions(name, caption, captions)
        unless remote_name.nil?
          remote_value = {
            '$ID' => remote_id.to_s.empty? ? SecureRandom.uuid : remote_id.to_s,
            '$Type' => 'Rest$ODataRemoteEnumerationValue', 'RemoteName' => remote_name.to_s
          }
        end
        @values << {
          name: name.to_s, id: id&.to_s, caption_id: caption_id&.to_s,
          captions: localized.transform_keys(&:to_s).transform_values(&:to_s),
          caption_ids: caption_ids.to_h.transform_keys(&:to_s).transform_values(&:to_s),
          image: image.to_s, remote_value:, translations_marker: translations_marker.to_i,
          export_level: export_level&.to_s
        }
      end

      def documentation(d) = (@doc = d)

      def bson_binary(base64, subtype: :generic)
        BSON::Binary.new(Base64.strict_decode64(base64), subtype.to_sym)
      end

      def to_h
        {
          name: @name, id: @id, unit_id: @unit_id, values: @values,
          documentation: @doc, excluded: @excluded, export_level: @export_level,
          remote_source: @remote_source, values_marker: @values_marker
        }
      end

      private

      def normalized_captions(name, caption, captions)
        return captions.to_h unless captions.nil?

        { 'en_US' => caption.nil? ? name.to_s : caption }
      end
    end

    class ConstantBuilder
      include PresentationValues

      CONSTANT_TYPES = {
        string: 'DataTypes$StringType', integer: 'DataTypes$IntegerType',
        boolean: 'DataTypes$BooleanType', decimal: 'DataTypes$DecimalType',
        datetime: 'DataTypes$DateTimeType'
      }.freeze

      attr_reader :name

      def initialize(name, type:, value: nil, **options)
        @name = name.to_s
        @type = type.to_sym == :date_time ? :datetime : type.to_sym
        @value = value
        @id = options[:id]&.to_s
        @type_id = options[:type_id]&.to_s
        @unit_id = options[:unit_id]&.to_s
        @doc = options.fetch(:documentation, '').to_s
        @excluded = options.fetch(:excluded, false) == true
        @export_level = options.fetch(:export_level, 'Hidden').to_s
        @exposed_to_client = options.fetch(:exposed_to_client, false) == true
        @properties = presentation_value_document(options.fetch(:properties, {}))
        @type_properties = presentation_value_document(options.fetch(:type_properties, {}))
      end

      def documentation(d) = (@doc = d)

      def to_h
        {
          name: @name, type: @type, value: @value, documentation: @doc,
          id: @id, type_id: @type_id, unit_id: @unit_id, excluded: @excluded,
          export_level: @export_level, exposed_to_client: @exposed_to_client,
          properties: @properties, type_properties: @type_properties
        }
      end
    end

    class ScheduledEventBuilder
      INTERVAL_UNITS = {
        milliseconds: 'Millisecond', seconds: 'Second', minutes: 'Minute',
        hours: 'Hour', days: 'Day', weeks: 'Week', months: 'Month', years: 'Year'
      }.freeze

      attr_reader :name

      def initialize(name, microflow:, interval: 1, unit: :days, enabled: true,
                     unit_id: nil, container_id: nil, documentation: '', excluded: false,
                     export_level: 'Hidden', interval_type: nil, start_at: nil,
                     time_zone: 'UTC', on_overlap: 'SkipNext', schedule: :auto,
                     schedule_id: nil, multiplier: nil, minute_offset: nil,
                     hour_of_day: nil, minute_of_hour: nil, weekdays: [])
        @name      = name.to_s
        @microflow = microflow.to_s
        @interval  = interval.to_i
        @unit      = unit.to_sym
        @enabled   = enabled == true
        @unit_id   = unit_id&.to_s
        @container_id = container_id&.to_s
        @doc       = documentation.to_s
        @excluded  = excluded == true
        @export_level = export_level.to_s
        @interval_type = (interval_type || INTERVAL_UNITS.fetch(@unit) do
          raise ArgumentError, "unsupported scheduled event unit #{@unit.inspect}"
        end).to_s
        @start_at = start_at&.to_s
        @time_zone = time_zone.to_s
        @on_overlap = on_overlap.to_s
        @schedule_specified = schedule != :auto
        return unless @schedule_specified && !schedule.nil?

        @schedule = schedule_document(
          schedule, schedule_id:, multiplier:, minute_offset:, hour_of_day:,
                    minute_of_hour:, weekdays:
        )
      end

      def documentation(d) = (@doc = d)

      def to_h
        {
          name: @name, microflow: @microflow, interval: @interval,
          unit: @unit, enabled: @enabled, documentation: @doc, unit_id: @unit_id,
          container_id: @container_id,
          excluded: @excluded, export_level: @export_level,
          interval_type: @interval_type, start_at: @start_at,
          time_zone: @time_zone, on_overlap: @on_overlap,
          schedule_specified: @schedule_specified, schedule: @schedule
        }
      end

      private

      def schedule_document(kind, schedule_id:, multiplier:, minute_offset:,
                            hour_of_day:, minute_of_hour:, weekdays:)
        type = kind.to_s
        type = "ScheduledEvents$#{type.split('_').map!(&:capitalize).join}Schedule" \
          unless type.start_with?('ScheduledEvents$')
        properties = {}
        properties[:multiplier] = Integer(multiplier) unless multiplier.nil?
        properties[:minute_offset] = Integer(minute_offset) unless minute_offset.nil?
        properties[:hour_of_day] = Integer(hour_of_day) unless hour_of_day.nil?
        properties[:minute_of_hour] = Integer(minute_of_hour) unless minute_of_hour.nil?
        unless Array(weekdays).empty?
          enabled = Array(weekdays).map { _1.to_s.downcase }.to_h { [_1, true] }
          %w[monday tuesday wednesday thursday friday saturday sunday].each do |day|
            properties[day.to_sym] = enabled.fetch(day, false)
          end
        end
        { type:, id: schedule_id&.to_s, properties: }
      end
    end
  end
end
