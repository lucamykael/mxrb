# frozen_string_literal: true

module Mxrb
  module Dsl
    # Method-oriented source for a flow. Methods compose the typed model; the
    # runtime evaluates its Mendix expressions and executes the resulting graph.
    class FlowProgram
      class << self
        def build(builder, entry: :main_line)
          apply(self, builder, entry:)
        end

        def apply(implementation, builder, entry: :main_line)
          raise ArgumentError, 'flow plan must be a class' unless implementation.is_a?(Class)

          program = implementation.allocate
          raise ArgumentError, "flow plan has no #{entry} method" unless program.respond_to?(entry, true)

          program.extend(Context)
          program.__send__(:compose, builder, entry)
        end
      end

      # Mixed into the isolated definition instance, never into a running service.
      module Context
        # Produces an ordinary Proc, binding a method/block to whichever typed
        # branch, loop or member builder invokes it. No global/current builder.
        def step(name = nil, &block)
          raise ArgumentError, 'step needs a method or a block, not both' if name && block
          raise ArgumentError, 'step needs a method or a block' unless name || block

          callable = callback(name, block)
          program = self
          proc { |builder| program.__send__(:within, builder) { program.instance_exec(&callable) } }
        end

        def decide(condition, branches: nil, cases: nil, if_true: nil, if_false: nil)
          bodies = decision_branches(branches, cases, if_true, if_false)
          program = self
          @flow_builder.decision(condition) do
            bodies.each { |value, body| on(value, &program.step(body)) }
          end
        end

        private

        def compose(builder, entry)
          @flow_builder = builder
          install_delegates
          __send__(:flow_contract) if entry.to_sym != :flow_contract && respond_to?(:flow_contract, true)
          __send__(entry)
        ensure
          @flow_builder = nil
        end

        def callback(name, block)
          return block if block
          return name if name.is_a?(Proc) || name.is_a?(Method)

          method(name)
        end

        def decision_branches(branches, cases, if_true, if_false)
          if [!branches.nil?, !cases.nil?, !if_true.nil? || !if_false.nil?].count(true) > 1
            raise ArgumentError, 'use one decision branch notation'
          end
          return branch_mapping(branches) unless branches.nil?
          return Array(cases).to_h unless cases.nil?

          { true => if_true, false => if_false }.compact
        end

        def branch_mapping(branches)
          raise ArgumentError, 'decision branches must be a mapping' unless branches.is_a?(Hash)

          branches
        end

        def install_delegates
          # Service#call is a runtime API, while FlowBuilder#call is a model
          # declaration. Definition-local delegates keep those two uses separate.
          methods = FlowBodyDsl.public_instance_methods + FlowBuilder.public_instance_methods(false) +
                    %i[on on_type otherwise argument]
          methods.uniq.each do |name|
            next if %i[step decide].include?(name)

            define_singleton_method(name) do |*arguments, **options, &block|
              @flow_builder.public_send(name, *arguments, **options, &block)
            end
          end
        end

        def within(builder)
          previous = @flow_builder
          @flow_builder = builder
          yield
        ensure
          @flow_builder = previous
        end
      end
    end
  end
end
