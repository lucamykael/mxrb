# frozen_string_literal: true

require 'mxrb'
require 'json'
require 'fileutils'
require 'securerandom'

# Native oracle for parameterized datasets and OQL text run through the Marketplace
# OQL module. Views.RunAll seeds the data, runs every case through OQL.Add*Parameter
# and OQL.ExecuteOQLStatement or OQL.CountRowsOQLStatement and logs
# "ORACLE <case>=<rows>". The module's Java sources are copied from
# MXRB_OQL_MODULE_SOURCE (a project's javasource/oql); they are not distributed here.
cases = JSON.parse(File.read(File.join(__dir__, 'cases.json')))
ADDERS = { 'string' => %w[AddStringParameter string], 'integer' => %w[AddIntegerLongValue integer],
           'decimal' => %w[AddDecimalParameter decimal], 'boolean' => %w[AddBooleanParameter boolean],
           'datetime' => %w[AddDateTimeParameter datetime] }.freeze
basic = ->(kind) { { kind: :basic, type: { kind: } } }
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :OQL do
    ADDERS.each_value do |action, kind|
      java_action action, parameters: [{ name: 'name', type: basic.call(:string) },
                                       { name: 'value', type: basic.call(kind.to_sym) }],
                          return_type: { kind: :boolean }
    end
    object = SecureRandom.uuid
    java_action 'AddObjectParameter', type_parameters: [{ name: 'TypeParameter', id: object }],
                                      parameters: [{ name: 'name', type: basic.call(:string) },
                                                   { name: 'value', type: { kind: :basic,
                                                                            type: { kind: :parameterized_entity,
                                                                                    pointer: object } } }],
                                      return_type: { kind: :boolean }
    result = SecureRandom.uuid
    java_action 'ExecuteOQLStatement', type_parameters: [{ name: 'ReturnEntity', id: result }],
                                       parameters: [
                                         { name: 'statement', type: basic.call(:string) },
                                         { name: 'returnEntity',
                                           type: { kind: :entity_type_parameter, pointer: result } },
                                         { name: 'amount', type: basic.call(:integer) },
                                         { name: 'offset', type: basic.call(:integer) },
                                         { name: 'preserveParameters', type: basic.call(:boolean) }
                                       ],
                                       return_type: { kind: :list, parameter: { kind: :parameterized_entity,
                                                                                pointer: result } }
    java_action 'CountRowsOQLStatement', parameters: [{ name: 'statement', type: basic.call(:string) },
                                                      { name: 'amount', type: basic.call(:integer) },
                                                      { name: 'offset', type: basic.call(:integer) }],
                                         return_type: { kind: :integer }
  end
  self.module :Views do
    enumeration(:Status) { %w[Draft Active Retired].each { value _1, caption: _1 } }
    entity(:Building) { string :Name }
    entity(:Area) { string :Name }
    entity :Asset do
      string :Name
      association 'Views.Area', name: :Asset_Area, cardinality: :many_to_one
    end
    entity :Program do
      string :Name
      enum :Status, enumeration: 'Views.Status'
      integer :Rank
      decimal :Amount
      datetime :Due
      boolean :Flag
      association 'Views.Building', name: :Program_Building, cardinality: :many_to_one
      association 'Views.Asset', name: :Program_Asset, cardinality: :many_to_one
    end
    entity :Result do
      non_persistent!
      string :Name
      string :AreaName
      integer :Rank
      decimal :Amount
      association 'Views.Building', name: :Result_Building, cardinality: :many_to_one
    end
    dataset :ByBuilding do
      parameter :BuildingID, object_of('Views.Building')
      parameter :Status, enum_of('Views.Status')
      oql 'SELECT p.Name AS Name, ar.Name AS AreaName, p.Rank AS Rank, p.Amount AS Amount, ' \
          'b.ID AS Result_Building FROM Views.Program AS p ' \
          'LEFT JOIN p/Views.Program_Asset/Views.Asset/Views.Asset_Area/Views.Area AS ar ' \
          'LEFT JOIN p/Views.Program_Building/Views.Building AS b ' \
          'WHERE b/ID = $BuildingID AND p/Status = $Status'
    end
    dataset :Typed do
      parameter :MinRank, integer
      parameter :MinAmount, decimal
      parameter :After, datetime
      parameter :Prefix, string
      oql 'SELECT p.Name AS Name, p.Rank AS Rank, p.Amount AS Amount FROM Views.Program AS p ' \
          'WHERE p.Rank >= $MinRank AND p.Amount > $MinAmount AND p.Due > $After AND p.Name LIKE $Prefix'
    end
    microflow :Seed do
      %w[North South].each { create_object 'Views.Building', as: _1.downcase, commit: true, set: { Name: "'#{_1}'" } }
      create_object 'Views.Area', as: :hall, commit: true, set: { Name: "'Hall'" }
      create_object 'Views.Asset', as: :press, commit: true do
        set :Name, to: "'Press'"
        set_association 'Views.Asset_Area', to: '$hall'
      end
      create_object 'Views.Asset', as: :loose, commit: true, set: { Name: "'Loose'" }
      [
        ['Alpha', 'Active', 1, '2.5', 2024, true, 'north', 'press'],
        ['Beta', 'Active', 2, '1', 2025, false, 'north', 'loose'],
        ['gamma', 'Draft', 3, '7.25', 2023, true, 'north', nil],
        ['nova', 'Active', 3, '9', 2025, true, 'south', 'press'],
        ['Delta', 'Retired', 1, nil, nil, false, nil, nil]
      ].each_with_index do |(name, status, rank, amount, year, flag, building, asset), index|
        create_object 'Views.Program', as: "program#{index}", commit: true do
          set :Name, to: "'#{name}'"
          set :Status, to: "Views.Status.#{status}"
          set :Rank, to: rank.to_s
          set :Amount, to: amount || 'empty'
          set :Due, to: year ? "dateTimeUTC(#{year}, 6, 1)" : 'empty'
          set :Flag, to: flag.to_s
          set_association 'Views.Program_Building', to: building ? "$#{building}" : 'empty'
          set_association 'Views.Program_Asset', to: asset ? "$#{asset}" : 'empty'
        end
      end
    end
    cases.each do |item|
      name = item.fetch('name')
      microflow "Case#{name}" do
        retrieve_objects 'Views.Building', as: :north, single: true, xpath: "[Name = 'North']"
        item.fetch('parameters').each do |kind, parameter, value|
          action = kind == 'object' ? 'AddObjectParameter' : ADDERS.fetch(kind).first
          call_java "OQL.#{action}" do
            argument "OQL.#{action}.name", "'#{parameter}'"
            argument "OQL.#{action}.value", value
          end
        end
        literal = "'#{item.fetch('statement').gsub("'", "''")}'"
        if item['count']
          call_java 'OQL.CountRowsOQLStatement', as: :total do
            argument 'OQL.CountRowsOQLStatement.statement', literal
            argument 'OQL.CountRowsOQLStatement.amount', item.fetch('amount', 0).to_s
            argument 'OQL.CountRowsOQLStatement.offset', '0'
          end
          log_message "ORACLE #{name}={1}", node: "'ORACLE'", parameters: ['toString($total)']
          next
        end
        create_variable :rows, type: :String, value: "''"
        (item['repeat'] ? %i[first second] : %i[first]).each do |round|
          call_java 'OQL.ExecuteOQLStatement', as: round do
            argument 'OQL.ExecuteOQLStatement.statement', literal
            entity_type_argument 'OQL.ExecuteOQLStatement.returnEntity', 'Views.Result'
            argument 'OQL.ExecuteOQLStatement.amount', item.fetch('amount', 0).to_s
            argument 'OQL.ExecuteOQLStatement.offset', item.fetch('offset', 0).to_s
            argument 'OQL.ExecuteOQLStatement.preserveParameters', (item['preserve'] == true).to_s
          end
          loop_over round, as: "#{round}_item" do
            retrieve_association "#{round}_item", association: 'Views.Result_Building', as: "#{round}_linked"
            row = "$#{round}_item"
            parts = %w[Name AreaName].map { "(if #{row}/#{_1} = empty then '<null>' else #{row}/#{_1})" } +
                    %w[Rank Amount].map { "(if #{row}/#{_1} = empty then '<null>' else toString(#{row}/#{_1}))" } +
                    ["(if $#{round}_linked = empty then '<null>' else $#{round}_linked/Name)"]
            change_variable :rows, to: "$rows + #{parts.join(" + '|' + ")} + ';'"
          end
          change_variable :rows, to: "$rows + '#'"
        end
        log_message "ORACLE #{name}={1}", node: "'ORACLE'", parameters: ['$rows']
      end
    end
    microflow :RunAll do
      return_type :Boolean
      call_microflow 'Views.Seed'
      cases.each { |item| call_microflow "Views.Case#{item.fetch('name')}" }
      return_value 'true'
    end
    page :Home do
      title 'OQL parameter oracle'
      button('Run', caption: 'Run') { on_click microflow: 'Views.RunAll' }
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength

if (source = ENV['MXRB_OQL_MODULE_SOURCE'])
  root = File.join(File.dirname(ENV.fetch('MXRB_OUTPUT_PATH')), 'javasource', 'oql')
  %w[actions implementation].each { FileUtils.mkdir_p(File.join(root, _1)) }
  (ADDERS.values.map(&:first) + %w[AddObjectParameter ExecuteOQLStatement CountRowsOQLStatement]).each do |name|
    FileUtils.cp(File.join(source, 'actions', "#{name}.java"), File.join(root, 'actions'))
  end
  FileUtils.cp(File.join(source, 'implementation', 'OQL.java'), File.join(root, 'implementation'))
end
