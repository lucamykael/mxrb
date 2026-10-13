# frozen_string_literal: true

module Mxrb
  module RubyApp
    AccessRuleMember = Data.define(:name, :rights, :id, :reference, :kind)

    # Ordered member declarations shared by persistent models and DTOs.
    class AccessRuleBuilder
      def initialize(members = [])
        @members = Array(members).dup
      end

      def member(name, rights:, id: nil, reference: nil, kind: :attribute)
        raise ArgumentError, 'access member requires a name' if name.to_s.empty?

        @members << AccessRuleMember.new(name:, rights:, id:, reference:, kind:)
      end

      def evaluate(&block)
        block.arity == 1 ? block.call(self) : instance_eval(&block)
        self
      end

      def members = @members.dup.freeze
    end
  end
end
