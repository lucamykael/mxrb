# frozen_string_literal: true

module Mxrb
  class Exporter
    # Declares enumerations, constants, OQL sources and database connections as Ruby.
    module DomainDocumentDeclarations
      private

      def enumeration_declaration(document)
        doc = document.fetch(:doc)
        options = {
          id: document_id(doc), unit_id: document.fetch(:id),
          documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
          export_level: doc.fetch('ExportLevel', 'Hidden'),
          values_marker: bson_marker(doc['Values'], 3)
        }
        remote_source = doc['RemoteSource']
        if remote_source.is_a?(Hash) &&
           remote_source['$Type'] == 'Rest$ODataRemoteEnumerationSource'
          options.merge!(
            remote_source_id: document_id(remote_source),
            remote_service: remote_source.fetch('ConsumedODataService', ''),
            remote_name: remote_source.fetch('RemoteName', '')
          )
        else
          options[:remote_source] = remote_source
        end
        lines = domain_call_lines(:enumeration, document.fetch(:name), options)
        lines[-1] = "#{lines[-1]} do"
        bson_items(doc['Values']).each do |value|
          caption = value.fetch('Caption')
          translations = bson_items(caption['Items'])
          value_options = {
            id: document_id(value), caption_id: document_id(caption),
            captions: translations.to_h { [_1.fetch('LanguageCode'), _1.fetch('Text', '')] },
            caption_ids: translations.to_h { [_1.fetch('LanguageCode'), document_id(_1)] },
            image: value.fetch('Image', ''),
            translations_marker: bson_marker(caption['Items'], 3)
          }
          remote_value = value['RemoteValue']
          if remote_value.is_a?(Hash) &&
             remote_value['$Type'] == 'Rest$ODataRemoteEnumerationValue'
            value_options[:remote_id] = document_id(remote_value)
            value_options[:remote_name] = remote_value.fetch('RemoteName', '')
          else
            value_options[:remote_value] = remote_value
          end
          value_options[:export_level] = value['ExportLevel'] if value.key?('ExportLevel')
          lines.concat(domain_call_lines(:value, value.fetch('Name'), value_options, indent: 2))
        end
        lines << 'end'
        lines.join("\n")
      end

      def constant_declaration(document)
        doc = document.fetch(:doc)
        properties = doc.reject do |key, _value|
          %w[$ID $Type Name Documentation Excluded ExportLevel ExposedToClient Type DefaultValue].include?(key)
        end
        type_properties = doc.fetch('Type').reject { |key, _value| %w[$ID $Type].include?(key) }
        domain_call_lines(:constant, document.fetch(:name), {
                            type: data_type_spec(doc.fetch('Type')), value: doc.fetch('DefaultValue', ''),
                            id: document_id(doc), type_id: document_id(doc.fetch('Type')),
                            unit_id: document.fetch(:id), documentation: doc.fetch('Documentation', ''),
                            excluded: doc['Excluded'] == true, export_level: doc.fetch('ExportLevel', 'Hidden'),
                            exposed_to_client: doc['ExposedToClient'] == true,
                            properties: presentation_value_spec(properties),
                            type_properties: presentation_value_spec(type_properties)
                          }).join("\n")
      end

      def oql_source_declaration(document)
        doc = document.fetch(:doc)
        semantic_call_source(:oql_source_document, document, {
                               query: doc.fetch('Oql', ''), documentation: doc.fetch('Documentation', ''),
                               excluded: doc['Excluded'] == true, export_level: doc.fetch('ExportLevel', 'Hidden')
                             })
      end

      def database_connection_declaration(document)
        doc = document.fetch(:doc)
        semantic_call_source(:database_connection, document, {
                               database_type: doc.fetch('DatabaseType', ''),
                               connection_string: doc.fetch('ConnectionString', ''),
                               username: doc.fetch('UserName', ''), password: doc.fetch('Password', ''),
                               connection: database_connection_parts_spec(doc.fetch('ConnectionInput')),
                               properties: bson_items(doc['AdditionalProperties']).map { database_property_spec(_1) },
                               properties_marker: bson_marker(doc['AdditionalProperties'], 2),
                               queries: bson_items(doc['Queries']).map { database_query_spec(_1) },
                               queries_marker: bson_marker(doc['Queries'], 3),
                               documentation: doc.fetch('Documentation', ''), excluded: doc['Excluded'] == true,
                               export_level: doc.fetch('ExportLevel', 'Hidden')
                             })
      end

      def database_connection_parts_spec(parts)
        {
          id: document_id(parts), host: parts.fetch('Host', ''),
          port: parts.fetch('Port', 0), database: parts.fetch('DatabaseName', '')
        }
      end

      def database_property_spec(property)
        value = property.fetch('Value')
        {
          id: document_id(property), key: property.fetch('Key'),
          value_id: document_id(value), value: value.fetch('Value', '')
        }
      end

      def database_query_spec(query)
        {
          id: document_id(query), name: query.fetch('Name'),
          kind: { 1 => :select, 2 => :execute }.fetch(query.fetch('QueryType'), query.fetch('QueryType')),
          query: query.fetch('Query', ''),
          parameters: bson_items(query['Parameters']).map { database_parameter_spec(_1) },
          parameters_marker: bson_marker(query['Parameters'], 2),
          tables: bson_items(query['TableMappings']).map { database_table_spec(_1) },
          tables_marker: bson_marker(query['TableMappings'], 2)
        }
      end

      def database_parameter_spec(parameter)
        {
          id: document_id(parameter), name: parameter.fetch('ParameterName'),
          database_name: parameter.fetch('DatabaseParameterName', ''),
          type: data_type_spec(parameter['DataType']), type_id: document_id(parameter['DataType']),
          default: parameter.fetch('DefaultValue', ''),
          empty_as_null: parameter['EmptyValueBecomesNull'] == true,
          mode: underscore(parameter.fetch('Mode', 'Unknown')).to_sym,
          sql_type: database_sql_type_spec(parameter.fetch('SqlDataType')),
          table_mapping: parameter['TableMapping']
        }
      end

      def database_table_spec(table)
        {
          id: document_id(table), entity: table.fetch('Entity', ''),
          table: table.fetch('TableName', ''),
          columns: bson_items(table['Columns']).map { database_column_spec(_1) },
          columns_marker: bson_marker(table['Columns'], 2)
        }
      end

      def database_column_spec(column)
        {
          id: document_id(column), attribute: column.fetch('Attribute', ''),
          column: column.fetch('ColumnName', ''),
          sql_type: database_sql_type_spec(column.fetch('SqlDataType'))
        }
      end

      def database_sql_type_spec(sql_type)
        limited = sql_type['$Type'] == 'DatabaseConnector$LimitedLengthSqlDataType'
        spec = {
          id: document_id(sql_type), kind: limited ? :limited : :simple,
          name: sql_type.fetch('DataTypeName', '')
        }
        spec[:length] = sql_type.fetch('Length') if limited
        spec
      end

      def semantic_database_connection?(doc)
        return false unless doc['ConnectionInput'].is_a?(Hash)
        return false unless doc['ConnectionInput']['$Type'] == 'DatabaseConnector$ConnectionParts'

        properties = bson_items(doc['AdditionalProperties'])
        queries = bson_items(doc['Queries'])
        properties.all? do |property|
          property['$Type'] == 'DatabaseConnector$AdditionalProperty' &&
            property.dig('Value', '$Type') == 'DatabaseConnector$ValueAsString'
        end && queries.all? { database_query_semantic?(_1) }
      end

      def database_query_semantic?(query)
        return false unless query['$Type'] == 'DatabaseConnector$DatabaseQuery'

        parameters = bson_items(query['Parameters'])
        tables = bson_items(query['TableMappings'])
        parameters.all? do |parameter|
          parameter['$Type'] == 'DatabaseConnector$QueryParameter' &&
            semantic_sql_type?(parameter['SqlDataType'])
        end && tables.all? do |table|
          table['$Type'] == 'DatabaseConnector$TableMapping' &&
            bson_items(table['Columns']).all? do |column|
              column['$Type'] == 'DatabaseConnector$ColumnMapping' &&
                semantic_sql_type?(column['SqlDataType'])
            end
        end
      end

      def semantic_sql_type?(sql_type)
        %w[
          DatabaseConnector$SimpleSqlDataType DatabaseConnector$LimitedLengthSqlDataType
        ].include?(sql_type.to_h['$Type'])
      end

      def domain_call_lines(method, name, options, indent: 0)
        pad = ' ' * indent
        entries = options.to_a
        lines = ["#{pad}#{method} #{symbol(name)},"]
        entries.each_with_index do |(key, value), index|
          comma = index == entries.size - 1 ? '' : ','
          lines << "#{pad}            #{key}: #{native_ruby(value, indent + 12)}#{comma}"
        end
        lines
      end

      def semantic_enumeration?(doc)
        return false unless doc.key?('Values')

        bson_items(doc['Values']).all? do |value|
          caption = value['Caption']
          caption.is_a?(Hash) && bson_items(caption['Items']).all? do |translation|
            translation.is_a?(Hash) && translation['$Type'] == 'Texts$Translation' &&
              translation.key?('LanguageCode')
          end
        end
      end
    end
  end
end
