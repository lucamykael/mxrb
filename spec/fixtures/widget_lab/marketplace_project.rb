# frozen_string_literal: true

# rubocop:disable Layout/HashAlignment, Layout/LineLength, Metrics/BlockLength

require 'base64'
require 'fileutils'
require 'json'
require 'mxrb'

destination = File.expand_path(ARGV.fetch(0))
source_widgets = File.expand_path(ARGV.fetch(1))
project_root = File.dirname(destination)
widget_root = File.join(project_root, 'widgets')
FileUtils.mkdir_p(widget_root)
FileUtils.cp(Dir.glob(File.join(source_widgets, '*.mpk')), widget_root)

definitions = Dir.glob(File.join(widget_root, '*.mpk')).sort.flat_map do |path|
  inventory = Mxrb::OfficialMarketplace::WidgetPackageInventory.read(path)
  inventory.widget_ids.filter_map { Mxrb::WidgetPackage.new(path).definition(_1) }
rescue Mxrb::MarketplaceError, Zip::Error, REXML::ParseException
  []
end
definitions.select! { _1.platform.to_s.casecmp('web').zero? }
definitions.uniq!(&:id)

raise 'no web Marketplace widgets found' if definitions.empty?

video = Base64.decode64(
  'AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMybW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAZAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAlx0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAZAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAACAAAAAgAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAGQAAAAAAABAAAAAAHUbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAEABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABf21pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAT9zdGJsAAAAt3N0c2QAAAAAAAAAAQAAAKdhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAACAAIABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAALWF2Y0MBQsAK/+EAFWdCwArZCWwEQAAAAwBAAAAFA8SJkgEABWjLg8sgAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAANXAAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAQAAAQAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAQAAAABAAAAJHN0c3oAAAAAAAAAAAAAAAQAAAKPAAAACgAAAAoAAAAJAAAAFHN0Y28AAAAAAAAAAQAAA2IAAABidWR0YQAAAFptZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAAJal0b28AAAAdZGF0YQAAAAEAAAAATGF2ZjYyLjEyLjEwMgAAAAhmcmVlAAACtG1kYXQAAAJxBgX//23cRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQgQVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9uczogY2FiYWM9MCByZWY9MyBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgxOjB4MTExIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9yZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTEgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0wIGNxbT0wIGRlYWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0yNTAga2V5aW50X21pbj0xMCBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTQwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAABZliIQP8RigACu/HAAED6OAAIDMnXXgAAAABkGaOB/lgAAAAAZBmlQHeWAAAAAFQZpgN8s='
)
public_assets = File.join(project_root, 'themesource', 'marketplace_lab', 'public')
FileUtils.mkdir_p(public_assets)
File.binwrite(File.join(public_assets, 'marketplace-widget.mp4'), video)
video_url = "data:video/mp4;base64,#{Base64.strict_encode64(video)}"

definitions_by_id = definitions.to_h { [_1.id, _1] }
widget = lambda do |definition, name, properties = {}|
  {
    type: :pluggable_widget, name:, events: [],
    options: {
      widget_id: definition.id, widget_name: definition.name, properties:,
      class: 'marketplace-widget-under-test'
    }
  }
end
text_widget = lambda do |name, caption|
  { type: :text, name:, events: [], options: { caption: } }
end
chart_series = lambda do |time: false, bubble: false|
  series = {
    dataSet: 'static', staticDataSource: { data_source: 'MarketplaceLab.Item' },
    staticName: { text: 'Marketplace items' },
    staticXAttribute: {
      attribute: time ? 'MarketplaceLab.Item.OccurredAt' : 'MarketplaceLab.Item.Name'
    },
    staticYAttribute: { attribute: 'MarketplaceLab.Item.Value' }
  }
  series[:staticSizeAttribute] = { attribute: 'MarketplaceLab.Item.Value' } if bubble
  { objects: [series] }
end
context_ids = %w[
  com.mendix.widget.web.chartplayground.ChartPlayground
  com.mendix.widget.web.datagriddatefilter.DatagridDateFilter
  com.mendix.widget.web.datagriddropdownfilter.DatagridDropdownFilter
  com.mendix.widget.web.datagridnumberfilter.DatagridNumberFilter
  com.mendix.widget.web.datagridtextfilter.DatagridTextFilter
  com.mendix.widget.web.dropdownsort.DropdownSort
  com.mendix.widget.web.selectionhelper.SelectionHelper
].freeze

