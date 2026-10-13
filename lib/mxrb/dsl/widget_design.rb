# frozen_string_literal: true

module Mxrb
  module Dsl
    # Accepts design: { "Property" => value } on widget, layout grid row and
    # column declarations and stores it as the declared element's design option.
    # A toggle is true, an option its name, and spacing a Hash of sides and
    # options, as in the theme's design-properties.json.
    module WidgetDesign
      # design: design_values(Size: "Large", Spacing: design_sides("margin-top": "M"))
      module Helpers
        def design_values(**values) = values
        def design_sides(**sides) = sides
      end

      module_function

      def wrap(owner, methods, list:)
        wrapper = Module.new
        methods.each { define_declaration(wrapper, _1, list) }
        owner.prepend(wrapper)
      end

      def define_declaration(wrapper, method_name, list)
        wrapper.define_method(method_name) do |*args, design: nil, **options, &block|
          elements = send(list)
          count = elements.size
          result = super(*args, **options, &block)
          WidgetDesign.attach(elements, count, design) unless design.nil?
          result
        end
      end

      def attach(elements, count, design)
        raise ArgumentError, 'design must accompany a widget declaration' if elements.size == count

        element = elements.last
        key = element.keys.first.is_a?(String) ? 'options' : :options
        design_key = key == 'options' ? 'design' : :design
        element[key] = (element[key] || {}).merge(design_key => normalize(design))
      end

      def normalize(design)
        raise ArgumentError, 'design requires a Hash of design property values' unless design.is_a?(Hash)

        design.to_h do |property, value|
          [property.to_s, normalize_value(property, value)]
        end
      end

      def normalize_value(property, value)
        case value
        when true then true
        when String, Symbol then value.to_s
        when Hash then value.to_h { |side, option| [side.to_s, option.to_s] }
        else raise ArgumentError, "design property #{property} requires true, an option name or a Hash of sides"
        end
      end
    end
  end
end
