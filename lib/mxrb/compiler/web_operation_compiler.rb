# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'

module Mxrb
  module Compiler
    # Builds the Runtime operation catalog consumed by generated web data sources.
    class WebOperationCompiler # rubocop:disable Metrics/ClassLength
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
        custom_widgets(unit.document).filter_map { operation(page_name, _1, role_sets, unit.document) } +
          data_action_operations(page_name, unit.document, role_sets)
      end

      def data_action_operations(page_name, document, role_sets) # rubocop:disable Metrics/MethodLength
        action_widgets(document).filter_map do |widget, action|
          type = case action['$Type']
                 when 'Forms$SaveChangesClientAction' then 'commit'
                 when 'Forms$CancelChangesClientAction' then 'rollback'
                 end
          if type
            next({
              'operationId' => self.class.operation_id(page_name, widget['Name']),
              'operationType' => type, 'parameters' => { 'Objects' => ['AnyObjectList'] },
              'constants' => {}, 'allowedUserRoleSets' => role_sets
            })
          end

          microflow_action_operation(page_name, widget, action, role_sets)
        end
      end # rubocop:enable Metrics/MethodLength

      def action_widgets(document)
        nested(document, 'Forms$ActionButton').map { [_1, _1['Action'] || {}] } +
          nested(document, 'Forms$DivContainer').map { [_1, _1['OnClickAction'] || {}] }
      end

      def microflow_action_operation(page_name, widget, action, role_sets)
        return unless action['$Type'] == 'Forms$MicroflowAction'

        name = action.dig('MicroflowSettings', 'Microflow').to_s
        return if name.empty?

        parameters = microflow_parameters(name)
        return unless parameters

        {
          'operationId' => self.class.operation_id(page_name, widget['Name']),
          'operationType' => 'callMicroflow', 'parameters' => parameters,
          'constants' => { 'MicroflowName' => name }, 'allowedUserRoleSets' => role_sets
        }
      end

      def microflow_parameters(qualified_name)
        flow = @source.units_of('Microflows$Microflow').find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == qualified_name
        end
        return unless flow

        parameters = nested(flow.document, 'Microflows$MicroflowParameter')
        return unless parameters.all? { supported_microflow_parameter?(_1) }

        parameters.to_h do |parameter|
          [parameter['Name'].to_s, [parameter.dig('VariableType', 'Entity').to_s]]
        end
      end

      def supported_microflow_parameter?(parameter)
        type = parameter['VariableType'] || {}
        type['$Type'] == 'DataTypes$ObjectType' && !type['Entity'].to_s.empty?
      end

      def operation(page_name, widget, role_sets, page_document)
        source = WebListDataSource.new(@source, widget)
        return unless source.supported?
        return xpath_operation(page_name, widget, role_sets, source, page_document) if source.xpath?
        return if source.nanoflow?

        {
          'operationId' => self.class.operation_id(page_name, widget['Name']),
          'operationType' => 'callMicroflow', 'parameters' => {},
          'constants' => { 'MicroflowName' => source.microflow_name }, 'allowedUserRoleSets' => role_sets
        }
      end

      def xpath_operation(page_name, widget, role_sets, source, page_document)
        variables = xpath_variables(source.xpath_constraint)
        page_parameters = object_page_parameters(page_document, variables)
        return unless page_parameters

        retrieve_operation(page_name, widget, role_sets, source, page_parameters)
      end

      def retrieve_operation(page_name, widget, role_sets, source, page_parameters)
        {
          'operationId' => self.class.operation_id(page_name, widget['Name']),
          'operationType' => 'retrieve',
          'parameters' => page_parameters.transform_values { [_1] },
          'constants' => constants(page_name, widget, source.xpath_constraint, source.entity),
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

      def constants(page_name, widget, constraint, entity)
        {
          'PageName' => page_name, 'WidgetName' => "#{page_name}.#{widget['Name']}",
          'UsedAssociations' => [], 'UsedAttributes' => used_attributes(widget, entity),
          'XPath' => xpath(entity, constraint)
        }
      end

      def xpath(entity, constraint)
        predicate = constraint.to_s.strip
        return "//#{entity}" if predicate.empty?

        "//#{entity}#{predicate.start_with?('[') ? predicate : "[#{predicate}]"}"
      end

      def custom_widgets(value) = nested(value, 'CustomWidgets$CustomWidget')

      def used_attributes(value, entity)
        attribute_names(value, entity)
      end

      def attribute_names(value, entity, result = [])
        collect_attribute_names(value, entity, result).uniq.sort
      end

      def collect_attribute_names(value, entity, result)
        case value
        when Hash then collect_hash_attributes(value, entity, result)
        when Array then value.each { collect_attribute_names(_1, entity, result) }
        when String then collect_string_attributes(value, entity, result)
        end
        result
      end

      def collect_hash_attributes(value, entity, result)
        path = attribute_inventory_path(value, entity) if value.key?('Attribute')
        result << path if path
        value.each_value { collect_attribute_names(_1, entity, result) }
      end

      def attribute_inventory_path(reference, entity)
        attribute = reference['Attribute'].to_s
        steps = array(reference.dig('EntityRef', 'Steps'))
        return "#{entity}/#{attribute}" if steps.empty? && attribute.start_with?("#{entity}.")
        return unless qualified_reference_steps?(steps) && attribute.include?('.')

        path = steps.flat_map { [_1['Association'], _1['DestinationEntity']] }
        ([entity] + path + [attribute]).join('/')
      end

      def qualified_reference_steps?(steps)
        steps.any? && steps.all? do |step|
          !step['Association'].to_s.empty? && !step['DestinationEntity'].to_s.empty?
        end
      end

      def collect_string_attributes(value, entity, result)
        value.scan(%r{\$currentObject/([A-Za-z_]\w*)}) do |match|
          result << "#{entity}/#{entity}.#{match.first}"
        end
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
    end # rubocop:enable Metrics/ClassLength
  end
end
