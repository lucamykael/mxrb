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
        role_sets = allowed_user_role_sets(unit)
        custom_widgets(unit.document).filter_map { operation(page_name, _1, role_sets) } +
          data_action_operations(page_name, unit.document, role_sets)
      end

      def data_action_operations(page_name, document, role_sets) # rubocop:disable Metrics/MethodLength
        nested(document, 'Forms$ActionButton').filter_map do |widget|
          type = case widget.dig('Action', '$Type')
                 when 'Forms$SaveChangesClientAction' then 'commit'
                 when 'Forms$CancelChangesClientAction' then 'rollback'
                 end
          next unless type

          {
            'operationId' => self.class.operation_id(page_name, widget['Name']),
            'operationType' => type, 'parameters' => { 'Objects' => ['AnyObjectList'] },
            'constants' => {}, 'allowedUserRoleSets' => role_sets
          }
        end
      end # rubocop:enable Metrics/MethodLength

      def operation(page_name, widget, role_sets)
        source = xpath_sources(widget).first
        return unless source

        entity = source.dig('EntityRef', 'Entity').to_s
        {
          'operationId' => self.class.operation_id(page_name, widget['Name']),
          'operationType' => 'retrieve', 'parameters' => {},
          'constants' => constants(page_name, widget, source, entity),
          'allowedUserRoleSets' => role_sets
        }
      end

      def allowed_user_role_sets(unit) # rubocop:disable Metrics/AbcSize
        module_roles = array(unit.document['AllowedModuleRoles']).map(&:to_s)
        security = @source.documents('Security$ProjectSecurity').first
        array(security&.fetch('UserRoles', nil)).filter_map do |role|
          next if (array(role['ModuleRoles']).map(&:to_s) & module_roles).empty?

          [role['Name'].to_s]
        end
      end # rubocop:enable Metrics/AbcSize

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
