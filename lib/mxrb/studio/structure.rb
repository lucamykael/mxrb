# frozen_string_literal: true

require 'digest'
require 'json'
require_relative '../io/bson_codec'

module Mxrb
  module Studio
    # Element-level view of native Mendix documents. Every Hash with a `$ID`
    # is an element; arrays of elements are ordered child lists. The functions
    # here compare documents independently of key order and of freshly
    # generated IDs, align a generated document with the IDs of an existing
    # one, express the differences as element operations, detect when two
    # sets of operations touch the same element and apply operations to a
    # document while leaving everything else untouched.
    module Structure # rubocop:disable Metrics/ModuleLength
      UUID = IO::BsonCodec::UUID_PATTERN

      module_function

      def element?(value) = value.is_a?(Hash) && value.key?('$ID')

      # Lower-case UUID text for a Binary or String identifier, else nil.
      def identity(value)
        case value
        when BSON::Binary then value.data.bytesize == 16 ? IO::BsonCodec.blob_to_uuid(value.data) : nil
        when String then value.match?(UUID) ? value.downcase : nil
        end
      end

      def id_of(element) = identity(element['$ID'])

      def element_list?(value) = value.is_a?(Array) && value.any? { element?(_1) }

      # ── Fingerprints ─────────────────────────────────────────────────────

      # Stable digest of a document's meaning: keys are sorted and the IDs the
      # document defines are replaced by their depth-first position, so two
      # generations of the same Ruby that differ only in fresh IDs or property
      # order have the same fingerprint. External references are kept.
      def fingerprint(document)
        tokens = {}
        each_element(document) { |element| tokens[id_of(element)] ||= tokens.size }
        Digest::SHA256.hexdigest(JSON.generate(canonical(document, tokens)))
      end

      def canonical(value, tokens = {}) # rubocop:disable Metrics/CyclomaticComplexity
        case value
        when Hash then value.keys.sort.map { [_1, canonical(value[_1], tokens)] }
        when Array then [:list, value.map { canonical(_1, tokens) }]
        when BSON::Binary then reference(value, tokens) || [:binary, value.type.to_s, value.data.unpack1('H*')]
        when String then reference(value, tokens) || value
        when Float then value.finite? ? value : value.to_s
        when Integer, true, false, nil then value
        else [:value, value.class.name, value.to_s]
        end
      end

      def reference(value, tokens)
        token = tokens[identity(value)]
        [:local, token] if token
      end

      def equal?(left, right) = canonical(left) == canonical(right)

      def each_element(value, &block)
        case value
        when Hash
          yield value if element?(value)
          value.each_value { each_element(_1, &block) }
        when Array then value.each { each_element(_1, &block) }
        end
      end

      # ── Index ────────────────────────────────────────────────────────────

      Node = Struct.new(:element, :parent, :key)

      def index(document)
        nodes = {}
        visit = lambda do |value, parent, key|
          if value.is_a?(Hash)
            if element?(value)
              nodes[id_of(value)] = Node.new(value, parent, key)
              parent = id_of(value)
            end
            value.each { |child_key, child| visit.call(child, parent, element?(value) ? child_key : key) }
          elsif value.is_a?(Array)
            value.each { visit.call(_1, parent, key) }
          end
        end
        visit.call(document, nil, nil)
        nodes
      end

      def ancestors(nodes, id)
        chain = []
        current = nodes[id]&.parent
        while current && !chain.include?(current)
          chain << current
          current = nodes[current]&.parent
        end
        chain
      end

      # ── Reconciliation ──────────────────────────────────────────────────

      # Returns a copy of `generated` whose elements take the IDs of the
      # matching elements of `existing`: same ID first, then the same type and
      # unique name, then the remaining elements of the same type in order.
      def reconcile(generated, existing)
        mapping = {}
        pair(generated, existing, mapping) if comparable?(generated, existing)
        rewrite(generated, mapping)
      end

      def comparable?(left, right) = element?(left) && element?(right) && left['$Type'] == right['$Type']

      def pair(generated, existing, mapping)
        mapping[id_of(generated)] = existing['$ID']
        (generated.keys & existing.keys).each { pair_values(generated[_1], existing[_1], mapping) }
      end

      def pair_values(generated, existing, mapping)
        if comparable?(generated, existing)
          pair(generated, existing, mapping)
        elsif generated.is_a?(Array) && existing.is_a?(Array)
          pair_lists(generated.select { element?(_1) }, existing.select { element?(_1) }, mapping)
        elsif generated.is_a?(Hash) && existing.is_a?(Hash) && !element?(generated) && !element?(existing)
          (generated.keys & existing.keys).each { pair_values(generated[_1], existing[_1], mapping) }
        end
      end

      def pair_lists(generated, existing, mapping)
        free = existing.dup
        pending = []
        generated.each do |item|
          match = free.find { id_of(_1) == id_of(item) && _1['$Type'] == item['$Type'] }
          match ? claim(item, match, free, mapping) : pending << item
        end
        pending = pair_named(pending, free, mapping)
        pending.each do |item|
          match = free.find { _1['$Type'] == item['$Type'] }
          claim(item, match, free, mapping) if match
        end
      end

      def pair_named(pending, free, mapping)
        named = ->(list) { list.select { _1['Name'].is_a?(String) && !_1['Name'].empty? }.group_by { [_1['$Type'], _1['Name']] } }
        candidates = named.call(free)
        wanted = named.call(pending)
        pending.reject do |item|
          name = [item['$Type'], item['Name']]
          match = candidates[name]&.first
          next false unless match && candidates[name].size == 1 && wanted[name].size == 1

          claim(item, match, free, mapping)
          true
        end
      end

      def claim(item, match, free, mapping)
        free.delete_if { _1.equal?(match) }
        pair(item, match, mapping)
      end

      def rewrite(value, mapping)
        case value
        when Hash then value.to_h { |key, child| [key, rewrite(child, mapping)] }
        when Array then value.map { rewrite(_1, mapping) }
        when BSON::Binary, String
          target = mapping[identity(value)]
          target ? same_shape(value, target) : copy(value)
        else value
        end
      end

      def same_shape(value, target)
        return copy(target) if target.instance_of?(value.class)

        value.is_a?(String) ? identity(target) : BSON::Binary.new(IO::BsonCodec.uuid_to_blob(identity(target)), value.type)
      end

      def copy(value)
        case value
        when Hash then value.to_h { |key, child| [key, copy(child)] }
        when Array then value.map { copy(_1) }
        when BSON::Binary then BSON::Binary.new(value.data.dup, value.type)
        when String then value.dup
        else value
        end
      end

      # ── Differences ─────────────────────────────────────────────────────

      # Element operations that turn `before` into `after` (same ID space):
      # set (one property of an element), insert/remove (an element in a
      # child list) and order (the relative order of a child list).
      def diff(before, after)
        old_nodes = index(before)
        new_nodes = index(after)
        new_nodes.each_with_object([]) do |(id, node), operations|
          previous = old_nodes[id]
          next unless previous

          (previous.element.keys | node.element.keys).each do |key|
            next if key == '$ID'

            property_operations(id, key, previous.element, node.element, operations)
          end
        end
      end

      def property_operations(id, key, before, after, operations)
        old_value = before[key]
        new_value = after[key]
        if element_list?(old_value) || element_list?(new_value)
          list_operations(id, key, Array(old_value), Array(new_value), operations)
        elsif element?(old_value) && element?(new_value) && id_of(old_value) == id_of(new_value)
          nil # compared as an element of its own
        elsif !(before.key?(key) == after.key?(key) && equal?(old_value, new_value))
          operations << { op: 'set', element: id, key:, value: copy(new_value), present: after.key?(key) }
        end
      end

      def list_operations(parent, key, before, after, operations) # rubocop:disable Metrics/AbcSize
        old_ids = before.select { element?(_1) }.map { id_of(_1) }
        new_items = after.select { element?(_1) }
        new_ids = new_items.map { id_of(_1) }
        (old_ids - new_ids).each { operations << { op: 'remove', parent:, key:, element: _1 } }
        new_items.each_with_index do |item, position|
          next if old_ids.include?(id_of(item))

          operations << { op: 'insert', parent:, key:, element: id_of(item), value: copy(item),
                          after: position.zero? ? nil : new_ids[position - 1], marker: marker(after) }
        end
        common = new_ids & old_ids
        operations << { op: 'order', parent:, key:, order: common } unless (old_ids & new_ids) == common
      end

      def marker(list) = list.first.is_a?(Integer) ? list.first : nil

      # ── Conflicts ───────────────────────────────────────────────────────

      # Operations of `theirs` that touch what `ours` changed: the same
      # property set to different values, a change inside an element the other
      # side removed, or two different orders of the same list.
      def conflicts(base, ours, theirs)
        nodes = index(base)
        theirs.filter_map do |operation|
          clash = ours.find { clash?(operation, _1, nodes) }
          [operation, clash] if clash
        end
      end

      def clash?(left, right, nodes)
        return true if removes?(left, right, nodes) || removes?(right, left, nodes)

        if left[:op] == 'set' && right[:op] == 'set'
          left.values_at(:element, :key) == right.values_at(:element, :key) &&
            !(left[:present] == right[:present] && equal?(left[:value], right[:value]))
        elsif left[:op] == 'order' && right[:op] == 'order'
          left.values_at(:parent, :key) == right.values_at(:parent, :key) && left[:order] != right[:order]
        else
          false
        end
      end

      # True when `remover` removes an element that `other` changes or uses.
      def removes?(remover, other, nodes)
        return false unless remover[:op] == 'remove'
        return false if other[:op] == 'remove' && other[:element] == remover[:element]

        target = other[:op] == 'set' ? other[:element] : other[:parent]
        target == remover[:element] || ancestors(nodes, target).include?(remover[:element])
      end

      # ── Application ─────────────────────────────────────────────────────

      def apply(document, operations)
        result = copy(document)
        structural, properties = operations.partition { %w[remove insert].include?(_1[:op]) }
        structural.sort_by { _1[:op] == 'remove' ? 0 : 1 }.each { apply_structural(result, _1) }
        nodes = index(result)
        properties.each { apply_property(nodes, _1) }
        result
      end

      def apply_structural(document, operation)
        parent = index(document)[operation[:parent]]
        return unless parent

        list = parent.element[operation[:key]]
        if operation[:op] == 'remove'
          list&.reject! { element?(_1) && id_of(_1) == operation[:element] }
        else
          list = parent.element[operation[:key]] = [operation[:marker]].compact unless list.is_a?(Array)
          list.insert(insert_position(list, operation[:after]), copy(operation[:value]))
        end
      end

      def insert_position(list, after)
        position = list.index { element?(_1) && id_of(_1) == after } if after
        return position + 1 if position

        after ? list.length : (marker(list) ? 1 : 0)
      end

      def apply_property(nodes, operation)
        if operation[:op] == 'set'
          element = nodes[operation[:element]]&.element
          return unless element

          operation[:present] ? element[operation[:key]] = copy(operation[:value]) : element.delete(operation[:key])
        else
          list = nodes[operation[:parent]]&.element&.[](operation[:key])
          reorder(list, operation[:order]) if list.is_a?(Array)
        end
      end

      def reorder(list, order)
        slots = list.each_index.select { element?(list[_1]) && order.include?(id_of(list[_1])) }
        items = slots.map { list[_1] }.sort_by { order.index(id_of(_1)) }
        slots.zip(items).each { |slot, item| list[slot] = item }
      end

      # ── Presentation ────────────────────────────────────────────────────

      def describe(nodes, id)
        node = nodes[id]
        return { id: } unless node

        path = (ancestors(nodes, id).reverse + [id]).map { label(nodes[_1]) }
        { id:, type: node.element['$Type'], name: node.element['Name'], path: path.join(' / ') }
      end

      def label(node)
        name = node.element['Name']
        type = node.element['$Type'].to_s.split('$').last
        name.is_a?(String) && !name.empty? ? "#{type} #{name}" : type.to_s
      end

      def present(value)
        case value
        when Hash then value.to_h { |key, child| [key, present(child)] }
        when Array then value.map { present(_1) }
        when BSON::Binary then identity(value) || { binary: value.data.unpack1('H*') }
        when Float then value.finite? ? value : value.to_s
        when String, Integer, true, false, nil then value
        else value.to_s
        end
      end
    end
  end
end
