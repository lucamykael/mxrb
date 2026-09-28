# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'App Services and Web Services certification' do
  it 'keeps supported consumed and published service contracts stable for two Ruby cycles' do
    Dir.mktmpdir('mxrb-app-web-services-') do |dir|
      current = File.join(dir, 'source.mpr')
      build_source(current)
      baseline_ids = service_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = service_source(exported)
        expect(source).to include(
          'consumed_app_service :DirectoryApi', 'published_web_service :LegacySoapApi',
          'FindPerson', 'LegacyServices.FindPerson'
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'native_fragment(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(service_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
  end

  it 'falls back for unknown service fields and structured published data entities' do
    exporter = Mxrb::Exporter.allocate
    app = service_document(:app)
    web = service_document(:web)
    app_action = app.fetch('Actions')[1]
    web_version = web.fetch('VersionedWebServices')[1]
    web_operation = web_version.fetch('Operations')[1]
    web_parameter = web_operation.fetch('Parameters')[1]

    expect(exporter.send(:semantic_consumed_app_service?, app)).to be(true)
    expect(exporter.send(:semantic_consumed_app_service?, app.merge('Future' => true))).to be(false)
    expect(exporter.send(:semantic_consumed_app_service?, app.merge('Msd' => 'opaque'))).to be(false)
    expect(exporter.send(:semantic_consumed_app_service?, replace(app, 'Actions', 'scalar'))).to be(false)
    bad_action_type = replace(app, 'Actions', app_action.merge('$Type' => 'Future'))
    expect(exporter.send(:semantic_consumed_app_service?, bad_action_type)).to be(false)
    unknown_action = replace(app, 'Actions', app_action.merge('Future' => true))
    expect(exporter.send(:semantic_consumed_app_service?, unknown_action)).to be(false)
    bad_parameter = app_action.merge('Parameters' => [2, 'scalar'])
    expect(exporter.send(:semantic_consumed_app_service?, replace(app, 'Actions', bad_parameter)))
      .to be(false)

    expect(exporter.send(:semantic_published_web_service?, web)).to be(true)
    expect(exporter.send(:semantic_published_web_service?, web.merge('Future' => true))).to be(false)
    expect(exporter.send(:semantic_web_service_version?, 'scalar')).to be(false)
    expect(exporter.send(:semantic_web_service_version?, web_version.merge('$Type' => 'Future')))
      .to be(false)
    expect(exporter.send(:semantic_web_service_operation?, web_operation.merge('Future' => true)))
      .to be(false)
    expect(exporter.send(:semantic_web_service_parameter?, web_parameter.merge('$Type' => 'Future')))
      .to be(false)
    entity = web_operation.fetch('DataEntity')
    expect(exporter.send(:semantic_web_service_data_entity?, entity.merge('Future' => true)))
      .to be(false)
    structured = entity.merge('ChildMembers' => [2, { '$Type' => 'WebServices$Attribute' }])
    expect(exporter.send(:semantic_web_service_data_entity?, structured)).to be(false)

    opaque = declaration_for('AppServices$ConsumedAppService', app.merge('Future' => true))
    declaration = exporter.send(:integration_document_declaration, opaque)
    expect(declaration).to include('native_document :Opaque', 'deep_structure:')
    opaque = declaration_for('WebServices$PublishedService', web.merge('Future' => true))
    declaration = exporter.send(:integration_document_declaration, opaque)
    expect(declaration).to include('native_document :Opaque', 'deep_structure:')
  end

  def build_source(path)
    Mxrb.define(path) do
      mendix_version '7.17.0'
      self.module :LegacyServices do
        consumed_app_service :DirectoryApi,
                             location_constant: 'LegacyServices.DirectoryLocation',
                             timeout: 15,
                             use_timeout: true,
                             actions: [{
                               id: SecureRandom.uuid, name: 'FindPerson',
                               caption: 'Find person', microflow: 'LegacyServices.FindPerson',
                               parameters: [{
                                 id: SecureRandom.uuid, name: 'Email', type: 'String',
                                 can_be_empty: false
                               }],
                               return_type: 'String', return_type_can_be_empty: true
                             }]
        published_web_service :LegacySoapApi, versions: [{
          id: SecureRandom.uuid, caption: 'Legacy SOAP API',
          target_namespace: 'https://example.test/legacy', version: 1,
          operations: [{
            id: SecureRandom.uuid, name: 'FindPerson',
            microflow: 'LegacyServices.FindPerson', image: 'System.Images.Select',
            data_entity: { id: SecureRandom.uuid },
            parameters: [{
              id: SecureRandom.uuid, type: 'String', element_name: 'Email',
              microflow_parameter: 'LegacyServices.FindPerson.Email',
              data_entity: { id: SecureRandom.uuid }
            }],
            return_element_name: 'Result', return_type: 'String',
            return_type_name: 'String'
          }]
        }]
      end
    end
  end

  def service_document(kind)
    builder = Mxrb::Dsl::ModuleBuilder.new(:Services)
    if kind == :app
      builder.consumed_app_service(
        :Api, actions: [{ name: 'Run', parameters: [{ name: 'Value' }] }]
      )
    else
      builder.published_web_service(:Api, versions: [{
        operations: [{ name: 'Run', data_entity: {}, parameters: [{ data_entity: {} }] }]
      }])
    end
    builder.native_documents.fetch(0).fetch(:doc)
  end

  def replace(document, field, value)
    copy = Mxrb::IO::BsonCodec.parse(Mxrb::IO::BsonCodec.serialize(document))
    copy[field] = [2, value]
    copy
  end

  def declaration_for(type, doc)
    {
      type:, name: 'Opaque', id: SecureRandom.uuid, container_id: SecureRandom.uuid,
      containment: 'Documents', doc:
    }
  end

  def service_source(exported)
    Dir[File.join(exported, 'modules', 'LegacyServices', 'infrastructure', '{endpoints,integrations}', '*.rb')]
      .map { File.read(_1) }.join("\n")
  end

  def service_ids(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        next unless %w[
          AppServices$ConsumedAppService WebServices$PublishedService
        ].include?(document['$Type'])

        [document['$Type'], document['Name'], unit['UnitID'].to_s]
      end.sort
    end
  end

  def generate(exported, rebuilt)
    previous = ENV['MXRB_OUTPUT_PATH']
    ENV['MXRB_OUTPUT_PATH'] = rebuilt
    load File.join(exported, 'project.rb')
  ensure
    previous ? ENV['MXRB_OUTPUT_PATH'] = previous : ENV.delete('MXRB_OUTPUT_PATH')
  end
end
# rubocop:enable Metrics/BlockLength, Metrics/MethodLength
