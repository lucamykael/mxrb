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
  self.module :Captions do
    entity(:Point) do
      string :Region
      string :Category
      decimal :Amount
      datetime :Recorded, localize_date: false
    end
    entity(:ChartContext) do
      non_persistent!
      string :Name
    end
    microflow :Load do
      retrieve_objects 'Captions.Point', as: :Existing, single: true
      decision '$Existing = empty' do
        on(true) do
          create_object 'Captions.Point', as: :Point, commit: true,
                                          set: { Region: "'North'", Category: "'A'", Amount: '1234.5',
                                                 Recorded: 'dateTimeUTC(2026, 10, 6, 12, 34, 56)' }
        end
        on(false) {}
      end
      create_object 'Captions.ChartContext', as: :Owner, set: { Name: "'Owner'" }
      return_type 'Captions.ChartContext'
      return_value '$Owner'
    end
    microflow :Change do
      retrieve_objects 'Captions.Point', as: :Point, single: true
      change_object(:Point, commit: true, refresh: true) { set 'Captions.Point/Amount', to: '$Point/Amount + 1' }
    end
    page :Home do
      title 'Structured captions'
      data_source microflow: 'Captions.Load'
      text_box :Name, attribute: 'Captions.ChartContext.Name', caption: 'Owner'
      button(:Change, caption: 'Change amount') { on_click microflow: 'Captions.Change' }
      parameters = [
        { attribute: 'Captions.Point.Region' },
        { attribute: 'Captions.Point.Amount', format: { decimal_precision: 3, group_digits: true } },
        { attribute: 'Captions.Point.Recorded', format: { date_format: 'Custom', custom_date_format: 'yyyy-MM-dd' } },
        { attribute: 'Captions.ChartContext.Name', source: { kind: :widget, name: 'dataView' } }
      ]
      line = { dataSet: 'dynamic', dynamicDataSource: { data_source: { entity: 'Captions.Point' } },
               groupByAttribute: { attribute: 'Captions.Point.Region' },
               dynamicName: { text: '{1}: {2} on {3} by {4}', parameters:,
                              translations: { 'pt_BR' => '{1}: {2} em {3} por {4}' } },
               dynamicXAttribute: { attribute: 'Captions.Point.Category' },
               dynamicYAttribute: { attribute: 'Captions.Point.Amount' } }
      pluggable_widget :Formatted, widget_id: 'com.mendix.widget.web.linechart.LineChart',
                                   widget_name: 'LineChart', properties: { lines: { objects: [line] } }
    end
  end
  navigation { profile :Responsive, home_page: 'Captions.Home' }
end
# rubocop:enable Metrics/BlockLength
