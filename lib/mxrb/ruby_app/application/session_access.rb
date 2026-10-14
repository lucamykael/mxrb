# frozen_string_literal: true

module Mxrb
  module RubyApp
    class Application
      # Exposes session, language, scheduler and asynchronous invocation state.
      module SessionAccess
        # The language code of the signed-in user (System.User_Language), if any.
        def user_language(context)
          user = session_user(context)
          language = user&.members&.fetch('User_Language', nil)
          language.respond_to?(:members) ? language.members['Code'] : nil
        end

        # The Language selector changes the language of the signed-in user, as the
        # Mendix client does; the platform sets it regardless of entity access.
        def change_language(code, context:)
          runtime_synchronize do
            user = session_user(context)
            raise ArgumentError, 'changing the language requires a signed-in user' unless user

            store = bridge.interpreter.store
            language = store.retrieve(Runtime::Languages::LANGUAGE).find { _1.members['Code'] == code.to_s }
            raise ArgumentError, "unknown language #{code}" unless language

            user.members['User_Language'] = language
            store.commit(user)
            code.to_s
          end
        end

        def async_invocations
          @async_invocations_mutex.synchronize { @async_invocations ||= AsyncInvocations.new(self) }
        end

        def access_control = (@access_control ||= bridge.access_control)

        def session_manager
          @session_manager ||= SessionManager.new(
            access_control, users: environment['MXRB_USERS_JSON'],
                            tokens: environment['MXRB_AUTH_TOKENS'],
                            ttl: environment.fetch('MXRB_SESSION_TTL', '3600'),
                            store: shared_store, directory: -> { bridge.store },
                            user_time_zone: ->(user) { Runtime::TimeZones.of_user(bridge.store, user) }
          )
        end

        def start_scheduler
          @scheduler_started = true
          bridge.start_scheduler
        end

        private

        def session_user(context)
          id = context&.user
          id && bridge.interpreter.store.find(Runtime::SystemDomain::USER, id.to_s)
        end

        def draft_owner(context)
          context.respond_to?(:user) && context.user ? "user:#{context.user}" : 'anonymous'
        end
      end
    end
  end
end
