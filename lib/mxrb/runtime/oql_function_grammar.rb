# frozen_string_literal: true

module Mxrb
  module Runtime
    # LOWER, UPPER, LENGTH, REPLACE, COALESCE, ROUND, CAST, DATEPART and DATEDIFF.
    module OqlFunctionGrammar
      FUNCTIONS = %w[LOWER UPPER LENGTH REPLACE COALESCE ROUND CAST DATEPART DATEDIFF].freeze
      CASTS = { 'STRING' => :string, 'INTEGER' => :integer, 'LONG' => :long, 'DECIMAL' => :decimal,
                'BOOLEAN' => :boolean, 'DATETIME' => :datetime }.freeze
      CAST_SOURCES = { 'STRING' => %i[number string boolean datetime], 'BOOLEAN' => %i[number boolean],
                       'DATETIME' => %i[string] }.freeze

      private

      def function(name)
        @tokens.shift
        expect('(')
        result = case name
                 when 'CAST' then cast_function
                 when 'DATEPART', 'DATEDIFF' then date_function(name)
                 else scalar_function(name, arguments)
                 end
        expect(')')
        result
      end

      def arguments
        values = [additive]
        values << additive while take(',')
        values
      end

      def scalar_function(name, values)
        case name
        when 'LOWER' then string_function(values, :string, &:downcase)
        when 'UPPER' then string_function(values, :string, &:upcase)
        when 'LENGTH' then string_function(values, :integer, &:length)
        when 'REPLACE' then replace_function(values)
        when 'COALESCE' then coalesce_function(values)
        else round_function(values)
        end
      end

      def string_function(values, type, &)
        error!('expected one string argument') unless values.length == 1 && values.first.kind == :string
        term(type, 0, nullable(values.first, &))
      end

      def replace_function(values)
        unless values.length == 3 && values.all? { _1.kind == :string }
          error!('REPLACE requires three string arguments')
        end
        term(:string, 0, ->(row) { OqlScalar.replace(*values.map { _1.read.call(row) }) })
      end

      def coalesce_function(values)
        error!('COALESCE requires at least two arguments') if values.length < 2
        type, scale = common_type(values)
        term(type, scale, ->(row) { values.lazy.map { _1.read.call(row) }.find { !_1.nil? } })
      end

      def round_function(values)
        value, digits = values
        unless values.length == 2 && value.kind == :number && digits.literal && OqlExpressionGrammar::INTEGERS.include?(digits.type)
          error!('ROUND requires a number and literal integer digits')
        end
        places = digits.read.call(nil).to_i
        term(:decimal, value.scale, nullable(value) { OqlScalar.round(_1, places) })
      end

      def cast_function
        value = additive
        expect('AS')
        target = cast_target(value)
        scale = target == 'DECIMAL' ? 8 : 0
        source = value.kind == :number ? numeric_type([value]) : value.kind
        term(CASTS.fetch(target), scale, nullable(value) { OqlScalar.cast(_1, source, target, value.scale) })
      end

      def cast_target(value)
        target = @tokens.shift.to_s.upcase
        error!("unsupported CAST target #{target}") unless CASTS.key?(target)
        error!("unsupported CAST to #{target}") unless CAST_SOURCES.fetch(target,
                                                                          %i[number string]).include?(value.kind)
        target
      end

      def date_function(name)
        part = @tokens.shift.to_s.upcase
        parts = name == 'DATEPART' ? OqlScalar::DATE_PARTS : OqlScalar::DATE_DIFFERENCES
        error!("unsupported #{name} part #{part}") unless parts.key?(part)
        values = [date_argument]
        values << date_argument if name == 'DATEDIFF'
        term(:integer, 0, date_reader(name, part, values))
      end

      def date_argument
        expect(',')
        value = additive
        error!('date functions require date and time values') unless value.kind == :datetime
        value
      end

      def date_reader(name, part, values)
        lambda do |row|
          dates = values.map { _1.read.call(row) }
          next nil if dates.include?(nil)

          name == 'DATEPART' ? OqlScalar.date_part(part, *dates) : OqlScalar.date_difference(part, *dates)
        end
      end
    end
  end
end
