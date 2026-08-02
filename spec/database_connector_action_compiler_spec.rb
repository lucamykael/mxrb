# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::Compiler::DatabaseConnectorActionCompiler do
  let(:query) do
    {
      '$ID' => '10000000-0000-4000-8000-000000000001', 'Name' => 'Users',
      'Query' => '', 'QueryType' => 2, 'Parameters' => [2],
      'TableMappings' => [2, {
        'TableName' => 'public.users', 'Entity' => 'Demo.User',
        'Columns' => [2, { 'ColumnName' => 'name', 'Attribute' => 'Demo.User.Name' }]
      }]
    }
  end
  let(:connection) do
    {
      '$Type' => 'DatabaseConnector$DatabaseConnection', 'Name' => 'DB',
      'UserName' => 'Demo.User', 'Password' => 'Demo.Password',
      'ConnectionString' => 'Demo.Source', 'DatabaseType' => 'PostgreSQL',
      'AdditionalProperties' => [2], 'Queries' => [2, query]
    }
  end
  let(:unit) do
    Mxrb::Compiler::SourceModel::Unit.new(
      id: 'connection', container_id: 'module', containment: 'Documents',
      document: connection, module_name: 'Demo'
    )
  end
  let(:source) { instance_double(Mxrb::Compiler::SourceModel, units: [unit]) }
  let(:compiler) { described_class.new(source) }
  let(:action) do
    {
      '$ID' => '20000000-0000-4000-8000-000000000002',
      'Query' => 'Demo.DB.Users', 'OutputVariableName' => 'Users',
      'ErrorHandlingType' => 'Rollback', 'ConnectionParameterMappings' => [2],
      'ParameterMappings' => [2]
    }
  end

  it 'lowers query-builder selects to deterministic External Database Connector calls' do
    result = compiler.compile(action)

    expect(result).to include(
      '$Type' => 'Microflows$JavaActionCallAction',
      'JavaAction' => 'ExternalDatabaseConnector.ExecuteQuery',
      'ResultVariableName' => 'Users'
    )
    values = result['ParameterMappings'].to_h { [_1['Parameter'].split('.').last, _1.dig('Value', 'ValueExpression')] }
    expect(values.fetch('sql')).to include('SELECT name FROM public.users')
    expect(values.fetch('connectionDetails')).to include('PostgreSQL', '@Demo.User')
    expect(values.fetch('columnMapping')).to include('Demo.User', 'Name')
    expect(result['ParameterMappings'].last.dig('Value', '$Type'))
      .to eq('Microflows$EntityTypeCodeActionParameterValue')
  end

  it 'supports dynamic callable statements, parameters, overrides, and additional properties' do
    query['Query'] = 'call do_work(?)'
    query['QueryType'] = 3
    query['TableMappings'] = [2]
    query['Parameters'] = [2,
                           { 'ParameterName' => 'When', 'DataType' => { '$Type' => 'DataTypes$DateTimeType' },
                             'SqlDataType' => { 'DataTypeName' => 'timestamp' }, 'Mode' => 'In' },
                           { 'ParameterName' => 'Flag', 'DataType' => { '$Type' => 'DataTypes$BooleanType' },
                             'SqlDataType' => { 'DataTypeName' => 'boolean' }, 'Mode' => 'In' }]
    connection['AdditionalProperties'] = [2,
                                          { 'Key' => 'schema', 'Value' => {
                                            '$Type' => 'DatabaseConnector$ValueAsConstant',
                                            'Value' => 'Demo.Schema'
                                          } }]
    action['DynamicQuery'] = '$DynamicSql'
    action['ConnectionParameterMappings'] = [2, { 'ParameterName' => 'DBUsername', 'Value' => '$User' },
                                             { 'ParameterName' => 'schema', 'Value' => '$Schema' }]
    action['ParameterMappings'] = [2, { 'ParameterName' => 'When', 'Value' => '$When' },
                                   { 'ParameterName' => 'Flag', 'Value' => '$Flag' }]

    result = compiler.compile(action)
    expect(result['JavaAction']).to eq('ExternalDatabaseConnector.ExecuteCallable')
    expressions = result['ParameterMappings'].map { _1.dig('Value', 'ValueExpression') }.join
    expect(expressions).to include('$DynamicSql', '$User', '$Schema', 'dateTimeToEpoch', 'toString($Flag)')
  end

  it 'fails closed for missing models, unsafe identifiers, and unsupported parameter types' do
    expect { compiler.compile(action.merge('Query' => 'Demo.DB.Missing')) }
      .to raise_error(Mxrb::CompilationError, /query.*not found/)
    expect { described_class.new(instance_double(Mxrb::Compiler::SourceModel, units: [])).compile(action) }
      .to raise_error(Mxrb::CompilationError, /connection.*not found/)

    query['TableMappings'][1]['TableName'] = 'users; DROP TABLE users'
    expect { compiler.compile(action) }.to raise_error(Mxrb::CompilationError, /unsafe database identifier/)

    query['Query'] = 'select ?'
    query['TableMappings'] = [2]
    query['Parameters'] = [2, { 'ParameterName' => 'Value', 'DataType' => { '$Type' => 'DataTypes$ObjectType' },
                                'SqlDataType' => {}, 'Mode' => 'In' }]
    action['ParameterMappings'] = [2, { 'ParameterName' => 'Value', 'Value' => '$Value' }]
    expect { compiler.compile(action) }.to raise_error(Mxrb::CompilationError, /unsupported database parameter type/)
  end

  it 'selects every audited statement/callable variant and parameter representation' do
    expect(compiler.send(:java_action_for, 'Query' => 'SELECT 1', 'TableMappings' => [2]))
      .to eq('ExternalDatabaseConnector.ExecuteStatement')
    expect(compiler.send(:java_action_for, 'Query' => 'WITH x AS (SELECT 1) SELECT * FROM x',
                                           'TableMappings' => [2, {}]))
      .to eq('ExternalDatabaseConnector.ExecuteQuery')
    expect(compiler.send(:java_action_for, 'Query' => 'UPDATE users SET name = name',
                                           'TableMappings' => [2]))
      .to eq('ExternalDatabaseConnector.ExecuteStatement')
    expect(compiler.send(:java_action_for, 'Query' => 'call work()', 'QueryType' => 0,
                                           'TableMappings' => [2]))
      .to eq('ExternalDatabaseConnector.ExecuteCallableStatement')
    expect(compiler.send(:java_action_for, 'Query' => 'execute work()', 'QueryType' => 0,
                                           'TableMappings' => [2, {}]))
      .to eq('ExternalDatabaseConnector.ExecuteCallableQuery')
    expect(compiler.send(:result_mappings, query, 'ExternalDatabaseConnector.ExecuteStatement')).to eq([])

    expect(compiler.send(:parameter_value, 'STRING', '$Value')).to include('urlEncode')
    expect(compiler.send(:parameter_value, 'INTEGER', '$Value')).to include('$Value')
    expect(compiler.send(:parameter_value, 'DECIMAL', '$Value')).to include('$Value')
  end

  it 'covers empty connection/property values and incomplete query-builder mappings' do
    connection['UserName'] = ''
    connection['AdditionalProperties'] = [2,
                                          { 'Key' => 'constant', 'Value' => {
                                            '$Type' => 'DatabaseConnector$ValueAsConstant', 'Value' => 'Demo.Value'
                                          } },
                                          { 'Key' => 'literal', 'Value' => {
                                            '$Type' => 'DatabaseConnector$ValueAsString', 'Value' => 'plain'
                                          } }]
    rendered = compiler.send(:connection_json, action, connection)
    expect(rendered).to include("'+('')+'", '@Demo.Value', 'plain')

    query['TableMappings'] = [2]
    expect { compiler.send(:query_builder_select, query) }
      .to raise_error(Mxrb::CompilationError, /no executable table/)
  end
end
# rubocop:enable Metrics/BlockLength
