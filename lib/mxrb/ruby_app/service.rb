# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Base for generated services. The default body executes through MXRB's
    # pure-Ruby native interpreter and can be replaced with idiomatic Ruby.
    class Service
      class << self
        attr_reader :mendix_id, :native_definition, :native_kind, :controller_definition

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          @mendix_name = value.to_s
          @mendix_id = SourceIdentity.resolve(self, :service, @mendix_name, id:)
          Registry.register(:service, @mendix_name, self, unit_id: @mendix_id)
        end

        # Declares how this Ruby service materializes as a Mendix flow. The
        # typed block is ordinary editable Ruby and supports both runtimes.
        def flow(kind = :microflow, public: false, export_level: 'Hidden', main: nil, &block)
          raise ArgumentError, 'use a main method or a definition block, not both' if main && block

          qualified = require_qualified_mendix_name!
          runtime, flow_kind = case kind.to_sym
                               when :microflow, :rule then %i[server use_case]
                               when :nanoflow then %i[client client_action]
                               else
                                 raise ArgumentError, 'flow kind must be microflow, nanoflow or rule'
                               end
          unit_id = native_unit_id(kind)
          SourceIdentity.validate_flow!(self, kind)
          @mendix_id = unit_id if @mendix_id.to_s.empty?
          native_type = { microflow: 'Microflows$Microflow', nanoflow: 'Microflows$Nanoflow',
                          rule: 'Microflows$Rule' }.fetch(kind.to_sym)
          builder = Dsl::FlowBuilder.new(
            qualified.split('.', 2).last,
            runtime:, kind: flow_kind, public:, unit_id:, metadata: FlowMetadata.for(unit_id, native_type)
          )
          if main
            Dsl::FlowProgram.apply(self, builder, entry: main)
          elsif block
            builder.instance_eval(&block)
          end
          FlowMetadata.validate!(unit_id, native_type, builder)
          @native_kind = kind.to_sym
          @native_definition = builder.to_h
          @native_definition[:export_level] = export_level.to_s if kind.to_sym == :rule
          @native_definition
        end

        # Compatibility for Ruby applications exported before `flow` became
        # the public, domain-oriented name.
        alias native flow

        def controller(controller_class, action:)
          unless controller_class.is_a?(String) || controller_class.is_a?(Symbol) ||
                 (controller_class.is_a?(Class) && controller_class <= Controller)
            raise ArgumentError, 'controller must be a registered name or RubyApp::Controller class'
          end

          action_name = action.to_sym
          raise ArgumentError, 'controller action cannot be empty' if action_name.to_s.empty?

          @controller_definition = { controller: controller_class, action: action_name }.freeze
        end

        private

        def require_qualified_mendix_name!
          value = @mendix_name.to_s
          return value if value.match?(/\A[A-Za-z_]\w*\.[A-Za-z_]\w*\z/)

          raise ArgumentError, 'call mendix_name with Module.Document before flow'
        end

        def native_unit_id(kind)
          return @mendix_id unless @mendix_id.to_s.empty?

          hex = Digest::SHA1.hexdigest("mxrb:ruby:#{kind}:#{@mendix_name}")
          "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
        end
      end

      def initialize(application, context: nil)
        @application = application
        @context = context
      end

      def call(**arguments) = native_call(arguments)

      private

      def execute_flow(arguments) = native_call(arguments)

      def native_call(arguments)
        if (definition = self.class.controller_definition)
          controller_class = definition.fetch(:controller)
          unless controller_class.is_a?(Class)
            controller_class = Registry.fetch(:controller, controller_class.to_s)
            raise ValidationError, "controller #{definition.fetch(:controller)} is not registered" \
              unless controller_class
          end
          controller = controller_class.new(@application, context: @context)
          return controller.public_send(definition.fetch(:action), **arguments.transform_keys(&:to_sym))
        end

        @application.native_call(self.class.mendix_name, arguments, context: @context)
      end
    end
    # rubocop:enable Metrics
  end
end
