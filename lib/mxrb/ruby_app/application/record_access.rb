# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Application
      # rubocop:disable Metrics
      # Lists, reads, creates, changes, commits and deletes records for the API.
      module RecordAccess
        def records(name, context: nil, association: nil, context_type: nil, context_id: nil,
                    filters: [], sort: [], offset: 0, limit: nil,
                    xpath: nil, xpath_context_type: nil, xpath_context_id: nil, xpath_variables: {})
          record_page(
            name, context:, association:, context_type:, context_id:, filters:, sort:, offset:, limit:,
                  xpath:, xpath_context_type:, xpath_context_id:, xpath_variables:
          ).fetch(:records)
        end

        def record_page(name, context: nil, association: nil, context_type: nil, context_id: nil,
                        filters: [], sort: [], offset: 0, limit: nil,
                        xpath: nil, xpath_context_type: nil, xpath_context_id: nil, xpath_variables: {})
          runtime_synchronize do
            filter = [association, context_type, context_id]
            if filter.any? && !filter.all? { !_1.to_s.empty? }
              raise ArgumentError,
                    'association filter requires association, context_type, and context_id'
            end
            store = bridge.interpreter.store
            values = if filter.all? { !_1.to_s.empty? }
                       parent = store.find(context_type.to_s, context_id.to_s)
                       if parent
                         authorize_entity!(parent.entity, :read, context, record: parent)
                         authorize_entity!(parent.entity, :read, context, member: association.to_s.split('.').last,
                                                                          record: parent)
                       end
                       parent ? store.retrieve_association(association.to_s, parent) : []
                     else
                       store.retrieve(name.to_s)
                     end
            values = values.select do |value|
              value.entity == name.to_s || (store.respond_to?(:schema) && store.schema.assignable?(value.entity,
                                                                                                   name.to_s))
            end
            if context
              values = values.select do |value|
                access_control.entity_allowed?(value.entity, action: :read, context:, record: value)
              end
            end
            unless xpath.nil?
              current = nil
              if xpath_context_type || xpath_context_id
                raise ArgumentError, 'XPath context requires type and id' if
                  xpath_context_type.to_s.empty? || xpath_context_id.to_s.empty?

                current = store.find(xpath_context_type, xpath_context_id)
                raise ArgumentError, 'XPath context object not found' unless current

                authorize_entity!(current.entity, :read, context, record: current)
              end
              constraint = Runtime::XPath.new(xpath, store:, policy: context && access_control, context:)
              variables = xpath_variable_values(xpath_variables, store, context)
              values = constraint.filter(values, variables.merge('currentObject' => current))
            end
            values = values.select { grid_record_matches?(_1, filters) }
            values = grid_sort_records(values, sort)
            total = values.length
            normalized_offset = Integer(offset || 0)
            normalized_limit = limit.nil? || limit.to_s.empty? ? nil : Integer(limit)
            raise ArgumentError, 'record offset must be non-negative' if normalized_offset.negative?
            raise ArgumentError, 'record limit must be positive' if normalized_limit && !normalized_limit.positive?

            values = values.drop(normalized_offset)
            values = values.first(normalized_limit) if normalized_limit
            { records: values.map { serialize(_1, context:) }, total: }
          ensure
            release_runtime_cache
          end
        end

        def record(name, id, context: nil)
          runtime_synchronize do
            value = bridge.interpreter.store.find(name.to_s, id.to_s)
            next unless value
            next unless !context || access_control.entity_allowed?(value.entity, action: :read, context:, record: value)

            serialize(value, context:)
          end
        end

        def create_record(name, attributes = nil, context: nil, **keyword_attributes)
          runtime_synchronize do
            attributes = keyword_attributes if attributes.nil?
            authorize_entity!(name, :create, context)
            bridge.interpreter.store.transaction do
              value = bridge.interpreter.store.create(name.to_s)
              attributes.to_h.each do |member, member_value|
                authorize_entity!(name, :write, context, member: member, record: value)
                value.members[member.to_s] = deserialize(member_value, context:)
              end
              bridge.interpreter.store.commit(value)
              serialize(value, context:)
            end
          end
        end

        # Client-created objects remain private to the browser until Save. The
        # temporary store object is removed before this synchronized call returns.
        def draft_record(name, context: nil)
          raise ArgumentError, 'type must be a nonempty string' unless name.is_a?(String) && !name.empty?

          runtime_synchronize do
            authorize_entity!(name, :create, context)
            store = bridge.interpreter.store
            value = store.create(name.to_s)
            begin
              serialize(value, context:).except(:draft_token).merge(new_record: true)
            ensure
              store.rollback(value)
            end
          end
        end

        # Storage restoration creates an uncommitted object, with a capability that
        # lets subsequent microflows resume it without persisting it prematurely.
        def restore_record(name, attributes, context: nil)
          unless name.is_a?(String) && !name.empty? && attributes.is_a?(Hash)
            raise ArgumentError, 'restore requires an entity type and attributes'
          end

          runtime_synchronize do
            authorize_entity!(name, :create, context)
            store = bridge.interpreter.store
            store.transaction do
              value = store.create(name)
              attributes.each do |member, member_value|
                authorize_entity!(name, :write, context, member:, record: value)
                value.members[member] = deserialize(member_value, context:)
              end
              serialize(value, context:)
            end
          ensure
            release_runtime_cache
          end
        end

        def delete_records(records, context: nil)
          unless records.is_a?(Array) && records.length <= 1000 && records.all? do |entry|
            entry.is_a?(Hash) && %w[type id].all? { entry[_1].is_a?(String) && !entry[_1].empty? }
          end
            raise ArgumentError, 'records must contain at most 1000 objects with type and id'
          end

          runtime_synchronize do
            bridge.interpreter.store.transaction do
              records.each do |entry|
                store = bridge.interpreter.store
                value = store.find(entry.fetch('type'), entry.fetch('id'))
                raise ArgumentError, 'record not found' unless value

                authorize_entity!(value.entity, :delete, context, record: value)
                store.delete(value)
                FileContent.new(store.database).delete(value.entity, value.id)
              end
            end
          end
          true
        end

        def delete_record(name, id, context: nil)
          runtime_synchronize do
            value = bridge.interpreter.store.find(name.to_s, id.to_s)
            next false unless value

            name = value.entity
            authorize_entity!(name, :delete, context, record: value)
            bridge.interpreter.store.transaction do
              bridge.interpreter.store.delete(value)
              FileContent.new(bridge.interpreter.store.database).delete(name, id)
            end
            true
          end
        end

        def update_record(name, id, attributes, context: nil)
          runtime_synchronize do
            value = bridge.interpreter.store.find(name.to_s, id.to_s)
            next unless value

            name = value.entity
            authorize_entity!(name, :write, context, record: value)
            bridge.interpreter.store.transaction do
              attributes.to_h.each do |member, member_value|
                authorize_entity!(name, :write, context, member: member, record: value)
                value.members[member.to_s] = deserialize(member_value, context:)
              end
              bridge.interpreter.store.commit(value)
              serialize(value, context:)
            end
          end
        end

        # Commit page drafts together: a missing object or denied member rolls
        # back every object, including the store's identity map.
        def commit_records(records, context: nil)
          unless records.is_a?(Array) && records.length <= 1000 && records.all? { valid_record_changes?(_1) }
            raise ArgumentError, 'records must contain at most 1000 objects with type, id and attributes'
          end

          keys = records.map { [_1.fetch('type'), _1.fetch('id')] }
          raise ArgumentError, 'duplicate record in commit' unless keys.uniq.size == keys.size

          runtime_synchronize do
            store = bridge.interpreter.store
            store.transaction do
              objects = records.to_h do |entry|
                key = [entry.fetch('type'), entry.fetch('id')]
                value = if entry['draft_token']
                          deserialize(entry, context:)
                        elsif entry['new_record'] == true
                          authorize_entity!(key.first, :create, context)
                          store.create(key.first)
                        else
                          store.find(*key)
                        end
                raise ArgumentError, "record #{key.join(' ')} not found" unless value

                authorize_entity!(value.entity, :create, context) if entry['draft_token']
                authorize_entity!(value.entity, :write, context, record: value)
                [key, value]
              end
              records.each do |entry|
                value = objects.fetch([entry.fetch('type'), entry.fetch('id')])
                entry.fetch('attributes').each do |member, member_value|
                  authorize_entity!(value.entity, :write, context, member:, record: value)
                  value.members[member] = deserialize_draft_member(member_value, objects, context:)
                end
              end
              store.database.execute('PRAGMA defer_foreign_keys = ON')
              store.commit(objects.values)
              records.map do |entry|
                value = objects.fetch([entry.fetch('type'), entry.fetch('id')])
                result = serialize(value, context:)
                result[:draft_id] = entry.fetch('id') if entry['new_record'] == true
                result
              end
            end
          ensure
            release_runtime_cache
          end
        end

        def file_content(name, id, context: nil, upload: nil, thumbnail: nil)
          if upload && (!upload.is_a?(Hash) || !%w[name content].all? { upload[_1].is_a?(String) })
            raise ArgumentError, 'file upload requires string name and base64 content'
          end

          runtime_synchronize do
            store = bridge.interpreter.store
            value = store.find(name.to_s, id.to_s)
            next unless value

            name = value.entity
            authorize_entity!(name, :read, context, record: value)
            authorize_entity!(name, upload ? :write : :read, context, member: 'Contents', record: value)
            files = FileContent.new(store.database)
            next files.thumbnail(name, id, *thumbnail) if thumbnail && !upload
            next files.read(name, id) unless upload

            store.transaction do
              files.attach(store.schema.entity(name))
              policy = Registry.fetch(:record, name.to_s)&.runtime_file_policy || {}
              metadata = files.write(name, id, upload.fetch('name'), upload.fetch('content'), **policy)
              fields = store.schema.entity(name).columns.map(&:name)
              { 'Name' => metadata.fetch(:name), 'FileSize' => metadata.fetch(:size),
                'HasContents' => true }.each do |key, item|
                value.members[key] = item if fields.include?(key)
              end
              store.commit(value)
              metadata
            end
          end
        end

        private

        # Nanoflow XPath variables: objects as {type, id} (read-authorized), tagged decimals and scalars.
        def xpath_variable_values(values, store, context)
          raise ArgumentError, 'XPath variables must be an object' unless values.is_a?(Hash)

          values.to_h do |name, value|
            next [name.to_s, Runtime::DecimalValues.parse(value.fetch(Runtime::DecimalValues::TAG))] if
              Runtime::DecimalValues.tagged?(value)
            next [name.to_s, value] unless value.is_a?(Hash)

            object = store.find(value['type'].to_s, value['id'].to_s)
            raise ArgumentError, "XPath variable $#{name} object not found" unless object

            authorize_entity!(object.entity, :read, context, record: object)
            [name.to_s, object]
          end
        end

        def deserialize_draft_member(value, objects, context:)
          value = value.transform_keys(&:to_s) if value.is_a?(Hash) && value.key?(:type) && value.key?(:id)
          if value.is_a?(Hash) && value['type'] && value['id']
            objects[[value['type'], value['id']]] || deserialize(value, context:)
          elsif value.is_a?(Hash)
            value.transform_values { deserialize_draft_member(_1, objects, context:) }
          elsif value.is_a?(Array)
            value.map { deserialize_draft_member(_1, objects, context:) }
          else
            value
          end
        end

        def valid_record_changes?(entry)
          entry.is_a?(Hash) && %w[type id].all? { entry[_1].is_a?(String) && !entry[_1].empty? } &&
            entry['attributes'].is_a?(Hash) && entry['attributes'].keys.all? { _1.is_a?(String) }
        end

        def grid_record_matches?(record, filters)
          Array(filters).all? do |raw|
            filter = raw.to_h.transform_keys(&:to_s)
            type = filter.fetch('type', 'text').to_s.downcase
            allowed = GRID_FILTER_OPERATORS[type] || raise(ArgumentError, "unsupported filter type #{type}")
            operator = filter.fetch('operator', GRID_DEFAULT_OPERATORS.fetch(type)).to_s.downcase
            raise ArgumentError, "unsupported #{type} filter operator #{operator}" unless allowed.include?(operator)

            attribute = grid_member_name(filter.fetch('attribute'))
            grid_filter_match?(record.members[attribute], filter['value'], type, operator)
          end
        end

        def grid_filter_match?(actual, expected, type, operator)
          return actual.nil? || actual.to_s.empty? if operator == 'empty'
          return !actual.nil? && !actual.to_s.empty? if operator == 'not_empty'

          left = grid_filter_value(actual, type)
          right = grid_filter_value(expected, type)
          return false if left.nil? || right.nil?
          return Array(right).include?(left) if type == 'enum' && operator == 'equals' && right.is_a?(Array)

          case operator
          when 'contains' then left.include?(right)
          when 'starts_with' then left.start_with?(right)
          when 'ends_with' then left.end_with?(right)
          when 'equals' then left == right
          when 'not_equals' then left != right
          when 'gt', 'after' then left > right
          when 'gte', 'on_or_after' then left >= right
          when 'lt', 'before' then left < right
          when 'lte', 'on_or_before' then left <= right
          when 'between'
            bounds = Array(expected).map { grid_filter_value(_1, type) }
            bounds.size == 2 && bounds.none?(&:nil?) && left >= bounds[0] && left <= bounds[1]
          end
        end

        def grid_filter_value(value, type)
          return value.map { grid_filter_value(_1, type) } if value.is_a?(Array)

          case type
          when 'text', 'enum' then value.to_s.downcase
          when 'number' then Runtime::DecimalValues.parse(value)
          when 'date' then Date.iso8601(value.to_s[0, 10])
          when 'boolean'
            return value if [true, false].include?(value)
            return true if value.to_s.casecmp?('true')

            false if value.to_s.casecmp?('false')
          end
        rescue ArgumentError, TypeError
          nil
        end

        def grid_sort_records(records, sortings)
          keys = Array(sortings).map do |raw|
            sorting = raw.to_h.transform_keys(&:to_s)
            direction = sorting.fetch('direction', 'Ascending').to_s
            unless %w[Ascending Descending asc desc].include?(direction)
              raise ArgumentError, "unsupported sort direction #{direction}"
            end

            [Runtime::SortPath.parse(sorting.fetch('attribute')), %w[Descending desc].include?(direction)]
          end
          read = Runtime::SortPath.reader { bridge.interpreter.store }
          Runtime::SortOrder.sort(records, keys) { |record, path| read.call(record, path) }
        end

        def grid_member_name(value)
          name = value.to_s.split(%r{[./]}).last.to_s
          raise ArgumentError, 'filter/sort attribute cannot be empty' if name.empty?

          name
        end
      end
      # rubocop:enable Metrics
    end
  end
end
