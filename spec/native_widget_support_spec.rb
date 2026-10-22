# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Mxrb::RubyApp::WidgetSupport do
  it 'renders the Native Mobile Resources widgets through their web adapters' do
    full = %w[
      accordion.Accordion activityindicator.ActivityIndicator animation.Animation appevents.AppEvents
      backgroundgradient.BackgroundGradient backgroundimage.BackgroundImage badge.Badge barchart.BarChart
      bottomsheet.BottomSheet carousel.Carousel colorpicker.ColorPicker columnchart.ColumnChart
      floatingactionbutton.FloatingActionButton gallery.Gallery gallerytextfilter.GalleryTextFilter image.Image
      introscreen.IntroScreen linechart.LineChart listviewswipe.ListViewSwipe piedoughnutchart.PieDoughnutChart
      popupmenu.PopupMenu progressbar.ProgressBar progresscircle.ProgressCircle qrcode.QRCode radiobuttons.RadioButtons
      rangeslider.RangeSlider rating.Rating repeater.Repeater safeareaview.SafeAreaView signature.Signature
      slider.Slider switch.Switch togglebuttons.ToggleButtons videoplayer.VideoPlayer webview.WebView
    ]
    full.each do |suffix|
      family = described_class.family("com.mendix.widget.native.#{suffix}")
      expect(family&.fetch('support')).to eq('full'), "#{suffix} should render fully"
    end
    approximate = %w[barcodescanner.BarcodeScanner feedback.Feedback maps.Maps notifications.Notifications]
    approximate.each do |suffix|
      family = described_class.family("com.mendix.widget.native.#{suffix}")
      expect(family&.fetch('support')).to eq('approximate'), "#{suffix} should render approximately"
      expect(family.fetch('note')).not_to be_empty
    end
    expect(described_class.family('com.mendix.widget.custom.Maps.Maps')).to be_nil
    expect(described_class.family('com.mendix.widget.web.notifications.Notifications')).to be_nil
  end
end
