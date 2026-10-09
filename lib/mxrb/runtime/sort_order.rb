# frozen_string_literal: true

module Mxrb
  module Runtime
    # Sort orders of Mendix 11.12.1. The database order places NULL first in
    # both directions and compares strings without regard to case. The
    # in-memory list Sort places NULL last in both directions and breaks case
    # ties lowercase first, like a Java collator. Both order false before true
    # and apply all keys in one stable pass.
    module SortOrder
      module_function

      def sort(records, keys, memory: false, &read)
        records.each_with_index.sort do |(left, left_index), (right, right_index)|
          compare_keys(left, right, keys, memory:, &read).nonzero? || (left_index <=> right_index)
        end.map(&:first)
      end

      def compare_keys(left, right, keys, memory: false)
        keys.each do |attribute, descending|
          comparison = compare(yield(left, attribute), yield(right, attribute), descending, memory:)
          return comparison unless comparison.zero?
        end
        0
      end

      def compare(left, right, descending, memory: false)
        return null_order(left, right, memory) if left.nil? || right.nil?

        comparison = sortable(left, memory) <=> sortable(right, memory)
        raise NativeRuntimeError, "cannot sort #{left.inspect} and #{right.inspect}" unless comparison

        descending ? -comparison : comparison
      end

      def null_order(left, right, memory)
        return 0 if left.nil? && right.nil?

        (left.nil? ? -1 : 1) * (memory ? -1 : 1)
      end

      def sortable(value, memory)
        case value
        when String then memory ? [value.downcase, value.swapcase] : value.downcase
        when true, false then value ? 1 : 0
        else value
        end
      end
    end
  end
end
