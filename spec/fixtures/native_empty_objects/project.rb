# frozen_string_literal: true

# Mendix 11.12.1: $latestError is empty outside an error handler, a member of an
# empty object is empty, and a log template shows an empty value as null.

require 'mxrb'
oracle = "'ORACLE'"
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Item) { string :Name }
    page :Home do
      title 'Late'
    end
    microflow :Probe do
      log_message 'ORACLE late_message={1}', node: oracle, parameters: ['$latestError/Message']
      log_message 'ORACLE late_empty={1}', node: oracle, parameters: ['toString($latestError = empty)']
      retrieve_objects 'Views.Item', as: :Nothing, single: true, xpath: "[Name = 'none']"
      log_message 'ORACLE empty_member={1}', node: oracle, parameters: ['$Nothing/Name']
      log_message 'ORACLE empty_member_concat={1}', node: oracle, parameters: ["'x' + $Nothing/Name"]
    end
    microflow :RunAll do
      return_type :Boolean
      call_microflow 'Views.Probe'
      return_value 'true'
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
