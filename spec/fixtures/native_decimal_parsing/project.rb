# frozen_string_literal: true

require 'mxrb'
require 'json'

# Headless native oracle for parseDecimal with Java DecimalFormat patterns and for
# random(); run with script/oql_native_oracle. Each case logs
# "ORACLE <name>=<value>", or "ORACLE <name>=ERROR" when the expression fails.
cases = JSON.parse(File.read(ENV.fetch('MXRB_ORACLE_CASES', File.join(__dir__, 'cases.json'))))
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Probe) { string :Name }
    cases.each do |item|
      name = item.fetch('name')
      microflow "Case#{name}" do
        create_variable :result, type: :String, value: "'ERROR'"
        change_variable :result, to: item.fetch('expr')
        rescue_all { log_message "ORACLE #{name}=ERROR", node: "'ORACLE'" }
        log_message "ORACLE #{name}={1}", node: "'ORACLE'", parameters: ['$result']
      end
    end
    microflow :RunAll do
      return_type :Boolean
      cases.each { |item| call_microflow "Views.Case#{item.fetch('name')}" }
      return_value 'true'
    end
    page :Home do
      title 'Decimal parsing oracle'
      button('Run', caption: 'Run') { on_click microflow: 'Views.RunAll' }
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
