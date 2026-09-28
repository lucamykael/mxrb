# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# rubocop:disable Metrics/BlockLength, Metrics/MethodLength
RSpec.describe 'XSD mapping certification' do
  it 'keeps an XML schema and its mapping references stable for two Ruby cycles' do
    Dir.mktmpdir('mxrb-xsd-certification-') do |dir|
      current = File.join(dir, 'source.mpr')
      build_source(current)
      baseline_ids = xsd_ids(current)

      2.times do |index|
        exported = File.join(dir, "ruby-#{index}")
        rebuilt = File.join(dir, "rebuilt-#{index}.mpr")
        Mxrb::Exporter.new(current, exported).export!
        source = xsd_source(exported)
        expect(source).to include(
          'xml_schema :ContactSchema', ':target_namespace =>', 'example.test/contact', 'xs:schema',
          'import_mapping :ReadContact', 'Schemas.ContactSchema',
          'imported_web_service :ContactSoap', 'wsdl:definitions'
        )
        expect(source).not_to include('native_document', 'deep_structure:', 'native_fragment(')

        generate(exported, rebuilt)
        expect(Mxrb.validate(rebuilt)).to be_valid
        expect(Mxrb.compare(current, rebuilt)).to be_identical
        expect(xsd_ids(rebuilt)).to eq(baseline_ids)
        current = rebuilt
      end
    end
  end

  it 'keeps unknown schema and entry variants in the native fallback' do
    exporter = Mxrb::Exporter.allocate
    valid = schema_document
    entry = valid.fetch('SchemaContentss')[1]
    expect(exporter.send(:semantic_xml_schema?, valid)).to be(true)
    expect(exporter.send(:semantic_xml_schema?, valid.merge('Future' => true))).to be(false)
    expect(exporter.send(:semantic_xml_schema?, replace_entry(valid, 'scalar'))).to be(false)
    future_type = replace_entry(valid, entry.merge('$Type' => 'XmlSchemas$FutureContents'))
    expect(exporter.send(:semantic_xml_schema?, future_type)).to be(false)
    future_field = replace_entry(valid, entry.merge('Future' => true))
    expect(exporter.send(:semantic_xml_schema?, future_field)).to be(false)

    declaration = exporter.send(:integration_document_declaration, {
      type: 'XmlSchemas$XmlSchema', name: 'Opaque', id: SecureRandom.uuid,
      container_id: SecureRandom.uuid, containment: 'Documents',
      doc: valid.merge('Future' => true)
    })
    expect(declaration).to include('native_document :Opaque', 'deep_structure:')
  end

  it 'keeps WSDL services with parsed operations in fallback until modeled' do
    exporter = Mxrb::Exporter.allocate
    valid = web_service_document
    description = valid.fetch('Description')
    expect(exporter.send(:semantic_imported_web_service?, valid)).to be(true)
    expect(exporter.send(:semantic_imported_web_service?, valid.merge('Future' => true)))
      .to be(false)
    expect(exporter.send(:semantic_imported_web_service?, valid.merge('Description' => 'bad')))
      .to be(false)
    parsed_description = description.merge(
      'Services' => [2, { '$Type' => 'WebServices$ServiceInfo' }]
    )
    expect(exporter.send(
             :semantic_imported_web_service?, valid.merge('Description' => parsed_description)
           )).to be(false)
    expect(exporter.send(:semantic_wsdl_entry?, 'bad')).to be(false)
    expect(exporter.send(:semantic_wsdl_entry?, {
      '$Type' => 'WebServices$FutureEntryImpl'
    })).to be(false)
    expect(exporter.send(:semantic_wsdl_schema_entry?, {
      '$Type' => 'XmlSchemas$FutureContents'
    })).to be(false)

    declaration = exporter.send(:integration_document_declaration, {
      type: 'WebServices$ImportedServiceImpl', name: 'OpaqueSoap', id: SecureRandom.uuid,
      container_id: SecureRandom.uuid, containment: 'Documents',
      doc: valid.merge('Future' => true)
    })
    expect(declaration).to include('native_document :OpaqueSoap', 'deep_structure:')
  end

  def build_source(path)
    schema = xsd
    service = wsdl
    Mxrb.define(path) do
      mendix_version '11.12.1'
      self.module :Schemas do
        page(:Home) { title 'XSD certification' }
        xml_schema :ContactSchema, file_path: 'contact.xsd', entries: [{
          id: SecureRandom.uuid, location: 'contact.xsd',
          target_namespace: 'https://example.test/contact', contents: schema
        }]
        import_mapping :ReadContact,
                       json_structure: '', xml_schema: 'Schemas.ContactSchema',
                       xsd_root_element_name: 'Contact', elements: [], excluded: true
        imported_web_service :ContactSoap, excluded: true,
                                           wsdl_url: 'https://example.test/contact?wsdl',
                                           target_namespace: 'https://example.test/contact',
                                           wsdl_entries: [{ contents: service, location: 'contact.wsdl' }],
                                           schema_entries: [{
                                             contents: schema, location: 'contact.xsd',
                                             target_namespace: 'https://example.test/contact'
                                           }]
      end
      navigation do
        profile :Responsive, home_page: 'Schemas.Home', app_title: 'XSD certification'
      end
    end
  end

  def schema_document
    builder = Mxrb::Dsl::ModuleBuilder.new(:Schemas)
    builder.xml_schema(:Schema, entries: [{ contents: xsd }])
    builder.native_documents.fetch(0).fetch(:doc)
  end

  def web_service_document
    builder = Mxrb::Dsl::ModuleBuilder.new(:Schemas)
    builder.imported_web_service(
      :Soap, wsdl_entries: [{ contents: wsdl }],
             schema_entries: [{ contents: xsd }]
    )
    builder.native_documents.fetch(0).fetch(:doc)
  end

  def xsd
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
                 targetNamespace="https://example.test/contact"
                 elementFormDefault="qualified">
        <xs:element name="Contact" type="xs:string"/>
      </xs:schema>
    XML
  end

  def wsdl
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <wsdl:definitions xmlns:wsdl="http://schemas.xmlsoap.org/wsdl/"
                        xmlns:soap="http://schemas.xmlsoap.org/wsdl/soap/"
                        targetNamespace="https://example.test/contact">
        <wsdl:service name="ContactService"/>
      </wsdl:definitions>
    XML
  end

  def replace_entry(document, entry)
    copy = Mxrb::IO::BsonCodec.parse(Mxrb::IO::BsonCodec.serialize(document))
    copy.fetch('SchemaContentss')[1] = entry
    copy
  end

  def xsd_source(exported)
    Dir[File.join(
      exported, 'modules', 'Schemas', 'infrastructure', '{mappings,integrations}', '**', '*.rb'
    )]
      .map { File.read(_1) }.join("\n")
  end

  def xsd_ids(path)
    Mxrb.open(path) do |project|
      project.all_units.filter_map do |unit|
        document = project.parse_bson(unit)
        next unless %w[
          XmlSchemas$XmlSchema ImportMappings$ImportMapping WebServices$ImportedServiceImpl
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
