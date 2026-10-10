# frozen_string_literal: true

require 'mxrb'
require 'json'

# Headless native oracle: Views.RunAll seeds the rows below, retrieves every view and
# logs "ORACLE <case>=<names>". script/oql_native_oracle runs it on MxBuild/Runtime.
cases = JSON.parse(File.read(ENV.fetch('MXRB_ORACLE_CASES', File.join(__dir__, 'cases.json'))))
rows = JSON.parse(File.read(File.join(__dir__, 'rows.json')))
decimals = %w[Amount Other]
literal = lambda do |key, value|
  if value.nil? then 'empty'
  elsif value.is_a?(String) && !decimals.include?(key) then "'#{value.gsub("'", "''")}'"
  else value.to_s
  end
end
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    entity :Location do
      string :Name
      string :Nick
      decimal :Amount
      decimal :Other
      boolean :Active
      integer :Rank
    end
    cases.each do |item|
      query = item['query'] || "SELECT l.Name AS Name FROM Views.Location AS l WHERE #{item.fetch('where')}"
      entity "View#{item.fetch('name')}" do
        string :Name
        oql_view query: query
      end
    end
    microflow :Seed do
      rows.each_with_index do |row, index|
        create_object 'Views.Location', as: "row#{index}", commit: true,
                                        set: row.to_h { |key, value| [key, literal.call(key, value)] }
      end
    end
    cases.each do |item|
      name = item.fetch('name')
      microflow "Case#{name}" do
        retrieve_objects "Views.View#{name}", as: :items, sort: [["Views.View#{name}.Name", 'Ascending']]
        create_variable :names, type: :String, value: "''"
        loop_over :items, as: :item do
          change_variable :names, to: "$names + (if $item/Name = empty then '<null>' else $item/Name) + ','"
        end
        log_message "ORACLE #{name}={1}", node: "'ORACLE'", parameters: ['$names']
      end
    end
    microflow :RunAll do
      return_type :Boolean
      call_microflow 'Views.Seed'
      cases.each { |item| call_microflow "Views.Case#{item.fetch('name')}" }
      return_value 'true'
    end
    page :Home do
      title 'OQL predicate oracle'
      button('Run', caption: 'Run') { on_click microflow: 'Views.RunAll' }
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
