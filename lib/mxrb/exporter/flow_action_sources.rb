# frozen_string_literal: true

module Mxrb
  class Exporter
    # Writes each microflow and nanoflow action as a line of the flow DSL.
    module FlowActionSources
      REST_PROXY_CONFIGURATION_FIELDS = %w[
        $ID $Type HostExpression PasswordExpression PortExpression UseConfigurationExpression
        UsernameExpression
      ].freeze

      private

      def action_dsl_line(obj, indent)
        action = obj['Action'] || {}
        pad    = ' ' * indent
        case action['$Type']
        when 'Microflows$CreateObjectAction', 'Microflows$CreateChangeAction'
          legacy = action['$Type'] == 'Microflows$CreateChangeAction'
          members = member_specs(action[legacy ? 'Items' : 'Members'])
          variable = legacy ? action['VariableName'] : action['OutputVariableName']
          commit_a = action['Commit'] == 'Yes' ? ', commit: true' : ''
          commit_a = ', commit: true, with_events: false' if action['Commit'] == 'YesWithoutEvents'
          refresh_a = action['RefreshInClient'] == true ? ', refresh: true' : ''
          command = "#{pad}create_object #{ruby(action['Entity'])}, as: :#{variable}#{commit_a}#{refresh_a}"
          members.empty? ? command : member_block(command, members, indent)
        when 'Microflows$ChangeObjectAction', 'Microflows$ChangeAction'
          legacy = action['$Type'] == 'Microflows$ChangeAction'
          members = member_specs(action[legacy ? 'Items' : 'Members'])
          variable = legacy ? action['ChangeVariableName'] : action['Variable']
          commit_a = action['Commit'] == 'Yes' ? ', commit: true' : ''
          commit_a = ', commit: true, with_events: false' if action['Commit'] == 'YesWithoutEvents'
          refresh_a = action['RefreshInClient'] == true ? ', refresh: true' : ''
          command = "#{pad}change_object :#{variable}#{commit_a}#{refresh_a}"
          members.empty? ? command : member_block(command, members, indent)
        when 'Microflows$RetrieveAction'
          src      = action['RetrieveSource'] || {}
          variable = action['ResultVariableName'] || action['ResultListName']
          if src['$Type'] == 'Microflows$AssociationRetrieveSource'
            "#{pad}retrieve_association :#{src['StartVariableName']}, " \
              "association: #{ruby(src['AssociationId'])}, as: :#{variable}"
          else
            xpath = (src['XpathConstraint'] || src['XPath']).to_s
            args = [ruby(src['Entity']), "as: :#{variable}"]
            args << "xpath: #{ruby(xpath)}" unless xpath.empty?
            range = src['Range'] || {}
            if range['$Type'] == 'Microflows$CustomRange'
              limit = range['LimitExpression'].to_s
              args << "limit: #{ruby(limit)}" unless limit.empty?
            elsif range['SingleObject'] == true
              args << 'single: true'
            end
            sortings = bson_items(src.dig('NewSortings', 'Sortings') || src['SortItems'])
            unless sortings.empty?
              rendered = sortings.map do |sorting|
                "[#{ruby(sorting_path(sorting))}, :#{underscore(sorting['SortOrder'])}]"
              end
              args << "sort: [#{rendered.join(', ')}]"
            end
            "#{pad}retrieve_objects #{args.join(', ')}"
          end
        when 'Microflows$CommitObjectsAction', 'Microflows$CommitAction'
          legacy = action['$Type'] == 'Microflows$CommitAction'
          variable = legacy ? action['CommitVariableName'] : action['Variable']
          with_events = legacy ? action.fetch('WithEvents', true) : action['CommitWithoutEvents'] != true
          events_a = with_events ? '' : ', with_events: false'
          refresh_a = action['RefreshInClient'] == true ? ', refresh: true' : ''
          "#{pad}commit :#{variable}#{events_a}#{refresh_a}"
        when 'Microflows$DeleteAction'
          variable = action['DeleteVariableName'] || action['DeleteVariable']
          refresh_a = action['RefreshInClient'] == true ? ', refresh: true' : ''
          "#{pad}delete :#{variable}#{refresh_a}"
        when 'Microflows$MicroflowCallAction'
          call    = action['MicroflowCall'] || {}
          out     = if action['UseReturnVariable'] == true
                      (action['ResultVariableName'] || action['OutputVariableName']).to_s
                    else
                      ''
                    end
          as_a = out.empty? ? '' : ", as: :#{out}"
          stored_result = (action['ResultVariableName'] || action['OutputVariableName']).to_s
          result_a = if out.empty? && !stored_result.empty?
                       ", result_name: #{symbol(stored_result)}, use_return: false"
                     elsif action['UseReturnVariable'] == true && out.empty?
                       ', use_return: true'
                     else
                       ''
                     end
          params = bson_items(call['ParameterMappings']).map { [_1['Parameter'], _1['Argument']] }
          call_with_arguments_line(
            pad, 'call_microflow', "#{ruby(call['Microflow'])}#{as_a}#{result_a}", params
          )
        when 'Microflows$CreateVariableAction'
          type = action.dig('VariableType', '$Type').to_s
          type = type.delete_prefix('DataTypes$').delete_suffix('Type')
          value = action['InitialValue']
          value_a = value.nil? || value.to_s.empty? ? '' : ", value: #{ruby_val(value)}"
          type_a = type.empty? ? '' : ", type: #{symbol(type)}"
          "#{pad}create_variable :#{action['VariableName']}#{type_a}#{value_a}"
        when 'Microflows$ChangeVariableAction'
          "#{pad}change_variable :#{action['ChangeVariableName']}, to: #{ruby_val(action['Value'])}"
        when 'Microflows$ShowMessageAction'
          flow_text_action_line(action, indent, validation: false)
        when 'Microflows$LogMessageAction'
          template = action['MessageTemplate'] || {}
          parameters = bson_items(template['Parameters']).map { _1['Expression'] }
          level_a = action['Level'].to_s.empty? ? '' : ", level: :#{underscore(action['Level'])}"
          node_a = action['Node'].to_s.empty? ? '' : ", node: #{ruby(action['Node'])}"
          stack_a = action['IncludeLatestStackTrace'] == true ? ', include_stack: true' : ''
          parameters_a = parameters.empty? ? '' : ", parameters: #{ruby(parameters)}"
          "#{pad}log_message #{ruby(template['Text'].to_s)}#{level_a}#{node_a}#{stack_a}#{parameters_a}"
        when 'Microflows$ShowFormAction'
          show_page_action_line(action, indent)
        when 'Microflows$ShowHomePageAction'
          "#{pad}show_home_page"
        when 'Microflows$CloseFormAction'
          count = action['NumberOfPagesToClose'].to_s
          count.empty? ? "#{pad}close_page" : "#{pad}close_page count: #{count.to_i}"
        when 'Microflows$JavaActionCallAction'
          call_action_line(
            pad, 'call_java', action['JavaAction'], action['ResultVariableName'],
            bson_items(action['ParameterMappings']).map do
              [_1['Parameter'], code_action_parameter_value(_1['Value'])]
            end,
            action['UseReturnVariable']
          )
        when 'Microflows$JavaScriptActionCallAction'
          call_action_line(
            pad, 'call_javascript', action['JavaScriptAction'], action['OutputVariableName'],
            bson_items(action['ParameterMappings']).map do
              [_1['Parameter'], code_action_parameter_value(_1['ParameterValue'])]
            end,
            action['UseReturnVariable']
          )
        when 'Microflows$NanoflowCallAction'
          call = action['NanoflowCall'] || {}
          call_action_line(
            pad, 'call_nanoflow', call['Nanoflow'], action['OutputVariableName'],
            bson_items(call['ParameterMappings']).map { [_1['Parameter'], _1['Argument']] },
            action['UseReturnVariable']
          )
        when 'Microflows$AppServiceCallAction'
          call_action_line(
            pad, 'call_app_service', action['AppServiceAction'], action['ResultVariableName'],
            bson_items(action['ParameterMappings']).map { [_1['Parameter'], _1['Argument']] },
            action['UseReturnVariable']
          )
        when 'Microflows$AggregateAction'
          args = [
            ":#{action['AggregateVariableName']}",
            "function: :#{underscore(action['AggregateFunction'])}",
            "as: :#{action['VariableName']}"
          ]
          args << "attribute: #{ruby(action['Attribute'])}" unless action['Attribute'].to_s.empty?
          "#{pad}aggregate #{args.join(', ')}"
        when 'Microflows$RollbackAction'
          refresh = action['RefreshInClient'] == true ? ', refresh: true' : ''
          "#{pad}rollback :#{action['RollbackVariableName']}#{refresh}"
        when 'Microflows$CastAction'
          "#{pad}cast :#{action['VariableName']}"
        when 'Microflows$CreateListAction'
          "#{pad}create_list #{ruby(action['Entity'])}, as: :#{action['VariableName']}"
        when 'Microflows$ListOperationsAction'
          operation = action['NewOperation'] || {}
          op = operation['$Type'].to_s.delete_prefix('Microflows$')
          args = [":#{underscore(op)}", ":#{operation['ListName']}"]
          second = operation['SecondListOrObjectName'].to_s
          expression = operation['Expression']
          args << "with: :#{second}" unless second.empty?
          %w[Attribute Association].each do |member|
            args << "#{member.downcase}: #{ruby(operation[member])}" unless operation[member].to_s.empty?
          end
          args << "expression: #{ruby(expression)}" unless expression.nil?
          sortings = bson_items(operation.dig('Sortings', 'Sortings'))
          unless sortings.empty?
            rendered = sortings.map do |sorting|
              "[#{ruby(sorting_path(sorting))}, :#{underscore(sorting['SortOrder'])}]"
            end
            args << "sort: [#{rendered.join(', ')}]"
          end
          args << "as: :#{action['ResultVariableName']}"
          "#{pad}list_operation #{args.join(', ')}"
        when 'Microflows$ChangeListAction'
          "#{pad}change_list :#{action['ChangeVariableName']}, " \
            "action: :#{underscore(action['Type'])}, value: #{ruby_val(action['Value'])}"
        when 'Microflows$ValidationFeedbackAction'
          flow_text_action_line(action, indent, validation: true)
        when 'Microflows$RestCallAction'
          rest_call_line(pad, action)
        when 'DatabaseConnector$ExecuteDatabaseQueryAction'
          database_query_line(pad, action)
        when 'Microflows$ImportXmlAction'
          import_xml_line(pad, action)
        when 'Microflows$ExportXmlAction'
          export_xml_line(pad, action)
        when 'Microflows$DownloadFileAction'
          args = [":#{action['FileDocumentVariableName']}"]
          args << 'show_in_browser: true' if action['ShowFileInBrowser'] == true
          error = underscore(action['ErrorHandlingType'])
          args << "error: :#{error}" unless error == 'rollback'
          "#{pad}download_file #{args.join(', ')}"
        end
      end

      # A sort attribute, with "Assoc/Destination/" steps when it goes through associations.
      def sorting_path(sorting)
        return sorting['AttributePath'] unless sorting['AttributePath'].to_s.empty?

        reference = sorting['AttributeRef'] || {}
        steps = bson_items(reference.dig('EntityRef', 'Steps'))
        attribute = reference['Attribute'].to_s
        return attribute if steps.empty?

        (steps.flat_map { [_1['Association'], _1['DestinationEntity']] } << attribute.split('.').last).join('/')
      end

      def database_query_line(pad, action)
        args = []
        query = action['Query'].to_s
        args << ruby(query.empty? ? nil : query)
        dynamic_query = action['DynamicQuery'].to_s
        args << "dynamic_query: #{ruby_val(dynamic_query)}" unless dynamic_query.empty?
        output = action['OutputVariableName'].to_s
        args << "as: :#{output}" unless output.empty?
        parameters = bson_items(action['ParameterMappings']).map do |mapping|
          [mapping['ParameterName'], mapping['Value']]
        end
        connection_parameters = bson_items(action['ConnectionParameterMappings']).map do |mapping|
          [mapping['ParameterName'], mapping['Value']]
        end
        error = underscore(action['ErrorHandlingType'])
        args << "error: :#{error}" unless error == 'rollback'
        declaration = "#{pad}execute_database_query #{args.join(', ')}"
        return declaration if parameters.empty? && connection_parameters.empty?

        lines = ["#{declaration} do"]
        parameters.each do |name, value|
          lines << "#{pad}  parameter #{ruby(name)}, #{ruby_val(value)}"
        end
        connection_parameters.each do |name, value|
          lines << "#{pad}  connection_parameter #{ruby(name)}, #{ruby_val(value)}"
        end
        lines << "#{pad}end"
        lines.join("\n")
      end

      def import_xml_line(pad, action)
        result = action['ResultHandling'] || {}
        mapping = result['ImportMappingCall'] || {}
        range = mapping['Range'] || {}
        args = [":#{action['XmlDocumentVariableName']}"]
        args << "mapping: #{ruby(mapping['ReturnValueMapping'])}"
        args << "as: :#{result['ResultVariableName']}"
        args << "result_entity: #{ruby(result.dig('VariableType', 'Entity'))}"
        args << 'validate: true' if action['IsValidationRequired'] == true
        content_type = underscore(mapping['ContentType'])
        args << "content_type: :#{content_type}" unless content_type == 'xml'
        commit = underscore(mapping['Commit'])
        args << "commit: :#{commit}" unless commit == 'yes_without_events'
        args << 'force_single: true' if mapping['ForceSingleOccurrence'] == true
        args << 'single: true' if range['SingleObject'] == true
        handling = underscore(mapping['ObjectHandlingBackup'])
        args << "object_handling: :#{handling}" unless handling == 'create'
        parameter = mapping['ParameterVariableName'].to_s
        args << "parameter_variable: :#{parameter}" unless parameter.empty?
        error = underscore(action['ErrorHandlingType'])
        args << "error: :#{error}" unless error == 'rollback'
        "#{pad}import_xml #{args.join(', ')}"
      end

      def export_xml_line(pad, action)
        output = action['OutputMethod'] || {}
        handling = action['ResultHandling'] || {}
        args = [":#{handling['MappingVariableName']}"]
        args << "mapping: #{ruby(handling['MappingId'])}"
        args << "as: :#{output['OutputVariableName']}"
        content_type = underscore(handling['ContentType'])
        args << "content_type: :#{content_type}" unless content_type == 'xml'
        args << 'validate: true' if action['IsValidationRequired'] == true
        error = underscore(action['ErrorHandlingType'])
        args << "error: :#{error}" unless error == 'rollback'
        "#{pad}export_xml #{args.join(', ')}"
      end

      def rest_call_line(pad, action)
        http = action['HttpConfiguration'] || {}
        location = http['CustomLocationTemplate'] || {}
        headers = Dsl::FlowRestBuilder.new
        bson_items(http['HttpHeaderEntries']).each { headers.header(_1.fetch('Key'), _1.fetch('Value')) }
        headers = headers.headers
        request = action['RequestHandling'] || {}
        result = action['ResultHandling'] || {}
        import_call = result['ImportMappingCall'] || {}
        args = [
          "method: :#{underscore(http['HttpMethod'])}",
          "location: #{ruby(location['Text'].to_s)}"
        ]
        parameters = bson_items(location['Parameters']).map { _1['Expression'] }
        args << "location_parameters: #{ruby(parameters)}" unless parameters.empty?
        if http['UseHttpAuthentication'] == true
          username = http['HttpAuthenticationUserName'].to_s
          password = http['HttpAuthenticationPassword'].to_s
          if username.empty? || password.empty?
            raise SerializationError, 'REST basic authentication requires both username and password'
          end

          args << "username: #{ruby(username)}"
          args << "password: #{ruby(password)}"
        end
        client_certificate = http['ClientCertificate'].to_s
        args << "client_certificate: #{ruby(client_certificate)}" unless client_certificate.empty?
        rest_proxy_source_option(action, args)
        if request['$Type'] == 'Microflows$CustomRequestHandling'
          template = request['Template'] || {}
          args << "request_body: #{ruby(template['Text'].to_s)}"
          request_parameters = bson_items(template['Parameters']).map { _1['Expression'] }
          args << "request_parameters: #{ruby(request_parameters)}" unless request_parameters.empty?
        else
          mapping_id = request['MappingId'].to_s
          mapping_variable = request['MappingVariableName'].to_s
          args << "request_mapping: #{ruby(mapping_id)}" unless mapping_id.empty?
          args << "request_variable: :#{mapping_variable}" unless mapping_variable.empty?
        end
        args << "result_mapping: #{ruby(import_call['ReturnValueMapping'])}" if import_call['ReturnValueMapping']
        if action['ResultHandlingType'] == 'HttpResponse'
          args << 'result_handling: :http_response'
        elsif action['ResultHandlingType'] == 'String'
          args << 'result_handling: :string'
        end
        args << "as: :#{result['ResultVariableName']}" unless result['ResultVariableName'].to_s.empty?
        args << "result_entity: #{ruby(result.dig('VariableType', 'Entity'))}" if result.dig('VariableType', 'Entity')
        args << "timeout: #{ruby(action['TimeOutExpression'])}" if action['UseRequestTimeOut'] == true
        args << "commit: :#{underscore(import_call['Commit'])}" unless import_call['Commit'].to_s.empty?
        content_type = underscore(import_call['ContentType'])
        args << "result_content_type: :#{content_type}" unless content_type.empty? || content_type == 'json'
        args << 'force_single: true' if import_call['ForceSingleOccurrence'] == true
        args << 'single: true' if import_call.dig('Range', 'SingleObject') == true
        object_handling = underscore(import_call['ObjectHandlingBackup'])
        args << "object_handling: :#{object_handling}" unless object_handling.empty? || object_handling == 'create'
        parameter = import_call['ParameterVariableName'].to_s
        args << "parameter_variable: :#{parameter}" unless parameter.empty?
        args << "error_result: :#{underscore(action['ErrorResultHandlingType'])}"
        args << "error: :#{underscore(action['ErrorHandlingType'])}"
        command = "#{pad}call_rest #{args.join(', ')}"
        return command if headers.empty?

        declarations = headers.map { |name, expression| "#{pad}  header #{ruby(name)}, #{ruby(expression)}" }
        ["#{command} do", *declarations, "#{pad}end"].join("\n")
      end

      def rest_proxy_source_option(action, args)
        proxy_type = action.fetch('RequestProxyType', 'DefaultProxy')
        proxy = action['ProxyConfiguration']
        case proxy_type
        when 'DefaultProxy'
          raise SerializationError, 'default REST proxy must not contain a configuration' if proxy
        when 'NoProxy'
          raise SerializationError, 'disabled REST proxy must not contain a configuration' if proxy

          args << 'proxy: :none'
        when 'Override'
          unless proxy.is_a?(Hash) && proxy['$Type'] == 'Microflows$ProxyConfiguration' &&
                 (proxy.keys - REST_PROXY_CONFIGURATION_FIELDS).empty?
            raise SerializationError, 'REST proxy override requires a valid proxy configuration'
          end
          if proxy['HostExpression'].to_s.empty? || proxy['PortExpression'].to_s.empty?
            raise SerializationError, 'REST proxy override requires host and port expressions'
          end
          if proxy['UsernameExpression'].to_s.empty? != proxy['PasswordExpression'].to_s.empty?
            raise SerializationError, 'REST proxy authentication requires both username and password'
          end

          args << "proxy: #{ruby({
                                   id: document_id(proxy), host: proxy['HostExpression'].to_s,
                                   port: proxy['PortExpression'].to_s, username: proxy['UsernameExpression'].to_s,
                                   password: proxy['PasswordExpression'].to_s,
                                   use: proxy.fetch('UseConfigurationExpression', 'true').to_s
                                 })}"
        else
          raise SerializationError, "unsupported REST proxy type #{proxy_type.inspect}"
        end
      end

      def call_action_line(pad, method, target, output, mappings, use_return)
        args = [ruby(target)]
        if use_return == true && !output.to_s.empty?
          args << "as: :#{output}"
        elsif !output.to_s.empty?
          args << "result_name: #{symbol(output)}"
          args << 'use_return: false'
        elsif use_return == true
          args << 'use_return: true'
        end
        call_with_arguments_line(pad, method, args.join(', '), mappings)
      end

      def call_with_arguments_line(pad, method, arguments, mappings)
        declaration = "#{pad}#{method} #{arguments}"
        return declaration if mappings.empty?

        lines = ["#{declaration} do"]
        mappings.each do |parameter, value|
          kind = value[:kind] || value['kind'] if value.is_a?(Hash)
          mapped_value = value[:value] || value['value'] if kind
          helper = kind ? "#{kind}_argument" : 'argument'
          mapped_value = value unless kind
          lines << "#{pad}  #{helper} #{ruby(parameter)}, #{ruby_val(mapped_value)}"
        end
        lines << "#{pad}end"
        lines.join("\n")
      end

      def code_action_parameter_value(value)
        value ||= {}
        type = value['$Type'].to_s
        return value['Argument'] if type.include?('$Basic')

        field, kind = case type
                      when /EntityTypeCodeActionParameterValue/ then ['Entity', :entity_type]
                      when /EntityType/ then ['Entity', :entity]
                      when /Microflow(?:Java)?/ then ['Microflow', :microflow]
                      when /ImportMapping/ then ['ImportMapping', :import_mapping]
                      when /ExportMapping/ then ['ExportMapping', :export_mapping]
                      else
                        [nil, :native]
                      end
        { kind: kind, value: field ? value[field] : value }
      end

      def translated_text(text_doc)
        return '' unless text_doc

        translations = text_doc['Translations'] || text_doc['Items']
        bson_items(translations).first&.fetch('Text', '') || ''
      end

      def translated_items(text_doc)
        return [] unless text_doc

        bson_items(text_doc['Translations'] || text_doc['Items'])
      end

      def show_page_action_line(action, indent)
        pad = ' ' * indent
        settings = action['FormSettings'] || {}
        args = [ruby(settings['Form'])]
        variable = action['FormObjectVariable'].to_s
        args << "object: :#{variable}" unless variable.empty?
        location = settings['Location'].to_s
        args << "location: :#{underscore(location)}" unless location.empty?
        close_pages = action['NumberOfPagesToClose'].to_s
        args << "close_pages: #{close_pages.to_i}" unless close_pages.empty?
        title = settings['FormTitle'] || settings['TitleOverride']
        translations = translated_items(title&.fetch('Text', title)).map do |translation|
          [translation['LanguageCode'].to_s, translation['Text'].to_s]
        end
        if translations.map(&:first).uniq.size != translations.size
          raise SerializationError, 'duplicate page title language cannot be represented by this declaration'
        end

        mappings = bson_items(settings['ParameterMappings'])
        command = "#{pad}show_page #{args.join(', ')}"
        return command if mappings.empty? && title.nil?

        lines = ["#{command} do"]
        mappings.each do |mapping|
          lines << "#{pad}  argument #{ruby(mapping['Parameter'])}, #{ruby(mapping['Argument'])}"
        end
        unless title.nil?
          lines << "#{pad}  title do"
          translations.each { |language, text| lines << "#{pad}    translation #{ruby(language)}, #{ruby(text)}" }
          lines << "#{pad}  end"
        end
        (lines << "#{pad}end").join("\n")
      end

      def flow_text_action_line(action, indent, validation:)
        template = action[validation ? 'FeedbackTemplate' : 'Template'] || {}
        builder = Dsl::FlowTextBuilder.new
        translated_items(template['Text']).each do |translation|
          builder.translation(translation.fetch('LanguageCode'), translation.fetch('Text', ''))
        end
        bson_items(template['Parameters']).each { builder.parameter(_1['Expression']) }
        if validation
          arguments = [symbol(action['ValidationVariableName'])]
          arguments << "attribute: #{ruby(action['Attribute'])}" unless action['Attribute'].to_s.empty?
          arguments << "association: #{ruby(action['Association'])}" unless action['Association'].to_s.empty?
          error = underscore(action['ErrorHandlingType'])
          arguments << "error: :#{error}" unless error == 'rollback'
        else
          arguments = []
          arguments << "type: :#{underscore(action['Type'])}" unless action['Type'].to_s.empty?
          arguments << 'blocking: true' if action['Blocking'] == true
        end
        command = validation ? 'validation_feedback' : 'show_message'
        declaration = [command, arguments.join(', ')].reject(&:empty?).join(' ')
        padding = ' ' * indent
        lines = ["#{padding}#{declaration} do"]
        builder.translations.each do |language, text|
          lines << "#{padding}  translation #{ruby(language)}, #{ruby(text)}"
        end
        builder.parameters.each { lines << "#{padding}  parameter #{ruby(_1)}" }
        [*lines, "#{padding}end"].join("\n")
      rescue ArgumentError, TypeError, KeyError => e
        raise SerializationError, "unsupported flow text declaration: #{e.class}"
      end

      def member_specs(members_bson)
        bson_items(members_bson).filter_map do |m|
          attr = m['Attribute'].to_s
          association = m['Association'].to_s
          raw_value = m['Value']
          val = raw_value.is_a?(Hash) ? raw_value['Value'].to_s : raw_value.to_s
          next if attr.empty? && association.empty?

          {
            attribute: attr, association: association, value: val,
            operation: m.fetch('Type', 'Set')
          }
        end
      end

      def members_dsl(members)
        members.map { "#{symbol(_1[:attribute])} => #{ruby_val(_1[:value])}" }.join(', ')
      end

      def member_block(command, members, indent)
        pad = ' ' * (indent + 2)
        lines = ["#{command} do"]
        members.each do |member|
          if member[:association].to_s.empty?
            lines << "#{pad}set #{symbol(member[:attribute])}, to: #{ruby_val(member[:value])}"
          else
            operation = underscore(member[:operation])
            operation_a = operation == 'set' ? '' : ", operation: :#{operation}"
            lines << "#{pad}set_association #{ruby(member[:association])}, " \
                     "to: #{ruby_val(member[:value])}#{operation_a}"
          end
        end
        lines << "#{' ' * indent}end"
        lines.join("\n")
      end
    end
  end
end
