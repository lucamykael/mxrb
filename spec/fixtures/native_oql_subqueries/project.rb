# frozen_string_literal: true

require 'mxrb'
require 'json'

# Headless native oracle for OQL subqueries, UNION and views over views: Views.RunAll
# seeds rows.json, retrieves every view and logs "ORACLE <case>=<rows>" where each row
# joins its attributes with '|'. Run with script/oql_native_oracle.
cases = JSON.parse(File.read(ENV.fetch('MXRB_ORACLE_CASES', File.join(__dir__, 'cases.json'))))
rows = JSON.parse(File.read(File.join(__dir__, 'rows.json')))
literal = lambda do |name, value|
  if value.nil? then 'empty'
  elsif name == 'Amount' || value.is_a?(Integer) then value.to_s
  else "'#{value.gsub("'", "''")}'"
  end
end
text = ->(value, type) { type == 'string' ? value : "toString(#{value})" }
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    entity :Location do
      string :Name
      string :Region
      decimal :Amount
      integer :Rank
    end
    entity :Visit do
      string :Place
      integer :Total
    end
    entity :ViewBase do
      string :Name
      string :Region
      integer :Rank
      oql_view query: 'SELECT l.Name AS Name, l.Region AS Region, l.Rank AS Rank FROM Views.Location AS l ' \
                      'WHERE l.Amount IS NOT NULL'
    end
    entity :ViewChainedBase do
      string :Name
      oql_view query: "SELECT b.Name AS Name FROM Views.ViewBase AS b WHERE b.Name LIKE 'N%'"
    end
    cases.each do |item|
      entity "View#{item.fetch('name')}" do
        string :Name
        item.fetch('attributes', {}).each { |name, type| public_send(type, name) }
        oql_view query: item.fetch('query')
      end
    end
    microflow :Seed do
      rows.each do |entity, records|
        records.each_with_index do |row, index|
          create_object "Views.#{entity}", as: "#{entity.downcase}#{index}", commit: true,
                                           set: row.to_h { |key, value| [key, literal.call(key, value)] }
        end
      end
    end
    cases.each do |item|
      name = item.fetch('name')
      columns = { 'Name' => 'string' }.merge(item.fetch('attributes', {}))
      microflow "Case#{name}" do
        retrieve_objects "Views.View#{name}", as: :items
        create_variable :rows, type: :String, value: "''"
        loop_over :items, as: :item do
          parts = columns.map do |column, type|
            "(if $item/#{column} = empty then '<null>' else #{text.call("$item/#{column}", type)})"
          end
          change_variable :rows, to: "$rows + #{parts.join(" + '|' + ")} + ';'"
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
      title 'OQL subquery oracle'
      button('Run', caption: 'Run') { on_click microflow: 'Views.RunAll' }
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
