# frozen_string_literal: true

module Mxrb
  module RubyApp
    # The expression is Mendix/JVM text, not a Ruby Regexp. Presence and nil
    # are preserved independently so importing a document never adds defaults.
    class RegularExpression
      TYPE = 'RegularExpressions$RegularExpression'
      FIELDS = {
        expression: 'Expression', documentation: 'Documentation',
        excluded: 'Excluded', export_level: 'ExportLevel'
      }.freeze
      UNSET = Object.new.freeze
      private_constant :UNSET

      class << self
        attr_reader :mendix_id

        def inherited(child)
          super
          child.instance_variable_set(:@properties, {})
        end

        def mendix_name(value = nil, id: nil)
          return @mendix_name unless value

          unless value.to_s.match?(/\A[A-Za-z_]\w*\.[A-Za-z_]\w*\z/)
            raise ArgumentError, 'regular-expression name must be qualified as Module.Name'
          end

          @mendix_name = value.to_s.dup.freeze
          @mendix_id = SourceIdentity.resolve(self, :regular_expression, @mendix_name, id:)
          Registry.register(:regular_expression, @mendix_name, self)
        end

        FIELDS.each do |field, property|
          define_method(field) do |value = UNSET|
            return @properties[property] if value.equal?(UNSET)

            valid = value.nil? || if field == :excluded
                                    value.equal?(true) || value.equal?(false)
                                  else
                                    value.is_a?(String)
                                  end
            raise TypeError, "invalid regular-expression #{field} type" unless valid

            @properties[property] = value.is_a?(String) ? value.dup.freeze : value
          end
        end

        def native_definition
          { id: mendix_id, name: mendix_name.to_s.split('.', 2).last,
            properties: @properties.dup.freeze }.freeze
        end
      end
    end
  end
end
