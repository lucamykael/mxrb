# frozen_string_literal: true

# Mendix 11.12.1 tells an empty string from empty: only a String attribute
# without a default value starts empty.

require 'mxrb'

oracle = "'ORACLE'"
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do # rubocop:disable Metrics/BlockLength
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Item) { string :Name }
    page :Home do
      title 'Empty'
    end
    microflow :RunAll do
      return_type :Boolean
      create_variable :Blank, type: :String, value: "''"
      create_variable :Spaces, type: :String, value: "trim('  ')"
      create_variable :Nothing, type: :String, value: 'empty'
      log_message 'ORACLE blank_eq_empty={1}', node: oracle, parameters: ['toString($Blank = empty)']
      log_message 'ORACLE blank_ne_empty={1}', node: oracle, parameters: ['toString($Blank != empty)']
      log_message 'ORACLE trimmed_ne_empty={1}', node: oracle, parameters: ['toString($Spaces != empty)']
      log_message 'ORACLE nothing_eq_blank={1}', node: oracle, parameters: ["toString($Nothing = '')"]
      log_message 'ORACLE literal_eq={1}', node: oracle, parameters: ["toString('' = empty)"]
      create_object 'Views.Item', as: :item, set: { Name: "''" }
      log_message 'ORACLE attr_eq_empty={1}', node: oracle, parameters: ['toString($item/Name = empty)']
      create_object 'Views.Item', as: :none
      log_message 'ORACLE default_attr_eq_empty={1}', node: oracle, parameters: ['toString($none/Name = empty)']
      log_message 'ORACLE default_attr_eq_blank={1}', node: oracle, parameters: ["toString($none/Name = '')"]
      log_message 'ORACLE length_nothing={1}', node: oracle, parameters: ['toString(length($Nothing))']
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
