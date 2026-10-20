# frozen_string_literal: true

# What getCaption and getKey give in a microflow on Mendix 11.12.1: of an
# enumeration literal, of an attribute holding a value, of an empty attribute,
# and compared with text, as the OIDC module compares its response mode.
# Views.RunAll runs after startup and logs one "ORACLE <case>=<value>" line each.

require 'mxrb'

output_path = ENV.fetch('MXRB_OUTPUT_PATH')
oracle = "'ORACLE'"
cases = {
  literal_caption: 'getCaption(Views.Mode.form_post)',
  literal_key: 'getKey(Views.Mode.form_post)',
  attribute_caption: 'getCaption($config/Mode)',
  attribute_key: 'getKey($config/Mode)',
  empty_caption: 'getCaption($blank/Mode)',
  empty_key: 'getKey($blank/Mode)',
  compare_caption: 'toString(getCaption(Views.Mode.form_post) = $config/Text)',
  compare_key: "toString(getKey($config/Mode) = 'form_post')",
  to_string: 'toString($config/Mode)',
  joined: "getCaption(Views.Mode.query) + '/' + getKey(Views.Mode.query)"
}

Mxrb.define(output_path) do
  mendix_version '11.12.1'
  self.module :Views do
    enumeration :Mode do
      value :query, caption: 'Query'
      value :form_post, caption: 'Form Post'
    end
    entity :Config do
      string :Text
      enum :Mode, enumeration: 'Views.Mode'
    end
    page :Home do
      title 'Enumeration captions oracle'
    end
    microflow :RunAll do
      return_type :Boolean
      create_object 'Views.Config', as: :config do
        set :Text, to: "'Form Post'"
        set :Mode, to: 'Views.Mode.form_post'
      end
      create_object 'Views.Config', as: :blank
      cases.each { |name, expression| log_message "ORACLE #{name}=[{1}]", node: oracle, parameters: [expression] }
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
