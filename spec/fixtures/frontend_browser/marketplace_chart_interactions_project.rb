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
  self.module :Interactions do
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
      retrieve_objects 'Interactions.Point', as: :Existing, single: true
      decision '$Existing = empty' do
        on(true) do
          [['North', 'A', 10], ['South', 'A', -5], ['North', 'A', 20],
           ['South', 'B', 15], ['North', 'B', 8]].each_with_index do |(region, category, value), index|
            create_object 'Interactions.Point', as: "Point#{index}", commit: true,
                                                set: { Region: "'#{region}'", Category: "'#{category}'",
                                                       Value: value.to_s, Position: index.to_s }
          end
        end
        on(false) {}
      end
      create_object 'Interactions.ChartContext', as: :Context, set: { Name: "'Stacked chart actions'" }
      return_type 'Interactions.ChartContext'
      return_value '$Context'
    end
    microflow :SelectPoint do
      parameter :Point, type: 'Interactions.Point'
      change_object(:Point, commit: true, refresh: true) { set 'Interactions.Point/Value', to: '$Point/Value + 1' }
    end
    microflow :AddPoint do
      create_object 'Interactions.Point', as: :North, commit: true, refresh: true,
                                          set: { Region: "'North'", Category: "'A'", Value: '7', Position: '5' }
      create_object 'Interactions.Point', as: :East, commit: true, refresh: true,
                                          set: { Region: "'East'", Category: "'C'", Value: '12', Position: '6' }
    end
    page :Home do
      title 'Stacked chart actions'
      data_source microflow: 'Interactions.Load'
      text_box :Name, attribute: 'Interactions.ChartContext.Name', caption: 'Title'
      button(:AddPoint, caption: 'Add series value') { on_click microflow: 'Interactions.AddPoint' }
      %w[ColumnChart BarChart].each do |kind|
        direction = 'Ascending'
        source = { data_source: { entity: 'Interactions.Point',
                                  sort: [{ attribute: 'Interactions.Point.Position', direction: }] } }
        series = { dataSet: 'dynamic', dynamicDataSource: source,
                   groupByAttribute: { attribute: 'Interactions.Point.Region' },
                   dynamicName: { text: 'Region {1}', parameters: ['$currentObject/Interactions.Point.Region'] },
                   dynamicXAttribute: { attribute: 'Interactions.Point.Category' },
                   dynamicYAttribute: { attribute: 'Interactions.Point.Value' }, aggregationType: 'sum',
                   dynamicOnClickAction: { action: { kind: :microflow, handler: 'Interactions.SelectPoint',
                                                     arguments: { Point: '$currentObject' } } } }
        if kind == 'BarChart'
          series[:dynamicXAttribute], series[:dynamicYAttribute] = series.values_at(:dynamicYAttribute,
                                                                                    :dynamicXAttribute)
        end
        key = :series
        pluggable_widget(
          "Stacked_#{kind}", widget_id: "com.mendix.widget.web.#{kind.downcase}.#{kind}",
                             widget_name: kind, properties: { barmode: 'stack', key => { objects: [series] } }
        )
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Interactions.Home' }
end
# rubocop:enable Metrics/BlockLength
