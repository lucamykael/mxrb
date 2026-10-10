# frozen_string_literal: true

require 'digest'

module Mxrb
  module RubyApp
    # Actions of the Marketplace OQL module, enabled only when the project's action
    # and its oql/implementation/OQL.java are the audited source bytes. Parameters
    # live per thread until a statement runs, like the module's ThreadLocal map.
    module KnownOqlModuleActions
      IMPLEMENTATION = '4ca7266903d62b6d209413f8ea3ff9709eaf2be7a3a09df8208ac09af0ebb707'
      SOURCES = {
        'AddBooleanParameter' => '390f568b75eb26ba731be35a0418ec76565b5ad75435416bc81b7473e214bfb8',
        'AddDateTimeParameter' => '685f49f9db066bda254b919c783aee31baf251f35990dbacd2aebbc3bc766747',
        'AddDecimalParameter' => '6441fa8fa3ecaa9ee33af5c809fdd8fa4e43e5563124c53d460a883992e48138',
        'AddIntegerLongValue' => 'cc52852cabd3961f9266be55a67e3b4555e9412c5319edbfc54e8a9f62af80d4',
        'AddObjectParameter' => '6bb4a3af5e10e6681f11447d0a9928367c5d534774d2f5fee176cb2b5a7f0e10',
        'AddStringParameter' => '45da0c706ccbd27123af07e5e0673bed77b8057b808ffe5e6e3f3b6d71807d6b',
        'CountRowsOQLStatement' => 'a4ddeaf54e23eb809ed8323f459d6b2931c54688ab5a8c3d511456fbb34407b4',
        'ExecuteOQLStatement' => '618db84356c881da99a26f4c428e5c6a39b41010edae16b9e06aaa605e0567ed'
      }.freeze
      KEY = :mxrb_oql_module_parameters

      module_function

      def registrations(directory)
        root = File.join(directory, 'javasource', 'oql')
        return '' unless audited?(File.join(root, 'implementation', 'OQL.java'), self::IMPLEMENTATION)

        self::SOURCES.filter_map do |name, hash|
          "Mxrb::RubyApp::KnownOqlModuleActions.register(#{name.inspect})" if
            audited?(File.join(root, 'actions', "#{name}.java"), hash)
        end.join("\n")
      end

      def audited?(path, hash)
        File.file?(path) && Digest::SHA256.hexdigest(File.binread(path).gsub("\r\n", "\n")) == hash
      end

      def parameters = Thread.current[KEY] ||= {}
      def reset! = Thread.current[KEY] = {}

      def register(name)
        Registry.register_java_custom_action("OQL.#{name}", with_store: true) do |arguments, store:|
          case name
          when 'ExecuteOQLStatement' then execute(arguments, store)
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

      def execute(arguments, store)
        result = store.oql_module_objects(arguments.fetch('statement'), arguments.fetch('returnEntity'),
                                          parameters:, amount: arguments['amount'], offset: arguments['offset'])
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
