# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative '../lib/mxrb'
require_relative 'modbus_tcp_simulator'

module Mxrb
  module Modbus
    # A complete local application: microflow -> adapter -> TCP -> SQLite.
    # Generated files are retained when this example is run from the command line.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    module ApplicationDemo
      WRITE_VALUE_ID = 'cf861ac8-2d89-4f72-8834-a9dd04063e21'

      module_function

      def build_project(path)
        builder = Mxrb::Dsl::Builder.new(path)
        builder.instance_eval do
          mendix_version '11.12.1'
          self.module :Industrial do
            entity :Measurement do
              integer :Setpoint
              integer :InputValue
            end
            java_action :WriteSetpoint, parameters: [{
              id: WRITE_VALUE_ID, name: 'Value', type: { kind: :basic, type: { kind: :integer } }
            }], return_type: { kind: :integer }
            java_action :ReadSetpoint, parameters: [], return_type: { kind: :integer }
            java_action :ReadInput, parameters: [], return_type: { kind: :integer }
            microflow :ConfigureAndSample do
              parameter :Value, type: :Integer
              return_type 'Industrial.Measurement'
              call_java 'Industrial.WriteSetpoint', as: :written, pass: { WRITE_VALUE_ID => '$Value' }
              call_java 'Industrial.ReadSetpoint', as: :setpoint
              call_java 'Industrial.ReadInput', as: :input
              create_object 'Industrial.Measurement', as: :measurement, commit: true,
                                                      set: { Setpoint: '$setpoint', InputValue: '$input' }
              return_value '$measurement'
            end
          end
        end
        builder.build!
      end

      def adapters(client)
        {
          'Industrial.WriteSetpoint' => ->(arguments) { client.write_single_register(0, arguments.fetch('Value')) },
          'Industrial.ReadSetpoint' => ->(_arguments) { client.read_holding_registers(0).first },
          'Industrial.ReadInput' => ->(_arguments) { client.read_input_registers(0).first }
        }
      end

      def run(root)
        path = File.join(root, 'Industrial.mpr')
        database = File.join(root, 'measurements.sqlite3')
        raise ArgumentError, 'demo output already exists' if [path, database].any? { File.exist?(_1) }

        build_project(path)
        raise ValidationError, 'invalid Modbus demonstration model' unless Mxrb.validate(path).valid?

        Mxrb.open(path) do |project|
          simulator = TcpSimulator.new(port: 0)
          worker = Thread.new { loop { simulator.serve_next } }
          client = Client.new(transport: :tcp, host: '127.0.0.1', port: simulator.port)
          capture_samples(project, database, client)
          samples = persisted_samples(project, database)
          raise Error, 'Modbus application did not persist the expected measurements' unless samples == [
            { setpoint: 42, input_value: 1234 }, { setpoint: 84, input_value: 1234 }
          ]

          { transport: :tcp, model_valid: true, mpr: path, database:, persisted_measurements: samples }
        ensure
          worker&.kill
          worker&.join
          simulator&.close
        end
      end

      def capture_samples(project, database, client)
        store = Runtime::SQLiteStore.new(project, path: database)
        runtime = Runtime::Native::Interpreter.new(project, store:, java_custom_actions: adapters(client))
        [42, 84].each { runtime.call('Industrial.ConfigureAndSample', 'Value' => _1) }
      ensure
        store&.close
      end

      def persisted_samples(project, database)
        store = Runtime::SQLiteStore.new(project, path: database)
        store.retrieve('Industrial.Measurement').map do |sample|
          { setpoint: sample.members.fetch('Setpoint'), input_value: sample.members.fetch('InputValue') }
        end
      ensure
        store&.close
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
  end
end

if $PROGRAM_NAME == __FILE__
  directory = Dir.mktmpdir('mxrb-modbus-application-')
  puts JSON.pretty_generate(Mxrb::Modbus::ApplicationDemo.run(directory))
end
