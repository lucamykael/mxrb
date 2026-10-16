# frozen_string_literal: true

# Find and Filter by attribute and by association on Mendix 11.12.1: which
# objects of a list match the value of the expression, for text (whose case
# matters or not), an enumeration, a decimal compared with an integer, an empty
# value and a reference, and a list compared with empty. Views.RunAll runs after startup and logs one
# "ORACLE <case>=<value>" line each.

require 'mxrb'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
oracle = "'ORACLE'"
code = { attribute: 'Views.Item.Code' }
group = { association: 'Views.Item_Group' }
finds = {
  find_text: [code, "'AB'"], find_text_case: [code, "'Ab'"], find_empty: [code, 'empty'],
  find_decimal: [{ attribute: 'Views.Item.Price' }, '2'],
  find_enum: [{ attribute: 'Views.Item.Size' }, 'Views.Size.Large'],
  find_association: [group, '$blue']
}
filters = { filter_association_empty: [group, 'empty'], filter_decimal: [{ attribute: 'Views.Item.Price' }, '2.5'] }

# rubocop:disable Metrics/BlockLength
Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Views do
    enumeration :Size do
      value :Small, caption: 'Small'
      value :Large, caption: 'Large'
    end
    entity(:Group) { string :Name }
    entity :Item do
      string :Name
      string :Code
      decimal :Price
      enum :Size, enumeration: 'Views.Size'
      association 'Views.Group', name: :Item_Group, cardinality: :many_to_one
    end
    page :Home do
      title 'List member operations oracle'
    end
    microflow :RunAll do
      return_type :Boolean
      create_object 'Views.Group', as: :red, set: { Name: "'red'" }, commit: true
      create_object 'Views.Group', as: :blue, set: { Name: "'blue'" }, commit: true
      create_object 'Views.Item', as: :first, commit: true do
        set :Name, to: "'first'"
        set :Code, to: "'ab'"
        set :Price, to: '2'
        set :Size, to: 'Views.Size.Small'
        set_association 'Views.Item_Group', to: '$red'
      end
      create_object 'Views.Item', as: :second, commit: true do
        set :Name, to: "'second'"
        set :Code, to: "'AB'"
        set :Price, to: '2.50'
        set :Size, to: 'Views.Size.Large'
        set_association 'Views.Item_Group', to: '$blue'
      end
      create_object 'Views.Item', as: :third, set: { Name: "'third'", Price: '3' }, commit: true
      retrieve_objects 'Views.Item', as: :items, sort: [['Views.Item.Name', :ascending]]
      finds.each do |name, (member, expression)|
        list_operation :find, :items, **member, expression:, as: name
        found = "if $#{name} = empty then 'none' else $#{name}/Name"
        log_message "ORACLE #{name}=[{1}]", node: oracle, parameters: [found]
      end
      filters.each do |name, (member, expression)|
        list_operation :filter, :items, **member, expression:, as: name
        aggregate name, function: :count, as: :"#{name}_count"
        log_message "ORACLE #{name}=[{1}]", node: oracle, parameters: ["toString($#{name}_count)"]
      end
      retrieve_objects 'Views.Item', as: :none, xpath: "[Name = 'nobody']"
      lists = { empty_list: '$none = empty', empty_list_not: '$none != empty', full_list: '$items = empty' }
      lists.each do |name, expression|
        log_message "ORACLE #{name}=[{1}]", node: oracle, parameters: ["toString(#{expression})"]
      end
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
