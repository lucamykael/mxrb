# frozen_string_literal: true

require 'mxrb'
require 'json'

cases = JSON.parse(File.read(File.join(__dir__, 'cases.json')))
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Probe) { string :Name }
    entity(:Department) { string :Name }
    entity :Employee do
      string :Name
      string :DepartmentName
      decimal :Salary
      datetime :DateOfBirth
      association 'Views.Department', name: :Employee_Department, cardinality: :many_to_one
    end
    cases.each do |item|
      entity "View#{item.fetch('name')}" do
        item.fetch('attributes').each { |name, type| public_send(type, name) }
        if item['reference']
          reference = item.fetch('reference')
          association reference.fetch('entity'), name: reference.fetch('name'), cardinality: :many_to_one
        end
        oql_view query: item.fetch('query')
      end
      microflow item.fetch('name') do
        retrieve_objects "Views.View#{item.fetch('name')}", as: :items
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
          if item['reference']
            reference = item.fetch('reference')
            retrieve_association :item, association: "Views.#{reference.fetch('name')}", as: :linked
            columns << "(if $linked = empty then '<null>' else $linked/#{reference.fetch('attribute')})"
          end
          change_variable :rows, to: "$rows + #{columns.join(" + '|' + ")} + ';'"
        end
        show_message 'Rows:{1}', parameters: ['$rows'], blocking: true
      end
    end
    microflow :Load do
      create_object 'Views.Probe', as: :probe, set: { Name: "'OQL relational oracle'" }
      return_type 'Views.Probe'
      return_value '$probe'
    end
    microflow :Seed do
      %w[North South Empty North Huge].each_with_index do |name, index|
        create_object 'Views.Department', as: "dept#{index}", commit: true, set: { Name: "'#{name}'" }
      end
      create_object 'Views.Department', as: :dept5, commit: true, set: { Name: 'empty' }
      [
        ['A', 'North', '10.125', 2000, 0], ['B', 'North', '20.375', 2001, 0],
        ['C', 'South', 'empty', nil, 1], ['D', 'Missing', '7.5', 1999, nil],
        ['E', 'North', '5.5', 2002, 3], ['F', 'Huge', '9007199254740993.125', 2003, 4],
        ['G', nil, '-2', 2004, 5], ['H', nil, 'empty', nil, nil]
      ].each_with_index do |(name, department, salary, year, reference), index|
        create_object 'Views.Employee', as: "employee#{index}", commit: true do
          set :Name, to: "'#{name}'"
          set :DepartmentName, to: department ? "'#{department}'" : 'empty'
          set :Salary, to: salary
          set :DateOfBirth, to: year ? "dateTimeUTC(#{year}, 1, 1)" : 'empty'
          set_association 'Views.Employee_Department', to: reference ? "$dept#{reference}" : 'empty'
        end
      end
      show_message 'Seeded', blocking: true
    end
    page :Home do
      title 'OQL relational oracle'
      data_source microflow: 'Views.Load'
      text_box :Name, attribute: 'Views.Probe.Name', caption: 'Name'
      (['Seed'] + cases.map { _1.fetch('name') }).each do |flow|
        button(flow, caption: flow) { on_click microflow: "Views.#{flow}" }
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
