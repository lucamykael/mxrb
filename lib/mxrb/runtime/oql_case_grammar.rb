# frozen_string_literal: true

module Mxrb
  module Runtime
    # Searched and simple CASE, and the common type of alternative values.
    module OqlCaseGrammar
      private

      def case_expression
        subject = additive unless @tokens.first.to_s.casecmp?('WHEN')
        branches = case_branches(subject)
        fallback = take('ELSE') ? additive : literal(:null, nil)
        expect('END')
        type, scale = common_type(branches.map(&:last) << fallback)
        term(type, scale, case_reader(branches, fallback))
      end

      def case_branches(subject)
        branches = []
        branches << case_branch(subject) while take('WHEN')
        error!('CASE requires WHEN') if branches.empty?
        branches
      end

      def case_branch(subject)
        condition = subject ? simple_condition(subject, additive) : boolean(disjunction)
        expect('THEN')
        [condition, additive]
      end

      # A simple CASE compares with =, where NULL never matches.
      def simple_condition(subject, value)
        return literal(:boolean, false) if value.kind == :null

        validate_comparison(subject, value, '=')
        comparison_reader(subject, value, '=')
      end

      def case_reader(branches, fallback)
        lambda do |row|
          branch = branches.find { |condition, _value| condition.read.call(row) == true }
          (branch&.last || fallback).read.call(row)
        end
      end

      def common_type(values)
        typed = values.reject { _1.kind == :null }
        error!('expected a typed value') if typed.empty?
        error!('incompatible value types') unless typed.map(&:kind).uniq.one?
        return [typed.first.type, 0] unless typed.first.kind == :number

        [numeric_type(typed), typed.map(&:scale).max]
      end
    end
  end
end
