# frozen_string_literal: true

require 'mxrb'
require 'json'

# Each case projects l.Name AS Name plus an expression AS Value of the given type.
cases = JSON.parse(File.read(ENV.fetch('MXRB_ORACLE_CASES', File.join(__dir__, 'cases.json'))))
rows = JSON.parse(File.read(File.join(__dir__, 'rows.json')))
decimals = %w[Amount Other]
literal = lambda do |key, value|
  if value.nil? then 'empty'
  elsif key == 'Moment' then "parseDateTimeUTC('#{value.delete_suffix('Z')}', 'yyyy-MM-dd''T''HH:mm:ss.SSS')"
  elsif value.is_a?(String) && !decimals.include?(key) then "'#{value.gsub("'", "''")}'"
  else value.to_s
  end
end
render = {
  'string' => '$item/Value', 'integer' => 'toString($item/Value)', 'long' => 'toString($item/Value)',
  'decimal' => 'toString($item/Value)', 'boolean' => 'toString($item/Value)',
  'datetime' => "formatDateTimeUTC($item/Value, 'yyyy-MM-dd HH:mm:ss')"
}
# Headless native oracle for OQL value expressions; run with script/oql_native_oracle.
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
      datetime :Moment, localize_date: false
    end
    cases.each do |item|
      type = item.fetch('type', 'string')
      entity "View#{item.fetch('name')}" do
        string :Name
        public_send(type, :Value, **(type == 'datetime' ? { localize_date: false } : {}))
        oql_view query: "SELECT l.Name AS Name, #{item.fetch('value')} AS Value FROM Views.Location AS l" \
                        "#{item['where'] ? " WHERE #{item['where']}" : ''}#{item['group'] ? ' GROUP BY l.Name' : ''}"
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
          type = item.fetch('type', 'string')
          shown = render.fetch(type)
          shown = "if $item/Value = empty then '<null>' else #{shown}" unless type == 'boolean'
          change_variable :names, to: "$names + $item/Name + ':' + (#{shown}) + '|'"
        end
        log_message "ORACLE #{name}={1}", node: "'ORACLE'", parameters: ['$names']
        rescue_all { log_message "ORACLE #{name}=<error>", node: "'ORACLE'" }
      end
    end
    microflow :RunAll do
      return_type :Boolean
      call_microflow 'Views.Seed'
      cases.each { |item| call_microflow "Views.Case#{item.fetch('name')}" }
      return_value 'true'
    end
    page :Home do
      title 'OQL expression oracle'
      button('Run', caption: 'Run') { on_click microflow: 'Views.RunAll' }
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
