# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
# Builds the official-MxBuild witness for message-backed XML mappings.
module MessageXmlFixture
  VERSION = '11.12.1'

  module_function

  def build(destination)
    Mxrb.define(destination) do
      mendix_version VERSION
      self.module :MessageXml do
        page(:Home) { title 'Message XML certification' }
        entity :Contact do
          string :Email
        end
        message_definition_collection :Contacts do
          entity_message :Contact,
                         id: SecureRandom.uuid,
                         exposed_entity_id: SecureRandom.uuid,
                         entity: 'MessageXml.Contact',
                         exposed_name: 'Contacts',
                         exposed_item_name: 'Contact',
                         original_name: 'Contact',
                         path: 'Contact',
                         max_occurs: 1 do
            exposed_attribute :Email,
                              id: SecureRandom.uuid,
                              attribute: 'MessageXml.Contact.Email',
                              original_name: 'Email',
                              path: 'Contact|Email',
                              primitive_type: :string
          end
        end
        import_mapping :ReadContact,
                       json_structure: '',
                       message_definition: 'MessageXml.Contacts.Contact',
                       elements: [MessageXmlFixture.import_root]
        export_mapping :WriteContact,
                       json_structure: '',
                       message_definition: 'MessageXml.Contacts.Contact',
                       elements: [MessageXmlFixture.export_root]
        microflow :ImportContact do
          parameter :Xml, type: :String
          return_type object_of('MessageXml.Contact')
          import_xml :Xml, mapping: 'MessageXml.ReadContact', as: :Contact,
                           result_entity: 'MessageXml.Contact', single: true
          return_value '$Contact'
        end
        microflow :ExportContact do
          parameter :Contact, type: object_of('MessageXml.Contact')
          return_type :String
          export_xml :Contact, mapping: 'MessageXml.WriteContact', as: :Xml
          return_value '$Xml'
        end
      end
      navigation do
        profile :Responsive, home_page: 'MessageXml.Home', app_title: 'Message XML'
      end
    end
  end

  def import_root
    mapping_root(:create)
  end

  def export_root
    mapping_root(:parameter).merge(backup_handling: :error)
  end

  def mapping_root(object_handling)
    {
      id: SecureRandom.uuid, kind: :object, name: 'Contacts',
      entity: 'MessageXml.Contact', xml_path: 'Contacts|Contact',
      min_occurs: 0, max_occurs: 1, object_handling:,
      children: [{
        id: SecureRandom.uuid, kind: :value, name: 'Email',
        attribute: 'MessageXml.Contact.Email', type: :string,
        type_id: SecureRandom.uuid, primitive: :string,
        xml_path: 'Contacts|Contact|Email', min_occurs: 0, max_occurs: 1
      }]
    }
  end
end

MessageXmlFixture.build(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
# rubocop:enable Metrics/AbcSize, Metrics/BlockLength, Metrics/MethodLength
