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
  self.module :Charts do
    entity(:Item) do
      string :Name
      decimal :Value
    end
    entity(:ChartContext) do
      non_persistent!
      string :Name
    end
    microflow :Load do
      retrieve_objects 'Charts.Item', as: :Existing, single: true, xpath: "[Name = 'First']"
      decision '$Existing = empty' do
        on(true) do
          create_object 'Charts.Item', as: :First, set: { Name: "'First'", Value: '10' }, commit: true
          create_object 'Charts.Item', as: :Second, set: { Name: "'Second'", Value: '20' }, commit: true
        end
        on(false) {}
      end
      create_object 'Charts.ChartContext', as: :Context, set: { Name: "'Live chart data'" }
      return_type 'Charts.ChartContext'
      return_value '$Context'
    end
    microflow :AddPoint do
      create_object 'Charts.Item', as: :Point, set: { Name: "'New value'", Value: '40' }, commit: true, refresh: true
    end
    page :Home do
      title 'Live chart data'
      data_source microflow: 'Charts.Load'
      text_box :Name, attribute: 'Charts.ChartContext.Name', caption: 'Title'
      button(:AddPoint, caption: 'Add chart point') { on_click microflow: 'Charts.AddPoint' }
      %w[LineChart BarChart PieChart].each do |kind|
        item_source = { data_source: { entity: 'Charts.Item', xpath: '[Value > 0]' } }
        properties = if kind == 'PieChart'
                       { seriesDataSource: item_source, seriesName: { text: 'Values' },
                         seriesValueAttribute: { attribute: 'Charts.Item.Value' } }
                     else
                       x_attribute, y_attribute = kind == 'BarChart' ? %w[Value Name] : %w[Name Value]
                       entry = { dataSet: 'static', staticDataSource: item_source,
                                 staticName: { text: 'Values' },
                                 staticXAttribute: { attribute: "Charts.Item.#{x_attribute}" },
                                 staticYAttribute: { attribute: "Charts.Item.#{y_attribute}" } }
                       { kind == 'LineChart' ? :lines : :series => { objects: [entry] } }
                     end
        pluggable_widget kind, widget_id: "com.mendix.widget.web.#{kind.downcase}.#{kind}",
                               widget_name: kind, properties:, class_name: 'chart-under-test'
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Charts.Home' }
end
# rubocop:enable Metrics/BlockLength
