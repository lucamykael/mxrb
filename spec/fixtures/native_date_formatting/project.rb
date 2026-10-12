# frozen_string_literal: true

require 'mxrb'
require 'json'

# Headless native oracle for date formatting; run with script/oql_native_oracle.
# Each case logs "ORACLE <name>=<expression value>" with dates $A..$D created in UTC.
cases = JSON.parse(File.read(ENV.fetch('MXRB_ORACLE_CASES', File.join(__dir__, 'cases.json'))))
dates = { 'A' => '2024-03-10T07:05:09.045', 'B' => '1999-12-31T23:59:59.999', 'C' => '2024-02-29T12:00:00.000',
          'D' => '2000-01-02T00:30:00.500' }
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Probe) { string :Name }
    cases.each do |item|
      microflow "Case#{item.fetch('name')}" do
        dates.each do |name, text|
          create_variable name, type: :DateTime,
                                value: "parseDateTimeUTC('#{text}', 'yyyy-MM-dd''T''HH:mm:ss.SSS')"
        end
        create_variable :result, type: :String, value: item.fetch('expr')
        log_message "ORACLE #{item.fetch('name')}={1}", node: "'ORACLE'", parameters: ['$result']
      end
    end
    microflow :RunAll do
      return_type :Boolean
      cases.each { |item| call_microflow "Views.Case#{item.fetch('name')}" }
      return_value 'true'
    end
    page :Home do
      title 'Date oracle'
      button('Run', caption: 'Run') { on_click microflow: 'Views.RunAll' }
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
