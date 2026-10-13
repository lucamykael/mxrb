# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'pages Studio Pro excludes from the app' do
  after { Mxrb::RubyApp::Registry.reset! }

  it 'exports the exclusion and does not serve an excluded page' do
    exporter = Mxrb::RubyApp::Exporter.allocate
    options = { appearance_class: '', appearance_style: '', data_source: nil }
    included = exporter.send(:page_source, 'App', 'HomePage', 'App.Home', 'home', 'Home', [], **options)
    excluded_source = exporter.send(:page_source, 'App', 'DraftPage', 'App.Draft', 'draft', 'Draft', [],
                                    **options, excluded: true)
    expect(included).not_to include('excluded')
    expect(excluded_source).to include("mendix_name \"App.Draft\"\n    excluded\n    configure(")

    page = Class.new(Mxrb::RubyApp::Page) do
      mendix_name 'App.Draft'
      excluded
      configure(title: 'Draft')
    end
    application = Mxrb::RubyApp::Application.allocate
    expect(page).to be_excluded
    expect(application.page('App.Draft')).to be_nil
  end
end
