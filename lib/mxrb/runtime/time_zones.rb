# frozen_string_literal: true

require 'tzinfo'
require_relative '../io/bson_codec'

module Mxrb
  module Runtime
    # The Runtime's System.TimeZone objects and the time zone a session runs in:
    # the user's time zone when set, otherwise the one the browser reports, otherwise
    # UTC. New users get the project's default time zone, as in Studio Pro.
    module TimeZones
      ZONE = 'System.TimeZone'
      USER_ZONE = 'User_TimeZone'

      module_function

      def settings(project)
        return project.time_zone_settings if project.respond_to?(:time_zone_settings)

        code = model_settings(project)['DefaultTimeZoneCode'].to_s
        code.empty? ? {} : { 'default' => code }
      end

      def model_settings(project)
        return {} unless project.respond_to?(:all_units)

        root = project.all_units.map { project.parse_bson(_1) }.find { _1['$Type'] == 'Settings$ProjectSettings' }
        return {} unless root

        IO::BsonCodec.parse_array(root['Settings'])[:items].find { _1['$Type'] == 'Settings$ModelSettings' } || root
      end

      # An IANA identifier the session can run in, or nil.
      def valid(code)
        code = code.to_s.strip
        return nil if code.empty?

        TZInfo::Timezone.get(code).identifier
      rescue TZInfo::InvalidTimezoneIdentifier
        nil
      end

      # Creates the System.TimeZone objects that are missing, one per IANA zone.
      def synchronize(store, identifiers: TZInfo::Timezone.all_identifiers)
        existing = store.retrieve(ZONE).to_h { [_1.members['Code'], _1] }
        missing = identifiers.reject { existing.key?(_1) }
        return if missing.empty?

        store.transaction { create_zones(store, missing) }
      end

      def create_zones(store, identifiers)
        identifiers.each do |code|
          zone = store.create(ZONE)
          offset = TZInfo::Timezone.get(code).base_utc_offset
          zone.members.merge!('Code' => code, 'Description' => description(code, offset),
                              'RawOffset' => offset * 1000)
          store.commit(zone)
        end
      end

      def description(code, offset)
        sign = offset.negative? ? '-' : '+'
        hours, minutes = offset.abs.divmod(3600)
        format('(GMT%s%02d:%02d) %s', sign, hours, minutes / 60, code)
      end

      # The time zone code of a user's System.User_TimeZone, if any.
      def of_user(store, user_id)
        user = user_id && store.find(SystemDomain::USER, user_id.to_s)
        zone = user && store.retrieve_association(USER_ZONE, user).first
        valid(zone&.members&.fetch('Code', nil))
      end

      # Gives a new user (or specialization) the default time zone.
      def assign_default(store, value, code)
        return unless code && value.members[USER_ZONE].nil?
        return unless store.schema.assignable?(value.entity, SystemDomain::USER)

        zone = store.retrieve(ZONE).find { _1.members['Code'] == code }
        value.members[USER_ZONE] = zone if zone
      end
    end
  end
end
