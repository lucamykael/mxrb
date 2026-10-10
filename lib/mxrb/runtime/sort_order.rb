# frozen_string_literal: true

module Mxrb
  module Runtime
    # Database sort order of Mendix 11.12.1: NULL first in both directions,
    # strings without regard to case, false before true. Keys apply in one
    # stable pass, so rows that compare equal keep their stored order.
    module SortOrder
      module_function

      def sort(records, keys, &read)
        records.each_with_index.sort do |(left, left_index), (right, right_index)|
          compare_keys(left, right, keys, &read).nonzero? || (left_index <=> right_index)
        end.map(&:first)
      end

      def compare_keys(left, right, keys)
        keys.each do |attribute, descending|
          comparison = compare(yield(left, attribute), yield(right, attribute), descending)
          return comparison unless comparison.zero?
        end
        0
      end

      def compare(left, right, descending)
        return 0 if left.nil? && right.nil?
        return -1 if left.nil?
        return 1 if right.nil?

        comparison = sortable(left) <=> sortable(right)
        raise NativeRuntimeError, "cannot sort #{left.inspect} and #{right.inspect}" unless comparison

        descending ? -comparison : comparison
      end

      def sortable(value)
        case value
        when String then value.downcase
        when true, false then value ? 1 : 0
        else value
        end
      end
    end
  end
end
