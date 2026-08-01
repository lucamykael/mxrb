# frozen_string_literal: true

require 'digest'
require 'json'

module Mxrb
  module Compiler
    # Mirrors Mendix's Database Connector build extension by lowering custom activities to Java calls.
    # The mapping mirrors one cohesive external build-extension contract.
    # rubocop:disable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity,
    # rubocop:disable Metrics/MethodLength, Metrics/PerceivedComplexity
    class DatabaseConnectorActionCompiler
      include ModelValues

      def initialize(source)
        @source = source
        @connections = connection_index
      end

      def compile(action)
        connection, query = resolve_query(action['Query'].to_s)
        java_action = java_action_for(query)
        mappings = basic_mappings(action, connection, query, java_action)
        mappings.concat(result_mappings(query, java_action))
        {
          '$ID' => action['$ID'], '$Type' => 'Microflows$JavaActionCallAction',
          'QueueSettings' => nil, 'ParameterMappings' => mappings,
          'ErrorHandlingType' => action['ErrorHandlingType'], 'JavaAction' => java_action,
          'ResultVariableName' => action['OutputVariableName'].to_s,
          'UseReturnVariable' => true
        }
      end

      private

      def connection_index
        @source.units.each_with_object({}) do |unit, result|
          next unless unit.document['$Type'] == 'DatabaseConnector$DatabaseConnection'

          result["#{unit.module_name}.#{unit.document['Name']}"] = unit.document
        end
      end

      def resolve_query(qualified)
        connection_name, _, query_name = qualified.rpartition('.')
        connection = @connections[connection_name]
        raise CompilationError, "database connection #{connection_name.inspect} not found" unless connection

        query = array(connection['Queries']).find { _1['Name'] == query_name }
        raise CompilationError, "database query #{qualified.inspect} not found" unless query

        [connection, query]
      end

      def java_action_for(query)
        sql = remove_comments(query['Query'].to_s).downcase
        selecting = (sql.start_with?('select ') && !sql.include?(' into ')) || sql.start_with?('with ')
        mapped = array(query['TableMappings']).any?
        if selecting
          return mapped ? 'ExternalDatabaseConnector.ExecuteQuery' : 'ExternalDatabaseConnector.ExecuteStatement'
        end
        return statement_action(mapped) unless callable?(query, sql)
        return 'ExternalDatabaseConnector.ExecuteCallable' if query['QueryType'].to_i == 3

        if mapped
          'ExternalDatabaseConnector.ExecuteCallableQuery'
        else
          'ExternalDatabaseConnector.ExecuteCallableStatement'
        end
      end

      def statement_action(mapped)
        mapped ? 'ExternalDatabaseConnector.ExecuteQuery' : 'ExternalDatabaseConnector.ExecuteStatement'
      end

      def callable?(query, sql)
        return true if query['QueryType'].to_i == 3
        return false unless query['QueryType'].to_i.zero?

        sql.match?(/\A\s*(?:\{\s*)?(?:call|exec(?:ute)?)\b/i)
      end

      def basic_mappings(action, connection, query, java_action)
        values = {
          'connectionDetails' => expression_literal(connection_json(action, connection)),
          'sql' => expression_literal(runtime_query(action, query)),
          'queryParameters' => expression_literal(parameters_json(action, query))
        }
        values.map.with_index { |(name, value), index| parameter_mapping(action, java_action, name, value, index) }
      end

      def result_mappings(query, java_action)
        return [] unless %w[
          ExternalDatabaseConnector.ExecuteQuery ExternalDatabaseConnector.ExecuteCallableQuery
          ExternalDatabaseConnector.ExecuteCallable
        ].include?(java_action)

        table = array(query['TableMappings']).first
        return [] unless table

        column_mapping = JSON.generate(
          'EntityName' => table['Entity'].to_s,
          'ColumnAttributeMapping' => array(table['Columns']).to_h do |column|
            [column['ColumnName'].to_s, column['Attribute'].to_s.split('.').last]
          end
        )
        offset = 10
        [
          parameter_mapping(query, java_action, 'columnMapping', expression_literal(column_mapping), offset),
          entity_parameter_mapping(query, java_action, 'OutputEntity', table['Entity'].to_s, offset + 1)
        ]
      end

      def connection_json(action, connection)
        overrides = array(action['ConnectionParameterMappings']).to_h do |mapping|
          [mapping['ParameterName'].to_s.downcase, mapping['Value'].to_s]
        end
        values = {
          'UserName' => raw(connection_value(overrides, connection, 'DBUsername', 'UserName')),
          'Password' => raw(connection_value(overrides, connection, 'DBPassword', 'Password')),
          'ConnectionString' => raw(connection_value(overrides, connection, 'DBSource', 'ConnectionString')),
          'DatabaseType' => connection['DatabaseType'].to_s,
          'AdditionalProperties' => additional_properties(overrides, connection)
        }
        raw_json(values)
      end

      def connection_value(overrides, connection, parameter, field)
        expression = overrides[parameter.downcase]
        expression ||= "@#{connection[field]}" unless connection[field].to_s.empty?
        expression ||= "''"
        "'+(#{expression})+'"
      end

      def additional_properties(overrides, connection)
        array(connection['AdditionalProperties']).to_h do |property|
          value = property['Value'] || {}
          expression = overrides[property['Key'].to_s.downcase]
          rendered = if expression
                       raw("'+(#{expression})+'")
                     elsif value['$Type'] == 'DatabaseConnector$ValueAsConstant'
                       raw("'+(@#{value['Value']})+'")
                     else
                       value['Value'].to_s
                     end
          [property['Key'].to_s, rendered]
        end
      end

      def runtime_query(action, query)
        dynamic = action['DynamicQuery'].to_s
        return "'+(#{dynamic})+'" unless dynamic.strip.empty?

        sql = query['Query'].to_s
        sql = query_builder_select(query) if sql.strip.empty?
        sql.gsub("'", "''")
      end

      def query_builder_select(query)
        table = array(query['TableMappings']).first
        columns = table && array(table['Columns']).filter_map { valid_identifier(_1['ColumnName']) }
        name = table && valid_identifier(table['TableName'])
        unless name && columns.any?
          raise CompilationError, 'database query builder has no executable table and column mapping'
        end

        "SELECT #{columns.join(', ')} FROM #{name}"
      end

      def valid_identifier(value)
        identifier = value.to_s
        return identifier if identifier.match?(/\A[A-Za-z_][A-Za-z0-9_$]*(?:\.[A-Za-z_][A-Za-z0-9_$]*)*\z/)

        raise CompilationError, "unsafe database identifier #{identifier.inspect}"
      end

      def parameters_json(action, query)
        mappings = array(action['ParameterMappings']).to_h do |mapping|
          [mapping['ParameterName'].to_s.downcase, mapping['Value'].to_s]
        end
        result = {}
        array(query['Parameters']).each_with_index do |parameter, index|
          type = parameter.dig('DataType', '$Type').to_s.sub(/\ADataTypes\$/, '').sub(/Type\z/, '').upcase
          value = parameter_value(type, mappings[parameter['ParameterName'].to_s.downcase])
          result[(index + 1).to_s] = {
            'Name' => parameter['ParameterName'], 'DataType' => type,
            'SqlDataType' => parameter.dig('SqlDataType', 'DataTypeName').to_s,
            'Value' => value && raw(value), 'ParameterMode' => parameter['Mode'].to_s,
            'DatabaseParameterName' => parameter['DatabaseParameterName'].to_s,
            'ParameterEntityMapping' => nil
          }
        end
        raw_json(result)
      end

      def parameter_value(type, expression)
        case type
        when 'DATETIME' then "'+(if (#{expression}) = NULL then NULL else dateTimeToEpoch(#{expression}))+'"
        when 'BOOLEAN' then "'+toString(#{expression})+'"
        when 'STRING'
          "'+(if (#{expression}) = NULL then NULL else (if (#{expression}) = 'null' then " \
            "'903be4ca-ed8b-ddcb-a339-741c4088484a' else (urlEncode(#{expression}))))+'"
        when 'INTEGER', 'DECIMAL' then "'+(#{expression})+'"
        else raise CompilationError, "unsupported database parameter type #{type.inspect}"
        end
      end

      def expression_literal(value) = "'#{value}'"

      def parameter_mapping(seed, java_action, name, value, index)
        {
          '$ID' => derived_id(seed, "mapping-#{index}"), '$Type' => 'Microflows$JavaActionParameterMapping',
          'Parameter' => "#{java_action}.#{name}",
          'Value' => {
            '$ID' => derived_id(seed, "value-#{index}"),
            '$Type' => 'Microflows$BasicCodeActionParameterValue', 'ValueExpression' => value
          }
        }
      end

      def entity_parameter_mapping(seed, java_action, name, entity, index)
        {
          '$ID' => derived_id(seed, "mapping-#{index}"), '$Type' => 'Microflows$JavaActionParameterMapping',
          'Parameter' => "#{java_action}.#{name}",
          'Value' => {
            '$ID' => derived_id(seed, "value-#{index}"),
            '$Type' => 'Microflows$EntityTypeCodeActionParameterValue',
            'Entity' => entity, 'ValueExpression' => "'#{entity}'"
          }
        }
      end

      def raw(value) = { '__mxrb_raw__' => value }

      def raw_json(value)
        rendered = JSON.generate(value)
        rendered.gsub(/\{"__mxrb_raw__":"((?:\\.|[^"\\])*)"\}/) do
          JSON.parse(%("#{Regexp.last_match(1)}"))
        end
      end

      def remove_comments(sql) = sql.gsub(%r{/\*[\s\S]*?\*/|--.*}, '').strip

      def derived_id(source, label)
        seed = "#{IO::BsonCodec.extract_id(source['$ID'])}:database-connector:#{label}"
        hex = Digest::SHA256.hexdigest(seed)[0, 32]
        "#{hex[0, 8]}-#{hex[8, 4]}-4#{hex[13, 3]}-8#{hex[17, 3]}-#{hex[20, 12]}"
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/ClassLength, Metrics/CyclomaticComplexity,
    # rubocop:enable Metrics/MethodLength, Metrics/PerceivedComplexity
  end
end