Mxrb.define(destination) do
  mendix_version '11.12.1'

  self.module :MarketplaceLab do
    enumeration :Status do
      value :Draft, caption: 'Draft'
      value :Ready, caption: 'Ready'
    end

    entity :Context do
      string :Name
      integer :Score
      boolean :Active
      enum :Status, enumeration: 'MarketplaceLab.Status'
    end

    entity :Item do
      string :Name
      string :Category
      decimal :Value
      datetime :OccurredAt
      enum :Status, enumeration: 'MarketplaceLab.Status'
    end

    microflow :LoadContext do
      create_object 'MarketplaceLab.Item', as: :FirstItem,
                                               set: {
                                                 Name: "'Alpha'", Category: "'Primary'", Value: '10',
                                                 Status: 'MarketplaceLab.Status.Ready'
                                               }, commit: true
      create_object 'MarketplaceLab.Item', as: :SecondItem,
                                               set: {
                                                 Name: "'Beta'", Category: "'Secondary'", Value: '20',
                                                 Status: 'MarketplaceLab.Status.Draft'
                                               }, commit: true
      create_object 'MarketplaceLab.Context', as: :Context,
                                                  set: { Name: "'Widget context'", Score: '3', Active: 'true' }
      return_value '$Context'
    end

    layout :Shell, title: 'Marketplace Widget Lab'

    page :Widgets do
      layout 'MarketplaceLab.Shell'
      title 'Marketplace widget certification laboratory'
      data_source microflow: 'MarketplaceLab.LoadContext'
      text :Heading, caption: 'Marketplace widget certification laboratory'
      definitions.each_with_index do |definition, index|
        name = "MarketplaceWidget#{index + 1}"
        next if context_ids.include?(definition.id)

        case definition.id
        when 'com.mendix.widget.web.areachart.AreaChart'
          playground = widget.call(
            definitions_by_id.fetch('com.mendix.widget.web.chartplayground.ChartPlayground'),
            'MarketplaceWidget12'
          )
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    series: chart_series.call,
                                    showPlaygroundSlot: true,
                                    playground: { widgets: [playground] }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.barchart.BarChart',
             'com.mendix.widget.web.columnchart.ColumnChart'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: { series: chart_series.call },
                                  class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.bubblechart.BubbleChart'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: { lines: chart_series.call(bubble: true) },
                                  class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.linechart.LineChart'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: { lines: chart_series.call },
                                  class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.timeseries.TimeSeries'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: { lines: chart_series.call(time: true) },
                                  class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.customchart.CustomChart'
          data = [{ x: %w[Alpha Beta], y: [10, 20], type: 'bar', name: 'Marketplace' }]
          layout = { title: { text: 'Marketplace custom chart' } }
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    dataStatic: JSON.generate(data), layoutStatic: JSON.generate(layout)
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.heatmap.HeatMap'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    seriesDataSource: { data_source: 'MarketplaceLab.Item' },
                                    seriesValueAttribute: { attribute: 'MarketplaceLab.Item.Value' },
                                    seriesItemSelection: { selection: 'None' },
                                    horizontalAxisAttribute: { attribute: 'MarketplaceLab.Item.Name' },
                                    verticalAxisAttribute: { attribute: 'MarketplaceLab.Item.Category' }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.piechart.PieChart'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    seriesDataSource: { data_source: 'MarketplaceLab.Item' },
                                    seriesName: { text: 'Item' },
                                    seriesValueAttribute: { attribute: 'MarketplaceLab.Item.Value' },
                                    seriesItemSelection: { selection: 'None' }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.custom.slider.Slider'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    valueAttribute: { attribute: 'MarketplaceLab.Context.Score' }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.custom.starrating.StarRating'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    rateAttribute: { attribute: 'MarketplaceLab.Context.Score' }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.custom.switch.Switch'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    booleanAttribute: { attribute: 'MarketplaceLab.Context.Active' }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.accessibilityhelper.AccessibilityHelper'
          target = {
            type: :container, name: 'AccessibilityTarget', events: [],
            options: { class: 'marketplace-accessibility-target' },
            children: [text_widget.call('AccessibilityText', 'Accessible content')]
          }
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    targetSelector: '.marketplace-accessibility-target',
                                    content: { widgets: [target] }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.accordion.Accordion'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    groups: { objects: [{
                                      headerText: { text: 'Marketplace section' },
                                      content: { widgets: [text_widget.call('AccordionText', 'Accordion content')] }
                                    }] }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.combobox.Combobox'
          drop_down name, attribute: 'MarketplaceLab.Context.Status', caption: 'Status'
        when 'com.mendix.widget.web.datagrid.Datagrid'
          date_filter = widget.call(
            definitions_by_id.fetch('com.mendix.widget.web.datagriddatefilter.DatagridDateFilter'),
            'MarketplaceWidget21'
          )
          dropdown_filter = widget.call(
            definitions_by_id.fetch('com.mendix.widget.web.datagriddropdownfilter.DatagridDropdownFilter'),
            'MarketplaceWidget22', attr: { attribute: 'MarketplaceLab.Item.Status' }
          )
          number_filter = widget.call(
            definitions_by_id.fetch('com.mendix.widget.web.datagridnumberfilter.DatagridNumberFilter'),
            'MarketplaceWidget23'
          )
          text_filter = widget.call(
            definitions_by_id.fetch('com.mendix.widget.web.datagridtextfilter.DatagridTextFilter'),
            'MarketplaceWidget24'
          )
          selection = widget.call(
            definitions_by_id.fetch('com.mendix.widget.web.selectionhelper.SelectionHelper'),
            'MarketplaceWidget32',
            customAllSelected: { widgets: [text_widget.call('AllSelected', 'All selected')] },
            customSomeSelected: { widgets: [text_widget.call('SomeSelected', 'Some selected')] },
            customNoneSelected: { widgets: [text_widget.call('NoneSelected', 'None selected')] }
          )
          data_grid name, entity: 'MarketplaceLab.Item', selection: 'Multi' do
            column :Name, attribute: 'MarketplaceLab.Item.Name', caption: 'Name', filter: text_filter
            column :Value, attribute: 'MarketplaceLab.Item.Value', caption: 'Value', filter: number_filter
            column :OccurredAt, attribute: 'MarketplaceLab.Item.OccurredAt', caption: 'Date',
                                filter: date_filter
            column :Status, attribute: 'MarketplaceLab.Item.Status', caption: 'Status',
                            filter: dropdown_filter
            filter selection
          end
        when 'com.mendix.widget.web.fieldset.Fieldset'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    legend: { text: 'Marketplace fieldset' },
                                    content: { widgets: [text_widget.call('FieldsetText', 'Fieldset content')] }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.gallery.Gallery'
          dropdown_sort = widget.call(
            definitions_by_id.fetch('com.mendix.widget.web.dropdownsort.DropdownSort'),
            'MarketplaceWidget25',
            attributes: { objects: [{
              attribute: { attribute: 'MarketplaceLab.Item.Name' },
              caption: { text: 'Name' }
            }] }
          )
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    datasource: { data_source: 'MarketplaceLab.Item' },
                                    itemSelection: { selection: 'None' },
                                    filtersPlaceholder: { widgets: [dropdown_sort] },
                                    content: { widgets: [text_widget.call('GalleryItem', 'Gallery item')] }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.htmlelement.HTMLElement'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    tagContentRepeatDataSource: { data_source: 'MarketplaceLab.Item' },
                                    tagContentContainer: {
                                      widgets: [text_widget.call('HtmlContent', 'HTML element content')]
                                    }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.image.Image'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    datasource: 'imageUrl',
                                    imageUrl: { text: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxNiIgaGVpZ2h0PSIxNiI+PHJlY3Qgd2lkdGg9IjE2IiBoZWlnaHQ9IjE2IiBmaWxsPSIjMDA2NmNjIi8+PC9zdmc+' },
                                    alternativeText: { text: 'Marketplace image' }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.languageselector.LanguageSelector'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    languageOptions: { data_source: 'System.Language' },
                                    languageCaption: { expression: '$Language/Description' },
                                    hideForSingle: false
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.popupmenu.PopupMenu'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    menuTrigger: { widgets: [text_widget.call('PopupTrigger', 'Open menu')] },
                                    basicItems: { objects: [{ caption: { text: 'Menu item' } }] }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.timeline.Timeline'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    data: { data_source: 'MarketplaceLab.Item' },
                                    title: { text: 'Timeline item' },
                                    description: { text: 'Marketplace timeline event' },
                                    timeIndication: { text: 'Now' }, groupEvents: false
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.tooltip.Tooltip'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    trigger: { widgets: [text_widget.call('TooltipTrigger', 'Hover for tooltip')] },
                                    textMessage: { text: 'Marketplace tooltip' }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.treenode.TreeNode'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    datasource: { data_source: 'MarketplaceLab.Item' },
                                    headerCaption: { text: 'Tree node' }, hasChildren: false,
                                    children: { widgets: [text_widget.call('TreeChild', 'Tree child')] }
                                  }, class_name: 'marketplace-widget-under-test'
        when 'com.mendix.widget.web.videoplayer.VideoPlayer'
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  properties: {
                                    type: 'dynamic', videoUrl: { text: video_url },
                                    iframeTitle: { text: 'Marketplace video' }, muted: true
                                  }, class_name: 'marketplace-widget-under-test'
        else
          pluggable_widget name, widget_id: definition.id, widget_name: definition.name,
                                  class_name: 'marketplace-widget-under-test'
        end
      end
    end
  end

  navigation do
    profile :Responsive, home_page: 'MarketplaceLab.Widgets', app_title: 'Marketplace Widget Lab'
  end
end

puts "Generated #{definitions.length} web Marketplace widget contracts"
# rubocop:enable Layout/HashAlignment, Layout/LineLength, Metrics/BlockLength
