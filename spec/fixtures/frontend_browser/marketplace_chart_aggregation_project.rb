# frozen_string_literal: true

require 'mxrb'
require 'fileutils'

destination = ENV.fetch('MXRB_OUTPUT_PATH')
widgets = File.join(File.dirname(destination), 'widgets')
FileUtils.mkdir_p(widgets)
FileUtils.cp(ENV.fetch('MXRB_CHARTS_PACKAGE'), File.join(widgets, 'Charts.mpk'))

# rubocop:disable Metrics/BlockLength
Mxrb.define(destination) do
  mendix_version '11.12.1'
  self.module :Aggregation do
    entity(:Point) do
      string :Category
      decimal :Value
      integer :Position
    end
    entity(:ChartContext) do
      non_persistent!
      string :Name
    end
    microflow :Load do
      retrieve_objects 'Aggregation.Point', as: :Existing, single: true
      decision '$Existing = empty' do
        on(true) do
          [['A', 10], ['B', 5], ['A', 20], ['B', 5], ['A', 10], ['B', 20], ['A', 40],
           ['A', nil]].each_with_index do |(category, value), index|
            values = { Category: "'#{category}'", Value: value.nil? ? 'empty' : value.to_s,
                       Position: index.to_s }
            create_object 'Aggregation.Point', as: "Point#{index}", commit: true, set: values
          end
        end
        on(false) {}
      end
      create_object 'Aggregation.ChartContext', as: :Context, set: { Name: "'Chart aggregation'" }
      return_type 'Aggregation.ChartContext'
      return_value '$Context'
    end
    microflow :AddPoint do
      create_object 'Aggregation.Point', as: :Point, commit: true, refresh: true,
                                         set: { Category: "'A'", Value: '100', Position: '9' }
    end
    page :Home do
      title 'Chart aggregation'
      data_source microflow: 'Aggregation.Load'
      text_box :Name, attribute: 'Aggregation.ChartContext.Name', caption: 'Title'
      button(:AddPoint, caption: 'Add aggregate value') { on_click microflow: 'Aggregation.AddPoint' }
      %w[count sum avg min max median mode first last].each do |aggregation|
        source = { data_source: { entity: 'Aggregation.Point',
                                  sort: [{ attribute: 'Aggregation.Point.Position', direction: 'Ascending' }] } }
        series = { dataSet: 'static', staticDataSource: source, staticName: { text: aggregation },
                   staticXAttribute: { attribute: 'Aggregation.Point.Category' },
                   staticYAttribute: { attribute: 'Aggregation.Point.Value' }, aggregationType: aggregation }
        pluggable_widget(
          "Aggregate_#{aggregation}", widget_id: 'com.mendix.widget.web.linechart.LineChart',
                                      widget_name: 'LineChart', properties: { lines: { objects: [series] } }
        )
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Aggregation.Home' }
end
# rubocop:enable Metrics/BlockLength
