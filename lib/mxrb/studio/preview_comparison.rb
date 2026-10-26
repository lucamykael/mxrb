# frozen_string_literal: true

require_relative 'structure'

module Mxrb
  module Studio
    # Describes the actual generated model, not a three-way merge or an apply
    # plan. Reconciled element identities are display hints only.
    class PreviewComparison
      def initialize(before, after, context:)
        @context = context
        @before = read_units(before)
        @after = read_units(after)
      end

      def units
        (@before.keys | @after.keys).sort.filter_map do |id|
          @context.check!
          describe_unit(id, @before[id], @after[id])
        end
      end

      private

      def read_units(path)
        mpr = IO::MprFile.open(path, readonly: true, apply_studio_compatibility: false)
        begin
          mpr.all_units.to_h do |unit|
            @context.check!
            [unit.fetch('UnitID'), { container: unit.fetch('ContainerID'),
                                     containment: unit.fetch('ContainmentName'), document: mpr.parse_contents(unit) }]
          end
        ensure
          mpr.close
        end
      end

      def describe_unit(id, before, after)
        document = (after || before).fetch(:document)
        action = change_action(before, after)
        changes = before && after ? modifications(before, after) : []
        return if action == 'modified' && changes.empty?

        { unit_id: id, type: document['$Type'], name: document['Name'], action:, changes: }
      end

      def change_action(before, after)
        return 'added' unless before

        after ? 'modified' : 'removed'
      end

      def modifications(before, after) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
        old = before.fetch(:document)
        generated = after.fetch(:document)
        changes = []
        unless before.values_at(:container, :containment) == after.values_at(:container, :containment)
          changes << { op: 'move', before: before.slice(:container, :containment),
                       after: after.slice(:container, :containment) }
        end
        return changes if Structure.fingerprint(old) == Structure.fingerprint(generated)

        aligned = Structure.reconcile(generated, old)
        operations = Structure.diff(old, aligned)
        if operations.empty?
          changes << { op: 'replace', before: present(old), after: present(aligned) }
        else
          operations.each { changes << describe_change(_1, old, aligned) }
        end
        changes
      end

      def describe_change(operation, before, after)
        id = operation[:element] || operation[:parent]
        old_nodes = Structure.index(before)
        new_nodes = Structure.index(after)
        nodes = new_nodes.key?(id) ? new_nodes : old_nodes
        { op: operation.fetch(:op), element: Structure.describe(nodes, id), key: operation[:key],
          before: change_value(operation, old_nodes[id]), after: change_value(operation, new_nodes[id]),
          before_present: property_present?(operation, old_nodes[id]),
          after_present: operation[:present] }.compact
      end

      # Set and order operations always name an element present on both sides.
      def property_present?(operation, node)
        node.element.key?(operation[:key]) if operation[:op] == 'set'
      end

      def change_value(operation, node)
        value = node&.element
        value = value.fetch(operation[:key], nil) if %w[set order].include?(operation[:op])
        present(value)
      end

      def present(value)
        case value
        when Hash then value.transform_values { present(_1) }
        when Array then value.map { present(_1) }
        when BSON::Binary then Structure.identity(value) || { binary_bytes: value.data.bytesize,
                                                              sha256: Digest::SHA256.hexdigest(value.data) }
        else Structure.present(value)
        end
      end
    end
  end
end
