# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Application
      # rubocop:disable Metrics
      # Converts records and values between Ruby objects and API payloads.
      module ValueSerialization
        private

        # Hashed strings such as System.User.Password never leave the server.
        def hashed_members(entity)
          (@hashed_members ||= {})[entity] ||= begin
            store = bridge.interpreter.store
            columns = store.respond_to?(:schema) ? store.schema.entity(entity).columns : []
            columns.select { _1.type == :hashstring }.map(&:name)
          rescue ArgumentError
            []
          end
        end

        def serialize(value, seen = {}, context: nil)
          case value
          when Runtime::Native::ObjectValue
            key = [value.entity, value.id]
            return { id: value.id, type: value.entity } if seen[key]

            branch = seen.merge(key => true)
            members = value.members.except(*hashed_members(value.entity))
            if context
              members = members.select do |member, _member_value|
                access_control.member_allowed?(
                  value.entity, member, action: :read, context:, record: value
                )
              end
            end
            result = { id: value.id, type: value.entity, attributes: serialize(members, branch, context:) }
            store = bridge.interpreter.store
            owner = draft_owner(context)
            if store.respond_to?(:draft?) &&
               (store.draft?(value) || store.client_drafts.registered?(value, owner:))
              token = store.client_drafts.capture(value, owner:)
              result.merge!(new_record: true, draft_token: token)
            end
            result
          when BigDecimal then Runtime::DecimalValues.encode(value)
          when Hash then value.to_h { [serialize(_1, seen, context:), serialize(_2, seen, context:)] }
          when Array then value.map { serialize(_1, seen, context:) }
          else value
          end
        end

        def deserialize(value = nil, context: nil, synchronize: false, **keyword_value)
          value = keyword_value if value.nil? && !keyword_value.empty?
          value = value.transform_keys(&:to_s) if value.is_a?(Hash) && value.key?(:id) && value.key?(:type)
          if Runtime::DecimalValues.tagged?(value)
            Runtime::DecimalValues.parse(value.fetch(Runtime::DecimalValues::TAG))
          elsif value.is_a?(Hash) && value['id'] && value['type']
            store = bridge.interpreter.store
            object = if value['draft_token']
                       store.client_drafts.resume(
                         value['draft_token'], entity: value['type'].to_s, id: value['id'].to_s,
                                               owner: draft_owner(context)
                       )
                     else
                       store.find(value['type'].to_s, value['id'].to_s)
                     end
            if !object && value['transient'] == true
              object = Runtime::Native::ObjectValue.new(
                entity: value['type'].to_s, id: value['id'].to_s, members: {}
              )
              value.fetch('attributes', {}).each do |member, member_value|
                object.members[member.to_s] = deserialize(member_value, context:, synchronize:)
              end
            end
            raise NativeRuntimeError, "object #{value['type']} #{value['id']} not found" unless object

            authorize_entity!(object.entity, :read, context, record: object)

            value.fetch('attributes', {}).each do |member, member_value|
              next unless synchronize

              authorize_entity!(object.entity, :write, context, member:, record: object)
              object.members[member.to_s] = deserialize(member_value, context:, synchronize:)
            end
            object
          elsif value.is_a?(Hash)
            value.to_h do
              [deserialize(_1, context:, synchronize:), deserialize(_2, context:, synchronize:)]
            end
          elsif value.is_a?(Array)
            value.map { deserialize(_1, context:, synchronize:) }
          else
            value
          end
        end

        def synchronize_context(value, context:)
          store = bridge.interpreter.store
          object = deserialize(value, context:)
          return object unless object.is_a?(Runtime::Native::ObjectValue) && value.is_a?(Hash)

          stage_reachable_drafts(object, context:)
          changes = value.fetch('attributes', {}).filter_map do |member, member_value|
            resolved = deserialize(member_value, context:)
            [member.to_s, resolved] unless context_values_equal?(object.members[member.to_s], resolved)
          end
          return object if changes.empty?

          apply = lambda do
            changes.each do |member, member_value|
              authorize_entity!(object.entity, :write, context, member:, record: object)
              object.members[member] = member_value
            end
            store.commit(object) if value['transient'] != true && !value['draft_token'] && store.respond_to?(:commit)
            object
          end
          return apply.call unless store.respond_to?(:transaction)

          store.transaction { apply.call }
        end

        def context_values_equal?(current, incoming)
          if current.is_a?(Runtime::Native::ObjectValue) || incoming.is_a?(Runtime::Native::ObjectValue)
            return current.is_a?(Runtime::Native::ObjectValue) &&
                   incoming.is_a?(Runtime::Native::ObjectValue) &&
                   current.entity == incoming.entity && current.id == incoming.id
          end
          if current.is_a?(Array) || incoming.is_a?(Array)
            return false unless current.is_a?(Array) && incoming.is_a?(Array) && current.size == incoming.size

            return current.zip(incoming).all? { context_values_equal?(_1, _2) }
          end
          if current.respond_to?(:iso8601) && incoming.is_a?(String)
            return Time.parse(incoming).to_i == Time.parse(current.iso8601).to_i
          end

          current == incoming
        rescue ArgumentError
          false
        end
      end
      # rubocop:enable Metrics
    end
  end
end
