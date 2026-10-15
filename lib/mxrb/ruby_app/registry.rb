# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Per-process registry populated by conventional app/**/*.rb files.
    module Registry
      ADAPTER_KINDS = %i[
        app_service web_service import_xml import_mapping export_mapping document regular_expression
      ].freeze
      COLLECTIONS = {
        constant: :@constants, enumeration: :@enumerations, record: :@records,
        controller: :@controllers, service: :@services, page: :@pages,
        module_security: :@module_security, project_security: :@project_security,
        scheduled_event: :@scheduled_events, regular_expression: :@regular_expressions, dataset: :@datasets,
        adapter: :@adapters, java_custom_action: :@java_custom_actions, presentation: :@presentation
      }.freeze

      module_function

      def reset!
        @constants = {}
        @enumerations = {}
        @records = {}
        @controllers = {}
        @services = {}
        @pages = {}
        @module_security = {}
        @project_security = {}
        @scheduled_events = {}
        @regular_expressions = {}
        @datasets = {}
        @adapters = {}
        @java_custom_actions = {}
        @presentation = {}
      end

      def register(kind, name, implementation, unit_id: nil)
        return register_service(name, implementation, unit_id:) if kind == :service

        collection(kind)[name] = implementation
      end

      def fetch(kind, name, unit_id: nil)
        return fetch_service(name, unit_id:) if kind == :service

        collection(kind)[name]
      end

      def all(kind) = collection(kind).dup.freeze

      def snapshot
        collection(:record)
        COLLECTIONS.to_h { |kind, variable| [kind, instance_variable_get(variable).dup] }.freeze
      end

      def restore!(state)
        COLLECTIONS.each do |kind, variable|
          instance_variable_set(variable, state.fetch(kind).dup)
        end
        self
      end

      def register_service(name, implementation, unit_id: nil)
        services = collection(:service)
        qualified_name = name.to_s
        identifier = unit_id.to_s
        matches = services.select do |_key, candidate|
          candidate.mendix_name.to_s == qualified_name
        end
        if matches.empty?
          services[qualified_name] = implementation
          return implementation
        end

        existing_ids = matches.values.map { _1.mendix_id.to_s }
        if identifier.empty? || existing_ids.any?(&:empty?)
          raise ValidationError,
                "ambiguous Ruby service #{qualified_name}: duplicate names require explicit unit ids"
        end

        if services.key?(qualified_name)
          existing = services.delete(qualified_name)
          services[service_key(qualified_name, existing.mendix_id)] = existing
        end
        services[service_key(qualified_name, identifier)] = implementation
        implementation
      end

      def fetch_service(name, unit_id: nil)
        services = collection(:service)
        qualified_name = name.to_s
        direct = services[qualified_name]
        return direct if direct && (unit_id.nil? || direct.mendix_id.to_s == unit_id.to_s)

        matches = services.values.select do |candidate|
          candidate.mendix_name.to_s == qualified_name &&
            (unit_id.nil? || candidate.mendix_id.to_s == unit_id.to_s)
        end
        return matches.first if matches.one?
        return nil if matches.empty?

        raise ValidationError,
              "ambiguous Ruby service #{qualified_name}: specify its unit id"
      end

      def service_key(name, unit_id) = [name.to_s, unit_id.to_s].freeze

      def register_adapter(kind, implementation = nil, &block)
        key = kind.to_sym
        raise ArgumentError, "unsupported Ruby adapter #{kind}" unless ADAPTER_KINDS.include?(key)

        callback = implementation || block
        raise ArgumentError, 'adapter must respond to call' unless callback.respond_to?(:call)

        register(:adapter, key, callback)
        callback
      end

      def adapters = all(:adapter)

      def register_java_custom_action(name, implementation = nil, with_store: false, with_context: false, &block)
        qualified_name = name.to_s
        unless qualified_name.match?(/\A[A-Za-z_]\w*\.[A-Za-z_]\w*\z/)
          raise ArgumentError, "Java Custom Action name must be qualified as Module.Action: #{name}"
        end

        callback = implementation || block
        raise ArgumentError, 'Java Custom Action adapter must respond to call' unless callback.respond_to?(:call)

        raise ArgumentError, 'choose with_store or with_context, not both' if with_store && with_context

        callback = Runtime::Native::StoreJavaAction.new(callback) if with_store
        callback = Runtime::Native::ContextJavaAction.new(callback) if with_context

        register(:java_custom_action, qualified_name, callback)
        callback
      end

      def java_custom_actions = all(:java_custom_action)

      def collection(kind)
        reset! unless defined?(@records) && @records
        instance_variable_get(COLLECTIONS.fetch(kind))
      end
    end
    # rubocop:enable Metrics
  end
end
