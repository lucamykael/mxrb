# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'

module Mxrb
  module Compiler
    # Builds the Runtime operation catalog consumed by generated web data sources.
    class WebOperationCompiler
      include ModelValues

      def self.operation_id(page_name, widget_name)
        Base64.strict_encode64(Digest::SHA256.digest("#{page_name}/#{widget_name}").byteslice(0, 16))
              .delete_suffix('==')
      end

      def initialize(source)
        @source = source
      end

      def write(path)
        operations = @source.units_of('Forms$Page').flat_map { page_operations(_1) }
        File.write(path, JSON.generate(operations))
        operations
      end

      private

      def page_operations(unit)
        page_name = "#{unit.module_name}.#{unit.document['Name']}"
        custom_widgets(unit.document).filter_map { operation(page_name, _1) }
      end

      def operation(page_name, widget)
        source = xpath_sources(widget).first
        return unless source

        entity = source.dig('EntityRef', 'Entity').to_s
        {
          'operationId' => self.class.operation_id(page_name, widget['Name']),
          'operationType' => 'retrieve', 'parameters' => {},
          'constants' => constants(page_name, widget, source, entity),
          'allowedUserRoleSets' => []
        }
      end

      def constants(page_name, widget, source, entity)
        constraint = source['XPathConstraint'].to_s
        {
          'PageName' => page_name, 'WidgetName' => "#{page_name}.#{widget['Name']}",
          'UsedAssociations' => [], 'UsedAttributes' => attribute_names(widget),
          'XPath' => "//#{entity}#{constraint.empty? ? '' : "[#{constraint}]"}"
        }
      end

      def custom_widgets(value) = nested(value, 'CustomWidgets$CustomWidget')
      def xpath_sources(value) = nested(value, 'CustomWidgets$CustomWidgetXPathSource')

      def attribute_names(value)
        nested(value, 'DomainModels$AttributeRef').filter_map { _1['Attribute'] }.uniq.sort
      end

      def nested(value, type, result = [])
        case value
        when Hash
          result << value if value['$Type'] == type
          value.each_value { nested(_1, type, result) }
        when Array then value.each { nested(_1, type, result) }
        end
        result
      end
    end
  end
end
