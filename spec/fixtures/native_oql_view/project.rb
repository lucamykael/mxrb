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
    microflow :ReadAssociation do
      retrieve_objects 'Views.LocationsView', as: :items
      list_operation :head, :items, as: :first
      retrieve_association :first, association: 'Views.LocationId', as: :location
      show_message 'Source: {1}', parameters: ['$location/Address'], blocking: true
    end
    microflow :ReadDirtySource do
      retrieve_objects 'Views.Location', as: :locations
      list_operation :head, :locations, as: :location
      change_object :location, set: { 'Views.Location.Name' => "'Unsaved'" }
      retrieve_objects 'Views.LocationsView', as: :items
      list_operation :head, :items, as: :first
      show_message 'Durable: {1}', parameters: ['$first/Name'], blocking: true
    end
    microflow :CommitChange do
      retrieve_objects 'Views.Location', as: :locations
      list_operation :head, :locations, as: :location
      change_object :location, set: { 'Views.Location.Name' => "'Changed'" }, commit: true
      show_message 'Committed', blocking: true
    end
    microflow :DeleteSource do
      retrieve_objects 'Views.Location', as: :locations
      list_operation :head, :locations, as: :location
      delete :location
      show_message 'Deleted', blocking: true
    end
    page :Home do
      title 'View entity oracle'
      data_source microflow: 'Views.Load'
      text_box :Name, attribute: 'Views.Probe.Name', caption: 'Name'
      %w[Seed ReadView ReadAssociation ReadDirtySource CommitChange DeleteSource].each do |flow|
        button(flow, caption: flow) { on_click microflow: "Views.#{flow}" }
      end
    end
  end
  navigation { profile :Responsive, home_page: 'Views.Home' }
end
# rubocop:enable Metrics/BlockLength
