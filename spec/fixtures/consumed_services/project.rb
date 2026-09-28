# frozen_string_literal: true

require 'mxrb'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
# Builds the official-MxBuild witness for REST calls and consumed OData.
module ConsumedServicesFixture
  VERSION = '11.12.1'
  METADATA = <<~XML
    <?xml version="1.0" encoding="utf-8"?>
    <edmx:Edmx Version="4.0" xmlns:edmx="http://docs.oasis-open.org/odata/ns/edmx">
      <edmx:DataServices>
        <Schema Namespace="Directory" xmlns="http://docs.oasis-open.org/odata/ns/edm">
          <EntityType Name="Person">
            <Key><PropertyRef Name="Id" /></Key>
            <Property Name="Id" Type="Edm.Int64" Nullable="false" />
            <Property Name="Name" Type="Edm.String" />
          </EntityType>
          <EntityContainer Name="Container">
            <EntitySet Name="People" EntityType="Directory.Person" />
          </EntityContainer>
        </Schema>
      </edmx:DataServices>
    </edmx:Edmx>
  XML

  module_function

  def build(destination)
    Mxrb.define(destination) do
      mendix_version VERSION
      self.module :ConsumedServices do
        page(:Home) { title 'Consumed services certification' }
        constant :DirectoryLocation, type: :string,
                                     value: 'https://directory.example.test'
        microflow :FetchDirectory do
          call_rest method: :get,
                    location: 'https://directory.example.test/people/{1}',
                    location_parameters: ["'active'"],
                    result_handling: :http_response,
                    as: :Response,
                    result_entity: 'System.HttpResponse',
                    timeout: '30',
                    error: :continue do
            header 'Accept', "'application/json'"
            header 'X-Correlation-Id', "'mxrb-certification'"
          end
        end
        consumed_odata_service :Directory,
                               service_name: 'Directory',
                               version: '2.0.0',
                               odata_version: 'OData4',
                               metadata: METADATA,
                               metadata_url: 'https://directory.example.test/$metadata',
                               catalog_url: 'https://directory.example.test',
                               timeout_expression: '30',
                               use_query_segment: true,
                               icon_base64: Base64.strict_encode64('icon'),
                               http_configuration_id: SecureRandom.uuid,
                               custom_location: '@ConsumedServices.DirectoryLocation'
      end
      navigation do
        profile :Responsive, home_page: 'ConsumedServices.Home', app_title: 'Consumed services'
      end
    end
  end
end

ConsumedServicesFixture.build(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
