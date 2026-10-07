# frozen_string_literal: true

require 'mxrb'
require 'fileutils'
require 'json'

destination = ENV.fetch('MXRB_OUTPUT_PATH')
widgets = File.join(File.dirname(destination), 'widgets')
FileUtils.mkdir_p(widgets)
FileUtils.cp(ENV.fetch('MXRB_CHARTS_PACKAGE'), File.join(widgets, 'Charts.mpk'))
static_data = [{ type: 'bar', name: 'Static', x: %w[A B], y: [10, 20] }].to_json
dynamic_data = [{ type: 'scatter', name: 'Dynamic', x: %w[A B], y: [15, 25] }].to_json
updated_data = [{ type: 'scatter', name: 'Changed', x: %w[A B], y: [30, 40] }].to_json

# rubocop:disable Metrics/BlockLength
Mxrb.define(destination) do
  mendix_version '11.12.1'
  self.module :Custom do
    entity(:ChartContext) do
      non_persistent!
      string :Data
      string :Layout
      string :Event
      integer :Clicks
    end
    microflow :Load do
      create_object 'Custom.ChartContext', as: :ChartContext,
                                           set: {
                                             Clicks: '0', Data: "'#{dynamic_data}'",
                                             Layout: "'{\"title\":{\"text\":\"Dynamic title\"}}'"
                                           }
      return_type 'Custom.ChartContext'
      return_value '$ChartContext'
    end
    microflow :Change do
      parameter :ChartContext, type: 'Custom.ChartContext'
      change_object(:ChartContext, refresh: true) { set 'Custom.ChartContext/Data', to: "'#{updated_data}'" }
    end
    microflow :Click do
      parameter :ChartContext, type: 'Custom.ChartContext'
      change_object(:ChartContext, refresh: true) { set 'Custom.ChartContext/Clicks', to: '$ChartContext/Clicks + 1' }
    end
    page :Home do
      title 'Custom Plotly'
      data_source microflow: 'Custom.Load'
      text_box :Event, attribute: 'Custom.ChartContext.Event', caption: 'Event'
      text_box :Clicks, attribute: 'Custom.ChartContext.Clicks', caption: 'Clicks'
      button(:Change, caption: 'Change traces') do
        on_click microflow: 'Custom.Change', pass: { ChartContext: '$currentObject' }
      end
      properties = {
        dataStatic: static_data, dataAttribute: { attribute: 'Custom.ChartContext.Data' }, sampleData: '',
        layoutStatic: { title: { text: 'Static title' }, barmode: 'group', yaxis: { range: [0, 50] } }.to_json,
        layoutAttribute: { attribute: 'Custom.ChartContext.Layout' }, sampleLayout: '{"title":{"text":"Sample title"}}',
        configurationOptions: '{"displayModeBar":true,"scrollZoom":true}',
        heightUnit: 'pixels', height: 400, widthUnit: 'pixels', width: 800,
        eventDataAttribute: { attribute: 'Custom.ChartContext.Event' },
        onClick: { action: { kind: 'microflow', handler: 'Custom.Click',
                             arguments: { ChartContext: '$currentObject' } } }
      }
      pluggable_widget :Advanced, widget_id: 'com.mendix.widget.web.customchart.CustomChart',
                                  widget_name: 'CustomChart', properties:
    end
  end
  navigation { profile :Responsive, home_page: 'Custom.Home' }
end
# rubocop:enable Metrics/BlockLength
