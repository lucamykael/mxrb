# frozen_string_literal: true

require 'mxrb'
# rubocop:disable Metrics/BlockLength
Mxrb.define(ENV.fetch('MXRB_OUTPUT_PATH')) do
  mendix_version '11.12.1'
  self.module :Views do
    entity(:Probe) { string :Name }
    entity(:Location) do
      string :Name
      string :Address
    end
    entity(:LocationsView) do
      string :Name
      string :Address
      association 'Views.Location', name: :LocationId, cardinality: :many_to_one
      oql_view source: 'Views.LocationsView'
    end
    oql_source_document :LocationsView,
                        query: 'FROM Views.Location SELECT ID AS LocationId, Name AS Name, Address AS Address'
    microflow :Load do
      create_object 'Views.Probe', as: :probe, set: { Name: "'View entity oracle'" }
      return_type 'Views.Probe'
      return_value '$probe'
    end
    microflow :Seed do
      create_object 'Views.Location', as: :first, commit: true, set: { Name: "'North'", Address: "'Street 1'" }
      create_object 'Views.Location', as: :second, commit: true, set: { Name: "'South'", Address: "'Street 2'" }
      show_message 'Seeded', blocking: true
    end
    microflow :ReadView do
      retrieve_objects 'Views.LocationsView', as: :items
      list_operation :head, :items, as: :first
      aggregate :items, function: :count, as: :count
      show_message '{1}: {2}', parameters: ['toString($count)', '$first/Name'], blocking: true
    end
    page :Home do
      title 'View entity oracle'
      data_source microflow: 'Views.Load'
      text_box :Name, attribute: 'Views.Probe.Name', caption: 'Name'
      button(:Seed, caption: 'Seed') { on_click microflow: 'Views.Seed' }
      button(:ReadView, caption: 'ReadView') { on_click microflow: 'Views.ReadView' }
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
