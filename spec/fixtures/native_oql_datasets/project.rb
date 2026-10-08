# frozen_string_literal: true

require 'mxrb'
require 'json'
require 'fileutils'

cases = JSON.parse(File.read(File.join(__dir__, 'cases.json')))
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Hr do
    entity(:Probe) { string :Name }
    entity(:Department) { string :Name }
    entity :Employee do
      string :Name
      string :DepartmentName
      decimal :Salary
      datetime :DateOfBirth
      association 'Hr.Department', name: :Employee_Department, cardinality: :many_to_one
    end
    entity :Result do
      non_persistent!
      string :Name
      datetime :MinDateOfBirth
      datetime :MaxDateOfBirth
      decimal :TotalSalary
      decimal :AvgSalary
      decimal :MinSalary
      integer :RowsCount
    end
    %w[RetrieveDatasetOql RetrieveAdvancedOql].each do |name|
      pointer = SecureRandom.uuid
      argument = name == 'RetrieveDatasetOql' ? 'DataSetName' : 'OqlQuery'
      java_action name, type_parameters: [{ name: 'ResultEntityType', id: pointer }],
                        parameters: [
                          { name: argument, type: { kind: :basic, type: { kind: :string } } },
                          { name: 'ResultEntity', type: { kind: :entity_type_parameter, pointer: } }
                        ],
                        return_type: { kind: :list, parameter: { kind: :parameterized_entity, pointer: } }
    end
    cases.each do |item|
      dataset(item.fetch('name')) { oql item.fetch('query') }
      %w[Dataset Text].each do |mode|
        microflow "#{item.fetch('name')}#{mode}" do
          action = mode == 'Dataset' ? 'RetrieveDatasetOql' : 'RetrieveAdvancedOql'
          argument = mode == 'Dataset' ? 'DataSetName' : 'OqlQuery'
          value = mode == 'Dataset' ? "Hr.#{item.fetch('name')}" : item.fetch('query')
          call_java "Hr.#{action}", as: :items do
            argument "Hr.#{action}.#{argument}", "'#{value.gsub("'", "''")}'"
            entity_type_argument "Hr.#{action}.ResultEntity", 'Hr.Result'
          end
          create_variable :rows, type: :String, value: "''"
          loop_over :items, as: :item do
            columns = item.fetch('attributes').map do |name, type|
              value = "$item/#{name}"
              text = case type
                     when 'datetime' then "formatDateTimeUTC(#{value}, 'yyyy-MM-dd')"
                     when 'string' then value
                     else "toString(#{value})"
                     end
              "(if #{value} = empty then '<null>' else #{text})"
            end
            change_variable :rows, to: "$rows + #{columns.join(" + '|' + ")} + ';'"
          end
          show_message 'Rows:{1}', parameters: ['$rows'], blocking: true
        end
      end
    end
    microflow :Load do
      create_object 'Hr.Probe', as: :probe, set: { Name: "'OQL dataset oracle'" }
      return_type 'Hr.Probe'
      return_value '$probe'
    end
    microflow :Seed do
      retrieve_objects 'Hr.Employee', as: :employees
      delete :employees
      retrieve_objects 'Hr.Department', as: :departments
      delete :departments
      %w[North South Empty North Huge].each_with_index do |name, index|
        create_object 'Hr.Department', as: "dept#{index}", commit: true, set: { Name: "'#{name}'" }
      end
      create_object 'Hr.Department', as: :dept5, commit: true, set: { Name: 'empty' }
      [
        ['A', 'North', '10.125', 2000, 0], ['B', 'North', '20.375', 2001, 0],
        ['C', 'South', 'empty', nil, 1], ['D', 'Missing', '7.5', 1999, nil],
        ['E', 'North', '5.5', 2002, 3], ['F', 'Huge', '9007199254740993.125', 2003, 4],
        ['G', nil, '-2', 2004, 5], ['H', nil, 'empty', nil, nil]
      ].each_with_index do |(name, department, salary, year, reference), index|
        create_object 'Hr.Employee', as: "employee#{index}", commit: true do
          set :Name, to: "'#{name}'"
          set :DepartmentName, to: department ? "'#{department}'" : 'empty'
          set :Salary, to: salary
          set :DateOfBirth, to: year ? "dateTimeUTC(#{year}, 1, 1)" : 'empty'
          set_association 'Hr.Employee_Department', to: reference ? "$dept#{reference}" : 'empty'
        end
      end
      show_message 'Seeded', blocking: true
    end
    page :Home do
      title 'OQL dataset oracle'
      data_source microflow: 'Hr.Load'
      text_box :Name, attribute: 'Hr.Probe.Name', caption: 'Name'
      (['Seed'] + cases.flat_map { |item| %w[Dataset Text].map { "#{item.fetch('name')}#{_1}" } }).each do |flow|
        button(flow, caption: flow) { on_click microflow: "Hr.#{flow}" }
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Hr.Home' }
end
# rubocop:enable Metrics/BlockLength

if (source = ENV['MXRB_OQL_JAVA_SOURCE'])
  target = File.join(File.dirname(ENV.fetch('MXRB_OUTPUT_PATH')), 'javasource', 'hr', 'actions')
  FileUtils.mkdir_p(target)
  %w[RetrieveDatasetOql RetrieveAdvancedOql].each do |name|
    FileUtils.cp(File.join(source, "#{name}.java"), target)
  end
end
