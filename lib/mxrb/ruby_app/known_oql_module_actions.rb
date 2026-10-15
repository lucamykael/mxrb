# frozen_string_literal: true

require 'digest'

module Mxrb
  module RubyApp
    # Actions of the Marketplace OQL module, enabled only when the project's action
    # and its oql/implementation/OQL.java are the audited source bytes of a release.
    # Parameters live per thread until a statement runs, like the module's ThreadLocal map.
    module KnownOqlModuleActions
      RELEASES = {
        '4.1.2' => {
          implementation: '4ca7266903d62b6d209413f8ea3ff9709eaf2be7a3a09df8208ac09af0ebb707',
          actions: {
            'AddBooleanParameter' => '390f568b75eb26ba731be35a0418ec76565b5ad75435416bc81b7473e214bfb8',
            'AddDateTimeParameter' => '685f49f9db066bda254b919c783aee31baf251f35990dbacd2aebbc3bc766747',
            'AddDecimalParameter' => '6441fa8fa3ecaa9ee33af5c809fdd8fa4e43e5563124c53d460a883992e48138',
            'AddIntegerLongValue' => 'cc52852cabd3961f9266be55a67e3b4555e9412c5319edbfc54e8a9f62af80d4',
            'AddObjectParameter' => '6bb4a3af5e10e6681f11447d0a9928367c5d534774d2f5fee176cb2b5a7f0e10',
            'AddStringParameter' => '45da0c706ccbd27123af07e5e0673bed77b8057b808ffe5e6e3f3b6d71807d6b',
            'CountRowsOQLStatement' => 'a4ddeaf54e23eb809ed8323f459d6b2931c54688ab5a8c3d511456fbb34407b4',
            'ExecuteOQLStatement' => '618db84356c881da99a26f4c428e5c6a39b41010edae16b9e06aaa605e0567ed'
          }
        },
        '2.10.0' => {
          implementation: '9be3db267dcb4aa3d349d2d89a8c08307fcd3e287f8faee238b08fd499cb13ce',
          actions: {
            'AddBooleanParameter' => 'a3cf834b15feb528a7b206c83c04fe9b7d819b0b5556467e498749797e44eb89',
            'AddDateTimeParameter' => '8b3db2fa1eee557d64a3e312f465553bfa11279c6764696a13aeb81e5151fd4c',
            'AddDecimalParameter' => '5e18596bccac92e92ce6a58c2ced30aa202735936ae32c2acb51033eec9b9761',
            'AddIntegerLongValue' => '8fb723bf1cfe3c0d3c5586a38f0ca92b6647fc10aa00a350831f5b23d2fe9af5',
            'AddObjectParameter' => '611f137bb3cb3d7f17e35eeb7e08cc7288f54390dca541265365f802d621ab9c',
            'AddStringParameter' => 'ccd7879f99caa8664420b9c36952e86db474a905759f7eb9fc23f2791269993f',
            'CountRowsOQLStatement' => '2c73573524b08dc18d5ca72bdf4b0d2542380fb6992aaca5642e7f32f50a6d37',
            'ExecuteOQLStatement' => '547c1360805c263a3dd3b0fe73244fa00df070889dac8311c655c31177b75974'
          }
        }
      }.freeze
      KEY = :mxrb_oql_module_parameters

      module_function

      def registrations(directory)
        root = File.join(directory, 'javasource', 'oql')
        release, sources = self::RELEASES.find do |_, candidate|
          audited?(File.join(root, 'implementation', 'OQL.java'), candidate.fetch(:implementation))
        end
        return '' unless release

        sources.fetch(:actions).filter_map do |name, hash|
          "Mxrb::RubyApp::KnownOqlModuleActions.register(#{name.inspect}, #{release.inspect})" if
            audited?(File.join(root, 'actions', "#{name}.java"), hash)
        end.join("\n")
      end

      def audited?(path, hash)
        File.file?(path) && Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n")) == hash
      end

      def parameters = Thread.current[KEY] ||= {}
      def reset! = Thread.current[KEY] = {}

      # Applications exported before releases were tracked register 4.1.2 actions by name only.
      def register(name, release = '4.1.2') # rubocop:disable Metrics/MethodLength
        unless RELEASES.fetch(release).fetch(:actions).key?(name)
          raise KeyError,
                "OQL #{release} #{name} is not audited"
        end

        Registry.register_java_custom_action("OQL.#{name}", with_store: true) do |arguments, store:|
          case name
          when 'ExecuteOQLStatement' then execute(arguments, store, release)
          when 'CountRowsOQLStatement' then count(arguments, store)
          else add(arguments)
          end
        end
      end

      def add(arguments)
        value = arguments['value']
        value = Runtime::OqlParameters::Identifier.new(value.id) if value.respond_to?(:entity) && value.respond_to?(:id)
        parameters[arguments.fetch('name')] = value
        true
      end

      def execute(arguments, store, release = '4.1.2')
        result = store.oql_module_objects(arguments.fetch('statement'), arguments.fetch('returnEntity'),
                                          release:, parameters:, amount: arguments['amount'],
                                          offset: arguments['offset'])
        reset! unless arguments['preserveParameters'] == true
        result
      end

      def count(arguments, store)
        result = store.oql_module_count(arguments.fetch('statement'), parameters:, amount: arguments['amount'])
        reset!
        result
      end
    end
  end
end
