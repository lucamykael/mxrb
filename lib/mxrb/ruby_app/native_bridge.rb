# frozen_string_literal: true

module Mxrb
  module RubyApp
    # rubocop:disable Metrics
    # Owns the source MPR and its pure-Ruby interpreter for one application.
    class NativeBridge
      attr_reader :access_control, :interpreter, :project, :scheduler, :store

      def initialize(path, database:, record_hooks: {}, adapters: {}, java_custom_actions: {},
                     allow_destructive: false, coordinator: nil, scheduler_lease_ttl: 300,
                     runtime_records: nil, runtime_project: nil, service_dispatch: nil, administrator_password: nil)
        FileUtils.mkdir_p(File.dirname(database))
        @project = runtime_project || Model::Project.open(path)
        schema = if runtime_project
                   Runtime::SchemaMigrator.derive_records(runtime_records)
                 elsif runtime_records
                   Runtime::SchemaMigrator.derive_overlay(@project, runtime_records)
                 end
        transient = runtime_records && runtime_transient_entities(runtime_records)
        store_options = { path: database, allow_destructive: }
        store_options.merge!(schema:, transient_entities: transient) if runtime_records
        @store = Runtime::SQLiteStore.new(@project, **store_options)
        @access_control = Runtime::AccessControl.new(@project)
        @interpreter = Runtime::Native::Interpreter.new(
          @project, store: @store, policy: @access_control, adapters:, java_custom_actions:, service_dispatch:
        )
        Runtime::SystemDomain.synchronize_roles(@store, @access_control.user_role_definitions)
        Runtime::Languages.synchronize(@store, Runtime::Languages.settings(@project))
        if administrator_password
          Runtime::SystemDomain.ensure_administrator(@store, password: administrator_password,
                                                             **@access_control.administrator)
        end
        register_record_hooks(record_hooks)
        validator = RecordValidation.new(record_hooks, @store)
        @store.on(:before_commit) { |value| validator.call(value) }
        policy = @access_control.password_policy
        @store.on(:before_commit) do |value|
          violation = policy.violation(value, @store.schema)
          raise RecordValidationError, [violation] if violation
        end
        @scheduler = Runtime::Scheduler.new(
          @project,
          executor: lambda { |name, **_metadata|
            service_dispatch ? service_dispatch.call(name, {}, nil) : @interpreter.call(name)
          }, coordinator:,
          lease_ttl: scheduler_lease_ttl
        )
      rescue StandardError
        close
        raise
      end

      def start_scheduler
        scheduler.start unless scheduler.jobs.empty?
        scheduler
      end

      def close
        scheduler&.shutdown
        store&.close
        project&.close
      end

      private

      def runtime_transient_entities(records)
        native = project.modules.flat_map do |mod|
          mod.entities.select { _1.persistable == false }.map { "#{mod.name}.#{_1.name}" }
        end
        ruby = records.to_h.values.select { _1.persistable == false }.map { _1.mendix_name.to_s }
        (native + ruby).uniq
      end

      def register_record_hooks(records)
        records.each do |entity, implementation|
          implementation.lifecycle_callbacks.to_h.each do |event, callbacks|
            callbacks.each do |callback|
              store.on(entity, event) do |value|
                implementation.from_native(value).run_lifecycle_callback(callback)
              end
            end
          end
        end
      end
    end
    # rubocop:enable Metrics
  end
end
