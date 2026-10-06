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
  self.module :Series do
    entity(:Point) do
      string :Region
      string :Category
      decimal :Value
      integer :Position
    end
    entity(:ChartContext) do
      non_persistent!
      string :Name
    end
    microflow :Load do
      retrieve_objects 'Series.Point', as: :Existing, single: true
      decision '$Existing = empty' do
        on(true) do
          [['North', 'A', 10], ['South', 'A', 5], ['North', 'A', 20],
           ['South', 'B', 15], ['North', 'B', 8]].each_with_index do |(region, category, value), index|
            create_object 'Series.Point', as: "Point#{index}", commit: true,
                                          set: { Region: "'#{region}'", Category: "'#{category}'",
                                                 Value: value.to_s, Position: index.to_s }
          end
        end
        on(false) {}
      end
      create_object 'Series.ChartContext', as: :Context, set: { Name: "'Dynamic charts'" }
      return_type 'Series.ChartContext'
      return_value '$Context'
    end
    microflow :AddPoint do
      create_object 'Series.Point', as: :North, commit: true, refresh: true,
                                    set: { Region: "'North'", Category: "'A'", Value: '7', Position: '5' }
      create_object 'Series.Point', as: :East, commit: true, refresh: true,
                                    set: { Region: "'East'", Category: "'C'", Value: '12', Position: '6' }
    end
    page :Home do
      title 'Dynamic charts'
      data_source microflow: 'Series.Load'
      text_box :Name, attribute: 'Series.ChartContext.Name', caption: 'Title'
      button(:AddPoint, caption: 'Add series value') { on_click microflow: 'Series.AddPoint' }
      %w[LineChart ColumnChart].each do |kind|
        direction = kind == 'ColumnChart' ? 'Descending' : 'Ascending'
        source = { data_source: { entity: 'Series.Point',
                                  sort: [{ attribute: 'Series.Point.Position', direction: }] } }
        series = { dataSet: 'dynamic', dynamicDataSource: source,
                   groupByAttribute: { attribute: 'Series.Point.Region' },
                   dynamicName: { text: 'Region {1}', parameters: ['$currentObject/Series.Point.Region'] },
                   dynamicXAttribute: { attribute: 'Series.Point.Category' },
                   dynamicYAttribute: { attribute: 'Series.Point.Value' }, aggregationType: 'sum' }
        key = kind == 'LineChart' ? :lines : :series
        pluggable_widget(
          "Dynamic_#{kind}", widget_id: "com.mendix.widget.web.#{kind.downcase}.#{kind}",
                             widget_name: kind, properties: { key => { objects: [series] } }
        )
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Series.Home' }
end
# rubocop:enable Metrics/BlockLength
