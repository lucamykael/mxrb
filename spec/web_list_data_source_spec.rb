# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe Mxrb::Compiler::WebListDataSource do
  def unit(module_name:, document:)
    Struct.new(:module_name, :document, keyword_init: true).new(module_name:, document:)
  end

  def widget
    {
      '$Type' => 'CustomWidgets$CustomWidget', 'Name' => 'gallery',
      'DataSource' => { '$Type' => 'Forms$MicroflowSource',
                        'MicroflowSettings' => { 'Microflow' => 'Demo.LoadItems' } }
    }
  end

  def units(query: 'SELECT name FROM items;', connection_default: '')
    action = { '$Type' => 'DatabaseConnector$ExecuteDatabaseQueryAction',
               'Query' => 'Demo.Database.SelectItems' }
    flow = unit(module_name: 'Demo', document: {
      '$Type' => 'Microflows$Microflow', 'Name' => 'LoadItems',
      'MicroflowReturnType' => { '$Type' => 'DataTypes$ListType', 'Entity' => 'Demo.Item' },
      'ObjectCollection' => { 'Objects' => [2, action] }
    })
    connection = unit(module_name: 'Demo', document: {
      '$Type' => 'DatabaseConnector$DatabaseConnection', 'Name' => 'Database',
      'ConnectionString' => 'Demo.Source', 'UserName' => 'Demo.User', 'Password' => 'Demo.Password',
      'Queries' => [2, { 'Name' => 'SelectItems', 'Query' => query,
                         'TableMappings' => [2, { 'Entity' => 'Demo.Item' }] }]
    })
    constants = %w[Source User Password].map do |name|
      unit(module_name: 'Demo', document: {
        '$Type' => 'Constants$Constant', 'Name' => name, 'DefaultValue' => connection_default
      })
    end
    [flow, connection, *constants]
  end

  def source(items)
    instance_double(Mxrb::Compiler::SourceModel, units: items).tap do |model|
      allow(model).to receive(:units_of) do |type|
        items.select { _1.document['$Type'] == type }
      end
    end
  end

  it 'lowers only a simple same-entity query whose connector has no configuration' do
    resolver = described_class.new(source(units), widget)
    expect(resolver).to be_supported
    expect(resolver).to be_xpath
    expect(resolver.entity).to eq('Demo.Item')

    configured = described_class.new(source(units(connection_default: 'configured')), widget)
    expect(configured).not_to be_xpath
    expect(configured).to be_microflow

    complex = described_class.new(source(units(query: 'SELECT name FROM items WHERE active = true;')), widget)
    expect(complex).not_to be_xpath
  end

  it 'resolves a nanoflow list independently from Runtime microflow operations' do
    flow = unit(module_name: 'Demo', document: {
      '$Type' => 'Microflows$Nanoflow', 'Name' => 'LoadItems',
      'MicroflowReturnType' => { '$Type' => 'DataTypes$ListType', 'Entity' => 'Demo.Item' }
    })
    nano_widget = widget
    nano_widget['DataSource'] = {
      '$Type' => 'Forms$NanoflowSource', 'Nanoflow' => 'Demo.LoadItems', 'ParameterMappings' => [2]
    }
    resolver = described_class.new(source([flow]), nano_widget)

    expect(resolver).to be_supported
    expect(resolver).to be_nanoflow
    expect(resolver).not_to be_microflow
    expect(resolver.entity).to eq('Demo.Item')
    expect(resolver.nanoflow_name).to eq('Demo.LoadItems')
  end

  it 'fails closed for missing sources, connections, constants, and mappings' do
    empty = described_class.new(source([]), {})
    expect(empty).not_to be_supported
    expect(empty.send(:flow_name, nil, 'Microflow')).to eq('')
    expect(empty.send(:connector_query, 'Demo.Missing.Query')).to eq([nil, nil])

    malformed = units
    malformed.reject! { _1.document['$Type'] == 'Constants$Constant' }
    resolver = described_class.new(source(malformed), widget)
    expect(resolver).to be_microflow
    expect(resolver).not_to be_xpath
    connection = malformed.find { _1.document['$Type'] == 'DatabaseConnector$DatabaseConnection' }
    expect(resolver.send(:connection_unconfigured?, connection.document.merge('Password' => ''))).to be(false)

    action = malformed.first.document.dig('ObjectCollection', 'Objects').find { _1.is_a?(Hash) }
    connection.document['Queries'].last['TableMappings'] = [2]
    expect(resolver.send(:simple_unconfigured_query?, action)).to be(false)
  end

  it 'covers the flat microflow-name fallback and an empty connection field' do
    resolver = described_class.new(source(units), widget)
    expect(resolver.send(:flow_name, { 'Microflow' => 'Demo.Flat' }, 'Microflow')).to eq('Demo.Flat')

    connection = units.find { _1.document['$Type'] == 'DatabaseConnector$DatabaseConnection' }
    expect(resolver.send(:connection_unconfigured?, connection.document.merge('ConnectionString' => '')))
      .to be(false)
  end

  it 'resolves direct database and association sources, including entity fallbacks' do
    database = {
      '$Type' => 'Forms$DatabaseSource',
      'EntityRef' => { 'Entity' => 'Demo.Direct' },
      'XPathConstraint' => '[Active = true]'
    }
    direct = described_class.new(source([]), 'DataSource' => database)
    expect(direct).to be_xpath
    expect(direct.entity).to eq('Demo.Direct')
    expect(direct.xpath_constraint).to eq('[Active = true]')

    association = {
      '$Type' => 'Forms$AssociationSource',
      'EntityRef' => {
        'Steps' => [2, { 'Association' => 'Demo.Parent_Items',
                         'DestinationEntity' => 'Demo.Item' }]
      }
    }
    associated = described_class.new(source([]), 'DataSource' => association)
    expect(associated).to be_association
    expect(associated.association_path).to eq('Demo.Parent_Items/Demo.Item')
    expect(associated.entity).to eq('Demo.Item')
  end

  it 'walks nested source arrays and rejects ambiguous connector actions and non-hashes' do
    nested_widget = {
      'Children' => [
        2,
        { '$Type' => 'CustomWidgets$CustomWidgetXPathSource',
          'EntityRef' => { 'Entity' => 'Demo.Nested' } }
      ]
    }
    nested = described_class.new(source([]), nested_widget)
    expect(nested).to be_xpath
    expect(nested.entity).to eq('Demo.Nested')

    empty = described_class.new(source([]), nil)
    expect(empty).not_to be_supported
    expect(empty.send(:nested, 'scalar', 'Anything')).to eq([])

    action = { '$Type' => 'DatabaseConnector$ExecuteDatabaseQueryAction' }
    flow = unit(module_name: 'Demo', document: {
      '$Type' => 'Microflows$Microflow', 'Name' => 'LoadItems',
      'MicroflowReturnType' => { 'Entity' => 'Demo.Item' },
      'Actions' => [action, action]
    })
    ambiguous = described_class.new(source([flow]), widget)
    expect(ambiguous).to be_microflow
    expect(ambiguous).not_to be_xpath
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
