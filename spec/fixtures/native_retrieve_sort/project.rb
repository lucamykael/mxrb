# frozen_string_literal: true

require 'mxrb'
require 'json'

cases = JSON.parse(File.read(File.join(__dir__, 'cases.json')))
rows = JSON.parse(File.read(File.join(__dir__, 'rows.json')))
decimals = %w[Amount Other]
literal = lambda do |key, value|
  if value.nil? then 'empty'
  elsif value.is_a?(String) && !decimals.include?(key) then "'#{value.gsub("'", "''")}'"
  else value.to_s
  end
end
# Headless native oracle for retrieve sorting; run with script/oql_native_oracle.
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
    microflow :Seed do
      rows.each_with_index do |row, index|
        create_object 'Views.Location', as: "row#{index}", commit: true,
                                        set: row.to_h { |key, value| [key, literal.call(key, value)] }
      end
    end
    cases.each do |item|
      name = item.fetch('name')
      microflow "Case#{name}" do
        retrieve_objects 'Views.Location', as: :items,
                                           sort: item.fetch('sort').map { |attr, dir| ["Views.Location.#{attr}", dir] }
        create_variable :names, type: :String, value: "''"
        loop_over :items, as: :item do
          change_variable :names, to: "$names + $item/Name + ','"
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
      title 'Retrieve sort oracle'
      button('Run', caption: 'Run') { on_click microflow: 'Views.RunAll' }
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
