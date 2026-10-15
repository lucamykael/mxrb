# frozen_string_literal: true

require 'bigdecimal'
require 'time'
require_relative 'decimal_values'

module Mxrb
  module Runtime
    # Values of @Module.Constant: a deployment override in MX_<Module>_<Constant>,
    # as the Mendix Runtime reads it, else the constant's default value.
    class Constants
      TYPES = {
        'DataTypes$BooleanType' => :boolean, 'DataTypes$IntegerType' => :integer,
        'DataTypes$LongType' => :long, 'DataTypes$DecimalType' => :decimal,
        'DataTypes$DateTimeType' => :datetime, 'DataTypes$StringType' => :string
      }.freeze

      def initialize(project, environment: ENV)
        @project = project
        @environment = environment
        @values = {}
      end

      def value(name) # rubocop:disable Metrics/AbcSize
        name = name.to_s
        return @values[name] if @values.key?(name)

        module_name, constant = name.split('.', 2)
        definition = definition(name)
        raise NativeRuntimeError, "unknown constant @#{name}" unless definition && constant

        variable = "MX_#{module_name}_#{constant}"
        value = @environment[variable]
        value = definition.fetch(:default) if value.nil?
        raise NativeRuntimeError, "constant @#{name} has no value; set #{variable}" if value.nil?

        @values[name] = self.class.cast(value, definition.fetch(:type))
      end

      def self.cast(value, type) # rubocop:disable Metrics/CyclomaticComplexity
        return nil if value.nil?

        text = value.to_s
        case type
        when :boolean then text.casecmp?('true')
        when :integer, :long then text.empty? ? nil : Integer(text, 10)
        when :decimal then text.empty? ? nil : DecimalValues.parse(text)
        when :datetime, :date_time then text.empty? ? nil : Time.iso8601("#{text.delete_suffix('Z')}Z")
        else text
        end
      end

      private

      # A Ruby application declares its constants; a model reads them from the MPR.
      def definition(name)
        return @project.constant_definition(name) if @project.respond_to?(:constant_definition)

        module_name, constant = name.split('.', 2)
        mod = @project.modules.find { _1.name == module_name }
        document = mod&.constants&.find { _1['Name'] == constant }
        document && { type: TYPES.fetch(document.dig('Type', '$Type'), :string), default: document['DefaultValue'] }
      end
    end
  end
end
