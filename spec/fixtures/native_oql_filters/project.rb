# frozen_string_literal: true

require 'mxrb'
require 'json'

cases = JSON.parse(File.read(File.join(__dir__, 'cases.json')))
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Probe) { string :Name }
    entity :Location do
      string :Name
      string :Nick
      decimal :Amount
      decimal :Other
      boolean :Active
    end
    cases.each_with_index do |item, index|
      columns = 'l.ID AS LocationId, l.Name AS Name'
      source = 'Views.Location AS l'
      predicate = item.fetch('where')
      query = if index.even?
                "FROM #{source} WHERE #{predicate} SELECT #{columns}"
              else
                "SELECT #{columns} FROM #{source} WHERE #{predicate}"
              end
      entity "View#{item.fetch('name')}" do
        string :Name
        association 'Views.Location', name: "Location#{item.fetch('name')}", cardinality: :many_to_one
        oql_view query: query.sub('AS LocationId', "AS Location#{item.fetch('name')}")
      end
      microflow item.fetch('name') do
        retrieve_objects "Views.View#{item.fetch('name')}", as: :items
        create_variable :names, type: :String, value: "''"
        loop_over :items, as: :item do
          change_variable :names, to: "$names + $item/Name + ','"
        end
        show_message 'Rows:{1}', parameters: ['$names'], blocking: true
      end
    end
    microflow :Load do
      create_object 'Views.Probe', as: :probe, set: { Name: "'OQL filter oracle'" }
      return_type 'Views.Probe'
      return_value '$probe'
    end
    microflow :Seed do
      [
        ['North', "'SELECT WHERE FROM'", '9007199254740993.125', '9007199254740993.125', 'true'],
        ['South', "'O''Brien'", '2.5', '3', 'false'],
        ['Empty', 'empty', 'empty', 'empty', 'true'],
        ['Zero', "''", '0', 'empty', 'false'],
        ['Negative', "''", '-1.25', '1', 'false']
      ].each_with_index do |(name, nick, amount, other, active), index|
        create_object 'Views.Location', as: "row#{index}", commit: true,
                                        set: { Name: "'#{name}'", Nick: nick, Amount: amount,
                                               Other: other, Active: active }
      end
      show_message 'Seeded', blocking: true
    end
    page :Home do
      title 'OQL filter oracle'
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
