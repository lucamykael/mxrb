# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'zip'

# rubocop:disable Metrics/BlockLength
RSpec.describe Mxrb::WidgetPackage do
  def widget_xml(id: 'example.Widget')
    <<~XML
      <widget id="#{id}" supportedPlatform="Web" offlineCapable="true" needsEntityContext="true" pluginWidget="true">
        <name>Example widget</name>
        <description>Package-backed widget</description>
        <helpUrl>https://example.test/help</helpUrl>
        <studioCategory>Data</studioCategory>
        <studioProCategory>Data containers</studioProCategory>
        <properties>
          <propertyGroup caption="General">
            <systemProperty key="Name" />
            <property key="enabled" type="boolean" defaultValue="true"><caption>Enabled</caption></property>
            <property key="disabled" type="boolean"><caption>Disabled</caption></property>
            <property key="count" type="integer" required="false"><caption>Count</caption></property>
            <property key="limit" type="integer" defaultValue="25"><caption>Limit</caption></property>
            <property key="mode" type="enumeration" defaultValue="cards">
              <caption>Mode</caption><description>Presentation mode</description>
              <enumerationValues><enumerationValue key="cards">Cards</enumerationValue></enumerationValues>
            </property>
            <property key="title" type="textTemplate" required="false" multiline="true">
              <caption>Title</caption><translations><translation lang="en_US">Animals</translation></translations>
            </property>
            <property key="subtitle" type="textTemplate" required="false"><caption>Subtitle</caption></property>
            <property key="formula" type="expression" defaultValue="$currentObject/Name"><caption>Formula</caption></property>
            <property key="attribute" type="attribute" isList="true" setLabel="true"
                      isLinked="true" isMetaData="true" selectableObjects="source">
              <caption>Attribute</caption>
              <attributeTypes><attributeType name="String" /></attributeTypes>
              <associationTypes><associationType name="Reference" /></associationTypes>
              <selectionTypes><selectionType name="Single" /></selectionTypes>
            </property>
            <property key="action" type="action" dataSource="source" onChange="changed"
                      defaultType="CallNanoflow">
              <caption>Action</caption><returnType type="Object" assignableTo="context" />
              <actionVariables><actionVariable key="input" caption="Input" type="String" /></actionVariables>
            </property>
            <property key="emptyAction" type="action"><caption>Empty action</caption><returnType /></property>
            <propertyGroup caption="Nested">
              <property key="rows" type="object"><caption>Rows</caption><properties>
                <propertyGroup caption="Row"><property key="label" type="string"><caption>Label</caption></property></propertyGroup>
              </properties></property>
            </propertyGroup>
          </propertyGroup>
        </properties>
      </widget>
    XML
  end

  def write_package(path, xml: widget_xml, manifest: true)
    Zip::File.open(path, create: true) do |zip|
      zip.get_output_stream('widgets/example.xml') { _1.write(xml) }
      next unless manifest

      zip.get_output_stream('package.xml') do |stream|
        stream.write('<package><widgetFiles><widgetFile path="widgets/example.xml" /></widgetFiles></package>')
      end
    end
  end

  def array(value) = Mxrb::IO::BsonCodec.parse_array(value)[:items]

  it 'discovers a widget in installed MPKs and builds its complete Mendix schema' do
    Dir.mktmpdir do |dir|
      widgets = File.join(dir, 'widgets')
      FileUtils.mkdir_p(widgets)
      File.write(File.join(widgets, 'a-broken.mpk'), 'not a zip')
      write_package(File.join(widgets, 'b-example.mpk'))

      definition = described_class.find(dir, 'example.Widget')
      expect(definition).to have_attributes(
        name: 'Example widget', platform: 'Web', offline: true,
        needs_context: true, plugin: true
      )
      expect(definition.properties.map { _1[:key] }).to eq(
        %w[Name enabled disabled count limit mode title subtitle formula attribute action emptyAction rows]
      )
      type, object = described_class.template(definition)
      expect(type).to include(
        'WidgetId' => 'example.Widget', 'WidgetName' => 'Example widget',
        'SupportedPlatform' => 'Web', 'OfflineCapable' => true
      )
      property_types = array(type.dig('ObjectType', 'PropertyTypes'))
      properties = array(object['Properties'])
      expect(property_types.size).to eq(13)
      expect(properties.size).to eq(12)
      by_key = property_types.to_h { [_1['PropertyKey'], _1['ValueType']] }
      expect(by_key.dig('mode', 'EnumerationValues')).not_to eq([2])
      expect(by_key.dig('attribute', 'AllowedTypes')).to eq([1, 'String'])
      expect(by_key.dig('attribute', 'AssociationTypes')).to eq([1, 'Reference'])
      expect(by_key.fetch('attribute')).to include(
        'IsLinked' => true, 'IsMetaData' => true, 'SetLabel' => true,
        'SelectableObjectsProperty' => 'source'
      )
      expect(by_key.dig('action', 'DefaultType')).to eq('CallNanoflow')
      expect(array(by_key.dig('action', 'ActionVariables')).first)
        .to include('Caption' => 'Input', 'Key' => 'input', 'Type' => 'String')
      expect(by_key.dig('action', 'ReturnType')).to include('Type' => 'Object', 'AssignableTo' => 'context')
      expect(by_key.dig('emptyAction', 'ReturnType')).to include('Type' => 'None')
      expect(array(by_key.dig('rows', 'ObjectType', 'PropertyTypes')).first['PropertyKey']).to eq('label')

      values = properties.to_h do |property|
        key = property_types.find { _1['$ID'] == property['TypePointer'] }['PropertyKey']
        [key, property['Value']]
      end
      expect(values.dig('enabled', 'PrimitiveValue')).to eq('true')
      expect(values.dig('disabled', 'PrimitiveValue')).to eq('false')
      expect(values.dig('count', 'PrimitiveValue')).to eq('0')
      expect(values.dig('limit', 'PrimitiveValue')).to eq('25')
      expect(values.dig('title', 'TextTemplate', '$Type')).to eq('Forms$ClientTemplate')
      expect(values.dig('subtitle', 'TextTemplate')).to be_nil
      expect(values.dig('formula', 'Expression')).to eq('$currentObject/Name')
      expect(values.dig('action', 'Expression')).to eq('')
    end
  end

  it 'supports packages without a manifest and returns nil for absent or malformed widgets' do
    Dir.mktmpdir do |dir|
      widgets = File.join(dir, 'widgets')
      FileUtils.mkdir_p(widgets)
      write_package(File.join(widgets, 'plain.mpk'), manifest: false)
      expect(described_class.find(dir, 'example.Widget')).not_to be_nil
      expect(described_class.find(dir, 'missing.Widget')).to be_nil

      malformed = File.join(widgets, 'malformed.mpk')
      write_package(malformed, xml: '<widget')
      expect(described_class.find(dir, 'still.missing')).to be_nil

      blank_first = File.join(widgets, 'blank-first.mpk')
      Zip::File.open(blank_first, create: true) do |zip|
        zip.get_output_stream('blank.xml') { _1.write('') }
        zip.get_output_stream('widget.xml') { _1.write(widget_xml(id: 'after.Blank')) }
      end
      expect(described_class.new(blank_first).definition('after.Blank')).not_to be_nil
    end
  end

  it 'reads direct nested properties without requiring an extra property group' do
    xml = <<~XML
      <widget id="direct.Widget"><name>Direct</name><properties>
        <property key="filters" type="object"><caption>Filters</caption><properties>
          <property key="filterOptions" type="object"><caption>Options</caption><properties>
            <property key="label" type="string"><caption>Label</caption></property>
          </properties></property>
          <systemProperty key="Name" />
        </properties></property>
      </properties></widget>
    XML
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'direct.mpk')
      write_package(path, xml:)
      definition = described_class.new(path).definition('direct.Widget')
      filters = definition.properties.fetch(0)
      options = filters.fetch(:children).fetch(0)
      expect(filters[:children].map { _1[:key] }).to eq(['filterOptions'])
      expect(options[:children].map { _1[:key] }).to eq(['label'])
      expect(options[:category]).to eq('General')
    end
  end

  it 'uses an installed widget schema directly when the writer creates a page widget' do
    Dir.mktmpdir do |dir|
      widgets = File.join(dir, 'widgets')
      FileUtils.mkdir_p(widgets)
      write_package(File.join(widgets, 'example.mpk'))
      writer = Mxrb::Writer.new(File.join(dir, 'project.mpr'), version: '11.12.1', modules: [])
      widget = writer.send(
        :pluggable_widget_doc,
        { type: :pluggable_widget, name: 'Example', events: [],
          options: { properties: { enabled: false } } },
        id: 'example.Widget', name: 'Example', studio_category: 'Data',
        studio_pro_category: 'Data containers'
      )
      writer.send(:hydrate_pluggable_widgets!, { 'Widgets' => [widget] }, {})
      properties = writer.send(:custom_widget_properties, widget)
      expect(properties.dig('enabled', 'Value', 'PrimitiveValue')).to eq('false')
      expect(widget).not_to have_key('__mxrb_widget_options')
    end
  end

  it 'ignores unrelated XML nodes and empty widget definitions defensively' do
    parser = described_class.allocate
    expect(parser.send(:elements, nil, 'widgetFile')).to eq([])
    xml = REXML::Document.new(<<~XML).root
      <widget id="empty.Widget">
        <name>Empty</name><properties><ignored />
          <propertyGroup caption="Outer"><ignored />
            <propertyGroup caption="Inner"><systemProperty key="Name" /><ignored />
              <propertyGroup caption="Deep"><property key="deep" type="string"><caption>Deep</caption></property></propertyGroup>
            </propertyGroup>
          </propertyGroup>
        </properties>
      </widget>
    XML
    definition = parser.send(:build_definition, xml)
    expect(definition.properties.map { _1[:key] }).to eq(%w[Name deep])
    without_properties = REXML::Document.new('<widget id="none"><name>None</name></widget>').root
    expect(parser.send(:build_definition, without_properties).properties).to eq([])
  end
end
# rubocop:enable Metrics/BlockLength
