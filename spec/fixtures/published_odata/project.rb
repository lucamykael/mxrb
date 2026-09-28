# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
# Builds the official-MxBuild witness for a read-only published OData service.
module PublishedODataFixture
  VERSION = '11.12.1'

  module_function

  def build(destination)
    Mxrb.define(destination) do
      mendix_version VERSION
      self.module :PublishedOData do
        module_role :Reader
        page(:Home) do
          title 'Published OData certification'
          allowed_roles 'PublishedOData.Reader'
        end
        entity :Contact do
          string :Email, required: true, unique: true
          string :DisplayName
          access_rule 'PublishedOData.Reader', read: :all
        end
        published_odata_service :ContactsApi,
                                path: 'odata/contacts/',
                                namespace: 'PublishedOData',
                                version: '1.0.0',
                                service_name: 'Contacts API',
                                allowed_roles: ['PublishedOData.Reader'],
                                authentication_types: [:basic],
                                summary: 'Typed OData certification',
                                entity_types: [PublishedODataFixture.contact_type],
                                entity_sets: [PublishedODataFixture.contacts_set]
      end
      security do
        security_level :CheckEverything
        user_role :Reader, module_roles: ['PublishedOData.Reader']
      end
      navigation do
        profile :Responsive, home_page: 'PublishedOData.Home', app_title: 'Published OData'
      end
    end
  end

  def contact_type
    {
      name: 'Contact', entity: 'PublishedOData.Contact',
      members: [
        { kind: :id, name: 'id' },
        {
          kind: :attribute, name: 'Email', attribute: 'Email',
          optional: false, edm_type: 'Edm.String'
        },
        {
          kind: :attribute, name: 'DisplayName', attribute: 'DisplayName',
          edm_type: 'Edm.String'
        }
      ]
    }
  end

  def contacts_set
    {
      name: 'Contacts', entity_type: 'Contact', paging: true, page_size: 100,
      read: :source, insert: :not_supported, update: :not_supported,
      delete: :not_supported, query: { countable: true, skip: true, top: true }
    }
  end
end

PublishedODataFixture.build(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
