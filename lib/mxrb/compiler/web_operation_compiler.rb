# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'

module Mxrb
  module Compiler
    # Builds the Runtime operation catalog consumed by generated web data sources.
    # rubocop:disable Metrics, Style/HashLikeCase, Style/MultilineBlockChain
    class WebOperationCompiler
      include ModelValues

      def self.operation_id(page_name, widget_name)
        Base64.strict_encode64(Digest::SHA256.digest("#{page_name}/#{widget_name}").byteslice(0, 16))
              .delete_suffix('==')
      end

      def self.menu_operation_id(action)
        identifier = IO::BsonCodec.extract_id(action['$ID']).to_s
        identifier = action.dig('MicroflowSettings', 'Microflow').to_s if identifier.empty?
        operation_id('Navigation', identifier)
      end

      def initialize(source)
        @source = source
      end

      def write(path)
        operations = @source.units_of('Forms$Page').select { web_page?(_1) }
                                                   .flat_map { page_operations(_1) }
        if @source.is_a?(SourceModel)
          operations.concat(@source.units_of('Forms$Layout').select { web_layout?(_1) }
                                   .flat_map { page_operations(_1) })
        end
        operations.concat(nanoflow_operations)
        operations = operations.uniq { _1['operationId'] }
        File.write(path, JSON.generate(operations))
        operations
      end

      private

      def web_page?(unit) = !@source.is_a?(SourceModel) || @source.web_page?(unit)
      def web_layout?(unit) = !@source.is_a?(SourceModel) || @source.web_layout?(unit)

      def page_operations(unit)
        page_name = "#{unit.module_name}.#{unit.document['Name']}"
        role_sets = allowed_user_role_sets(unit)
        operations = page_related_documents(unit.document).flat_map do |document|
          custom_widgets(document).filter_map { operation(page_name, _1, role_sets, document) } +
            standard_data_source_widgets(document).filter_map do |widget|
              standard_data_source_operation(page_name, widget, role_sets, document)
            end + data_action_operations(page_name, document, role_sets) + menu_action_operations(document) +
            data_grid_filter_operations(page_name, document, role_sets)
        end
        operations << page_cancel_operation(page_name, role_sets) if popup_page?(unit)
        operations.uniq { _1['operationId'] }
      end

      def data_grid_filter_operations(page_name, document, role_sets)
        return [] unless @source.is_a?(SourceModel)

        custom_widgets(document).flat_map do |grid|
          next [] unless custom_widget_id(grid) == DataGridBundleCompiler::WIDGET_ID

          grid_filter_specs(grid).map do |filter, endpoint, caption|
            {
              'operationId' => self.class.operation_id(page_name, "#{grid['Name']}$#{filter['Name']}"),
              'operationType' => 'retrieve', 'parameters' => {},
              'constants' => {
                'PageName' => page_name, 'WidgetName' => "#{page_name}.#{grid['Name']}",
                'UsedAssociations' => [], 'UsedAttributes' => ["#{endpoint}/#{endpoint}.#{caption}"],
                'XPath' => "//#{endpoint}"
              },
              'allowedUserRoleSets' => role_sets
            }
          end
        end
      end

      def grid_filter_specs(grid)
        values = custom_property_values(grid['Object'])
        array(values.dig('columns', 1, 'Objects')).filter_map do |column|
          column_values = custom_property_values(column)
          steps = array(column_values.dig('attribute', 1, 'AttributeRef', 'EntityRef', 'Steps'))
          filter = array(column_values.dig('filter', 1, 'Widgets')).first
          next if steps.empty? || filter.nil?

          endpoint = steps.last['DestinationEntity'].to_s
          caption = column_values.dig('attribute', 1, 'AttributeRef', 'Attribute').to_s.split('.').last
          [filter, endpoint, caption] unless endpoint.empty? || caption.empty?
        end
      end

      def custom_widget_id(widget)
        pointer = IO::BsonCodec.extract_id(widget.dig('Object', 'TypePointer'))
        @source.document_index.values.find do |document|
          IO::BsonCodec.extract_id(document.dig('ObjectType', '$ID')) == pointer
        end&.fetch('WidgetId', nil)
      end

      def custom_property_values(object)
        array(object&.fetch('Properties', nil)).filter_map do |property|
          type = @source.document_index[IO::BsonCodec.extract_id(property['TypePointer'])]
          [type['PropertyKey'], [type.dig('ValueType', 'Type'), property['Value']]] if type
        end.to_h
      end

      def page_cancel_operation(page_name, role_sets)
        {
          'operationId' => self.class.operation_id(page_name, '$cancelChanges'),
          'operationType' => 'rollback', 'parameters' => { 'Objects' => ['AnyObjectList'] },
          'constants' => {}, 'allowedUserRoleSets' => role_sets
        }
      end

      def popup_page?(unit)
        return false unless @source.is_a?(SourceModel) && unit.document['$Type'] == 'Forms$Page'

        name = unit.document.dig('FormCall', 'Form').to_s
        layout = qualified_unit('Forms$Layout', name)
        popup_layout_document?(layout&.document)
      end

      def popup_layout_document?(document)
        return false unless document
        return true if document['Name'].to_s.match?(/popup/i)

        document['CanvasWidth'].to_i.positive? && document['CanvasWidth'].to_i <= 800 &&
          menu_widgets(document).empty? && nested(document, 'Forms$Header').empty?
      end

      def menu_action_operations(document)
        menu_widgets(document).flat_map do |widget|
          resolved_menu_items(widget['MenuSource']).flat_map { menu_item_operations(_1) }
        end
      end

      def menu_item_operations(item)
        action = item['Action'] || {}
        own = action['$Type'] == 'Forms$MicroflowAction' ? [menu_microflow_operation(action)].compact : []
        own + array(item['Items']).flat_map { menu_item_operations(_1) }
      end

      def menu_microflow_operation(action)
        name = action.dig('MicroflowSettings', 'Microflow').to_s
        flow = qualified_unit('Microflows$Microflow', name)
        parameters = microflow_parameters(name)
        return unless flow && parameters

        {
          'operationId' => self.class.menu_operation_id(action),
          'operationType' => 'callMicroflow', 'parameters' => parameters,
          'constants' => { 'MicroflowName' => name },
          'allowedUserRoleSets' => allowed_user_role_sets(flow)
        }
      end

      def menu_widgets(document)
        %w[Forms$NavigationTree Forms$MenuBar Forms$SimpleMenuBar].flat_map { nested(document, _1) }
      end

      def resolved_menu_items(source)
        case source&.fetch('$Type', nil)
        when 'Forms$MenuDocumentSource'
          unit = qualified_unit('Menus$MenuDocument', source['Menu'].to_s)
          array(unit&.document&.dig('ItemCollection', 'Items'))
        when 'Forms$NavigationSource'
          profile = @source.units_of('Navigation$NavigationDocument').flat_map do |unit|
            array(unit.document['Profiles'])
          end.find { _1['Name'] == source['NavigationProfile'] }
          array(profile&.dig('Menu', 'Items'))
        else []
        end
      end

      def page_related_documents(document, seen = {})
        references = nested(document, 'Forms$SnippetCallWidget').map { _1.dig('FormCall', 'Form').to_s }
        references.filter_map do |qualified|
          next if qualified.empty? || seen[qualified]

          seen[qualified] = true
          unit = @source.units_of('Forms$Snippet').find do |candidate|
            "#{candidate.module_name}.#{candidate.document['Name']}" == qualified
          end
          unit && page_related_documents(unit.document, seen)
        end.flatten(1).prepend(document)
      end

      def data_action_operations(page_name, document, role_sets) # rubocop:disable Metrics/MethodLength
        entities = widget_entities(document, document_scope_entity(document))
        action_widgets(document).filter_map do |widget, action|
          type = case action['$Type']
                 when 'Forms$SaveChangesClientAction' then 'commit'
                 when 'Forms$CancelChangesClientAction' then 'rollback'
                 when 'Forms$DeleteClientAction' then 'delete'
                 when 'Forms$CreateObjectClientAction' then 'create'
                 end
          if type
            entity = entities[widget]
            parameters = if type == 'create'
                           {}
                         elsif type == 'delete' && !entity.to_s.empty?
                           { 'Objects' => ["[#{entity}]"] }
                         else
                           { 'Objects' => ['AnyObjectList'] }
                         end
            constants = type == 'create' ? { 'ObjectType' => action.dig('EntityRef', 'Entity').to_s } : {}
            next({
              'operationId' => self.class.operation_id(page_name, widget['Name']),
              'operationType' => type, 'parameters' => parameters,
              'constants' => constants, 'allowedUserRoleSets' => role_sets
            })
          end

          microflow_action_operation(page_name, widget, action, role_sets)
        end
      end # rubocop:enable Metrics/MethodLength

      def action_widgets(document)
        nested(document, 'Forms$ActionButton').map { [_1, _1['Action'] || {}] } +
          nested(document, 'Forms$DivContainer').map { [_1, _1['OnClickAction'] || {}] } +
          custom_widgets(document).flat_map do |widget|
            nested(widget['Object'], 'CustomWidgets$WidgetValue').filter_map do |value|
              action = value['Action'] || {}
              [widget, action] unless action['$Type'].to_s.empty? || action['$Type'] == 'Forms$NoAction'
            end
          end
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
        return {} if flow.nil? && qualified_name == 'System.ShowHomePage'
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
        return association_operation(page_name, widget, role_sets, source) if source.association?
        return if source.nanoflow?

        {
          'operationId' => self.class.operation_id(page_name, widget['Name']),
          'operationType' => 'retrieveByMicroflow', 'parameters' => microflow_parameters(source.microflow_name) || {},
          'constants' => data_source_constants(page_name, widget, source.microflow_name),
          'allowedUserRoleSets' => role_sets
        }
      end

      def standard_data_source_widgets(document)
        nested(document, 'Forms$ListView') + nested(document, 'Forms$DataView')
      end

      def standard_data_source_operation(page_name, widget, role_sets, page_document)
        entities = widget_entities(page_document, document_scope_entity(page_document))
        source_entity = entities[widget]
        return data_view_operation(page_name, widget, role_sets, source_entity) if widget['$Type'] == 'Forms$DataView'

        source = WebListDataSource.new(@source, widget)
        if source.association?
          return association_retrieve_operation(
            page_name, widget, role_sets, source.association_path, source_entity
          )
        end
        operation(page_name, widget, role_sets, page_document)
      end

      def data_view_operation(page_name, widget, role_sets, source_entity = nil)
        source = widget['DataSource'] || {}
        if source['$Type'] == 'Forms$MicroflowSource'
          name = source.dig('MicroflowSettings', 'Microflow').to_s
          return unless present_name?(name)

          return retrieve_by_microflow_operation(page_name, widget, role_sets, name)
        end
        path = entity_ref_path(source['EntityRef'])
        return if path.empty?

        association_retrieve_operation(page_name, widget, role_sets, path, source_entity)
      end

      def association_operation(page_name, widget, role_sets, source)
        association_retrieve_operation(page_name, widget, role_sets, source.association_path)
      end

      def association_retrieve_operation(page_name, widget, role_sets, path, source_entity = nil)
        source_entity ||= association_source_entity(path)
        return unless source_entity

        destination = path.split('/').last.to_s
        {
          'operationId' => self.class.operation_id(page_name, widget['Name']),
          'operationType' => 'retrieve', 'parameters' => { 'CurrentObject' => [source_entity] },
          'constants' => {
            'PageName' => page_name, 'WidgetName' => "#{page_name}.#{widget['Name']}",
            'UsedAssociations' => used_associations(widget, destination),
            'UsedAttributes' => used_attributes(widget, destination), 'EntityPath' => path
          },
          'allowedUserRoleSets' => role_sets
        }
      end

      def call_microflow_operation(page_name, widget, role_sets, name)
        parameters = microflow_parameters(name)
        return unless parameters

        {
          'operationId' => self.class.operation_id(page_name, widget['Name']),
          'operationType' => 'callMicroflow', 'parameters' => parameters,
          'constants' => { 'MicroflowName' => name }, 'allowedUserRoleSets' => role_sets
        }
      end

      def retrieve_by_microflow_operation(page_name, widget, role_sets, name)
        parameters = microflow_parameters(name)
        return unless parameters

        {
          'operationId' => self.class.operation_id(page_name, widget['Name']),
          'operationType' => 'retrieveByMicroflow', 'parameters' => parameters,
          'constants' => data_source_constants(page_name, widget, name),
          'allowedUserRoleSets' => role_sets
        }
      end

      def data_source_constants(page_name, widget, microflow_name)
        {
          'MicroflowName' => microflow_name, 'PageName' => page_name,
          'WidgetName' => "#{page_name}.#{widget['Name']}"
        }
      end

      def present_name?(value) = value.match?(/\A[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)+\z/)

      def qualified_unit(type, qualified_name)
        @source.units_of(type).find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == qualified_name
        end
      end

      def entity_ref_path(reference)
        array(reference&.fetch('Steps', nil)).flat_map do |step|
          [step['Association'], step['DestinationEntity']]
        end.map(&:to_s).reject(&:empty?).join('/')
      end

      def association_source_entity(path)
        association_name = path.split('/').first.to_s
        module_name, _, name = association_name.rpartition('.')
        domain = @source.units_of('DomainModels$DomainModel').find { _1.module_name == module_name }
        association = array(domain&.document&.fetch('Associations', nil)).find { _1['Name'] == name }
        pointer = IO::BsonCodec.extract_id(association&.fetch('ParentPointer', nil))
        entity = array(domain&.document&.fetch('Entities', nil)).find do |candidate|
          IO::BsonCodec.extract_id(candidate['$ID']) == pointer
        end
        "#{module_name}.#{entity['Name']}" if entity
      end

      def used_associations(value, entity)
        attribute_names(value, entity).select { _1.count('/') > 1 }.map do |path|
          path.split('/')[0...-1].join('/')
        end.uniq.sort
      end

      def widget_entities(document, initial_scope = nil)
        {}.compare_by_identity.tap { collect_widget_entities(document, initial_scope, _1) }
      end

      def document_scope_entity(document)
        array(document['Parameters']).filter_map do |parameter|
          parameter.dig('ParameterType', 'Entity') || parameter.dig('ParameterType', 'ObjectType', 'Entity')
        end.first
      end

      def collect_widget_entities(value, scope_entity, result)
        case value
        when Hash
          result[value] = scope_entity if %w[
            Forms$ActionButton Forms$ListView Forms$DataView CustomWidgets$CustomWidget
          ].include?(value['$Type'])
          child_entity = widget_scope_entity(value) || scope_entity
          value.each_value { collect_widget_entities(_1, child_entity, result) }
        when Array then value.each { collect_widget_entities(_1, scope_entity, result) }
        end
      end

      def widget_scope_entity(widget)
        if %w[Forms$ListView CustomWidgets$CustomWidget].include?(widget['$Type'])
          entity = WebListDataSource.new(@source, widget).entity
          return entity unless entity.empty?
        end
        return unless widget['$Type'] == 'Forms$DataView'

        source = widget['DataSource'] || {}
        steps = array(source.dig('EntityRef', 'Steps'))
        steps.last&.fetch('DestinationEntity', nil) || source.dig('EntityRef', 'Entity') ||
          microflow_return_entity(source)
      end

      def microflow_return_entity(source)
        name = source.dig('MicroflowSettings', 'Microflow').to_s
        flow = @source.units_of('Microflows$Microflow').find do |unit|
          "#{unit.module_name}.#{unit.document['Name']}" == name
        end
        flow&.document&.dig('MicroflowReturnType', 'Entity')
      end

      def nanoflow_operations
        return [] unless @source.is_a?(SourceModel)

        @source.units_of('Microflows$Nanoflow').flat_map do |unit|
          qualified_name = "#{unit.module_name}.#{unit.document['Name']}"
          nanoflow_action_operations(qualified_name, unit.document)
        end
      end

      def nanoflow_action_operations(qualified_name, document)
        entities = nanoflow_variable_entities(document)
        nested(document, 'Microflows$ActionActivity').filter_map do |activity|
          action = activity['Action'] || {}
          operation = nanoflow_server_operation(qualified_name, activity, action, entities)
          operation&.merge('allowedUserRoleSets' => [])
        end
      end

      def nanoflow_server_operation(qualified_name, activity, action, entities)
        operation_id = self.class.operation_id(qualified_name, model_id(activity))
        if action['$Type'] == 'Microflows$MicroflowCallAction'
          name = action.dig('MicroflowCall', 'Microflow').to_s
          parameters = microflow_parameters(name)
          return if name.empty? || !parameters

          return operation_record(operation_id, 'callMicroflow', parameters, 'MicroflowName' => name)
        end
        return unless commit_action?(action)

        variable = action['CommitVariableName'] || action['ChangeVariableName'] ||
                   action['OutputVariableName'] || action['VariableName']
        entity = entities[variable]
        parameter = entity.to_s.empty? ? 'AnyObjectList' : "[#{entity}]"
        operation_record(operation_id, 'commit', { 'Objects' => [parameter] }, {})
      end

      def commit_action?(action)
        action['$Type'] == 'Microflows$CommitAction' ||
          %w[Microflows$ChangeAction Microflows$CreateChangeAction].include?(action['$Type']) &&
            action['Commit'] == 'Yes'
      end

      def operation_record(operation_id, type, parameters, constants)
        {
          'operationId' => operation_id, 'operationType' => type,
          'parameters' => parameters, 'constants' => constants
        }
      end

      def nanoflow_variable_entities(document)
        nested(document, 'Microflows$MicroflowParameter').each_with_object({}) do |parameter, result|
          entity = parameter.dig('VariableType', 'Entity').to_s
          result[parameter['Name']] = entity unless entity.empty?
        end.tap do |result|
          nested(document, 'Microflows$ActionActivity').each do |activity|
            action = activity['Action'] || {}
            variable = action['OutputVariableName'] || action['VariableName']
            entity = action['Entity'].to_s
            result[variable] = entity if !variable.to_s.empty? && !entity.empty?
          end
        end
      end

      def model_id(value)
        identifier = value.is_a?(Hash) && value.key?('$ID') ? value['$ID'] : value
        IO::BsonCodec.extract_id(identifier).to_s
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
    end
    # rubocop:enable Metrics, Style/HashLikeCase, Style/MultilineBlockChain
  end
end
