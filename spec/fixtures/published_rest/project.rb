# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
# Builds the official-MxBuild witness for typed published REST and mappings.
module PublishedRestFixture
  VERSION = '11.12.1'

  module_function

  def build(destination)
    Mxrb.define(destination) do
      mendix_version VERSION
      self.module :PublishedApi do
        page(:Home) { title 'Published REST certification' }
        entity :Item do
          autonumber :ItemId
          string :Name
        end
        microflow :ListItems do
          return_type list_of('PublishedApi.Item')
          create_list 'PublishedApi.Item', as: :Items
          return_value '$Items'
        end
        microflow :ShowItem do
          parameter :id, type: :Integer
          return_type object_of('PublishedApi.Item')
          retrieve_objects 'PublishedApi.Item', as: :Item,
                                                xpath: '[ItemId = $id]', single: true
          return_value '$Item'
        end
        microflow :CreateItem do
          parameter :name, type: :String
          return_type object_of('PublishedApi.Item')
          create_object 'PublishedApi.Item', as: :Item, commit: true do
            set 'PublishedApi.Item.Name', to: '$name'
          end
          return_value '$Item'
        end
        published_rest_service :ItemsApi,
                               path: 'api/published', version: '1.0',
                               service_name: 'Items API',
                               public_documentation: 'Typed REST certification',
                               enable_cors: true,
                               requires_authentication: false do
          resource :items do
            get :index, path: '', microflow: 'PublishedApi.ListItems'
            get :show, path: '{id}', microflow: 'PublishedApi.ShowItem'
            post :create, path: '', microflow: 'PublishedApi.CreateItem',
                          success_status: :created
          end
        end
      end
      navigation do
        profile :Responsive, home_page: 'PublishedApi.Home', app_title: 'Published REST'
      end
    end
  end
end

PublishedRestFixture.build(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
