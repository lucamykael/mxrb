# frozen_string_literal: true

require 'mxrb'
require 'json'
cases = JSON.parse(File.read(File.join(__dir__, 'cases.json')))
literal = ->(value) { "'#{value.gsub("'", "''")}'" }
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Dates do
    entity(:Probe) { string :Name }
    microflow :Load do
      return_type 'Dates.Probe'
      create_object 'Dates.Probe', as: :item, set: { Name: "'Date parsing oracle'" }
      return_value '$item'
    end
    cases.each do |item|
      name = item.fetch('name')
      expression = "toString(dateTimeToEpoch(parseDateTimeUTC(#{literal.call(item.fetch('input'))}, " \
                   "#{literal.call(item.fetch('format'))}, dateTimeUTC(2000))))"
      microflow(name) do
        return_type :String
        return_value expression
      end
      nanoflow "Client#{name}" do
        show_message '{1}', parameters: [expression], blocking: true
      end
    end
    page :Home do
      title 'Date parsing oracle'
      data_source microflow: 'Dates.Load'
      text_box :Name, attribute: 'Dates.Probe.Name', caption: 'Name'
      cases.each do |item|
        name = "Client#{item.fetch('name')}"
        button(name, caption: name) { on_click nanoflow: "Dates.#{name}" }
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Dates.Home' }
end
# rubocop:enable Metrics/BlockLength
