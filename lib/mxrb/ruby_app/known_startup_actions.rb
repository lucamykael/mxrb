# frozen_string_literal: true

require 'digest'

module Mxrb
  module RubyApp
    # Marketplace actions that after-startup microflows run, enabled only for the
    # audited sources of each action and of the classes it calls.
    module KnownStartupActions
      MODULES = {
        'UnitTesting' => {
          root: 'unittesting',
          releases: {
            '10.0.4' => {
              'ConfigurationManager' => '6ba0f1a09208145774164a44124f891355d76f2f3fa3e13f2bc056c94078e9e3',
              'actions/IsEnabled' => '8a8f937944f5db022b5b2750989e678b346054f67fe140220ecc8870c4168d79',
              'actions/Initialize' => 'ca0c2e4c819131def6b863b7f8730f7639f7bd9cf262b315715a48d85b624031',
              'actions/IsInitialized' => '3374f7808af8dfc6bf77b2c82a786d4a987e0531fb0c0b4e4a525098e41009ca',
              'actions/RegisterModelUpdateSubscriber' =>
                'ff8fe41e66454efaf2c6fba9799662cf885de7716ab2f520e0d7cd02148eac6c'
            }
          },
          helpers: %w[ConfigurationManager]
        },
        'OIDC' => {
          root: 'oidc',
          releases: {
            '3.3.1' => {
              'actions/DeleteExpiredAuthAttempts' => 'f0b5332beb4e7daefd5817c1348e8b66e170d526c6ced1399431a4dc3b21812d',
              'implementation/StaleDBObjectCleaner' =>
                'f6988a1b503d1c15ef5590e3633dc244f63264effbbfb0f7b92169fef261ab2a',
              'implementation/ThreadingBatchingListProcessor' =>
                '3db928d7a99283de14684f9cf199d174b8858b6d13c71e93b766d685244ea7da',
              'implementation/MendixDataStorageUtils' =>
                'ea6f2ae3a0935b1c6d4ccb05fd745bf769c4c371c30a9d94f4f6de1a55f44509'
            }
          },
          helpers: %w[implementation/StaleDBObjectCleaner implementation/ThreadingBatchingListProcessor
                      implementation/MendixDataStorageUtils]
        }
      }.freeze
      ACTIONS = {
        'UnitTesting.IsEnabled' => :unit_testing_enabled, 'UnitTesting.Initialize' => :unit_testing_initialize,
        'UnitTesting.IsInitialized' => :unit_testing_initialized,
        'UnitTesting.RegisterModelUpdateSubscriber' => :register_model_update_subscriber,
        'OIDC.DeleteExpiredAuthAttempts' => :delete_expired_auth_attempts
      }.freeze
      # ConfigurationManager keeps these per Java process.
      STATE = { initialized: false }.compare_by_identity
      STATE_LOCK = Mutex.new

      module_function

      def registrations(directory) # rubocop:disable Metrics/AbcSize
        ACTIONS.keys.filter_map do |qualified|
          module_name, action = qualified.split('.', 2)
          spec = MODULES.fetch(module_name)
          root = File.join(directory, 'javasource', spec.fetch(:root))
          release = spec.fetch(:releases).find do |_, sources|
            (spec.fetch(:helpers) + ["actions/#{action}"]).all? { audited?(File.join(root, "#{_1}.java"), sources[_1]) }
          end&.first
          "Mxrb::RubyApp::KnownStartupActions.register(#{qualified.inspect}, #{release.inspect})" if release
        end.join("\n")
      end

      def audited?(path, hash)
        !hash.nil? && File.file?(path) && Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n")) == hash
      end

      def register(qualified, release)
        module_name, action = qualified.split('.', 2)
        unless MODULES.fetch(module_name).fetch(:releases).fetch(release).key?("actions/#{action}")
          raise KeyError, "#{module_name} #{release} #{action} is not audited"
        end

        handler = method(ACTIONS.fetch(qualified))
        Registry.register_java_custom_action(qualified, with_context: true) do |arguments, context:|
          handler.call(arguments, context)
        end
      end

      # Enabled for local development only next to Studio Pro's modeler, which an
      # MXRB application never has, else through the UnitTesting.Enabled constant.
      def unit_testing_enabled(_arguments, context) = context.constant('UnitTesting.Enabled') == true

      def unit_testing_initialize(_arguments, _context)
        STATE_LOCK.synchronize { STATE[:initialized] = true }
        nil
      end

      def unit_testing_initialized(_arguments, _context) = STATE_LOCK.synchronize { STATE[:initialized] }

      # Model update subscriptions exist for local development only.
      def register_model_update_subscriber(_arguments, context)
        context.log('UnitTestRunner', 'Debug', 'Did not subscribe to model updates, not in local development')
        false
      end

      def delete_expired_auth_attempts(arguments, context) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        minutes = arguments['expiresInMinutes']
        batch = arguments['batchSize']
        raise Runtime::JavaActionError.new('java.lang.NullPointerException', 'expiresInMinutes is null') if minutes.nil?
        raise Runtime::JavaActionError.new('java.lang.NullPointerException', 'batchSize is null') if batch.nil?

        cutoff = Time.now - (minutes.to_i * 60)
        stale = context.store.retrieve('OIDC.AuthAttempt').select do |attempt|
          created = attempt.members['createdDate']
          created && created <= cutoff
        end
        context.store.delete(stale) unless stale.empty?
        nil
      end
    end
  end
end
